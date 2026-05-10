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

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

enum CockpitLayout { fullRD, cockpit, split }

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
/// In Cockpit mode the [rdBody] stays in the tree underneath the cockpit
/// panel — both keep their state, so swapping modes does not reconnect
/// the RD session.
class CockpitLayoutSwitcher extends StatelessWidget {
  final Widget rdBody;
  final SessionID sessionId;
  const CockpitLayoutSwitcher({
    Key? key,
    required this.rdBody,
    required this.sessionId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final mode = CockpitState.mode.value;
      switch (mode) {
        case CockpitLayout.fullRD:
          return rdBody;
        case CockpitLayout.cockpit:
          // RD continues rendering underneath; cockpit obscures it visually.
          return Stack(
            fit: StackFit.expand,
            children: [
              rdBody,
              Positioned.fill(child: CockpitPanel(sessionId: sessionId)),
            ],
          );
        case CockpitLayout.split:
          return Column(
            children: [
              Expanded(child: rdBody),
              Container(height: 1, color: Colors.white24),
              Expanded(child: CockpitPanel(sessionId: sessionId)),
            ],
          );
      }
    });
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.black54,
            child: Row(
              children: [
                const Icon(Icons.dashboard, color: Colors.white70, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cockpit (substrate — bridge not yet connected)',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: DictationPanel(sessionId: sessionId)),
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
    _ctrl.dispose();
    super.dispose();
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
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    await _ensureReady();
    if (!_ready) return;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        if (r.finalResult && r.recognizedWords.isNotEmpty) {
          final cur = _ctrl.text.trim();
          final next =
              cur.isEmpty ? r.recognizedWords : '$cur ${r.recognizedWords}';
          _ctrl.text = next;
          _ctrl.selection =
              TextSelection.collapsed(offset: _ctrl.text.length);
        }
      },
      listenMode: stt.ListenMode.dictation,
      partialResults: false,
    );
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    bind.sessionInputString(sessionId: widget.sessionId, value: text);
    final preview =
        text.length > 40 ? '${text.substring(0, 40)}…' : text;
    showToast('Sent via RD (bridge fallback): "$preview"');
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
