import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  test('consolidates legacy secrets into one secure keyring record', () async {
    final backingStore = _MemorySecureKeyStore({
      'wallet-key': 'wallet-secret',
      'roast-key': 'roast-secret',
      'iroh-key': 'iroh-secret',
    });
    final keyring = KeyringSecureKeyStore(backingStore);

    expect(await keyring.read('wallet-key'), 'wallet-secret');
    expect(await keyring.read('roast-key'), 'roast-secret');
    expect(await keyring.read('iroh-key'), 'iroh-secret');
    expect(backingStore.values.keys, ['sygnature_secure_keyring_v1']);
    expect(
      jsonDecode(backingStore.values.values.single),
      containsPair('wallet-key', 'wallet-secret'),
    );

    backingStore.readKeys.clear();
    final restored = KeyringSecureKeyStore(backingStore);
    expect(await restored.read('wallet-key'), 'wallet-secret');
    expect(await restored.read('roast-key'), 'roast-secret');
    expect(await restored.read('iroh-key'), 'iroh-secret');
    expect(backingStore.readKeys, ['sygnature_secure_keyring_v1']);
  });
}

class _MemorySecureKeyStore(final Map<String, String> values)
    implements SecureKeyStore {
  final List<String> readKeys = [];

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
