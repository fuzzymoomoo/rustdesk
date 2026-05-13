// Cockpit substrate — layout shell + dictation panel.
//
// This is the SUBSTRATE for the mobile cockpit (per Prof's review of the
// cockpit-architecture brief, 2026-05-09). Strict no-bridge-consumers rule:
// the dictation panel's Send button currently falls back to the existing
// RustDesk session input pipe (sessionInputString). When the
// vscode-mother-bridge ships and passes its end-to-end smoke test, a
// follow-up swaps the Send target to the bridge endpoint.
//
// Three layout modes:
//   - Full RD       : existing remote-desktop view fills the screen.
//   - Cockpit       : cockpit panel covers the RD viewport. RD continues
//                     decoding underneath (Stack), so swapping back to
//                     Full RD is instant — no reconnect.
//   - Split         : 50/50 vertical split, RD on top, cockpit below.
//
// PiP overlay (small floating RD when in Cockpit mode) is deliberately
// deferred to v2 — keeping v1 small enough to smoke-test the layout shell.

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:webview_flutter/webview_flutter.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'bridge_client.dart';
import 'command_sheet.dart';
import 'terminal_mirror.dart';
import 'voice_input.dart';

enum CockpitLayout { fullRD, cockpit, split, code }

/// Reactive layout mode shared across the remote page.
class CockpitState {
  static final Rx<CockpitLayout> mode = CockpitLayout.fullRD.obs;
}

/// Mode-switcher strip. Renders as a thin top bar with three buttons.
class CockpitModeBar extends StatelessWidget {
  const CockpitModeBar({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final current = CockpitState.mode.value;
      return Material(
        color: MyTheme.accent,
        elevation: 4,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 36,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _btn('Full RD', Icons.fullscreen, CockpitLayout.fullRD, current),
                _btn('Cockpit', Icons.dashboard, CockpitLayout.cockpit, current),
                _btn('Split', Icons.splitscreen, CockpitLayout.split, current),
                _btn('Code', Icons.code, CockpitLayout.code, current),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _btn(String label, IconData icon, CockpitLayout target,
      CockpitLayout current) {
    final selected = current == target;
    return TextButton.icon(
      onPressed: () => CockpitState.mode.value = target,
      icon: Icon(icon,
          color: selected ? Colors.white : Colors.white70, size: 16),
      label: Text(label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          )),
      style: TextButton.styleFrom(
        backgroundColor: selected ? Colors.white24 : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// Picks the right body for the current layout mode.
///
/// All sub-trees stay alive across mode swaps so nothing reloads:
///   - [rdBody] always sits in the Stack (hidden via Offstage when
///     in Code mode) so the RustDesk session keeps its decoder + auth.
///   - [CodeTab] is lazily built the first time the user visits Code
///     mode, then kept in the tree (Offstage when other modes are
///     active) so the embedded WebView preserves its page state.
class CockpitLayoutSwitcher extends StatefulWidget {
  final Widget rdBody;
  final SessionID sessionId;
  const CockpitLayoutSwitcher({
    Key? key,
    required this.rdBody,
    required this.sessionId,
  }) : super(key: key);

  @override
  State<CockpitLayoutSwitcher> createState() => _CockpitLayoutSwitcherState();
}

class _CockpitLayoutSwitcherState extends State<CockpitLayoutSwitcher> {
  Widget? _codeTab;

  Widget _rdLayout(CockpitLayout mode) {
    switch (mode) {
      case CockpitLayout.fullRD:
      case CockpitLayout.code:
        return widget.rdBody;
      case CockpitLayout.cockpit:
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.rdBody,
            Positioned.fill(
                child: CockpitPanel(sessionId: widget.sessionId)),
          ],
        );
      case CockpitLayout.split:
        return Column(
          children: [
            Expanded(child: widget.rdBody),
            Container(height: 1, color: Colors.white24),
            Expanded(child: CockpitPanel(sessionId: widget.sessionId)),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final mode = CockpitState.mode.value;
      if (mode == CockpitLayout.code) _codeTab ??= const CodeTab();
      // RD body can be Offstage when hidden — the FFI session is
      // independent of widget paint.
      //
      // The WebView is different: Android pauses it as soon as the
      // native view is detached from the window (which Offstage does),
      // which closes any live WebSocket — fatal for VS Code remote.
      // So once the Code tab has been built, keep it painted at
      // opacity 0.001: still invisible to the eye, but the Android
      // WebView keeps its surface attached and the JS engine + sockets
      // stay alive.
      return Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: mode == CockpitLayout.code,
            child: _rdLayout(mode),
          ),
          if (_codeTab != null)
            Opacity(
              opacity: mode == CockpitLayout.code ? 1.0 : 0.001,
              child: IgnorePointer(
                ignoring: mode != CockpitLayout.code,
                child: _codeTab!,
              ),
            ),
        ],
      );
    });
  }
}

/// Code tab — an embedded WebView pointed at a user-configured URL.
/// The widget is built once and kept alive (via Offstage at the parent
/// layout switcher) so swapping modes does not reload the page. A small
/// top bar exposes refresh + edit-URL.
class CodeTab extends StatefulWidget {
  const CodeTab({Key? key}) : super(key: key);

  @override
  State<CodeTab> createState() => _CodeTabState();
}

class _CodeTabState extends State<CodeTab> {
  late final WebViewController _controller;
  String _loadedUrl = '';

  String _savedUrl() {
    final v = bind.mainGetLocalOption(key: kOptionCodeTabUrl).trim();
    return v.isEmpty ? kDefaultCodeTabUrl : v;
  }

  @override
  void initState() {
    super.initState();
    _loadedUrl = _savedUrl();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(_loadedUrl));
  }

  Future<void> _refresh() async {
    final saved = _savedUrl();
    if (saved != _loadedUrl) {
      _loadedUrl = saved;
      await _controller.loadRequest(Uri.parse(saved));
      setState(() {});
    } else {
      await _controller.reload();
    }
  }

  Future<void> _editUrl() async {
    final ctrl = TextEditingController(text: _savedUrl());
    final newUrl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(translate('Code tab URL')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(translate('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(translate('OK')),
          ),
        ],
      ),
    );
    if (newUrl == null || newUrl.isEmpty) return;
    await bind.mainSetLocalOption(key: kOptionCodeTabUrl, value: newUrl);
    _loadedUrl = newUrl;
    await _controller.loadRequest(Uri.parse(newUrl));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 36,
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.refresh,
                    color: Colors.white70, size: 18),
                tooltip: 'Reload',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: _refresh,
              ),
              Expanded(
                child: GestureDetector(
                  onTap: _editUrl,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      _loadedUrl,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit,
                    color: Colors.white70, size: 18),
                tooltip: 'Edit URL',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: _editUrl,
              ),
            ],
          ),
        ),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    );
  }
}

