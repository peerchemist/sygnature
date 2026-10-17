enum WalletCurrency(final String shortName) {
  peercoin('PPC'),
  peercoinTestnet('tPPC'),
}

class WalletNetwork {
  const WalletNetwork({
    required this.blockchainId,
    required this.networkId,
    required this.currency,
    required this.blockchainLabel,
    required this.networkLabel,
    required this.accountTypeLabel,
    required this.derivationPathTemplate,
  });

  final String blockchainId;
  final String networkId;
  final WalletCurrency currency;
  final String blockchainLabel;
  final String networkLabel;
  final String accountTypeLabel;
  final String derivationPathTemplate;

  String get storageId => '$blockchainId:$networkId';
  String get label => '$blockchainLabel $networkLabel';
  String derivationPathForAccount(int accountIndex) =>
      derivationPathTemplate.replaceAll('{account}', '$accountIndex');

  bool matches({required String blockchainId, required String networkId}) =>
      this.blockchainId == blockchainId && this.networkId == networkId;
}
