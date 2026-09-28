import 'package:coinlib/coinlib.dart';

import '../models/wallet_network.dart';

class PeercoinNetworkPreset extends WalletNetwork {
  const PeercoinNetworkPreset({
    required super.networkId,
    required super.networkLabel,
    required super.derivationPathTemplate,
    required this.coinType,
    required this.network,
  }) : super(
         blockchainId: 'peercoin',
         blockchainLabel: 'Peercoin',
         accountTypeLabel: 'Taproot BIP-86',
       );

  final int coinType;
  final Network network;

  String get id => networkId;
}

abstract final class PeercoinNetworks {
  static final mainnet = PeercoinNetworkPreset(
    networkId: 'mainnet',
    networkLabel: 'mainnet',
    coinType: 6,
    network: Network.mainnet,
    derivationPathTemplate: "m/86'/6'/{account}'/0/0",
  );

  static final testnet = PeercoinNetworkPreset(
    networkId: 'testnet',
    networkLabel: 'testnet',
    coinType: 1,
    network: Network.testnet,
    derivationPathTemplate: "m/86'/1'/{account}'/0/0",
  );

  static final values = List<PeercoinNetworkPreset>.unmodifiable([
    mainnet,
    testnet,
  ]);

  static PeercoinNetworkPreset byId(String networkId) => values.firstWhere(
    (network) => network.networkId == networkId,
    orElse: () => throw ArgumentError.value(
      networkId,
      'networkId',
      'Unknown Peercoin network.',
    ),
  );

  static PeercoinNetworkPreset fromWalletNetwork(WalletNetwork network) {
    if (network.blockchainId != mainnet.blockchainId) {
      throw UnsupportedError(
        'Unsupported blockchain: ${network.blockchainId}.',
      );
    }
    return byId(network.networkId);
  }
}