/// The cockpit panel itself. v1 hosts the dictation buffer and a
/// "bridge not yet connected" notice. Extra panels (Claude state, worker
/// status, cha_os, Hades cycles) land here once the bridge is ready.
class CockpitPanel extends StatelessWidget {
  final SessionID sessionId;
  const CockpitPanel({Key? key, required this.sessionId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            color: Colors.black54,
            child: Row(
              children: [
                const SizedBox(width: 4),
                const Icon(Icons.dashboard, color: Colors.white70, size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Cockpit',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_command_key,
                      color: Colors.white70, size: 18),
                  tooltip: 'Commands',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () => showCommandSheet(context),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: const TerminalMirror(terminalName: 'claude'),
          ),
          Container(height: 1, color: Colors.white12),
          Expanded(
            flex: 1,
            child: DictationPanel(sessionId: sessionId),
          ),
        ],
      ),
    );
  }
}

/// Dictation buffer — voice → STT → editable text → Send.
///
/// In the substrate, Send falls back to RustDesk's existing
/// sessionInputString (toast confirms the fallback path). Once the
/// vscode-mother-bridge lands, swap Send to POST /claude/prompt.
class DictationPanel extends StatefulWidget {
  final SessionID sessionId;
  const DictationPanel({Key? key, required this.sessionId}) : super(key: key);

  @override
  State<DictationPanel> createState() => _DictationPanelState();
}

class _DictationPanelState extends State<DictationPanel> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final TextEditingController _ctrl = TextEditingController();
  bool _ready = false;
  bool _listening = false;

  @override
  void dispose() {
    _speech.cancel();
    TailnetVoice.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _appendToBuffer(String text) {
    final cur = _ctrl.text.trim();
    final next = cur.isEmpty ? text : '$cur $text';
    _ctrl.text = next;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
  }

  Future<void> _ensureReady() async {
    if (_ready) return;
    _ready = await _speech.initialize(
      onStatus: (s) {
        if (s == 'notListening' || s == 'done') {
          if (mounted) setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!_ready) showToast(translate('Voice input unavailable'));
  }

  Future<void> _toggleMic() async {
    final tailnet = currentVoiceProvider() == kVoiceProviderTailnet;
    if (_listening) {
      if (tailnet) {
        final text = await TailnetVoice.stopAndTranscribe();
        if (mounted) setState(() => _listening = false);
        if (text != null && text.isNotEmpty) _appendToBuffer(text);
      } else {
        await _speech.stop();
        if (mounted) setState(() => _listening = false);
      }
      return;
    }
    if (tailnet) {
      final path = await TailnetVoice.startRecording();
      if (path != null && mounted) setState(() => _listening = true);
      return;
    }
    await _ensureReady();
    if (!_ready) return;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        if (r.finalResult && r.recognizedWords.isNotEmpty) {
          _appendToBuffer(r.recognizedWords);
        }
      },
      listenMode: stt.ListenMode.dictation,
      partialResults: false,
    );
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    final preview =
        text.length > 40 ? '${text.substring(0, 40)}…' : text;

    if (BridgeClient.isConfigured()) {
      // Slice 2 happy path: focus the active editor on Mother's laptop
      // then type the buffer into it via the bridge.
      final result = await BridgeClient.focusAndSend(text);
      if (result.ok) {
        showToast('Sent via bridge: "$preview"');
        _ctrl.clear();
        return;
      }
      // Surface what went wrong, then fall back to RD so the dictation
      // isn't lost. Common 409 cause: no editor focused on the laptop.
      final code = result.statusCode ?? 'no-response';
      showToast('Bridge $code: ${result.error ?? "unknown"} — falling back to RD');
    }

    // Pre-bridge fallback (or bridge unreachable / not configured):
    // route via the existing RustDesk session input pipe.
    bind.sessionInputString(sessionId: widget.sessionId, value: text);
    showToast('Sent via RD: "$preview"');
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.black26,
                hintText: 'Tap mic to dictate, edit before sending…',
                hintStyle: const TextStyle(color: Colors.white54),
                border: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                isDense: true,
                contentPadding: const EdgeInsets.all(8),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: _toggleMic,
                icon: Icon(
                  _listening ? Icons.mic : Icons.mic_none,
                  color: _listening ? Colors.redAccent : Colors.white,
                ),
                tooltip: 'Toggle dictation',
              ),
              TextButton.icon(
                onPressed: () => _ctrl.clear(),
                icon: const Icon(Icons.clear, color: Colors.white70),
                label: const Text('Clear',
                    style: TextStyle(color: Colors.white70)),
              ),
              ElevatedButton.icon(
                onPressed: _send,
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Send'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: MyTheme.accent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
