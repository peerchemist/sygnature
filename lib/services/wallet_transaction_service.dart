import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';

import '../models/electrumx_utxo.dart';
import '../models/wallet_network.dart';
import '../models/wallet_transaction.dart';
import 'peercoin_network_service.dart';

sealed class WalletTransactionFailure implements Exception {
  const WalletTransactionFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class InvalidDestinationAddress extends WalletTransactionFailure {
  const InvalidDestinationAddress()
    : super('Enter a valid Taproot address for the selected network.');
}

class InvalidSendAmount extends WalletTransactionFailure {
  const InvalidSendAmount() : super('Enter an amount greater than zero.');
}

class InvalidFeeRate extends WalletTransactionFailure {
  const InvalidFeeRate() : super('Enter a fee rate greater than zero.');
}

class WalletInsufficientFunds extends WalletTransactionFailure {
  const WalletInsufficientFunds()
    : super('The wallet does not have enough funds for the amount and fee.');
}

class WalletSigningUnavailable extends WalletTransactionFailure {
  const WalletSigningUnavailable()
    : super('Signing material is unavailable for this wallet.');
}

class WalletTransactionRejected extends WalletTransactionFailure {
  const WalletTransactionRejected(super.message);
}

abstract interface class WalletTransactionService {
  WalletTransactionPreview prepare({
    required String accountId,
    required WalletNetwork network,
    required String sourceAddress,
    required List<ElectrumxUtxo> availableUtxos,
    required WalletSendRequest request,
  });

  SignedWalletTransaction sign({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
    required String privateKeyHex,
  });

  ThresholdWalletTransaction prepareThresholdSigning({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
  });

  SignedWalletTransaction completeThresholdSigning({
    required ThresholdWalletTransaction transaction,
    required List<Uint8List> signatures,
    required String expectedInternalKeyHex,
  });
}

class ThresholdWalletTransaction({
  required final Transaction transaction,
  required final List<TaprootKeySignDetails> signDetails,
}) {
  List<Uint8List> get signatureHashes => [
    for (final details in signDetails) TaprootSignatureHasher(details).hash,
  ];

  Map<String, Object?> toJson() => {
    'transactionHex': bytesToHex(transaction.toBytes()),
    'previousOutputs': [
      for (final output in signDetails.first.prevOuts)
        {
          'value': output.value.toString(),
          'scriptHex': bytesToHex(output.scriptPubKey),
        },
    ],
    'inputIndexes': [for (final details in signDetails) details.inputN],
  };

  factory ThresholdWalletTransaction.fromJson(Map<Object?, Object?> json) {
    final transaction = Transaction.fromHex(json['transactionHex']! as String);
    final previousOutputs = (json['previousOutputs']! as List)
        .map((raw) {
          final output = raw as Map;
          return Output.fromScriptBytes(
            BigInt.parse(output['value']! as String),
            hexToBytes(output['scriptHex']! as String),
          );
        })
        .toList(growable: false);
    final inputIndexes = (json['inputIndexes']! as List).cast<int>();
    if (inputIndexes.length != transaction.inputs.length ||
        previousOutputs.length != transaction.inputs.length) {
      throw const FormatException('Invalid stored threshold transaction.');
    }
    return ThresholdWalletTransaction(
      transaction: transaction,
      signDetails: [
        for (final inputIndex in inputIndexes)
          TaprootKeySignDetails(
            tx: transaction,
            inputN: inputIndex,
            prevOuts: previousOutputs,
          ),
      ],
    );
  }
}

class CoinlibWalletTransactionService implements WalletTransactionService {
  const CoinlibWalletTransactionService();

  @override
  WalletTransactionPreview prepare({
    required String accountId,
    required WalletNetwork network,
    required String sourceAddress,
    required List<ElectrumxUtxo> availableUtxos,
    required WalletSendRequest request,
  }) {
    if (!request.maximum && request.amountSats <= 0) {
      throw const InvalidSendAmount();
    }

    final preset = PeercoinNetworks.fromWalletNetwork(network);
    final destination = _taprootAddress(
      request.destinationAddress.trim(),
      preset.network,
    );
    final source = _taprootAddress(sourceAddress, preset.network);
    if (request.feeRateSatsPerKb <= 0) {
      throw const InvalidFeeRate();
    }

    final candidates = availableUtxos
        .where((utxo) => utxo.address == sourceAddress && utxo.value > 0)
        .map(_candidate)
        .toList(growable: false);
    final feePerKb = BigInt.from(request.feeRateSatsPerKb);
    final amountSats = request.maximum
        ? _maximumAmount(
            candidates: candidates,
            destination: destination,
            change: source,
            feePerKb: feePerKb,
            minFee: preset.network.minFee,
            minChange: preset.network.minOutput,
          )
        : request.amountSats;
    if (amountSats <= 0) throw const WalletInsufficientFunds();
    final recipient = Output.fromAddress(BigInt.from(amountSats), destination);
    final selection = request.maximum
        ? CoinSelection(
            selected: candidates,
            recipients: [recipient],
            changeProgram: source.program,
            feePerKb: feePerKb,
            minFee: preset.network.minFee,
            minChange: preset.network.minOutput,
          )
        : CoinSelection.optimal(
            candidates: candidates,
            recipients: [recipient],
            changeProgram: source.program,
            feePerKb: feePerKb,
            minFee: preset.network.minFee,
            minChange: preset.network.minOutput,
          );
    if (!selection.ready) throw const WalletInsufficientFunds();

    final selectedUtxos = selection.selected
        .map(
          (candidate) => availableUtxos.firstWhere(
            (utxo) =>
                OutPoint.fromHex(utxo.txHash, utxo.txPos) ==
                candidate.input.prevOut,
          ),
        )
        .toList(growable: false);

    return WalletTransactionPreview(
      accountId: accountId,
      sourceAddress: sourceAddress,
      destinationAddress: destination.toString(),
      amountSats: amountSats,
      feeSats: selection.fee.toInt(),
      changeSats: selection.changeValue.toInt(),
      feeRateSatsPerKb: request.feeRateSatsPerKb,
      selectedUtxos: List.unmodifiable(selectedUtxos),
    );
  }

