import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/ui_sounds.dart';

void main() {
  test('generated cues are valid, audible, and distinct PCM WAV signals', () {
    final fingerprints = <int>{};

    final levels = <double>[];
    for (final cue in UiSoundCue.values) {
      final wav = generateUiSoundWav(cue);
      final data = ByteData.sublistView(wav);

      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(data.getUint32(4, Endian.little), wav.length - 8);
      expect(data.getUint16(20, Endian.little), 1);
      expect(data.getUint16(22, Endian.little), 1);
      expect(data.getUint32(24, Endian.little), 24000);
      expect(data.getUint16(34, Endian.little), 16);
      expect(data.getUint32(40, Endian.little), wav.length - 44);

      var audibleSamples = 0;
      var peak = 0;
      var energy = 0.0;
      var fingerprint = 2166136261;
      for (var offset = 44; offset < wav.length; offset += 2) {
        final sample = data.getInt16(offset, Endian.little);
        if (sample != 0) audibleSamples++;
        peak = math.max(peak, sample.abs());
        energy += sample * sample;
        fingerprint = (fingerprint ^ sample) * 16777619 & 0xffffffff;
      }
      expect(audibleSamples, greaterThan(1000));
      expect(peak / 32768, lessThanOrEqualTo(0.701));
      expect((wav.length - 44) / 48, inInclusiveRange(250, 500));
      expect(data.getInt16(44, Endian.little), 0);
      expect(wav.sublist(wav.length - 1200), everyElement(0));
      levels.add(math.sqrt(energy / ((wav.length - 44) ~/ 2)) / 32768);
      fingerprints.add(fingerprint);
    }

    // The preview deliberately uses the signing-request cue.
    expect(fingerprints, hasLength(UiSoundCue.values.length - 1));
    expect(levels.reduce(math.max) / levels.reduce(math.min), lessThan(1.26));
  });

  test('preview matches signing and notes decay rather than sustain', () {
    final wav = generateUiSoundWav(UiSoundCue.signingRequest);
    expect(generateUiSoundWav(UiSoundCue.notificationTest), wav);
    final data = ByteData.sublistView(wav);
    double energy(int startMs, int endMs) {
      var sum = 0.0;
      for (var i = startMs * 24; i < endMs * 24; i++) {
        final sample = data.getInt16(44 + i * 2, Endian.little);
        sum += sample * sample;
      }
      return sum;
    }

    expect(energy(20, 60), greaterThan(energy(80, 120) * 3));
  });

  testWidgets('retries failed initialization after a cooldown', (tester) async {
    final audio = _FakeAudio()..initFailures = 1;
    final sounds = UiSounds(audio: audio);
    sounds.coinsReceived();
    await tester.pump();
    expect(audio.initCalls, 1);
    expect(audio.played, isEmpty);
    await tester.pump(const Duration(milliseconds: 601));
    sounds.coinsReceived();
    await tester.pump();
    expect(audio.initCalls, 1);
    await tester.pump(const Duration(seconds: 3));
    sounds.coinsReceived();
    await tester.pump();
    expect(audio.initCalls, 2);
    expect(audio.played, [UiSoundCue.coinsReceived]);
    await _dispose(tester, sounds, audio);
  });

  testWidgets('coalesces startup bursts and keeps the approval request', (
    tester,
  ) async {
    final audio = _FakeAudio()..initGate = Completer<void>();
    final sounds = UiSounds(audio: audio);
    sounds.coinsReceived();
    sounds.coinsReceived();
    sounds.signingRequest();
    sounds.roastGroupCreated();
    expect(audio.initCalls, 1);
    audio.initGate!.complete();
    await tester.pump();
    expect(audio.played, [UiSoundCue.signingRequest]);
    audio.live.clear();
    sounds.signingRequest();
    await tester.pump();
    expect(audio.played, hasLength(1));
    await tester.pump(const Duration(milliseconds: 600));
    sounds.signingRequest();
    await tester.pump();
    expect(audio.played, hasLength(2));
    await _dispose(tester, sounds, audio);
  });

  testWidgets(
    'approval fades and replaces an informational cue without overlap',
    (tester) async {
      final audio = _FakeAudio();
      final sounds = UiSounds(audio: audio);
      sounds.coinsReceived();
      await tester.pump();
      sounds.signingRequest();
      await tester.pump();
      expect(audio.fades, 1);
      expect(audio.played, [UiSoundCue.coinsReceived]);
      await tester.pump(const Duration(milliseconds: 20));
      expect(audio.played, [
        UiSoundCue.coinsReceived,
        UiSoundCue.signingRequest,
      ]);
      expect(audio.maxLive, 1);
      sounds.dkgRequest();
      sounds.roastGroupCreated();
      await tester.pump();
      expect(audio.played, hasLength(2));
      await _dispose(tester, sounds, audio);
    },
  );

  testWidgets('recovers asynchronous device failure with bounded retries', (
    tester,
  ) async {
    final audio = _FakeAudio()..startFailures = 1;
    final sounds = UiSounds(audio: audio);
    sounds.coinsReceived();
    await tester.pump();
    audio.failures.add(AudioDeviceStartFailure.deviceUnavailable);
    await tester.pump();
    expect(audio.startCalls, 1);
    expect(audio.live, isEmpty);
    sounds.signingRequest();
    await tester.pump();
    expect(audio.startCalls, 1);
    expect(audio.played, hasLength(1));
    await tester.pump(const Duration(seconds: 3));
    sounds.signingRequest();
    await tester.pump();
    expect(audio.startCalls, 2);
    expect(audio.played.last, UiSoundCue.signingRequest);
    await _dispose(tester, sounds, audio);
    expect(audio.failures.hasListener, isFalse);
  });

  testWidgets('disposal during initialization releases audio without playing', (
    tester,
  ) async {
    final audio = _FakeAudio()..initGate = Completer<void>();
    final sounds = UiSounds(audio: audio);
    sounds.coinsReceived();
    final disposal = sounds.dispose();
    audio.initGate!.complete();
    await tester.pump();
    await disposal;
    sounds.signingRequest();
    await tester.pump();
    expect(audio.played, isEmpty);
    expect(audio.deinitCalls, 1);
    await _dispose(tester, sounds, audio);
  });

  testWidgets('muted or invalid volume does not initialize audio', (
    tester,
  ) async {
    final audio = _FakeAudio();
    final sounds = UiSounds(audio: audio);
    for (final volume in [0.0, -1.0, double.nan, double.infinity]) {
      sounds.notificationTest(volume: volume);
    }
    await tester.pump();
    expect(audio.initCalls, 0);
    await _dispose(tester, sounds, audio);
  });

  testWidgets('releases its sources but preserves a borrowed engine', (
    tester,
  ) async {
    final audio = _FakeAudio()..initialized = true;
    final sounds = UiSounds(audio: audio);
    sounds.notificationTest(volume: 2);
    await tester.pump();
    expect(audio.volumes, [1.0]);
    await _dispose(tester, sounds, audio);
    expect(audio.disposedSources, hasLength(UiSoundCue.values.length));
    expect(audio.initCalls, 0);
    expect(audio.deinitCalls, 0);
  });
}

