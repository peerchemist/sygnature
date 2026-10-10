import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// No wallet identifiers occur outside the authenticated ciphertext.
abstract final class BackupEnvelope {
  static const headerLength = 60;
  static const maxFileBytes = 16 * 1024 * 1024;
  static const memoryKiB = 65536;
  static const iterations = 3;
  static const parallelism = 1;

  static Uint8List _random(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  static void validateHeader(Uint8List file) {
    if (file.length < 77 || file.length > maxFileBytes) {
      throw const FormatException(
        'Backup file must contain 77 bytes to 16 MiB.',
      );
    }
    if (!const ListEquality().equals(
          file.sublist(0, 8),
          ascii.encode('ROASTBAK'),
        ) ||
        file[8] != 1 ||
        file[9] != 1 ||
        file[10] != 1) {
      throw const FormatException('Unsupported backup format or algorithm.');
    }
    final data = ByteData.sublistView(file);
    final memory = data.getUint32(11);
    final rounds = data.getUint32(15);
    final lanes = file[19];
    if (memory < 65536 ||
        memory > 262144 ||
        rounds < 3 ||
        rounds > 10 ||
        lanes < 1 ||
        lanes > 4 ||
        memory % (4 * lanes) != 0) {
      throw const FormatException(
        'Backup KDF parameters exceed permitted bounds.',
      );
    }
  }

  static Future<Uint8List> encrypt(
    Uint8List plaintext,
    String passphrase,
  ) async {
    if (plaintext.isEmpty || plaintext.length > maxFileBytes - 76) {
      throw const FormatException('Backup payload is too large or empty.');
    }
    final header = Uint8List(60)..setRange(0, 8, ascii.encode('ROASTBAK'));
    header[8] = header[9] = header[10] = 1;
    ByteData.sublistView(header)
      ..setUint32(11, memoryKiB)
      ..setUint32(15, iterations);
    header[19] = parallelism;
    header.setRange(20, 36, _random(16));
    header.setRange(36, 60, _random(24));
    return Isolate.run(() => _encrypt(plaintext, passphrase, header));
  }

  static Future<Uint8List> decrypt(Uint8List file, String passphrase) {
    validateHeader(file);
    return Isolate.run(() => _decrypt(file, passphrase));
  }

  static Future<SecretKey> _key(Uint8List header, String passphrase) async {
    final password = Uint8List.fromList(utf8.encode(passphrase));
    final passwordKey = SecretKeyData(password, overwriteWhenDestroyed: true);
    try {
      // Pin the pure Dart implementation; backup crypto never uses native APIs.
      return await DartArgon2id(
        memory: ByteData.sublistView(header).getUint32(11),
        iterations: ByteData.sublistView(header).getUint32(15),
        parallelism: header[19],
        hashLength: 32,
      ).deriveKey(
        secretKey: passwordKey,
        nonce: Uint8List.sublistView(header, 20, 36),
      );
    } finally {
      passwordKey.destroy();
      password.fillRange(0, password.length, 0);
    }
  }

  static Future<Uint8List> _encrypt(
    Uint8List plaintext,
    String passphrase,
    Uint8List header,
  ) async {
    final key = await _key(header, passphrase);
    try {
      final cipher = Xchacha20.poly1305Aead();
      final box = await cipher.encrypt(
        plaintext,
        secretKey: key,
        nonce: Uint8List.sublistView(header, 36),
        aad: header,
      );
      final file = Uint8List.fromList([
        ...header,
        ...box.cipherText,
        ...box.mac.bytes,
      ]);
      final verified = await cipher.decrypt(box, secretKey: key, aad: header);
      try {
        if (!const ListEquality().equals(verified, plaintext)) {
          throw StateError('Backup encryption verification failed.');
        }
      } finally {
        verified.fillRange(0, verified.length, 0);
      }
      return file;
    } finally {
      key.destroy();
    }
  }

  static Future<Uint8List> _decrypt(Uint8List file, String passphrase) async {
    final header = Uint8List.sublistView(file, 0, 60);
    final key = await _key(header, passphrase);
    try {
      final plaintext = await Xchacha20.poly1305Aead().decrypt(
        SecretBox(
          Uint8List.sublistView(file, 60, file.length - 16),
          nonce: Uint8List.sublistView(header, 36),
          mac: Mac(Uint8List.sublistView(file, file.length - 16)),
        ),
        secretKey: key,
        aad: header,
      );
      if (plaintext is Uint8List) return plaintext;
      final result = Uint8List.fromList(plaintext);
      plaintext.fillRange(0, plaintext.length, 0);
      return result;
    } on SecretBoxAuthenticationError {
      throw const FormatException('Incorrect passphrase or damaged backup.');
    } finally {
      key.destroy();
    }
  }
}

// Avoid another dependency just to compare byte buffers.
final class const ListEquality() {
  bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
