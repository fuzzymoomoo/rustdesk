// Bridge client — talks to alexandria-mother-bridge over the tailnet/LAN.
//
// Contract per the bridge's README + src/handlers/input.ts:
//
//   POST /input        body: {text: string}   header: X-Cockpit-Tier: write
//   POST /cmd/<id>     body: {args?: any[]}   header: X-Cockpit-Tier: write
//   GET  /state                                no auth
//
// Every write/destructive call needs:
//   X-Cockpit-Token : <64-hex-char token>
//   X-Cockpit-Tier  : write
//
// Recommended request flow for voice-input (slice 2):
//   1. /cmd/workbench.action.focusActiveEditorGroup
//   2. /input { text }
//
// Errors of note:
//   401 token_invalid              — token wrong/rotated; surface, fall back
//   403 tier_mismatch              — header missing/lower than required
//   403 command_not_allowlisted    — not in v1 allowlist (ADD-1)
//   409 state_mismatch             — no editor focused; pre-focus and retry
//   503 bridge_unavailable         — audit log degraded; nothing the client can do
//
// /input text is never logged verbatim — only length + hash-8. The client
// does not need to handle redaction.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../consts.dart';
import '../../models/platform_model.dart';

class BridgeResult {
  final bool ok;
  final int? statusCode;
  final String? error;
  final dynamic body;
  const BridgeResult.success(this.body)
      : ok = true,
        statusCode = 200,
        error = null;
  const BridgeResult.failure(this.statusCode, this.error)
      : ok = false,
        body = null;
}

class BridgeClient {
  static String url() {
    final v = bind.mainGetLocalOption(key: kOptionBridgeUrl).trim();
    return v.isEmpty ? kDefaultBridgeUrl : v;
  }

  static String token() =>
      bind.mainGetLocalOption(key: kOptionBridgeToken).trim();

  static bool isConfigured() => token().isNotEmpty;

  static Map<String, String> _writeHeaders() => {
        'Content-Type': 'application/json',
        'X-Cockpit-Token': token(),
        'X-Cockpit-Tier': 'write',
      };

  /// GET /state — editor + workspace snapshot. No auth required.
  static Future<BridgeResult> getState() async {
    try {
      final resp = await http
          .get(Uri.parse('${url()}/state'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        return BridgeResult.failure(resp.statusCode, _shortBody(resp.body));
      }
      return BridgeResult.success(jsonDecode(resp.body));
    } catch (e) {
      return BridgeResult.failure(null, _short(e));
    }
  }

  /// POST /cmd/{commandId}. v1 commands are write-tier.
  static Future<BridgeResult> runCommand(String commandId,
      {List<dynamic>? args}) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${url()}/cmd/$commandId'),
            headers: _writeHeaders(),
            body: jsonEncode({if (args != null) 'args': args}),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return BridgeResult.failure(resp.statusCode, _shortBody(resp.body));
      }
      return BridgeResult.success(_safeJson(resp.body));
    } catch (e) {
      return BridgeResult.failure(null, _short(e));
    }
  }

  /// POST /input — type the given text into the focused editor.
  /// Bridge enforces a 4096-char cap; client trims to that for safety.
  static Future<BridgeResult> sendInput(String text) async {
    final trimmed = text.length > 4096 ? text.substring(0, 4096) : text;
    try {
      final resp = await http
          .post(
            Uri.parse('${url()}/input'),
            headers: _writeHeaders(),
            body: jsonEncode({'text': trimmed}),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return BridgeResult.failure(resp.statusCode, _shortBody(resp.body));
      }
      return BridgeResult.success(_safeJson(resp.body));
    } catch (e) {
      return BridgeResult.failure(null, _short(e));
    }
  }

  /// Recommended flow for the voice-input-preview slice: pre-focus the
  /// active editor group, then send the text. Surfaces the first
  /// non-ok result (typically state_mismatch or token_invalid).
  static Future<BridgeResult> focusAndSend(String text) async {
    final focus =
        await runCommand('workbench.action.focusActiveEditorGroup');
    if (!focus.ok) return focus;
    return sendInput(text);
  }

  static dynamic _safeJson(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  static String _shortBody(String body) {
    if (body.isEmpty) return '';
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}
