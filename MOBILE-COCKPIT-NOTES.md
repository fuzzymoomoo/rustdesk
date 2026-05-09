# RustDesk Mobile → Alexandria Cockpit Notes

Author: Worker B (msi, Sonnet 4.6)
Date: 2026-05-09
Branch: `worker-b/quick-keys-and-stt` on `https://github.com/fuzzymoomoo/rustdesk`
Audience: dev on the other side (Mother / work-laptop Opus 4.7)

This is a one-shot brief: what we built today + the cockpit vision Warrick laid out. Use as inspiration; come back with the concrete brief for me.

---

## 1. What's done — committed to `worker-b/quick-keys-and-stt`

Two commits on top of upstream tag `1.4.6`:

- `81031be` — `fix(flutter): repair Dart 3.5 type-promotion errors in toolbar`
  Two leftover parameter-reassignments in `flutter/lib/common/widgets/toolbar.dart` that broke compilation under Dart 3.5+ flow analysis. Real upstream-PR-shaped fix.

- `23dabf7` — `feat(mobile): add quick-key buttons (1/2/Enter) and voice-to-text mic`

### The four new buttons

Live in the bottom toolbar of `flutter/lib/mobile/pages/remote_page.dart` (`getBottomAppBar()`), gated by the same "keyboard available" condition as the existing Keyboard button. Visible whenever a remote keyboard is in scope.

| # | Icon | Action | FFI call |
|---|---|---|---|
| 1 | `Icons.looks_one` | Send literal `1` | `bind.sessionInputString(sessionId, '1')` |
| 2 | `Icons.looks_two` | Send literal `2` | `bind.sessionInputString(sessionId, '2')` |
| 3 | `Icons.keyboard_return` | Send Enter | `inputModel.inputKey('VK_ENTER')` |
| 4 | `Icons.mic` / `mic_none` | Voice → text | Android `SpeechRecognizer` via `speech_to_text` package, then `sessionInputString(transcript)` |

### Voice input behaviour

Two modes, configurable via `Settings → Voice input mode` (radio):

- **Push-to-talk (default):** long-press the mic to record while held, release to finalise.
- **Toggle:** tap to start, tap again to stop.

Both modes:
- Mic icon turns red while listening.
- Final transcript only (partial results disabled) — no half-formed words sneaking in.
- Engine lazily initialised on first use; permission prompt fires then. `RECORD_AUDIO` already declared in manifest from voice-call feature.
- Stopped + cancelled in `dispose()`.

**Double-tap the mic** flips between PTT and Toggle without leaving the screen, with toast confirmation.

Why drop the multi-mode (Whisper-on-msi / cloud) plan: Claude Code is exceptionally tolerant of transcription quirks. For dictating natural-language prompts, Android `SpeechRecognizer` is genuinely good. The dictation buffer also makes it review-and-Enter rather than fire-and-forget. Whisper local + cloud were over-engineered for the use case. Available as future modes if we hit accuracy walls.

### Settings entry

In `flutter/lib/mobile/pages/settings_page.dart` under `enhancementsTiles`, just above "Keep screen on". Uses the same `_getPopupDialogRadioEntry` widget, persists via `bind.mainSetLocalOption(key: kOptionVoiceInputMode, value: ...)`.

Constants live in `flutter/lib/consts.dart`:
```dart
const String kOptionVoiceInputMode = "voice-input-mode";
const String kVoiceInputModePtt = "ptt";
const String kVoiceInputModeToggle = "toggle";
```

---

## 2. Build infrastructure (so you don't waste a day rediscovering)

The official 1.4.6 source-from-clean-clone won't build on Windows without setup. Captured here for posterity:

### Toolchain landed on msi
- Flutter 3.24.5 (pinned to match RustDesk CI) at `C:\flutter`
- JDK 17 (Temurin 17.0.19) at `C:\Users\fuzzy\jdk17` — JBR 21 from Android Studio is too new for Gradle 7.6.4
- LLVM 22.1.5 at `C:\Program Files\LLVM` — needed for `flutter_rust_bridge_codegen` (libclang)
- Rust stable + `cargo-expand 1.0.95` + `flutter_rust_bridge_codegen 1.80.1` + `rustfmt`
- Android cmdline-tools at `$ANDROID_HOME/cmdline-tools/latest/`
- Android platform 34 + build-tools 34.0.0
- `flutter config --jdk-dir "$HOME/jdk17"` — Flutter overrides `JAVA_HOME` with Android Studio's JBR otherwise

Source these via `C:\Fuzzy\rustDesk\env.sh` (sourced at the top of every bash session).

### The lift-the-.so trick — saves ~3GB of Android NDK + Rust Android targets + vcpkg

Our changes are pure Dart/Flutter; the Rust core (`librustdesk.so`) doesn't need rebuilding. So:

