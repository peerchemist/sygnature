import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/wallet_transaction.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/roast_key_service.dart';
import 'package:sygnature_ng/services/wallet_transaction_service.dart';

import 'fixtures/peercoin_taproot_transaction_fixture.dart';

void main() {
  const service = CoinlibWalletTransactionService();
  final sourceKeyHex = '${List.filled(63, '0').join()}1';
  late ECPrivateKey sourceKey;
  late ECPrivateKey destinationKey;
  late String sourceAddress;
  late String destinationAddress;

  setUpAll(() async {
    await loadCoinlib();
    sourceKey = ECPrivateKey.fromHex(sourceKeyHex);
    destinationKey = ECPrivateKey.fromHex('${List.filled(63, '0').join()}2');
    sourceAddress = P2TRAddress.fromTweakedKey(
      sourceKey.pubkey,
      hrp: Network.mainnet.bech32Hrp,
    ).toString();
    destinationAddress = P2TRAddress.fromTweakedKey(
      destinationKey.pubkey,
      hrp: Network.mainnet.bech32Hrp,
    ).toString();
  });

  test('prepares and signs a Taproot key-path spend', () {
    final preview = service.prepare(
      accountId: 'wallet-0',
      network: PeercoinNetworks.mainnet,
      sourceAddress: sourceAddress,
      availableUtxos: [
        ElectrumxUtxo(
          address: sourceAddress,
          txHash: List.filled(64, 'a').join(),
          txPos: 1,
          height: 100,
          value: 2000000,
        ),
      ],
      request: WalletSendRequest(
        destinationAddress: destinationAddress,
        amountSats: 1000000,
        feeRateSatsPerKb: Network.mainnet.feePerKb.toInt(),
        signingMessage: 'Quarterly hosting bill',
      ),
    );

    expect(preview.selectedUtxos, hasLength(1));
    expect(preview.amountSats, 1000000);
    expect(preview.signingMessage, 'Quarterly hosting bill');
    expect(
      preview.feeSats,
      greaterThanOrEqualTo(Network.mainnet.minFee.toInt()),
    );
    expect(preview.changeSats, 2000000 - preview.amountSats - preview.feeSats);

    final signed = service.sign(
      network: PeercoinNetworks.mainnet,
      preview: preview,
      privateKeyHex: sourceKeyHex,
    );
    final transaction = Transaction.fromHex(signed.rawTransactionHex);

    expect(transaction.complete, isTrue);
    expect(transaction.txid, signed.transactionId);
    expect(transaction.inputs, hasLength(1));
    expect(transaction.outputs, hasLength(2));
    expect(
      transaction.outputs.any(
        (output) => bytesEqual(
          output.scriptPubKey,
          Address.fromString(
            sourceAddress,
            Network.mainnet,
          ).program.script.compiled,
        ),
      ),
      isTrue,
    );
  });

  test('rejects destination addresses from another network', () {
    final testnetAddresses = [
      P2TRAddress.fromTweakedKey(
        destinationKey.pubkey,
        hrp: Network.testnet.bech32Hrp,
      ),
      P2PKHAddress.fromPublicKey(
        destinationKey.pubkey,
        version: Network.testnet.p2pkhPrefix,
      ),
      P2SHAddress.fromRedeemScript(
        P2PKH.fromPublicKey(destinationKey.pubkey).script,
        version: Network.testnet.p2shPrefix,
      ),
    ];

    for (final testnetAddress in testnetAddresses) {
      expect(
        () => service.prepare(
          accountId: 'wallet-0',
          network: PeercoinNetworks.mainnet,
          sourceAddress: sourceAddress,
          availableUtxos: const [],
          request: WalletSendRequest(
            destinationAddress: testnetAddress.toString(),
            amountSats: 1000000,
            feeRateSatsPerKb: 10000,
          ),
        ),
        throwsA(isA<InvalidDestinationAddress>()),
      );
    }
  });

  test('sends Taproot funds to P2PKH and P2SH addresses', () {
    final destinations = [
      P2PKHAddress.fromPublicKey(
        destinationKey.pubkey,
        version: Network.mainnet.p2pkhPrefix,
      ),
      P2SHAddress.fromRedeemScript(
        P2PKH.fromPublicKey(destinationKey.pubkey).script,
        version: Network.mainnet.p2shPrefix,
      ),
    ];

    for (final destination in destinations) {
      final preview = service.prepare(
        accountId: 'wallet-0',
        network: PeercoinNetworks.mainnet,
        sourceAddress: sourceAddress,
        availableUtxos: [
          ElectrumxUtxo(
            address: sourceAddress,
            txHash: List.filled(64, 'e').join(),
            txPos: 0,
            height: 100,
            value: 2000000,
          ),
        ],
        request: WalletSendRequest(
          destinationAddress: destination.toString(),
          amountSats: 1000000,
          feeRateSatsPerKb: Network.mainnet.feePerKb.toInt(),
        ),
      );
      final signed = service.sign(
        network: PeercoinNetworks.mainnet,
        preview: preview,
        privateKeyHex: sourceKeyHex,
      );
      final transaction = Transaction.fromHex(signed.rawTransactionHex);

      expect(transaction.complete, isTrue);
      expect(
        transaction.outputs.any(
          (output) => bytesEqual(
            output.scriptPubKey,
            destination.program.script.compiled,
          ),
        ),
        isTrue,
      );
    }
  });

  test('formats P2PKH and P2SH outputs for ROAST review', () {
    const keyService = RoastKeyService();
    final destinations = [
      P2PKHAddress.fromPublicKey(
        destinationKey.pubkey,
        version: Network.mainnet.p2pkhPrefix,
      ),
      P2SHAddress.fromRedeemScript(
        P2PKH.fromPublicKey(destinationKey.pubkey).script,
        version: Network.mainnet.p2shPrefix,
      ),
    ];

    for (final destination in destinations) {
      final scriptHex = bytesToHex(destination.program.script.compiled);
      expect(
        keyService.addressForScript(PeercoinNetworks.mainnet, scriptHex),
        destination.toString(),
      );
    }
  });

  test('assembles and verifies externally produced threshold signatures', () {
    final taproot = Taproot(internalKey: sourceKey.pubkey);
    final thresholdAddress = P2TRAddress.fromTaproot(
      taproot,
      hrp: Network.mainnet.bech32Hrp,
    ).toString();
    final preview = service.prepare(
      accountId: 'shared-wallet-0',
      network: PeercoinNetworks.mainnet,
      sourceAddress: thresholdAddress,
      availableUtxos: [
        ElectrumxUtxo(
          address: thresholdAddress,
          txHash: List.filled(64, 'd').join(),
          txPos: 0,
          height: 100,
          value: 2000000,
        ),
      ],
      request: WalletSendRequest(
        destinationAddress: destinationAddress,
        amountSats: 1000000,
        feeRateSatsPerKb: Network.mainnet.feePerKb.toInt(),
      ),
    );
    final unsigned = service.prepareThresholdSigning(
      network: PeercoinNetworks.mainnet,
      preview: preview,
    );
    final restored = ThresholdWalletTransaction.fromJson(unsigned.toJson());
    expect(
      bytesToHex(restored.transaction.toBytes()),
      bytesToHex(unsigned.transaction.toBytes()),
    );
    expect(
      restored.signatureHashes.map(bytesToHex),
      unsigned.signatureHashes.map(bytesToHex),
    );
    final tweakedPrivateKey = taproot.tweakPrivateKey(sourceKey);
    final signatures = [
      for (final hash in unsigned.signatureHashes)
        SchnorrSignature.sign(tweakedPrivateKey, hash).data,
    ];

    final signed = service.completeThresholdSigning(
      transaction: restored,
      signatures: signatures,
      expectedInternalKeyHex: sourceKey.pubkey.hex,
    );

    expect(Transaction.fromHex(signed.rawTransactionHex).complete, isTrue);
    expect(
      () => service.completeThresholdSigning(
        transaction: unsigned,
        signatures: [SchnorrSignature.sign(destinationKey, Uint8List(32)).data],
        expectedInternalKeyHex: sourceKey.pubkey.hex,
      ),
      throwsA(isA<WalletTransactionRejected>()),
    );
  });

  test('matches the deterministic Taproot transaction fixture', () {
    final internalKey = ECPrivateKey.fromHex(fixtureInternalPrivateKeyHex);
    final taproot = Taproot(internalKey: internalKey.pubkey);
    final spendKey = taproot.tweakPrivateKey(internalKey);
    final destinationKey = ECPrivateKey.fromHex(
      fixtureDestinationPrivateKeyHex,
    );

    expect(internalKey.pubkey.hex, fixtureInternalPublicKeyHex);
    expect(bytesToHex(spendKey.data), fixtureSpendPrivateKeyHex);
    expect(
      P2TRAddress.fromTaproot(
        taproot,
        hrp: Network.mainnet.bech32Hrp,
      ).toString(),
      fixtureSourceAddress,
    );
    expect(
      P2TRAddress.fromTweakedKey(
        destinationKey.pubkey,
        hrp: Network.mainnet.bech32Hrp,
      ).toString(),
      fixtureDestinationAddress,
    );

    final preview = service.prepare(
      accountId: 'fixture-wallet',
      network: PeercoinNetworks.mainnet,
      sourceAddress: fixtureSourceAddress,
      availableUtxos: const [
        ElectrumxUtxo(
          address: fixtureSourceAddress,
          txHash: fixtureUtxoTransactionId,
          txPos: fixtureUtxoIndex,
          height: 100,
          value: fixtureUtxoValue,
        ),
      ],
      request: const WalletSendRequest(
        destinationAddress: fixtureDestinationAddress,
        amountSats: 0,
        feeRateSatsPerKb: fixtureFeeRate,
        maximum: true,
      ),
    );

    expect(preview.amountSats, fixtureAmount);
    expect(preview.feeSats, fixtureFee);
    expect(preview.changeSats, fixtureChange);

    final unsigned = service.prepareThresholdSigning(
      network: PeercoinNetworks.mainnet,
      preview: preview,
    );
    expect(
      bytesToHex(unsigned.transaction.toBytes()),
      fixtureUnsignedTransactionHex,
    );
    expect(
      bytesToHex(unsigned.signatureHashes.single),
      fixtureSignatureHashHex,
    );

    final signature = SchnorrSignature.sign(
      spendKey,
      unsigned.signatureHashes.single,
    );
    expect(bytesToHex(signature.data), fixtureSignatureHex);

    final thresholdSigned = service.completeThresholdSigning(
      transaction: unsigned,
      signatures: [signature.data],
      expectedInternalKeyHex: fixtureInternalPublicKeyHex,
    );
    expect(thresholdSigned.rawTransactionHex, fixtureSignedTransactionHex);
    expect(thresholdSigned.transactionId, fixtureTransactionId);

    final locallySigned = service.sign(
      network: PeercoinNetworks.mainnet,
      preview: preview,
      privateKeyHex: fixtureSpendPrivateKeyHex,
    );
    expect(locallySigned.rawTransactionHex, fixtureSignedTransactionHex);
    expect(locallySigned.transactionId, fixtureTransactionId);
  });

  test('maximum spend deducts the fee and creates no change', () {
    final preview = service.prepare(
      accountId: 'wallet-0',
      network: PeercoinNetworks.mainnet,
      sourceAddress: sourceAddress,
      availableUtxos: [
        ElectrumxUtxo(
          address: sourceAddress,
          txHash: List.filled(64, 'c').join(),
          txPos: 0,
          height: 100,
          value: 100000,
        ),
      ],
      request: WalletSendRequest(
        destinationAddress: destinationAddress,
        amountSats: 0,
        feeRateSatsPerKb: Network.mainnet.feePerKb.toInt(),
        maximum: true,
      ),
    );

    expect(preview.changeSats, 0);
    expect(preview.amountSats + preview.feeSats, 100000);
  });

  test('rejects amounts that do not leave enough value for the fee', () {
    expect(
      () => service.prepare(
        accountId: 'wallet-0',
        network: PeercoinNetworks.mainnet,
        sourceAddress: sourceAddress,
        availableUtxos: [
          ElectrumxUtxo(
            address: sourceAddress,
            txHash: List.filled(64, 'b').join(),
            txPos: 0,
            height: 100,
            value: 1000000,
          ),
        ],
        request: WalletSendRequest(
          destinationAddress: destinationAddress,
          amountSats: 1000000,
          feeRateSatsPerKb: 10000,
        ),
      ),
      throwsA(isA<WalletInsufficientFunds>()),
    );
  });
}
