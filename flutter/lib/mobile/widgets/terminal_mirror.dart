// TerminalMirror — live read-only mirror of Mother's VS Code terminal,
// via the alexandria-mother-bridge SSE endpoint (Slice 3.5).
//
// Wire format locked in:
//   C:\WorkerB\proposals\bridge-terminal-stream.md (addendum 2026-05-12)
//
// Source URL is configurable via kOptionTerminalStreamUrl; default
// points at the mockstream on msi while W1 builds the real SSE
// endpoint on the bridge. Swap the option to the real bridge URL when
// it ships — no widget code change.
//
// Strict slice scope:
//   - HTTP SSE only (no WebSocket).
//   - Rolling 500-line buffer.
//   - ListView.builder, monospace.
//   - Auto-scroll-to-bottom unless the user scrolls up.
//   - ANSI strip-only on render (colour rendering is a follow-up).
//   - Reconnect on disconnect: 1s, 2s, 4s, 8s, 16s, 30s (capped).
//   - Subscribe on mount, dispose on unmount.
//   - Last-Event-ID header on reconnect for replay.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../consts.dart';
import '../../models/platform_model.dart';

class TerminalMirror extends StatefulWidget {
  /// Optional explicit terminal name. If null, the configured URL is
  /// used as-is (so an operator override can specify `?name=` or omit
  /// it for all-terminals).
  final String? terminalName;

  const TerminalMirror({Key? key, this.terminalName}) : super(key: key);

  @override
  State<TerminalMirror> createState() => _TerminalMirrorState();
}

