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

class const DerivedWalletMaterial({
  required final String derivationPath,
  required final String address,
  required final String privateKeyHex,
});

abstract class WalletKeyService {
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
  });

  DerivedWalletMaterial deriveAddress({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
    required int addressIndex,
  });

  List<DerivedWalletMaterial> deriveAddresses({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
    required int firstAddressIndex,
    required int lastAddressIndex,
  }) => [
    for (
      var addressIndex = firstAddressIndex;
      addressIndex <= lastAddressIndex;
      addressIndex++
    )
      deriveAddress(
        network: network,
        rootSeed: rootSeed,
        accountIndex: accountIndex,
        addressIndex: addressIndex,
      ),
  ];
}

class CoinlibWalletKeyService extends WalletKeyService {
  @override
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
  }) => deriveAddress(
    network: network,
    rootSeed: rootSeed,
    accountIndex: accountIndex,
    addressIndex: 0,
  );

  @override
  DerivedWalletMaterial deriveAddress({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
    required int addressIndex,
  }) => deriveAddresses(
    network: network,
    rootSeed: rootSeed,
    accountIndex: accountIndex,
    firstAddressIndex: addressIndex,
    lastAddressIndex: addressIndex,
  ).single;

  @override
  List<DerivedWalletMaterial> deriveAddresses({
    required WalletNetwork network,
    required Uint8List rootSeed,
    required int accountIndex,
    required int firstAddressIndex,
    required int lastAddressIndex,
  }) {
    if (rootSeed.length != 64) throw _invalidRootSeed;
    if (accountIndex < 0 || accountIndex >= HDKey.hardenBit) {
      throw _invalidAccountIndex;
    }
    if (firstAddressIndex < 0 ||
        lastAddressIndex < firstAddressIndex ||
        lastAddressIndex >= HDKey.hardenBit) {
      throw _invalidAccountIndex;
    }
    try {
      final peercoinNetwork = PeercoinNetworks.fromWalletNetwork(network);
      final basePath = network.derivationPathForAccount(accountIndex);
      final pathPrefix = basePath.substring(0, basePath.lastIndexOf('/') + 1);
      final addressParent = HDPrivateKey.fromSeed(rootSeed)
          .derivePath(basePath.substring(0, basePath.lastIndexOf('/')));
      return [
        for (
          var addressIndex = firstAddressIndex;
          addressIndex <= lastAddressIndex;
          addressIndex++
        )
          _deriveAddressFromParent(
            addressParent,
            addressIndex: addressIndex,
            path: '$pathPrefix$addressIndex',
            addressHrp: peercoinNetwork.network.bech32Hrp,
          ),
      ];
    } on WalletKeyFailure {
      rethrow;
    } on Object {
      throw _derivationFailed;
    }
  }

  static DerivedWalletMaterial _deriveAddressFromParent(
    HDPrivateKey parent, {
    required int addressIndex,
    required String path,
    required String addressHrp,
  }) {
    final child = parent.derive(addressIndex);
    final taproot = Taproot(internalKey: child.publicKey);
    final spendKey = taproot.tweakPrivateKey(child.privateKey);
    return DerivedWalletMaterial(
      derivationPath: path,
      address: P2TRAddress.fromTaproot(taproot, hrp: addressHrp).toString(),
      privateKeyHex: bytesToHex(spendKey.data),
    );
  }
}
