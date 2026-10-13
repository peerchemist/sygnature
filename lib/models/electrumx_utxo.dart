class ElectrumxUtxo {
  const ElectrumxUtxo({
    required this.address,
    required this.txHash,
    required this.txPos,
    required this.height,
    required this.value,
  });

  final String address;
  final String txHash;
  final int txPos;
  final int height;
  final int value;

  bool get isConfirmed => height > 0;

  static ElectrumxUtxo fromJson({
    required String address,
    required Object? value,
  }) {
    if (value is! Map) {
      throw const FormatException('Invalid ElectrumX UTXO entry.');
    }

    final txHash = value['tx_hash'];
    final txPos = value['tx_pos'];
    final height = value['height'];
    final satoshis = value['value'];
    if (txHash is! String ||
        !_transactionHash.hasMatch(txHash) ||
        txPos is! int ||
        txPos < 0 ||
        height is! int ||
        height < 0 ||
        satoshis is! int ||
        satoshis < 0) {
      throw const FormatException('Invalid ElectrumX UTXO entry.');
    }

    return ElectrumxUtxo(
      address: address,
      txHash: txHash,
      txPos: txPos,
      height: height,
      value: satoshis,
    );
  }

  static final _transactionHash = RegExp(r'^[0-9a-fA-F]{64}$');
}

class ElectrumxTransactionHistoryEntry {
  const ElectrumxTransactionHistoryEntry({
    required this.transactionId,
    required this.height,
    this.confirmations,
    this.timestamp,
    this.netSats,
    this.feeSats,
    this.outputs = const [],
    this.inputOutpoints = const [],
  });

  final String transactionId;
  final int height;
  final int? confirmations;
  final DateTime? timestamp;
  final int? netSats;
  final int? feeSats;
  final List<ElectrumxTransactionOutput> outputs;
  final List<String> inputOutpoints;

  bool get isConfirmed => height > 0;
  bool get hasTransactionDetails => netSats != null;

  static ElectrumxTransactionHistoryEntry fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Invalid ElectrumX history entry.');
    }
    final transactionId = value['tx_hash'];
    final height = value['height'];
    if (transactionId is! String ||
        !_transactionHash.hasMatch(transactionId) ||
        height is! int ||
        height < -1) {
      throw const FormatException('Invalid ElectrumX history entry.');
    }
    return ElectrumxTransactionHistoryEntry(
      transactionId: transactionId,
      height: height,
    );
  }

  static final _transactionHash = RegExp(r'^[0-9a-fA-F]{64}$');
}

typedef ElectrumxTransactionOutput = ({int value, String? address});
