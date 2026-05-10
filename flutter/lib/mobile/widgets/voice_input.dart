// Voice input — Tailnet-Whisper helper.
//
// We support two voice providers, selected via the local option
// kOptionVoiceInputProvider:
//
//   - kVoiceProviderAndroid   (default): the existing speech_to_text
//                                       package using the OS recognizer.
//                                       Each call site keeps its own
//                                       speech_to_text instance.
//
//   - kVoiceProviderTailnet            : record audio locally, POST it
//                                       to an OpenAI-compatible Whisper
//                                       endpoint on the tailnet, parse
//                                       the JSON response. Single-flight
//                                       static helper below.
//
// The TailnetVoice helpers are designed to slot into the existing
// start/stop control flow at each call site without forcing a refactor:
//
//   start:  await TailnetVoice.startRecording();
//   stop:   final text = await TailnetVoice.stopAndTranscribe();
//
// Errors and missing config surface as toasts from inside the helper,
// so call sites only need to handle the returned text (null = nothing
// to insert).

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/platform_model.dart';

String currentVoiceProvider() {
  final v = bind.mainGetLocalOption(key: kOptionVoiceInputProvider);
  return v.isEmpty ? kVoiceProviderAndroid : v;
}

class TailnetVoice {
  static final Record _recorder = Record();
  static String? _path;

  /// Begin recording to a temp file. Returns the path on success or
  /// null if permission was denied / recording could not start.
  static Future<String?> startRecording() async {
    if (!await _recorder.hasPermission()) {
      showToast(translate('Microphone permission denied'));
      return null;
    }
    final dir = await getTemporaryDirectory();
    _path =
        '${dir.path}/rustdesk-voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await _recorder.start(
        path: _path!,
        encoder: AudioEncoder.aacLc,
        samplingRate: 16000,
        numChannels: 1,
        bitRate: 32000,
      );
      return _path;
    } catch (e) {
      showToast('Recorder failed: ${_short(e)}');
      _path = null;
      return null;
    }
  }

  /// Stop recording, POST the file to the configured Whisper endpoint,
  /// and return the transcribed text (or null on any failure).
  static Future<String?> stopAndTranscribe() async {
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      showToast('Recorder stop failed: ${_short(e)}');
      return null;
    }
    if (path == null) return null;

    final configured =
        bind.mainGetLocalOption(key: kOptionVoiceInputUrl).trim();
    final url = configured.isEmpty ? kDefaultSttUrl : configured;
    final token = bind.mainGetLocalOption(key: kOptionVoiceInputToken).trim();

    try {
      final req = http.MultipartRequest('POST', Uri.parse(url));
      if (token.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(await http.MultipartFile.fromPath('file', path));
      req.fields['model'] = 'whisper-1';
      req.fields['response_format'] = 'json';

      final streamed =
          await req.send().timeout(const Duration(seconds: 60));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        showToast('Voice service ${streamed.statusCode}');
        return null;
      }
      final j = jsonDecode(body);
      final text = (j['text'] ?? '').toString().trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      showToast('Voice service failed: ${_short(e)}');
      return null;
    } finally {
      _safeDelete(path);
    }
  }

  /// Cancel an in-flight recording (no transcription, no insertion).
  static Future<void> cancel() async {
    try {
      if (await _recorder.isRecording()) {
        final p = await _recorder.stop();
        if (p != null) _safeDelete(p);
      }
    } catch (_) {/* nothing useful to do */}
  }

  static void _safeDelete(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }
}

String currentTtsPlayback() {
  final v = bind.mainGetLocalOption(key: kOptionTtsPlayback);
  return v.isEmpty ? kTtsPlaybackServer : v;
}

/// Tailnet TTS — text in, audio either played at server, returned to
/// tablet, or both. Body matches Warrick's voice-server contract:
/// {text, play_on_server, play_on_source, voice, blocking}.
///
/// "Play at server" path: server speaks, JSON status comes back —
/// works end-to-end. "Play on tablet" path: server returns WAV bytes;
/// tablet playback itself is parked until we vendor an audio-playback
/// path that doesn't trip AGP-7 plugin compat (the same issue that
/// forced `record` back to v4).
class TailnetTts {
  /// Speak [text]. Returns true on success.
  static Future<bool> speak(String text) async {
    if (text.trim().isEmpty) return false;
    final configured = bind.mainGetLocalOption(key: kOptionTtsUrl).trim();
    final url = configured.isEmpty ? kDefaultTtsUrl : configured;
    final token =
        bind.mainGetLocalOption(key: kOptionVoiceInputToken).trim();
    final playback = currentTtsPlayback();

    final playOnServer =
        playback == kTtsPlaybackServer || playback == kTtsPlaybackBoth;
    final playOnSource =
        playback == kTtsPlaybackTablet || playback == kTtsPlaybackBoth;

    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final body = jsonEncode({
        'text': text,
        'play_on_server': playOnServer,
        'play_on_source': playOnSource,
      });
      final resp = await http
          .post(Uri.parse(url), headers: headers, body: body)
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200 && resp.statusCode != 204) {
        showToast('TTS service ${resp.statusCode}');
        return false;
      }
      if (playOnSource) {
        // Server returns the WAV file in resp.bodyBytes.
        // TODO: wire to a tablet audio player. Parked until we land an
        // audioplayers / Kotlin MediaPlayer path that works alongside
        // record 4.4.4 (AGP-7 compatible).
        showToast(
            'TTS audio received (${resp.bodyBytes.length} bytes); '
            'tablet playback not yet wired');
        return playOnServer; // server side still succeeded if both
      }
      return true;
    } catch (e) {
      showToast('TTS service failed: ${TailnetVoice._short(e)}');
      return false;
    }
  }
}
