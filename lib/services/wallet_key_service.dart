import 'dart:convert';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../models/mnemonic_seed.dart';

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
    required List<String> wordlist,
  });

  DerivedWalletMaterial deriveAccount({
    required String mnemonic,
    required int accountIndex,
  });
}

class CoinlibWalletKeyService implements WalletKeyService {
  CoinlibWalletKeyService({
    Network? network,
    EntropyGenerator? entropyGenerator,
  }) : _network = network ?? Network.mainnet,
       _entropyGenerator = entropyGenerator ?? generateRandomBytes;

  static const purpose = 86;
  static const peercoinCoinType = 6;
  static const _pbkdf2Rounds = 2048;

  final Network _network;
  final EntropyGenerator _entropyGenerator;

  @override
  MnemonicSession generateMnemonic({
    required MnemonicLanguage language,
    required int wordCount,
    required List<String> wordlist,
  }) {
    if (wordCount != 12 && wordCount != 24) {
      throw ArgumentError.value(
        wordCount,
        'wordCount',
        'Only 12- and 24-word BIP-39 phrases are supported.',
      );
    }

    final normalizedWordlist = wordlist
        .map((word) => word.trim())
        .toList(growable: false);
    if (normalizedWordlist.length != 2048 ||
        normalizedWordlist.any((word) => word.isEmpty) ||
        normalizedWordlist.toSet().length != 2048) {
      throw ArgumentError.value(
        wordlist,
        'wordlist',
        'A BIP-39 wordlist must contain 2,048 unique words.',
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

    final checksum = sha256Hash(entropy);
    final checksumBitCount = entropy.length ~/ 4;
    final totalBitCount = entropy.length * 8 + checksumBitCount;
    final words = <String>[];

    for (var offset = 0; offset < totalBitCount; offset += 11) {
      var index = 0;
      for (var bit = 0; bit < 11; bit++) {
        final position = offset + bit;
        final source = position < entropy.length * 8 ? entropy : checksum;
        final sourcePosition = position < entropy.length * 8
            ? position
            : position - entropy.length * 8;
        final value =
            (source[sourcePosition ~/ 8] >> (7 - sourcePosition % 8)) & 1;
        index = (index << 1) | value;
      }
      words.add(normalizedWordlist[index]);
    }

    return MnemonicSession(
      words: List.unmodifiable(words),
      language: language,
      createdInApp: true,
    );
  }

  @override
  DerivedWalletMaterial deriveAccount({
    required String mnemonic,
    required int accountIndex,
  }) {
    if (accountIndex < 0 || accountIndex >= HDKey.hardenBit) {
      throw ArgumentError.value(accountIndex, 'accountIndex');
    }
    final path = derivationPath(accountIndex);
    final seed = mnemonicToSeed(mnemonic);
    final child = HDPrivateKey.fromSeed(seed).derivePath(path);
    final taproot = Taproot(internalKey: child.publicKey);
    final spendKey = taproot.tweakPrivateKey(child.privateKey);
    final address = P2TRAddress.fromTaproot(
      taproot,
      hrp: _network.bech32Hrp,
    ).toString();

    return DerivedWalletMaterial(
      derivationPath: path,
      address: address,
      privateKeyHex: bytesToHex(spendKey.data),
    );
  }

  static String derivationPath(int accountIndex) =>
      "m/$purpose'/$peercoinCoinType'/$accountIndex'/0/0";

  /// BIP-39 seed derivation using NFKD normalization and PBKDF2-HMAC-SHA512.
  static Uint8List mnemonicToSeed(String mnemonic, {String passphrase = ''}) {
    final password = Uint8List.fromList(utf8.encode(unicode.nfkd(mnemonic)));
    final salt = Uint8List.fromList(
      utf8.encode(unicode.nfkd('mnemonic$passphrase')),
    );
    final firstBlock = Uint8List(salt.length + 4)..setAll(0, salt);
    firstBlock[firstBlock.length - 1] = 1;

    var round = hmacSha512(password, firstBlock);
    final result = Uint8List.fromList(round);
    for (var iteration = 1; iteration < _pbkdf2Rounds; iteration++) {
      round = hmacSha512(password, round);
      for (var index = 0; index < result.length; index++) {
        result[index] ^= round[index];
      }
    }
    return result;
  }
}
