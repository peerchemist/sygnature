import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';

void main() {
  setUpAll(loadCoinlib);

  test('generates the official 128-bit zero-entropy BIP-39 vector', () async {
    final words = await File('assets/wordlists/english.txt').readAsLines();
    final service = CoinlibWalletKeyService(
      entropyGenerator: (length) => Uint8List(length),
    );

    final mnemonic = service.generateMnemonic(
      language: MnemonicLanguage.byId('english'),
      wordCount: 12,
      wordlist: words,
    );

    expect(
      mnemonic.phrase,
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about',
    );
  });

  test('generates a valid 24-word checksum from 256-bit entropy', () async {
    final words = await File('assets/wordlists/english.txt').readAsLines();
    final service = CoinlibWalletKeyService(
      entropyGenerator: (length) => Uint8List(length),
    );

    final mnemonic = service.generateMnemonic(
      language: MnemonicLanguage.byId('english'),
      wordCount: 24,
      wordlist: words,
    );

    expect(mnemonic.words, hasLength(24));
    expect(mnemonic.words.take(23), everyElement('abandon'));
    expect(mnemonic.words.last, 'art');
  });

  test('derives the official BIP-39 seed', () {
    final seed = CoinlibWalletKeyService.mnemonicToSeed(
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about',
      passphrase: 'TREZOR',
    );

    expect(
      bytesToHex(seed),
      'c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553'
      '1f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04',
    );
  });

  test('normalizes equivalent Unicode passphrases before seed derivation', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';

    final composed = CoinlibWalletKeyService.mnemonicToSeed(
      mnemonic,
      passphrase: '\u00e9',
    );
    final decomposed = CoinlibWalletKeyService.mnemonicToSeed(
      mnemonic,
      passphrase: 'e\u0301',
    );

    expect(composed, orderedEquals(decomposed));
  });

  test('derives a Peercoin BIP-86 address and its matching spend key', () {
    final service = CoinlibWalletKeyService();
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';

    final material = service.deriveAccount(mnemonic: mnemonic, accountIndex: 0);
    final spendKey = ECPrivateKey.fromHex(material.privateKeyHex);
    final addressFromStoredKey = P2TRAddress.fromTweakedKey(
      spendKey.pubkey,
      hrp: Network.mainnet.bech32Hrp,
    ).toString();

    expect(material.derivationPath, "m/86'/6'/0'/0/0");
    expect(material.address, startsWith('pc1p'));
    expect(material.privateKeyHex, hasLength(64));
    expect(addressFromStoredKey, material.address);
  });
}
