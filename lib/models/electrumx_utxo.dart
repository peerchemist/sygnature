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
