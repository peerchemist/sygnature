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
      _SynthNote(midi: 76, startMs: 0, durationMs: 130, gain: 0.8),
      _SynthNote(midi: 81, startMs: 85, durationMs: 180),
    ],
    // The settings preview uses a real approval cue at its actual level.
    UiSoundCue.signingRequest || UiSoundCue.notificationTest => const [
      _SynthNote(midi: 69, startMs: 0, durationMs: 160, gain: 0.9),
      _SynthNote(midi: 69, startMs: 165, durationMs: 190),
    ],
    UiSoundCue.dkgRequest => const [
      _SynthNote(midi: 62, startMs: 0, durationMs: 160, gain: 0.8),
      _SynthNote(midi: 66, startMs: 110, durationMs: 160, gain: 0.9),
      _SynthNote(midi: 69, startMs: 220, durationMs: 180),
    ],
    UiSoundCue.roastGroupCreated => const [
      _SynthNote(midi: 62, startMs: 0, durationMs: 180, gain: 0.72),
      _SynthNote(midi: 66, startMs: 70, durationMs: 180, gain: 0.8),
      _SynthNote(midi: 69, startMs: 140, durationMs: 190, gain: 0.88),
      _SynthNote(midi: 74, startMs: 210, durationMs: 220),
    ],
  };
  final durationMs = notes
      .map((note) => note.startMs + note.durationMs)
      .reduce(math.max);
  final sampleCount = ((durationMs + 25) * sampleRate / 1000).ceil();
  final mixed = Float64List(sampleCount);

  for (final note in notes) {
    final start = note.startMs * sampleRate ~/ 1000;
    final length = note.durationMs * sampleRate ~/ 1000;
    final frequency = 440 * math.pow(2, (note.midi - 69) / 12);
    final phaseStep = 2 * math.pi * frequency / sampleRate;
    final releaseLength = math.min(sampleRate * 0.04, length / 2);
    final decayStep = math.exp(-3 / length);
    final harmonicDecayStep = math.exp(-7 / length);
    var decay = 1.0;
    var harmonic = 0.22;

    for (var position = 0; position < length; position++) {
      final attack = math.min(1.0, position / (sampleRate * 0.006));
      final release = math.min(1.0, (length - 1 - position) / releaseLength);
      final envelope = _smoothStep(attack) * _smoothStep(release) * decay;
      final phase = phaseStep * position;
      final oscillator = math.sin(phase) + harmonic * math.sin(phase * 2);
      mixed[start + position] += note.gain * envelope * oscillator;
      decay *= decayStep;
      harmonic *= harmonicDecayStep;
    }
  }

  // Match energy across cues while preserving headroom for their transients.
  var peak = 0.0;
  var energy = 0.0;
  for (final sample in mixed) {
    peak = math.max(peak, sample.abs());
    energy += sample * sample;
  }
  final gain = math.min(0.16 / math.sqrt(energy / sampleCount), 0.7 / peak);
  final pcm = Int16List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    pcm[i] = (mixed[i] * gain * 32767).round().clamp(-32768, 32767);
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
  final Map<UiSoundCue, Timer> _recentCues = {};
  Future<void>? _initialization;
  Future<void>? _playTask;
  Future<void>? _recovery;
  StreamSubscription<AudioDeviceStartFailure>? _deviceFailures;
  Timer? _retryTimer;
  ({UiSoundCue cue, double volume})? _pending;
  ({UiSoundCue cue, SoundHandle handle})? _active;
  bool _deviceNeedsStart = false;
  bool _ownsEngine = false;
  bool _ready = false;
  bool _disposed = false;

  Future<void> init() {
    if (_disposed || _ready || _retryTimer != null) {
      return Future<void>.value();
    }
    return _initialization ??= _initialize().whenComplete(() {
      _initialization = null;
    });
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
      _deviceFailures = _audio.audioDeviceStartFailures.listen((failure) {
        if (_disposed) return;
        _deviceNeedsStart = true;
        unawaited(_recoverDevice());
      });
    } catch (error, stackTrace) {
      AppLogger.warn(
        'UI sounds unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      _cooldown();
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

  static int _priority(UiSoundCue cue) => switch (cue) {
    UiSoundCue.signingRequest || UiSoundCue.dkgRequest => 1,
    _ => 0,
  };

  void _play(UiSoundCue cue, double volume) {
    if (_disposed ||
        !volume.isFinite ||
        volume <= 0 ||
        _recentCues.containsKey(cue)) {
      return;
    }
    _recentCues[cue] = Timer(const Duration(milliseconds: 600), () {
      _recentCues.remove(cue);
    });
    final pending = _pending;
    if (pending == null || _priority(cue) >= _priority(pending.cue)) {
      _pending = (cue: cue, volume: volume.clamp(0.0, 1.0));
    }
    _startPlayback();
  }

  void _startPlayback() {
    _playTask ??= _playWhenReady().whenComplete(() {
      _playTask = null;
      if (_pending != null && !_disposed) _startPlayback();
    });
  }

  Future<void> _playWhenReady() async {
    try {
      await init();
      if (_deviceNeedsStart) await _recoverDevice();
      if (!_ready || _disposed || _deviceNeedsStart) {
        _pending = null;
        return;
      }
      while (_pending != null && !_disposed) {
        final request = _pending!;
        _pending = null;
        final active = _active;
        if (active != null && _audio.getIsValidVoiceHandle(active.handle)) {
          // Do not build up a queue of stale notifications. Approval requests
          // may gently interrupt an informational cue; other overlaps drop.
          if (_priority(request.cue) <= _priority(active.cue)) continue;
          _audio.fadeVolume(active.handle, 0, const Duration(milliseconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await _audio.stop(active.handle);
          if (_disposed) return;
        }
        final handle = _audio.play(
          _sources[request.cue]!,
          volume: request.volume,
        );
        _active = (cue: request.cue, handle: handle);
      }
    } catch (error, stackTrace) {
      _pending = null;
      AppLogger.warn(
        'Unable to play UI sound',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _cooldown() {
    if (_disposed || _retryTimer != null) return;
    _retryTimer = Timer(const Duration(seconds: 3), () => _retryTimer = null);
  }

  Future<void> _recoverDevice() =>
      _recovery ??= _restartDevice().whenComplete(() {
        _recovery = null;
      });

  Future<void> _restartDevice() async {
    if (_disposed || !_ready || _retryTimer != null) return;
    _cooldown();
    try {
      await _audio.startAudioDevice();
      _deviceNeedsStart = false;
    } catch (error, stackTrace) {
      AppLogger.warn(
        'UI audio device unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      // A failed output device can retain a valid voice. Do not replay that
      // stale notification when a later event successfully restarts the device.
      final active = _active;
      _active = null;
      if (active != null) {
        try {
          await _audio.stop(active.handle);
        } catch (_) {
          // The engine may have already invalidated the voice.
        }
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pending = null;
    _retryTimer?.cancel();
    for (final timer in _recentCues.values) {
      timer.cancel();
    }
    _recentCues.clear();
    await _initialization;
    await _playTask;
    await _recovery;
    await _releaseAudio();
  }

  Future<void> _releaseAudio() async {
    _ready = false;
    await _deviceFailures?.cancel();
    _deviceFailures = null;
    _active = null;
    _deviceNeedsStart = false;
    if (_audio.isInitialized) {
      for (final source in _sources.values) {
        try {
          await _audio.disposeSource(source);
        } catch (_) {
          // The engine may already have released sources during shutdown.
        }
      }
      if (_ownsEngine) {
        try {
          await _audio.deinitAsync();
        } catch (error, stackTrace) {
          AppLogger.warn(
            'Unable to release UI audio',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }
    _sources.clear();
    _ownsEngine = false;
  }
}