  @override
  SignedWalletTransaction sign({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
    required String privateKeyHex,
  }) {
    final built = _buildTransaction(network: network, preview: preview);
    var transaction = built.transaction;
    for (
      var inputIndex = 0;
      inputIndex < transaction.inputs.length;
      inputIndex++
    ) {
      transaction = transaction.signTaproot(
        inputN: inputIndex,
        key: ECPrivateKey.fromHex(privateKeyHex),
        prevOuts: built.previousOutputs,
      );
    }
    if (!transaction.complete) {
      throw const WalletTransactionRejected('Unable to sign the transaction.');
    }
    return SignedWalletTransaction(
      transactionId: transaction.txid,
      rawTransactionHex: bytesToHex(transaction.toBytes()),
    );
  }

  @override
  ThresholdWalletTransaction prepareThresholdSigning({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
  }) {
    final built = _buildTransaction(network: network, preview: preview);
    return ThresholdWalletTransaction(
      transaction: built.transaction,
      signDetails: [
        for (
          var inputIndex = 0;
          inputIndex < built.transaction.inputs.length;
          inputIndex++
        )
          TaprootKeySignDetails(
            tx: built.transaction,
            inputN: inputIndex,
            prevOuts: built.previousOutputs,
          ),
      ],
    );
  }

  @override
  SignedWalletTransaction completeThresholdSigning({
    required ThresholdWalletTransaction transaction,
    required List<Uint8List> signatures,
    required String expectedInternalKeyHex,
  }) {
    if (signatures.length != transaction.signDetails.length) {
      throw const WalletTransactionRejected(
        'The coordinator returned an unexpected signature count.',
      );
    }
    final outputKey = Taproot(
      internalKey: ECCompressedPublicKey.fromHex(expectedInternalKeyHex),
    ).tweakedKey;
    var signed = transaction.transaction;
    for (var index = 0; index < signatures.length; index++) {
      final signature = SchnorrSignature(signatures[index]);
      final hash = TaprootSignatureHasher(transaction.signDetails[index]).hash;
      if (!signature.verify(outputKey, hash)) {
        throw const WalletTransactionRejected(
          'The coordinator returned an invalid threshold signature.',
        );
      }
      final input = signed.inputs[index];
      if (input is! TaprootKeyInput) {
        throw const WalletTransactionRejected(
          'The threshold signature does not match a Taproot key input.',
        );
      }
      signed = signed.replaceInput(
        input.addSignature(SchnorrInputSignature(signature)),
        index,
      );
    }
    if (!signed.complete) {
      throw const WalletTransactionRejected('Unable to sign the transaction.');
    }
    return SignedWalletTransaction(
      transactionId: signed.txid,
      rawTransactionHex: bytesToHex(signed.toBytes()),
    );
  }

  static ({Transaction transaction, List<Output> previousOutputs})
  _buildTransaction({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
  }) {
    final preset = PeercoinNetworks.fromWalletNetwork(network);
    final source = _taprootAddress(preview.sourceAddress, preset.network);
    final destination = _taprootAddress(
      preview.destinationAddress,
      preset.network,
    );
    final candidates = preview.selectedUtxos.map(_candidate).toList();
    final selection = CoinSelection(
      selected: candidates,
      recipients: [
        Output.fromAddress(BigInt.from(preview.amountSats), destination),
      ],
      changeProgram: source.program,
      feePerKb: BigInt.from(preview.feeRateSatsPerKb),
      minFee: preset.network.minFee,
      minChange: preset.network.minOutput,
    );
    if (!selection.ready ||
        selection.fee.toInt() != preview.feeSats ||
        selection.changeValue.toInt() != preview.changeSats) {
      throw const WalletTransactionRejected(
        'The transaction preview is no longer valid.',
      );
    }
    return (
      transaction: selection.transaction,
      previousOutputs: preview.selectedUtxos
          .map((utxo) => Output.fromAddress(BigInt.from(utxo.value), source))
          .toList(growable: false),
    );
  }

  static InputCandidate _candidate(ElectrumxUtxo utxo) => InputCandidate(
    input: TaprootKeyInput(prevOut: OutPoint.fromHex(utxo.txHash, utxo.txPos)),
    value: BigInt.from(utxo.value),
    defaultSigHash: true,
  );

  static int _maximumAmount({
    required List<InputCandidate> candidates,
    required P2TRAddress destination,
    required P2TRAddress change,
    required BigInt feePerKb,
    required BigInt minFee,
    required BigInt minChange,
  }) {
    if (candidates.isEmpty) return 0;
    final estimate = CoinSelection(
      selected: candidates,
      recipients: [Output.fromAddress(BigInt.zero, destination)],
      changeProgram: change.program,
      feePerKb: feePerKb,
      minFee: minFee,
      minChange: minChange,
    );
    return (estimate.inputValue - estimate.fee).toInt();
  }

  static P2TRAddress _taprootAddress(String value, Network network) {
    try {
      final address = Address.fromString(value, network);
      if (address is P2TRAddress) return address;
    } on Exception {
      // The caller receives a stable, sanitized validation failure below.
    }
    throw const InvalidDestinationAddress();
  }
}