1. `unzip lib/{arm64-v8a,armeabi-v7a}/libc++_shared.so lib/{arm64-v8a,armeabi-v7a}/librustdesk.so` from a 1.4.6 release APK.
2. Drop into `flutter/android/app/src/main/jniLibs/<abi>/`.
3. `jniLibs` is gitignored — won't pollute the repo.
4. Gradle picks up jniLibs automatically when packaging.
5. `flutter build apk --debug --target-platform android-arm64` rebuilds only the Dart layer.
6. First build: ~10 min (Gradle plugin pull). Subsequent: ~30 sec.

If you ever touch the Rust core, you need full NDK + Rust Android targets + vcpkg + ~3 GB of native deps. Until then, the lift trick is the iteration loop.

### Side note on `cargo metadata`
RustDesk's `flutter/android/app/build.gradle` shells out to `cargo metadata` to find the `rustls-platform-verifier-android` Maven dir. That works without compiling Rust *as long as* the crate registry has been populated (one `cargo metadata --format-version 1` from the repo root suffices).

### Two pre-existing bugs in 1.4.6 source

1. The Dart 3.5 type-promotion errors in `toolbar.dart` (fixed in this branch).
2. `flutter/lib/generated_bridge.dart` is gitignored and not present in the source tree — needs `flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h` from the repo root after a fresh clone.

---

## 3. Install on a tablet

```
adb uninstall com.carriez.flutter_hbb       # if official is installed
adb install --bypass-low-target-sdk-block flutter/build/app/outputs/flutter-apk/app-debug.apk
```

Debug builds are signed with the debug keystore — different from upstream's release signature, so `-r` reinstall fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Uninstall first. Loses saved server config; takes ~30 sec to re-enter.

---

## 4. The cockpit vision — Warrick's brainstorm, raw

Verbatim from this morning's thinking:

> layout control, show just claude view, show just editor view, show labyrinth easily, simplify browsing alexandria, the library, using hades, hephaestus for remote use, worker status in rustdesk ui, run a fork of labyrinth directly in the rustdesk UI, fork of hephaestus directly in rustdesk (just monitoring, and test deployment surfaces), ctrl shift p menu directly in rustdesk, move claude voice input preview into rustdesk, expand the rustdesk ui so it's functional — when we use eg hades, the "remote desktop view" becomes a tab or little preview window

The thread underneath: today the RustDesk Android app is **a window into the remote desktop**. The vision is a **mobile cockpit for the Alexandria stack** where the remote-desktop view is one panel among many — and arguably not the most important one most of the time.

---

## 5. How I see these working — technical sketches (NOT a decided plan)

### The architectural pivot

RustDesk's mobile UI is currently a 1:1 viewer over a single `FFI` session. To become a cockpit, the screen layout needs to host:

- The remote-desktop preview (existing `remote_page.dart` content, but resizable / dockable)
- An embedded view of *some* Alexandria service (Labyrinth / Hephaestus / Hades / Claude)
- A toolbar layer that's context-aware (knows what panel you're in)

Easiest path: a **`PanelHost` widget** that swaps between modes — Full Remote / Split / Service-Primary — driven by user gestures (the existing collapse arrow already exists at line 571 of remote_page.dart, expand vertically into a tab strip).

### Embedding Alexandria services

Two viable channels for getting a service's UI into the RustDesk app:

