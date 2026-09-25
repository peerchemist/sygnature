import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/wallet_transaction.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/wallet_transaction_service.dart';

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
      ),
    );

    expect(preview.selectedUtxos, hasLength(1));
    expect(preview.amountSats, 1000000);
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

  test('rejects a Taproot address from another network', () {
    final testnetAddress = P2TRAddress.fromTweakedKey(
      destinationKey.pubkey,
      hrp: Network.testnet.bech32Hrp,
    ).toString();

    expect(
      () => service.prepare(
        accountId: 'wallet-0',
        network: PeercoinNetworks.mainnet,
        sourceAddress: sourceAddress,
        availableUtxos: const [],
        request: WalletSendRequest(
          destinationAddress: testnetAddress,
          amountSats: 1000000,
          feeRateSatsPerKb: 10000,
        ),
      ),
      throwsA(isA<InvalidDestinationAddress>()),
    );
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
          value: 2000000,
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
    expect(preview.amountSats + preview.feeSats, 2000000);
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
