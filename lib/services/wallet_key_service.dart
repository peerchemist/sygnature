import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart' as bip39;
import 'package:coinlib/coinlib.dart';

import '../models/mnemonic_seed.dart';
import '../models/wallet_network.dart';
import 'peercoin_network_service.dart';

typedef EntropyGenerator = Uint8List Function(int length);

class DerivedWalletMaterial {
  const DerivedWalletMaterial({
    required this.derivationPath,
    required this.address,
    required this.privateKeyHex,
  });

  final String derivationPath;
  final String address;

  /// Taproot-tweaked private key used for key-path spending.
  final String privateKeyHex;
}

abstract interface class WalletKeyService {
  MnemonicSession generateMnemonic({
    required MnemonicLanguage language,
    required int wordCount,
  });

  MnemonicValidationResult validateMnemonic({
    required String mnemonic,
    required MnemonicLanguage language,
  });

  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required String mnemonic,
    required MnemonicLanguage language,
    required int accountIndex,
  });
}

class CoinlibWalletKeyService implements WalletKeyService {
  CoinlibWalletKeyService({EntropyGenerator? entropyGenerator})
    : _entropyGenerator = entropyGenerator ?? generateRandomBytes;

  final EntropyGenerator _entropyGenerator;

  @override
  MnemonicSession generateMnemonic({
    required MnemonicLanguage language,
    required int wordCount,
  }) {
    if (wordCount != 12 && wordCount != 24) {
      throw ArgumentError.value(
        wordCount,
        'wordCount',
        'Only 12- and 24-word BIP-39 phrases are supported.',
      );
    }

    final entropy = _entropyGenerator(wordCount == 12 ? 16 : 32);
    final expectedLength = wordCount == 12 ? 16 : 32;
    if (entropy.length != expectedLength) {
      throw StateError(
        'Entropy generator returned ${entropy.length} bytes; '
        'expected $expectedLength.',
      );
    }

    try {
      final mnemonic = bip39.Mnemonic(entropy, language.bip39Language);
      return MnemonicSession(
        words: List.unmodifiable(mnemonic.words),
        language: language,
        createdInApp: true,
      );
    } finally {
      entropy.fillRange(0, entropy.length, 0);
    }
  }

  @override
  MnemonicValidationResult validateMnemonic({
    required String mnemonic,
    required MnemonicLanguage language,
  }) {
    final normalized = mnemonic.replaceAll('\u3000', ' ').trim();
    final inputWords = normalized.isEmpty
        ? const <String>[]
        : normalized.split(RegExp(r'\s+'));
    if (inputWords.length != 12 && inputWords.length != 24) {
      return const MnemonicValidationResult.invalid(
        'Recovery phrase must contain 12 or 24 words.',
      );
    }

    try {
      final parsed = bip39.Mnemonic.fromWords(
        words: inputWords,
        language: language.bip39Language,
      );
      return MnemonicValidationResult.valid(List.unmodifiable(parsed.words));
    } on bip39.MnemonicWordNotFoundException {
      return const MnemonicValidationResult.invalid(
        'Recovery phrase contains a word outside the selected wordlist.',
      );
    } on bip39.MnemonicInvalidChecksumException {
      return const MnemonicValidationResult.invalid(
        'Recovery phrase checksum is invalid.',
      );
    } on bip39.MnemonicException {
      return const MnemonicValidationResult.invalid(
        'Recovery phrase is invalid.',
      );
    }
  }

  @override
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required String mnemonic,
    required MnemonicLanguage language,
    required int accountIndex,
  }) {
    if (accountIndex < 0 || accountIndex >= HDKey.hardenBit) {
      throw ArgumentError.value(accountIndex, 'accountIndex');
    }
    final peercoinNetwork = PeercoinNetworks.fromWalletNetwork(network);
    final path = network.derivationPathForAccount(accountIndex);
    final seed = mnemonicToSeed(mnemonic, language: language);
    try {
      final child = HDPrivateKey.fromSeed(seed).derivePath(path);
      final taproot = Taproot(internalKey: child.publicKey);
      final spendKey = taproot.tweakPrivateKey(child.privateKey);
      final address = P2TRAddress.fromTaproot(
        taproot,
        hrp: peercoinNetwork.network.bech32Hrp,
      ).toString();

      return DerivedWalletMaterial(
        derivationPath: path,
        address: address,
        privateKeyHex: bytesToHex(spendKey.data),
      );
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  static Uint8List mnemonicToSeed(
    String mnemonic, {
    String passphrase = '',
    MnemonicLanguage? language,
  }) {
    final words = mnemonic
        .replaceAll('\u3000', ' ')
        .trim()
        .split(RegExp(r'\s+'));
    final parsed = bip39.Mnemonic.fromWords(
      words: words,
      language: (language ?? MnemonicLanguage.english).bip39Language,
      passphrase: passphrase,
    );
    return Uint8List.fromList(parsed.seed);
  }
}
