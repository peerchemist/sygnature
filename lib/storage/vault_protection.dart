import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:pointycastle/export.dart';

import 'hive_storage_initializer.dart';

enum VaultProtectionMode { system, password }

class const VaultProtectionConfig({
  required final VaultProtectionMode mode,
  final String? salt,
  final String? verifier,
  final int iterations = 3,
  final int memoryPowerOfTwo = 16,
}) {
  static const _modeKey = 'mode';
  static const _saltKey = 'salt';
  static const _verifierKey = 'verifier';
  static const _iterationsKey = 'iterations';
  static const _memoryPowerOfTwoKey = 'memoryPowerOfTwo';

  factory VaultProtectionConfig.fromJson(Map<dynamic, dynamic> json) {
    final modeName = json[_modeKey];
    final mode = VaultProtectionMode.values
        .where((value) => value.name == modeName)
        .firstOrNull;
    if (mode == null) {
      throw StateError('The vault protection mode is invalid.');
    }
    final salt = json[_saltKey];
    final verifier = json[_verifierKey];
    final iterations = json[_iterationsKey];
    final memoryPowerOfTwo = json[_memoryPowerOfTwoKey];
    if (mode == VaultProtectionMode.password &&
        (salt is! String ||
            salt.isEmpty ||
            verifier is! String ||
            verifier.isEmpty ||
            iterations is! int ||
            memoryPowerOfTwo is! int)) {
      throw StateError('The password protection settings are invalid.');
    }
    return VaultProtectionConfig(
      mode: mode,
      salt: salt as String?,
      verifier: verifier as String?,
      iterations: iterations as int? ?? 3,
      memoryPowerOfTwo: memoryPowerOfTwo as int? ?? 16,
    );
  }

  Map<String, Object?> toJson() => {
    _modeKey: mode.name,
    if (salt != null) _saltKey: salt,
    if (verifier != null) _verifierKey: verifier,
    _iterationsKey: iterations,
    _memoryPowerOfTwoKey: memoryPowerOfTwo,
  };

  VaultProtectionConfig withVerifier(Uint8List bytes) => VaultProtectionConfig(
    mode: mode,
    salt: salt,
    verifier: base64UrlEncode(bytes),
    iterations: iterations,
    memoryPowerOfTwo: memoryPowerOfTwo,
  );

  bool matchesVerifier(Uint8List bytes) {
    final encoded = verifier;
    if (encoded == null) return false;
    late final Uint8List expected;
    try {
      expected = base64Url.decode(encoded);
    } on FormatException {
      return false;
    }
    if (expected.length != bytes.length) return false;
    var difference = 0;
    for (var index = 0; index < expected.length; index++) {
      difference |= expected[index] ^ bytes[index];
    }
    return difference == 0;
  }
}

class const VaultKeyMaterial({
  required final Uint8List walletKey,
  required final Uint8List roastKey,
  required final Uint8List verifier,
});

class VaultProtectionStore(final Box<dynamic> _box) {
  static const _boxName = 'sygnature_bootstrap_v1';
  static const _configKey = 'vault_protection';

  static Future<VaultProtectionStore> open() async {
    await HiveStorageInitializer.initialize(boxName: _boxName);
    return VaultProtectionStore(await Hive.openBox<dynamic>(_boxName));
  }

  VaultProtectionConfig? get config {
    final raw = _box.get(_configKey);
    if (raw == null) return null;
    if (raw is! Map) {
      throw StateError('The vault protection settings are invalid.');
    }
    return VaultProtectionConfig.fromJson(raw);
  }

  VaultProtectionConfig createPasswordConfig() => VaultProtectionConfig(
    mode: VaultProtectionMode.password,
    salt: base64UrlEncode(Hive.generateSecureKey()),
  );

  Future<void> configurePassword(VaultProtectionConfig config) async {
    if (config.mode != VaultProtectionMode.password ||
        config.salt == null ||
        config.verifier == null) {
      throw ArgumentError(
        'Complete password protection settings are required.',
      );
    }
    await _box.put(_configKey, config.toJson());
  }

  Future<void> configureSystem() => _box.put(
    _configKey,
    const VaultProtectionConfig(mode: VaultProtectionMode.system).toJson(),
  );
}

bool systemVaultAvailable({bool? web, TargetPlatform? platform}) {
  final isWeb = web ?? kIsWeb;
  final currentPlatform = platform ?? defaultTargetPlatform;
  return isWeb || currentPlatform != TargetPlatform.macOS;
}

Future<VaultKeyMaterial> deriveVaultKeyMaterial(
  String password,
  VaultProtectionConfig config,
) => compute(_deriveVaultKeyMaterial, {
  'password': password,
  'salt': config.salt,
  'iterations': config.iterations,
  'memoryPowerOfTwo': config.memoryPowerOfTwo,
});

@visibleForTesting
VaultKeyMaterial deriveVaultKeyMaterialSync(
  String password,
  VaultProtectionConfig config,
) => _deriveVaultKeyMaterial({
  'password': password,
  'salt': config.salt,
  'iterations': config.iterations,
  'memoryPowerOfTwo': config.memoryPowerOfTwo,
});

VaultKeyMaterial _deriveVaultKeyMaterial(Map<String, Object?> settings) {
  final password = settings['password'];
  final encodedSalt = settings['salt'];
  final iterations = settings['iterations'];
  final memoryPowerOfTwo = settings['memoryPowerOfTwo'];
  if (password is! String ||
      encodedSalt is! String ||
      iterations is! int ||
      memoryPowerOfTwo is! int) {
    throw StateError('The password protection settings are invalid.');
  }

  final passwordBytes = Uint8List.fromList(utf8.encode(password));
  final rootKey = Uint8List(32);
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        base64Url.decode(encodedSalt),
        desiredKeyLength: rootKey.length,
        iterations: iterations,
        memoryPowerOf2: memoryPowerOfTwo,
        lanes: 1,
      ),
    );
  generator.deriveKey(passwordBytes, 0, rootKey, 0);
  passwordBytes.fillRange(0, passwordBytes.length, 0);

  try {
    return VaultKeyMaterial(
      walletKey: _deriveDomainKey(rootKey, 'wallet-v1'),
      roastKey: _deriveDomainKey(rootKey, 'roast-v1'),
      verifier: _deriveDomainKey(rootKey, 'password-verifier-v1'),
    );
  } finally {
    rootKey.fillRange(0, rootKey.length, 0);
  }
}

Uint8List _deriveDomainKey(Uint8List rootKey, String domain) {
  final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(rootKey));
  return hmac.process(Uint8List.fromList(utf8.encode('sygnature:$domain')));
}
