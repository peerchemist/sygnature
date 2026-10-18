import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart' as bip39;
import 'package:coinlib/coinlib.dart';

import '../models/mnemonic_seed.dart';
import '../models/wallet_network.dart';
import 'peercoin_network_service.dart';

typedef EntropyGenerator = Uint8List Function(int length);

const _unsupportedWordCount = WalletKeyFailure(
  WalletKeyFailureKind.unsupportedWordCount,
);
const _entropyUnavailable = WalletKeyFailure(
  WalletKeyFailureKind.entropyUnavailable,
);
const _invalidMnemonicLength = WalletKeyFailure(
  WalletKeyFailureKind.invalidMnemonicLength,
);
const _unknownMnemonicWord = WalletKeyFailure(
  WalletKeyFailureKind.unknownMnemonicWord,
);
const _invalidMnemonicChecksum = WalletKeyFailure(
  WalletKeyFailureKind.invalidMnemonicChecksum,
);
const _invalidMnemonic = WalletKeyFailure(WalletKeyFailureKind.invalidMnemonic);
const _invalidAccountIndex = WalletKeyFailure(
  WalletKeyFailureKind.invalidAccountIndex,
);
const _derivationFailed = WalletKeyFailure(
  WalletKeyFailureKind.derivationFailed,
);

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

  DerivedWalletMaterial deriveAddress({
    required WalletNetwork network,
    required String mnemonic,
    required MnemonicLanguage language,
    required int accountIndex,
    required int addressIndex,
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
      throw _unsupportedWordCount;
    }

    final expectedLength = wordCount == 12 ? 16 : 32;
    late final Uint8List entropy;
    try {
      entropy = _entropyGenerator(expectedLength);
    } on Object {
      throw _entropyUnavailable;
    }
    if (entropy.length != expectedLength) {
      entropy.fillRange(0, entropy.length, 0);
      throw _entropyUnavailable;
    }

    try {
      final mnemonic = bip39.Mnemonic(entropy, language.bip39Language);
      return MnemonicSession(
        words: List.unmodifiable(mnemonic.words),
        language: language,
        createdInApp: true,
      );
    } on Object {
      throw _entropyUnavailable;
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
      return const MnemonicValidationResult.invalid(_invalidMnemonicLength);
    }

    try {
      final parsed = bip39.Mnemonic.fromWords(
        words: inputWords,
        language: language.bip39Language,
      );
      return MnemonicValidationResult.valid(List.unmodifiable(parsed.words));
    } on bip39.MnemonicWordNotFoundException {
      return const MnemonicValidationResult.invalid(_unknownMnemonicWord);
    } on bip39.MnemonicInvalidChecksumException {
      return const MnemonicValidationResult.invalid(_invalidMnemonicChecksum);
    } on bip39.MnemonicException {
      return const MnemonicValidationResult.invalid(_invalidMnemonic);
    } on Object {
      return const MnemonicValidationResult.invalid(_invalidMnemonic);
    }
  }

  @override
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required String mnemonic,
    required MnemonicLanguage language,
    required int accountIndex,
  }) => deriveAddress(
    network: network,
    mnemonic: mnemonic,
    language: language,
    accountIndex: accountIndex,
    addressIndex: 0,
  );

  @override
  DerivedWalletMaterial deriveAddress({
    required WalletNetwork network,
    required String mnemonic,
    required MnemonicLanguage language,
    required int accountIndex,
    required int addressIndex,
  }) {
    if (accountIndex < 0 || accountIndex >= HDKey.hardenBit) {
      throw _invalidAccountIndex;
    }
    if (addressIndex < 0 || addressIndex >= HDKey.hardenBit) {
      throw _invalidAccountIndex;
    }
    Uint8List? seed;
    try {
      final peercoinNetwork = PeercoinNetworks.fromWalletNetwork(network);
      final basePath = network.derivationPathForAccount(accountIndex);
      final path =
          '${basePath.substring(0, basePath.lastIndexOf('/') + 1)}$addressIndex';
      seed = mnemonicToSeed(mnemonic, language: language);
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
    } on WalletKeyFailure {
      rethrow;
    } on Object {
      throw _derivationFailed;
    } finally {
      seed?.fillRange(0, seed.length, 0);
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
    try {
      final parsed = bip39.Mnemonic.fromWords(
        words: words,
        language: (language ?? MnemonicLanguage.english).bip39Language,
        passphrase: passphrase,
      );
      return Uint8List.fromList(parsed.seed);
    } on Object {
      throw _invalidMnemonic;
    }
  }
}
