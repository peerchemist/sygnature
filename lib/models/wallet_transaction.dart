import 'electrumx_utxo.dart';

class WalletSendRequest {
  const WalletSendRequest({
    required this.destinationAddress,
    required this.amountSats,
    required this.feeRateSatsPerKb,
    this.maximum = false,
    this.signingMessage = '',
    this.useNewChangeAddress = false,
  });

  final String destinationAddress;
  final int amountSats;
  final int feeRateSatsPerKb;
  final bool maximum;
  final String signingMessage;
  final bool useNewChangeAddress;
}

class WalletTransactionPreview {
  const WalletTransactionPreview({
    required this.accountId,
    required this.sourceAddress,
    required this.destinationAddress,
    required this.amountSats,
    required this.feeSats,
    required this.changeSats,
    required this.feeRateSatsPerKb,
    required this.selectedUtxos,
    this.signingMessage = '',
    required this.changeAddress,
    required this.changeDerivationPath,
    required this.changeAddressIndex,
    required this.inputDerivationPaths,
  });

  final String accountId;
  final String sourceAddress;
  final String destinationAddress;
  final int amountSats;
  final int feeSats;
  final int changeSats;
  final int feeRateSatsPerKb;
  final List<ElectrumxUtxo> selectedUtxos;
  final String signingMessage;
  final String? changeAddress;
  final String? changeDerivationPath;
  final int changeAddressIndex;

  /// Derivation path keyed by every owned input address in this transaction.
  final Map<String, String> inputDerivationPaths;

  int get inputSats =>
      selectedUtxos.fold(0, (total, utxo) => total + utxo.value);
}

class SignedWalletTransaction {
  const SignedWalletTransaction({
    required this.transactionId,
    required this.rawTransactionHex,
  });

  final String transactionId;
  final String rawTransactionHex;
}

class WalletSendResult {
  const WalletSendResult({
    required this.transactionId,
    required this.serverTransactionId,
  });

  final String transactionId;
  final String serverTransactionId;
}
