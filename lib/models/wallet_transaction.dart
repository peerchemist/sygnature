import 'electrumx_utxo.dart';

class WalletSendRequest {
  const WalletSendRequest({
    required this.destinationAddress,
    required this.amountSats,
    required this.feeRateSatsPerKb,
    this.maximum = false,
  });

  final String destinationAddress;
  final int amountSats;
  final int feeRateSatsPerKb;
  final bool maximum;
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
  });

  final String accountId;
  final String sourceAddress;
  final String destinationAddress;
  final int amountSats;
  final int feeSats;
  final int changeSats;
  final int feeRateSatsPerKb;
  final List<ElectrumxUtxo> selectedUtxos;

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