class _TerminalMirrorState extends State<TerminalMirror> {
  static const int _maxLines = 500;
  static const List<int> _backoffSeq = [1, 2, 4, 8, 16, 30];
  static final RegExp _ansi = RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]');

  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  String _partial = '';
  String? _lastEventId;
  bool _connected = false;
  String? _lastError;
  bool _userScrolledUp = false;
  int _backoffIdx = 0;

  http.Client? _client;
  StreamSubscription<List<int>>? _sub;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrolled);
    _connect();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScrolled);
    _scroll.dispose();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _client?.close();
    super.dispose();
  }

  String _resolvedUrl() {
    final raw =
        bind.mainGetLocalOption(key: kOptionTerminalStreamUrl).trim();
    return raw.isEmpty ? kDefaultTerminalStreamUrl : raw;
  }

  void _onScrolled() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
    if (_userScrolledUp == atBottom) {
      setState(() => _userScrolledUp = !atBottom);
    }
  }

  Future<void> _connect() async {
    _sub?.cancel();
    _client?.close();
    _reconnectTimer?.cancel();

    final url = _resolvedUrl();
    if (url.isEmpty) {
      _scheduleReconnect('no URL configured');
      return;
    }

    final client = http.Client();
    _client = client;
    final req = http.Request('GET', Uri.parse(url));
    req.headers['Accept'] = 'text/event-stream';
    if (_lastEventId != null) {
      req.headers['Last-Event-ID'] = _lastEventId!;
    }

    http.StreamedResponse resp;
    try {
      resp = await client.send(req);
    } catch (e) {
      _scheduleReconnect(_short(e));
      return;
    }

    if (resp.statusCode != 200) {
      _scheduleReconnect('HTTP ${resp.statusCode}');
      return;
    }

    if (!mounted) {
      client.close();
      return;
    }
    setState(() {
      _connected = true;
      _lastError = null;
      _backoffIdx = 0;
    });

    final buffer = StringBuffer();
    _sub = resp.stream.listen(
      (chunk) {
        buffer.write(utf8.decode(chunk, allowMalformed: true));
        _drainBuffer(buffer);
      },
      onError: (e) => _scheduleReconnect(_short(e)),
      onDone: () => _scheduleReconnect('stream closed'),
      cancelOnError: true,
    );
  }

  void _drainBuffer(StringBuffer buf) {
    while (true) {
      final s = buf.toString();
      final boundary = s.indexOf('\n\n');
      if (boundary < 0) return;
      final frame = s.substring(0, boundary);
      buf.clear();
      buf.write(s.substring(boundary + 2));
      _handleFrame(frame);
    }
  }

  void _handleFrame(String frame) {
    String? id;
    final dataLines = <String>[];
    for (final line in frame.split('\n')) {
      if (line.startsWith('id:')) {
        id = line.substring(3).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (dataLines.isEmpty) return;
    final dataStr = dataLines.join('\n');
    if (id != null && id.isNotEmpty) {
      _lastEventId = id;
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(dataStr) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = json['type'] as String?;
    switch (type) {
      case 'data':
        final raw = (json['data'] ?? '').toString();
        _appendRaw(_ansi.allMatches(raw).isEmpty ? raw : raw.replaceAll(_ansi, ''));
        break;
      case 'open':
        _appendSystemLine('-- ${json['terminal'] ?? ''} opened --');
        break;
      case 'close':
        _appendSystemLine('-- ${json['terminal'] ?? ''} closed --');
        break;
      case 'rename':
        _appendSystemLine(
            '-- renamed: ${json['renamed_from'] ?? '?'} -> ${json['terminal'] ?? '?'} --');
        break;
      case 'lag':
        _appendSystemLine('-- lag: dropped ${json['dropped'] ?? '?'} frames --');
        break;
      case 'ping':
        break; // keep-alive only
    }
  }

  void _appendRaw(String text) {
    if (text.isEmpty) return;
    final combined = _partial + text;
    final parts = combined.split('\n');
    _partial = parts.removeLast();
    if (parts.isEmpty && _partial.isEmpty) return;
    setState(() {
      for (final p in parts) {
        _lines.add(p);
      }
      _trim();
    });
    _autoScrollSoon();
  }

  void _appendSystemLine(String line) {
    if (_partial.isNotEmpty) {
      setState(() {
        _lines.add(_partial);
        _partial = '';
      });
    }
    setState(() {
      _lines.add(line);
      _trim();
    });
    _autoScrollSoon();
  }

  void _trim() {
    while (_lines.length > _maxLines) {
      _lines.removeAt(0);
    }
  }

  void _autoScrollSoon() {
    if (_userScrolledUp) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _scheduleReconnect(String reason) {
    _sub?.cancel();
    _client?.close();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _lastError = reason;
    });
    final delay = _backoffSeq[_backoffIdx];
    _backoffIdx = (_backoffIdx + 1).clamp(0, _backoffSeq.length - 1);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (mounted) _connect();
    });
  }

  String _short(Object e) {
    final s = e.toString();
    return s.length > 80 ? '${s.substring(0, 77)}...' : s;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Column(
        children: [
          _headerBar(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _headerBar() {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.black54,
      child: Row(
        children: [
          Icon(
            _connected ? Icons.terminal : Icons.cloud_off,
            color: _connected ? Colors.greenAccent : Colors.amberAccent,
            size: 12,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _connected
                  ? 'terminal · live'
                  : 'reconnecting${_lastError != null ? " · ${_lastError!}" : ""}',
              style: const TextStyle(color: Colors.white70, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_userScrolledUp)
            InkWell(
              onTap: () {
                _userScrolledUp = false;
                _autoScrollSoon();
                setState(() {});
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'jump ↓',
                  style: TextStyle(color: Colors.cyanAccent, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_lines.isEmpty && _partial.isEmpty) {
      return Center(
        child: Text(
          _connected ? 'waiting for output...' : 'connecting...',
          style: const TextStyle(color: Colors.white24, fontSize: 11),
        ),
      );
    }
    final total = _lines.length + (_partial.isEmpty ? 0 : 1);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      itemCount: total,
      itemBuilder: (ctx, i) {
        final text = i < _lines.length ? _lines[i] : _partial;
        return Text(
          text.isEmpty ? ' ' : text,
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.25,
          ),
        );
      },
    );
  }
}
