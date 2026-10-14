import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/ui_sounds.dart';

void main() {
  test('generated cues are valid, audible, and distinct PCM WAV signals', () {
    final fingerprints = <int>{};

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
      var fingerprint = 2166136261;
      for (var offset = 44; offset < wav.length; offset += 2) {
        final sample = data.getInt16(offset, Endian.little);
        if (sample != 0) audibleSamples++;
        fingerprint = (fingerprint ^ sample) * 16777619 & 0xffffffff;
      }
      expect(audibleSamples, greaterThan(1000));
      fingerprints.add(fingerprint);
    }

    expect(fingerprints, hasLength(UiSoundCue.values.length));
  });
}
