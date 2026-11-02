import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';

void main() {
  setUpAll(loadCoinlib);

  final rootSeed = Uint8List.fromList([
    for (var index = 0; index < 64; index++) index,
  ]);

  test('requires a 64-byte random root seed', () {
    expect(
      () => CoinlibWalletKeyService().deriveAccount(
        network: PeercoinNetworks.mainnet,
        rootSeed: Uint8List(32),
        accountIndex: 0,
      ),
      throwsA(
        isA<WalletKeyFailure>().having(
          (failure) => failure.kind,
          'kind',
          WalletKeyFailureKind.invalidRootSeed,
        ),
      ),
    );
  });

  test('derives a Peercoin BIP-86 address and its matching spend key', () {
    final material = CoinlibWalletKeyService().deriveAccount(
      network: PeercoinNetworks.mainnet,
      rootSeed: rootSeed,
      accountIndex: 0,
    );
    final keyBytes = CoinlibWalletKeyService().deriveSpendKey(
      network: PeercoinNetworks.mainnet,
      rootSeed: rootSeed,
      accountIndex: 0,
      addressIndex: 0,
    );
    addTearDown(() => keyBytes.fillRange(0, keyBytes.length, 0));
    final spendKey = ECPrivateKey(keyBytes);

    expect(material.derivationPath, "m/86'/6'/0'/0/0");
    expect(material.address, startsWith('pc1p'));
    expect(keyBytes, hasLength(32));
    expect(
      P2TRAddress.fromTweakedKey(
        spendKey.pubkey,
        hrp: Network.mainnet.bech32Hrp,
      ).toString(),
      material.address,
    );
  });

  test('uses the selected Peercoin network address prefix', () {
    final service = CoinlibWalletKeyService();
    final mainnet = service.deriveAccount(
      network: PeercoinNetworks.mainnet,
      rootSeed: rootSeed,
      accountIndex: 0,
    );
    final testnet = service.deriveAccount(
      network: PeercoinNetworks.testnet,
      rootSeed: rootSeed,
      accountIndex: 0,
    );

    expect(mainnet.address, startsWith('pc1p'));
    expect(testnet.address, startsWith('tpc1p'));
    expect(mainnet.derivationPath, "m/86'/6'/0'/0/0");
    expect(testnet.derivationPath, "m/86'/1'/0'/0/0");
    expect(testnet.address, isNot(mainnet.address));
  });

  for (final network in PeercoinNetworks.values) {
    test(
      'public discovery matches private derivation on ${network.networkId}',
      () {
        final service = CoinlibWalletKeyService();
        final seed = Uint8List.fromList(rootSeed);
        final parent = service.deriveAddressParentKey(
          network: network,
          rootSeed: seed,
          accountIndex: 3,
        );
        expect(HDKey.decode(parent), isA<HDPublicKey>());
        seed.fillRange(0, seed.length, 0);
        final addresses = service.derivePublicAddresses(
          network: network,
          addressParentKey: parent,
          accountIndex: 3,
          firstAddressIndex: 0,
          lastAddressIndex: 20,
        );
        // Compare with the previous private-path derivation independently of
        // the service's public-parent implementation.
        final master = HDPrivateKey.fromSeed(rootSeed);
        for (final index in [0, 1, 7, 20]) {
          final path = "m/86'/${network.coinType}'/3'/0/$index";
          final child = master.derivePath(path);
          final expected = Taproot(internalKey: child.publicKey);
          expect(addresses[index].derivationPath, path);
          expect(
            addresses[index].address,
            P2TRAddress.fromTaproot(
              expected,
              hrp: network.network.bech32Hrp,
            ).toString(),
          );
          final spendKey = service.deriveSpendKey(
            network: network,
            rootSeed: rootSeed,
            accountIndex: 3,
            addressIndex: index,
          );
          try {
            expect(spendKey, expected.tweakPrivateKey(child.privateKey).data);
            expect(
              P2TRAddress.fromTweakedKey(
                ECPrivateKey(spendKey).pubkey,
                hrp: network.network.bech32Hrp,
              ).toString(),
              addresses[index].address,
            );
          } finally {
            spendKey.fillRange(0, spendKey.length, 0);
          }
        }
      },
    );
  }

  test('public discovery rejects an extended private key', () {
    expect(
      () => CoinlibWalletKeyService().derivePublicAddresses(
        network: PeercoinNetworks.mainnet,
        addressParentKey: HDPrivateKey.fromSeed(rootSeed)
            .encode(Network.mainnet.privHDPrefix),
        accountIndex: 0,
        firstAddressIndex: 0,
        lastAddressIndex: 1,
      ),
      throwsA(isA<WalletKeyFailure>()),
    );
  });

  test('public discovery rejects hardened address indexes', () {
    final service = CoinlibWalletKeyService();
    final parent = service.deriveAddressParentKey(
      network: PeercoinNetworks.mainnet,
      rootSeed: rootSeed,
      accountIndex: 0,
    );
    expect(
      () => service.derivePublicAddresses(
        network: PeercoinNetworks.mainnet,
        addressParentKey: parent,
        accountIndex: 0,
        firstAddressIndex: HDKey.hardenBit,
        lastAddressIndex: HDKey.hardenBit,
      ),
      throwsA(isA<WalletKeyFailure>()),
    );
  });

  test('derives a stable address sequence from the same root', () {
    final service = CoinlibWalletKeyService();
    final parent = service.deriveAddressParentKey(
      network: PeercoinNetworks.mainnet,
      rootSeed: rootSeed,
      accountIndex: 3,
    );
    final addresses = service.derivePublicAddresses(
      network: PeercoinNetworks.mainnet,
      addressParentKey: parent,
      accountIndex: 3,
      firstAddressIndex: 0,
      lastAddressIndex: 1,
    );
    final change = service
        .derivePublicAddresses(
          network: PeercoinNetworks.mainnet,
          addressParentKey: parent,
          accountIndex: 3,
          firstAddressIndex: 1,
          lastAddressIndex: 1,
        )
        .single;

    expect(addresses.map((address) => address.derivationPath), [
      "m/86'/6'/3'/0/0",
      "m/86'/6'/3'/0/1",
    ]);
    expect(addresses[1].address, change.address);
    expect(addresses[1].address, isNot(addresses[0].address));
  });
}
