import 'package:coinlib/coinlib.dart';

class PeercoinNetworkPreset {
  const PeercoinNetworkPreset({
    required this.id,
    required this.label,
    required this.network,
  });

  final String id;
  final String label;
  final Network network;
}

abstract final class PeercoinNetworks {
  static final mainnet = PeercoinNetworkPreset(
    id: 'mainnet',
    label: 'Peercoin mainnet',
    network: Network.mainnet,
  );

  static final testnet = PeercoinNetworkPreset(
    id: 'testnet',
    label: 'Peercoin testnet',
    network: Network.testnet,
  );

  static final values = List<PeercoinNetworkPreset>.unmodifiable([
    mainnet,
    testnet,
  ]);
}