1. **WebView panel.** If Labyrinth / Hephaestus expose web UIs (which I assume they do given they're internal tools), Flutter's `webview_flutter` plugin can render them inside a tab. Pros: zero new UI code per service; whatever you build in the browser shows up. Cons: native gesture polish absent; auth needs to be threaded through.

2. **Native Flutter panel + JSON API.** Each service exposes a small REST/WS endpoint; the Android app has a hand-rolled Flutter view per service. Pros: perfect fit, native feel. Cons: every service needs Android-side code.

Recommended hybrid: WebView for monitoring/observation surfaces (Hephaestus dashboards, Labyrinth navigation) where polish doesn't matter much; native Flutter for the high-frequency interactions (Claude approve/deny, voice preview, worker status).

### Worker status in RustDesk UI

Native panel. Tablet polls/subscribes to a small endpoint on Mother (work-laptop) at e.g. `100.85.254.38:port/workers` returning JSON like:
```json
{
  "workers": [
    {"id": "A", "host": "fuzzyone", "status": "idle", "last_task": "..."},
    {"id": "B", "host": "msi", "status": "running", "last_task": "rustdesk button work"}
  ]
}
```
Render as a vertical strip with state badges. Long-press a worker to inspect last activity / kill / message.

### VS Code extension bridge (Ctrl+Shift+P, Claude voice preview, approve/deny)

This is where the keystroke-only model genuinely runs out of road. A small VS Code extension on the remote exposing a bridge API:

- `POST /cmd/{commandId}` → executes a registered VS Code command (`workbench.action.showCommands`, `claude.approve`, `claude.submit`)
- `POST /input` → sends text to the active editor / Claude prompt
- `GET /state` → returns current focus context, active file, Claude state
- `GET /claude/voice-preview` → after voice STT, the extension can show a preview overlay in the IDE before submission

Tablet calls these over Tailscale (`100.81.194.125:vsport` for Worker A, etc.). RustDesk's keystroke pipe stays for everything else (any non-VS-Code app).

The Ctrl+Shift+P button on the toolbar would call `POST /cmd/workbench.action.showCommands` — instant, no focus-and-keystroke guesswork. Even better: tablet then displays the command palette's filterable list as a native Flutter sheet, the user picks, the result fires `POST /cmd/<id>`.

### Claude voice input preview moved into RustDesk

Today: voice → text → directly inserted via `sessionInputString`. No chance to review.

Better: voice → text → **shown in a dictation buffer panel on the tablet** with edit + send buttons → on send, transmitted via the VS Code extension (or `sessionInputString` if no extension available) → then optionally Enter.

The buffer panel can sit at the bottom of the tablet screen above the keyboard, leaving the remote-desktop preview visible. Long dictations of multi-sentence prompts become reviewable.

### "Show just Claude view / show just editor view"

This is layout presets. The VS Code extension can drive the IDE's own commands:
- `workbench.action.toggleSidebarVisibility`
- `workbench.action.toggleAuxiliaryBar`
- `editor.action.maximizeEditorGroup`

Plus RustDesk-side viewport hints — the tablet asks the extension "what's the current Claude panel rect?" and crops the remote view to that, simulating zoom-and-pan automatically.

### Hades / Labyrinth / Hephaestus tabs

Each as either:
- WebView panel pointed at the service's HTTP UI
- Or native Flutter panel calling the service's API

Hades especially: the read-cycle exhibits we've been producing are JSON. A native Flutter "cycles" tab on the tablet reading those JSON exhibits straight from the council fixtures (or via a small Hades read endpoint) gives a phone-friendly governance view.

---

## 6. Sequence I'd build in (biggest bang per unit of work)

1. **VS Code extension bridge skeleton.** Endpoints `/cmd`, `/input`, `/state`. Two days. Unblocks half the rest.
2. **Voice-input-preview panel.** Move STT result into a tablet-side buffer with edit/send. Two days. Immediate quality-of-life win for Claude dictation.
3. **Ctrl+Shift+P button + native command palette sheet.** Calls `/cmd/workbench.action.showCommands`, pulls the result into a native sheet. Half a day after step 1.
4. **Worker status panel.** Tablet polls Mother's worker endpoint. One day.
5. **Layout shell with two-panel split.** Remote-desktop on top, embedded service WebView on bottom. Drag divider. Two days.
6. **Hades read-cycles native tab.** JSON in, scrollable list out. One day.
7. **Hephaestus / Labyrinth WebView tabs.** Half a day each once layout shell is done.

Tabs (multi-session) we explicitly parked as too lofty for the current arc.

---

## 7. Open questions for the dev on the other side

- **Where do Labyrinth and Hephaestus live?** If they're not yet network-exposed, what does the deployment surface look like? I can sketch the Flutter side from any URL once they have one.
- **VS Code extension hosting.** Build it as a separate repo (`vscode-rustdesk-bridge`?) or a folder in this fork (`tools/vscode-bridge/`)? My instinct: separate repo, easier life cycle.
- **Tailscale identity vs auth.** Tailnet membership is reasonable trust for unrolled-out services. Want a token layer on top before any of this leaves the tailnet?
- **Worker B's role in this.** Happy to keep building on the RustDesk side. The VS Code extension I can bootstrap if you want it on this branch, or you can hand it off.
- **Tabs (lofty goal).** Still parked, or revisit once layout shell exists?

---

## 8. Where to look in the code

- Bottom toolbar: [flutter/lib/mobile/pages/remote_page.dart:486](flutter/lib/mobile/pages/remote_page.dart#L486) — `getBottomAppBar()`
- Mic state + helpers: [flutter/lib/mobile/pages/remote_page.dart:84](flutter/lib/mobile/pages/remote_page.dart#L84) — added in `_RemotePageState`
- Settings entry: [flutter/lib/mobile/pages/settings_page.dart:644](flutter/lib/mobile/pages/settings_page.dart#L644) — `enhancementsTiles.add(...)`
- Constants: [flutter/lib/consts.dart:136](flutter/lib/consts.dart#L136)
- Toolbar Dart-3.5 fix: [flutter/lib/common/widgets/toolbar.dart:541](flutter/lib/common/widgets/toolbar.dart#L541)

Branch on GitHub: `https://github.com/fuzzymoomoo/rustdesk/tree/worker-b/quick-keys-and-stt`
Diff against 1.4.6: `https://github.com/fuzzymoomoo/rustdesk/compare/1.4.6...worker-b/quick-keys-and-stt`
