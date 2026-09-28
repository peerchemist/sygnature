import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

/// Short, non-blocking audio cues for successful UI actions.
///
/// Audio is optional: an unavailable output device must never stop the user
/// from using the wallet.
class UiSounds({SoLoud? audio}) {
  final SoLoud _audio = audio ?? SoLoud.instance;

  AudioSource? _low;
  AudioSource? _high;
  Future<void>? _initialization;
  bool _ownsEngine = false;
  bool _ready = false;
  bool _disposed = false;

  Future<void> init() {
    if (_disposed || _ready) return Future<void>.value();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      _ownsEngine = !_audio.isInitialized;
      if (_ownsEngine) {
        await _audio.init(
          linuxAudioBackend:
              !kIsWeb && defaultTargetPlatform == TargetPlatform.linux
              ? LinuxAudioBackend.pulseAudio
              : LinuxAudioBackend.auto,
        );
      }
      if (_disposed) return;

      _low = await _audio.loadWaveform(WaveForm.sin, false, 1, 0);
      if (_disposed) return;
      _high = await _audio.loadWaveform(WaveForm.sin, false, 1, 0);
      if (_disposed) return;

      _audio.setWaveformFreq(_low!, 660);
      _audio.setWaveformFreq(_high!, 990);
      _ready = true;
    } catch (error, stackTrace) {
      debugPrint('UI sounds unavailable: $error\n$stackTrace');
      await _releaseAudio();
    }
  }

  /// Plays a soft ascending two-note confirmation without blocking the UI.
  void message({double volume = 0.5}) => unawaited(_playMessage(volume));

  Future<void> _playMessage(double volume) async {
    await init();
    if (!_ready || _disposed) return;

    try {
      final now = _audio.getEngineTime();
      _audio.playScheduled(
        _low!,
        now,
        duration: const Duration(milliseconds: 90),
        volume: 0.36 * volume.clamp(0.0, 1.0),
      );
      _audio.playScheduled(
        _high!,
        now + const Duration(milliseconds: 65),
        duration: const Duration(milliseconds: 140),
        volume: 0.315 * volume.clamp(0.0, 1.0),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to play UI sound: $error\n$stackTrace');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _initialization;
    await _releaseAudio();
  }

  Future<void> _releaseAudio() async {
    _ready = false;
    if (_audio.isInitialized) {
      for (final source in [_low, _high]) {
        if (source != null) {
          try {
            await _audio.disposeSource(source);
          } catch (_) {
            // The engine may already have released sources during shutdown.
          }
        }
      }
      if (_ownsEngine) await _audio.deinitAsync();
    }
    _low = null;
    _high = null;
  }
}
