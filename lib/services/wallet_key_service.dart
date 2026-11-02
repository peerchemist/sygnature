import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';

import '../models/wallet_network.dart';
import 'peercoin_network_service.dart';

const _invalidRootSeed = WalletKeyFailure(WalletKeyFailureKind.invalidRootSeed);
const _invalidAccountIndex = WalletKeyFailure(
  WalletKeyFailureKind.invalidAccountIndex,
);
const _derivationFailed = WalletKeyFailure(
  WalletKeyFailureKind.derivationFailed,
);

enum WalletKeyFailureKind {
  invalidRootSeed,
  invalidAccountIndex,
  derivationFailed,
}

class const WalletKeyFailure(final WalletKeyFailureKind kind)
    implements Exception {
  @override
  String toString() => switch (kind) {
    WalletKeyFailureKind.invalidRootSeed => 'The wallet root seed is invalid.',
    WalletKeyFailureKind.invalidAccountIndex =>
      'The wallet derivation index is invalid.',
    WalletKeyFailureKind.derivationFailed => 'Wallet key derivation failed.',
  };
}

/// Public address information, safe to retain during discovery and review.
class const DerivedWalletAddress({
  required final String derivationPath,
  required final String address,
});

/// Account provisioning material retained by the current vault/backup schema.
/// Address discovery and transaction signing do not use the stored spend key.
class const DerivedWalletMaterial({
  required final String derivationPath,
  required final String address,
  required final String privateKeyHex,
});

abstract interface class WalletKeyService {
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
  });

  /// Encoded extended public key at the account's external chain (change = 0).
  String deriveAddressParentKey({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
  });

  List<DerivedWalletAddress> derivePublicAddresses({
    required WalletNetwork network,
    required String addressParentKey,
    required int accountIndex,
    required int firstAddressIndex,
    required int lastAddressIndex,
  });

  /// Returns an owned mutable buffer; the caller must wipe it after signing.
  Uint8List deriveSpendKey({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
    required int addressIndex,
  });
}

class CoinlibWalletKeyService implements WalletKeyService {
  @override
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
  }) {
    try {
      final child = _addressParent(network, rootSeed, accountIndex).derive(0);
      final taproot = Taproot(internalKey: child.publicKey);
      final key = taproot.tweakPrivateKey(child.privateKey).data;
      try {
        return DerivedWalletMaterial(
          derivationPath: network.derivationPathForAccount(accountIndex),
          address: P2TRAddress.fromTaproot(
            taproot,
            hrp: PeercoinNetworks.fromWalletNetwork(network).network.bech32Hrp,
          ).toString(),
          privateKeyHex: bytesToHex(key),
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    } on WalletKeyFailure {
      rethrow;
    } on Object {
      throw _derivationFailed;
    }
  }

  static void _requireIndex(int index) {
    if (index < 0 || index >= HDKey.hardenBit) throw _invalidAccountIndex;
  }

  static HDPrivateKey _addressParent(
    WalletNetwork network,
    Uint8List rootSeed,
    int accountIndex,
  ) {
    if (rootSeed.length != 64) throw _invalidRootSeed;
    _requireIndex(accountIndex);
    final basePath = network.derivationPathForAccount(accountIndex);
    return HDPrivateKey.fromSeed(rootSeed)
        .derivePath(basePath.substring(0, basePath.lastIndexOf('/')));
  }

  @override
  String deriveAddressParentKey({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
  }) {
    try {
      return _addressParent(network, rootSeed, accountIndex).hdPublicKey.encode(
        PeercoinNetworks.fromWalletNetwork(network).network.pubHDPrefix,
      );
    } on WalletKeyFailure {
      rethrow;
    } on Object {
      throw _derivationFailed;
    }
  }

  @override
  List<DerivedWalletAddress> derivePublicAddresses({
    required WalletNetwork network,
    required String addressParentKey,
    required int accountIndex,
    required int firstAddressIndex,
    required int lastAddressIndex,
  }) {
    _requireIndex(accountIndex);
    _requireIndex(firstAddressIndex);
    _requireIndex(lastAddressIndex);
    if (lastAddressIndex < firstAddressIndex) throw _invalidAccountIndex;
    try {
      final preset = PeercoinNetworks.fromWalletNetwork(network).network;
      final parent = HDPublicKey.decode(addressParentKey, preset.pubHDPrefix);
      final basePath = network.derivationPathForAccount(accountIndex);
      final pathPrefix = basePath.substring(0, basePath.lastIndexOf('/') + 1);
      return [
        for (var index = firstAddressIndex; index <= lastAddressIndex; index++)
          DerivedWalletAddress(
            derivationPath: '$pathPrefix$index',
            address: P2TRAddress.fromTaproot(
              Taproot(internalKey: parent.derive(index).publicKey),
              hrp: preset.bech32Hrp,
            ).toString(),
          ),
      ];
    } on WalletKeyFailure {
      rethrow;
    } on Object {
      throw _derivationFailed;
    }
  }

  @override
  Uint8List deriveSpendKey({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
    required int addressIndex,
  }) {
    _requireIndex(addressIndex);
    try {
      final child = _addressParent(
        network,
        rootSeed,
        accountIndex,
      ).derive(addressIndex);
      // Coinlib owns internal key copies and exposes no destruction API. Only
      // the returned byte buffer is owned (and wipeable) by our caller.
      return Taproot(internalKey: child.publicKey)
          .tweakPrivateKey(child.privateKey)
          .data;
    } on WalletKeyFailure {
      rethrow;
    } on Object {
      throw _derivationFailed;
    }
  }
}
