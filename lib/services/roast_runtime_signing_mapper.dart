part of 'roast_runtime_manager.dart';

RoastSigningRequest _mapSigningRequest(
  WorkerSigningRequest request, {
  required String idHex,
}) {
  final proposal = request.decodeProposal();
  final metadata = proposal.metadata;
  final kind = switch (metadata) {
    TaprootTransactionSignatureMetadata() =>
      RoastSigningRequestKind.transaction,
    MessageSignatureMetadata() => RoastSigningRequestKind.message,
    _ => RoastSigningRequestKind.unsupported,
  };
  var inputSats = 0;
  var transactionInputCount = 0;
  var usesSupportedSighash = false;
  final usesExpectedTaprootTweak = proposal.requiredSigs.every(
    (signature) => signature.signDetails.mastHash?.isEmpty == true,
  );
  final usesUntweakedKey = proposal.requiredSigs.every(
    (signature) => signature.signDetails.mastHash == null,
  );
  var signedInputIndexes = const <int>[];
  var previousOutputScripts = const <String>[];
  var inputOutpoints = const <String>[];
  var outputs = const <RoastSigningOutput>[];
  final hasTransactionMetadata =
      metadata is TaprootTransactionSignatureMetadata;
  if (metadata is TaprootTransactionSignatureMetadata) {
    transactionInputCount = metadata.transaction.inputs.length;
    inputOutpoints = [
      for (final input in metadata.transaction.inputs)
        '${bytesToHex(Uint8List.fromList(input.prevOut.hash.reversed.toList()))}:${input.prevOut.n}',
    ];
    usesSupportedSighash = metadata.signDetails.every(
      (details) =>
          details is TaprootKeySignDetails && details.hashType.schnorrDefault,
    );
    signedInputIndexes = [
      for (final details in metadata.signDetails) details.inputN,
    ];
    final previousOutputSets = metadata.signDetails
        .where((details) => details.prevOuts.isNotEmpty)
        .map((details) => details.prevOuts)
        .toList();
    if (previousOutputSets.isNotEmpty) {
      final previousOutputs = previousOutputSets.reduce(
        (first, next) => first.length >= next.length ? first : next,
      );
      inputSats = previousOutputs.fold(
        0,
        (sum, output) => sum + output.value.toInt(),
      );
      previousOutputScripts = [
        for (final output in previousOutputs) bytesToHex(output.scriptPubKey),
      ];
    }
    outputs = [
      for (final output in metadata.transaction.outputs)
        RoastSigningOutput(
          valueSats: output.value.toInt(),
          scriptHex: bytesToHex(output.scriptPubKey),
        ),
    ];
  }
  return RoastSigningRequest(
    idHex: idHex,
    proposalHex: bytesToHex(request.proposalBytes),
    creator: request.creator,
    expiry: request.expiry,
    kind: kind,
    hasTransactionMetadata: hasTransactionMetadata,
    usesSupportedSighash: usesSupportedSighash,
    usesExpectedTaprootTweak: usesExpectedTaprootTweak,
    usesUntweakedKey: usesUntweakedKey,
    status: request.status,
    progress: RoastSigningProgress(
      threshold: request.progress.threshold,
      contributingParticipants: List.unmodifiable(
        request.progress.contributingParticipants,
      ),
      stage: request.progress.stage,
    ),
    inputSats: inputSats,
    transactionInputCount: transactionInputCount,
    signedInputIndexes: signedInputIndexes,
    previousOutputScripts: previousOutputScripts,
    inputOutpoints: inputOutpoints,
    outputs: outputs,
    masterGroupKeys: [
      for (final signature in proposal.requiredSigs) signature.groupKey.hex,
    ],
    derivationPaths: [
      for (final signature in proposal.requiredSigs)
        List.unmodifiable(signature.hdDerivation),
    ],
    message: proposal.message,
    signedMessageText: metadata is MessageSignatureMetadata
        ? metadata.payload.text
        : null,
  );
}
