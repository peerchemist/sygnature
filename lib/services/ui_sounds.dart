import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'app_logger.dart';

enum UiSoundCue {
  coinsReceived,
  signingRequest,
  dkgRequest,
  roastGroupCreated,
  notificationTest,
}

class const _SynthNote({
  required final int midi,
  required final int startMs,
  required final int durationMs,
  final double gain = 1,
});

/// Generates a short mono PCM signal entirely from oscillators and envelopes.
@visibleForTesting
Uint8List generateUiSoundWav(UiSoundCue cue) {
  const sampleRate = 24000;
  final notes = switch (cue) {
    UiSoundCue.coinsReceived => const [
      _SynthNote(midi: 76, startMs: 0, durationMs: 150, gain: 0.8),
      _SynthNote(midi: 83, startMs: 90, durationMs: 230),
    ],
    UiSoundCue.signingRequest => const [
      _SynthNote(midi: 69, startMs: 0, durationMs: 105),
      _SynthNote(midi: 69, startMs: 145, durationMs: 105),
      _SynthNote(midi: 72, startMs: 290, durationMs: 180, gain: 0.9),
    ],
    UiSoundCue.dkgRequest => const [
      _SynthNote(midi: 62, startMs: 0, durationMs: 150, gain: 0.8),
      _SynthNote(midi: 66, startMs: 105, durationMs: 150, gain: 0.9),
      _SynthNote(midi: 69, startMs: 210, durationMs: 220),
    ],
    UiSoundCue.roastGroupCreated => const [
      _SynthNote(midi: 60, startMs: 0, durationMs: 180, gain: 0.72),
      _SynthNote(midi: 64, startMs: 95, durationMs: 190, gain: 0.8),
      _SynthNote(midi: 67, startMs: 190, durationMs: 210, gain: 0.88),
      _SynthNote(midi: 72, startMs: 285, durationMs: 300),
    ],
    UiSoundCue.notificationTest => const [
      _SynthNote(midi: 67, startMs: 0, durationMs: 130, gain: 0.8),
      _SynthNote(midi: 74, startMs: 85, durationMs: 210),
    ],
  };
  final durationMs = notes
      .map((note) => note.startMs + note.durationMs)
      .reduce(math.max);
  final sampleCount = ((durationMs + 35) * sampleRate / 1000).ceil();
  final pcm = Int16List(sampleCount);

  for (var sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
    var mixed = 0.0;
    for (final note in notes) {
      final start = note.startMs * sampleRate ~/ 1000;
      final length = note.durationMs * sampleRate ~/ 1000;
      final position = sampleIndex - start;
      if (position < 0 || position >= length) continue;

      final attack = math.min(1.0, position / (sampleRate * 0.008));
      final release = math.min(
        1.0,
        (length - position) / math.min(sampleRate * 0.045, length / 2),
      );
      final envelope = _smoothStep(attack) * _smoothStep(release);
      final frequency = 440 * math.pow(2, (note.midi - 69) / 12);
      final phase = 2 * math.pi * frequency * position / sampleRate;
      final oscillator = math.sin(phase) + 0.16 * math.sin(phase * 2);
      mixed += note.gain * envelope * oscillator;
    }
    pcm[sampleIndex] = (mixed * 0.38 * 32767).round().clamp(-32768, 32767);
  }

  return _encodePcmWav(pcm, sampleRate);
}

double _smoothStep(double value) => value * value * (3 - 2 * value);

Uint8List _encodePcmWav(Int16List pcm, int sampleRate) {
  const headerLength = 44;
  final bytes = Uint8List(headerLength + pcm.lengthInBytes);
  final data = ByteData.sublistView(bytes);

  bytes.setAll(0, 'RIFF'.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setAll(8, 'WAVE'.codeUnits);
  bytes.setAll(12, 'fmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setAll(36, 'data'.codeUnits);
  data.setUint32(40, pcm.lengthInBytes, Endian.little);
  for (var index = 0; index < pcm.length; index++) {
    data.setInt16(headerLength + index * 2, pcm[index], Endian.little);
  }
  return bytes;
}

/// Short, non-blocking audio cues for wallet and ROAST events.
///
/// Audio is optional: an unavailable output device must never stop the user
/// from using the wallet.
class UiSounds({SoLoud? audio}) {
  final SoLoud _audio = audio ?? SoLoud.instance;

  final Map<UiSoundCue, AudioSource> _sources = {};
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

      for (final cue in UiSoundCue.values) {
        _sources[cue] = await _audio.loadMem(
          'sygnature-${cue.name}.wav',
          generateUiSoundWav(cue),
        );
        if (_disposed) return;
      }
      _ready = true;
    } catch (error, stackTrace) {
      AppLogger.warn(
        'UI sounds unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      await _releaseAudio();
    }
  }

  void coinsReceived({double volume = 0.5}) =>
      _play(UiSoundCue.coinsReceived, volume);

  void signingRequest({double volume = 0.5}) =>
      _play(UiSoundCue.signingRequest, volume);

  void dkgRequest({double volume = 0.5}) =>
      _play(UiSoundCue.dkgRequest, volume);

  void roastGroupCreated({double volume = 0.5}) =>
      _play(UiSoundCue.roastGroupCreated, volume);

  void notificationTest({double volume = 0.5}) =>
      _play(UiSoundCue.notificationTest, volume);

  void _play(UiSoundCue cue, double volume) =>
      unawaited(_playWhenReady(cue, volume));

  Future<void> _playWhenReady(UiSoundCue cue, double volume) async {
    await init();
    if (!_ready || _disposed) return;

    try {
      _audio.play(_sources[cue]!, volume: 0.7 * volume.clamp(0.0, 1.0));
    } catch (error, stackTrace) {
      AppLogger.warn(
        'Unable to play UI sound',
        error: error,
        stackTrace: stackTrace,
      );
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
      for (final source in _sources.values) {
        try {
          await _audio.disposeSource(source);
        } catch (_) {
          // The engine may already have released sources during shutdown.
        }
      }
      if (_ownsEngine) await _audio.deinitAsync();
    }
    _sources.clear();
  }
}