Future<void> _dispose(
  WidgetTester tester,
  UiSounds sounds,
  _FakeAudio audio,
) async {
  // Stream cancellation may complete outside the widget test's fake clock.
  await tester.runAsync(() async {
    await sounds.dispose();
    await audio.failures.close();
  });
}

class _FakeSource(final UiSoundCue cue) implements AudioSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAudio implements SoLoud {
  final failures = StreamController<AudioDeviceStartFailure>.broadcast(
    sync: true,
  );
  final played = <UiSoundCue>[];
  final volumes = <double>[];
  final live = <SoundHandle>{};
  final disposedSources = <AudioSource>[];
  bool initialized = false;
  int initFailures = 0;
  int startFailures = 0;
  int initCalls = 0;
  int startCalls = 0;
  int deinitCalls = 0;
  int fades = 0;
  int maxLive = 0;
  Completer<void>? initGate;

  @override
  bool get isInitialized => initialized;

  @override
  Stream<AudioDeviceStartFailure> get audioDeviceStartFailures =>
      failures.stream;

  Future<void> _init() async {
    initCalls++;
    if (initFailures-- > 0) {
      throw StateError('Synthetic initialization failure');
    }
    await initGate?.future;
    initialized = true;
  }

  @override
  Future<void> startAudioDevice() async {
    startCalls++;
    if (startFailures-- > 0) throw StateError('Synthetic device failure');
  }

  @override
  bool getIsValidVoiceHandle(SoundHandle handle) => live.contains(handle);

  @override
  Future<void> stop(SoundHandle handle) async => live.remove(handle);

  @override
  void fadeVolume(SoundHandle handle, double to, Duration time) => fades++;

  @override
  Future<void> disposeSource(AudioSource source) async {
    disposedSources.add(source);
    live.clear();
  }

  @override
  Future<void> deinitAsync() async {
    deinitCalls++;
    initialized = false;
  }

  // Forward only the large optional-argument APIs used by this service.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #init:
        return _init();
      case #loadMem:
        final path = invocation.positionalArguments.first as String;
        return Future<AudioSource>.value(
          _FakeSource(
            UiSoundCue.values.singleWhere(
              (cue) => path == 'sygnature-${cue.name}.wav',
            ),
          ),
        );
      case #play:
        played.add((invocation.positionalArguments.first as _FakeSource).cue);
        volumes.add(invocation.namedArguments[#volume] as double);
        final handle = SoundHandle(played.length);
        live.add(handle);
        maxLive = math.max(maxLive, live.length);
        return handle;
      default:
        return super.noSuchMethod(invocation);
    }
  }
}
