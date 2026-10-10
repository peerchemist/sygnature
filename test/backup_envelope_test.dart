import 'dart:typed_data';
import 'dart:convert';

import 'package:coinlib/coinlib.dart' show bytesToHex, hexToBytes;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/backup_envelope.dart';

// Independently generated with argon2-cffi (v1.3) and PyNaCl/libsodium.
const syntheticBackupVector =
    '524f41535442414b010101000100000000000301000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262780df443a76c32b93641f04e893c8239e754d579dd1c2b74b5023f769045c00b2176daf3b132c195a3d7e6d669b8f4691fc0d9a4c02fe7f4009cb503c9e74';
const syntheticPassphrase = 'synthetic backup 🔐';
const syntheticPlaintext =
    'a46667726f757073806777616c6c657473806a637265617465645f6174006e736368656d615f76657273696f6e01';

void main() {
  test(
    'independent default Argon2id and XChaCha20 envelope known answer',
    () async {
      final plaintext = await BackupEnvelope.decrypt(
        hexToBytes(syntheticBackupVector),
        syntheticPassphrase,
      );
      expect(bytesToHex(plaintext), syntheticPlaintext);
      final key =
          await DartArgon2id(
            memory: 65536,
            iterations: 3,
            parallelism: 1,
            hashLength: 32,
          ).deriveKey(
            secretKey: SecretKeyData(utf8.encode(syntheticPassphrase)),
            nonce: List.generate(16, (i) => i),
          );
      expect(
        bytesToHex(Uint8List.fromList(await key.extractBytes())),
        '15479c7cda408971c7d9329ddc7762931436f536daf097e0b300ce0a5f79381e',
      );
      key.destroy();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'successful round trip and fresh salt/nonce for identical exports',
    () async {
      final p = hexToBytes(syntheticPlaintext);
      final a = await BackupEnvelope.encrypt(p, ' passphrase with spaces ');
      final b = await BackupEnvelope.encrypt(p, ' passphrase with spaces ');
      expect(a.sublist(20, 36), isNot(b.sublist(20, 36)));
      expect(a.sublist(36, 60), isNot(b.sublist(36, 60)));
      expect(await BackupEnvelope.decrypt(a, ' passphrase with spaces '), p);
      expect(
        () => BackupEnvelope.decrypt(a, 'passphrase with spaces'),
        throwsFormatException,
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  for (final offset in [20, 36, 60, 121]) {
    test(
      'authentication rejects altered header/ciphertext/tag at $offset',
      () async {
        final file = hexToBytes(syntheticBackupVector);
        file[offset] ^= 1;
        await expectLater(
          BackupEnvelope.decrypt(file, syntheticPassphrase),
          throwsFormatException,
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
  test('wrong passphrase rejected', () async {
    await expectLater(
      BackupEnvelope.decrypt(hexToBytes(syntheticBackupVector), 'wrong'),
      throwsFormatException,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
  test('strict envelope lengths and algorithms rejected before deriving', () {
    final original = hexToBytes(syntheticBackupVector);
    for (final length in [0, 8, 59, 60, 75, 76]) {
      expect(
        () => BackupEnvelope.decrypt(
          Uint8List.sublistView(original, 0, length),
          '',
        ),
        throwsFormatException,
      );
    }
    for (final offset in [0, 8, 9, 10]) {
      final file = Uint8List.fromList(original)..[offset] = 255;
      expect(() => BackupEnvelope.decrypt(file, ''), throwsFormatException);
    }
    for (final (memory, rounds, lanes) in [
      (0, 3, 1),
      (65535, 3, 1),
      (262145, 3, 1),
      (65536, 0, 1),
      (65536, 11, 1),
      (65536, 3, 0),
      (65536, 3, 255),
    ]) {
      final file = Uint8List.fromList(original)..[19] = lanes;
      ByteData.sublistView(file)
        ..setUint32(11, memory)
        ..setUint32(15, rounds);
      expect(() => BackupEnvelope.decrypt(file, ''), throwsFormatException);
    }
    expect(
      () => BackupEnvelope.decrypt(
        Uint8List(BackupEnvelope.maxFileBytes + 1),
        '',
      ),
      throwsFormatException,
    );
  });
  test('truncated authenticated payload rejected', () async {
    final file = hexToBytes(syntheticBackupVector);
    await expectLater(
      BackupEnvelope.decrypt(
        Uint8List.sublistView(file, 0, file.length - 1),
        syntheticPassphrase,
      ),
      throwsFormatException,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
