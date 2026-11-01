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
    final spendKey = ECPrivateKey.fromHex(material.privateKeyHex);

    expect(material.derivationPath, "m/86'/6'/0'/0/0");
    expect(material.address, startsWith('pc1p'));
    expect(material.privateKeyHex, hasLength(64));
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
    expect(testnet.privateKeyHex, isNot(mainnet.privateKeyHex));
  });

  test('derives a stable address sequence from the same root', () {
    final service = CoinlibWalletKeyService();
    final addresses = service.deriveAddresses(
      network: PeercoinNetworks.mainnet,
      rootSeed: rootSeed,
      accountIndex: 3,
      firstAddressIndex: 0,
      lastAddressIndex: 1,
    );
    final change = service.deriveAddress(
      network: PeercoinNetworks.mainnet,
      rootSeed: rootSeed,
      accountIndex: 3,
      addressIndex: 1,
    );

    expect(addresses.map((address) => address.derivationPath), [
      "m/86'/6'/3'/0/0",
      "m/86'/6'/3'/0/1",
    ]);
    expect(addresses[1].address, change.address);
    expect(addresses[1].privateKeyHex, change.privateKeyHex);
    expect(addresses[1].address, isNot(addresses[0].address));
  });
}
