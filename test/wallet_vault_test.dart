import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/models/wallet_activity.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';

void main() {
  test('preserves the network selected for each account', () {
    final vault = WalletVault(
      accounts: [
        WalletAccount(
          id: 'peercoin-testnet-0',
          name: 'Test wallet',
          accountIndex: 0,
          blockchainId: 'peercoin',
          networkId: 'testnet',
          derivationState: WalletDerivationState.pending,
          createdAt: DateTime.utc(2026),
        ),
      ],
      nextAccountIndex: 0,
      selectedAccountId: 'peercoin-testnet-0',
      activities: [
        WalletActivity(
          id: 'signed:1',
          accountId: 'peercoin-testnet-0',
          type: WalletActivityType.transactionSigned,
          occurredAt: DateTime.utc(2026, 1, 2, 3, 4),
          reference: 'transaction-id',
          transactionStatus: WalletTransactionStatus.confirmed,
          blockHeight: 123,
        ),
      ],
    );

    expect(vault.toJson()['schemaVersion'], WalletVault.schemaVersion);
    final restored = WalletVault.fromJson(vault.toJson());

    expect(restored.accounts.single.blockchainId, 'peercoin');
    expect(restored.accounts.single.networkId, 'testnet');
    expect(restored.selectedAccountId, 'peercoin-testnet-0');
    expect(
      restored.accounts.single.derivationState,
      WalletDerivationState.pending,
    );
    expect(
      restored.activities.single.type,
      WalletActivityType.transactionSigned,
    );
    expect(restored.activities.single.reference, 'transaction-id');
    expect(
      restored.activities.single.transactionStatus,
      WalletTransactionStatus.confirmed,
    );
    expect(restored.activities.single.blockHeight, 123);
    expect(
      restored.activities.single.occurredAt,
      DateTime.utc(2026, 1, 2, 3, 4),
    );
  });

  test('round trips a completed signed message activity', () {
    final original = WalletActivity(
      id: 'message-signed:setup:request',
      accountId: 'shared',
      type: WalletActivityType.messageSigned,
      occurredAt: DateTime.utc(2026),
      details: 'Hello world',
      signedMessagePublicKeyHex: 'public-key',
      signedMessageSignatureHex: 'signature',
      signedMessageEncoded: 'portable-message',
    );

    final restored = WalletActivity.fromJson(original.toJson());

    expect(restored.details, 'Hello world');
    expect(restored.signedMessagePublicKeyHex, 'public-key');
    expect(restored.signedMessageSignatureHex, 'signature');
    expect(restored.signedMessageEncoded, 'portable-message');
  });

  test('round trips a request activity expiry', () {
    final expiresAt = DateTime.utc(2026, 1, 2, 3, 4);
    final original = WalletActivity(
      id: 'message-signature-requested:setup:request',
      accountId: 'shared',
      type: WalletActivityType.messageSignatureRequested,
      occurredAt: DateTime.utc(2026),
      expiresAt: expiresAt,
      reference: 'request',
    );

    final restored = WalletActivity.fromJson(original.toJson());

    expect(restored.expiresAt, expiresAt);
  });

  test('round trips a vault with an empty activity feed', () {
    final json = WalletVault(accounts: const [], nextAccountIndex: 0).toJson();

    expect(WalletVault.fromJson(json).activities, isEmpty);
  });

  test('migrates legacy nullable derivation data to explicit states', () {
    Map<String, Object?> account({
      required String id,
      String? address,
      String? privateKeyHex,
      String? keySource,
    }) => {
      'id': id,
      'name': id,
      'accountIndex': 0,
      'blockchainId': 'peercoin',
      'networkId': 'mainnet',
      'keySource': ?keySource,
      'address': address,
      'privateKeyHex': privateKeyHex,
      'createdAt': '2026-01-01T00:00:00.000Z',
    };

    final restored = WalletVault.fromJson({
      'schemaVersion': 1,
      'accounts': [
        account(id: 'ready', address: 'pc1pready', privateKeyHex: 'secret'),
        account(id: 'watch', address: 'pc1pwatch'),
        account(id: 'pending'),
        account(id: 'roast', address: 'pc1proast', keySource: 'roast'),
      ],
      'nextAccountIndex': 1,
      'roastSetups': const [],
      'activities': const [],
    });

    expect(restored.accounts.map((account) => account.derivationState), [
      WalletDerivationState.ready,
      WalletDerivationState.watchOnly,
      WalletDerivationState.pending,
      WalletDerivationState.ready,
    ]);
    expect(restored.accounts[1].keySource, WalletKeySource.watchOnly);
  });

  test('round trips every explicit derivation state', () {
    for (final state in WalletDerivationState.values) {
      final keySource = state == WalletDerivationState.watchOnly
          ? WalletKeySource.watchOnly
          : WalletKeySource.personal;
      final account = WalletAccount(
        id: state.name,
        name: state.name,
        accountIndex: 0,
        blockchainId: 'peercoin',
        networkId: 'mainnet',
        derivationState: state,
        keySource: keySource,
        createdAt: DateTime.utc(2026),
      );

      final restored = WalletAccount.fromJson(account.toJson());
      expect(restored.derivationState, state);
      expect(restored.keySource, keySource);
    }
  });

  test('round trips archived account state and restores it', () {
    final account = WalletAccount(
      id: 'archived',
      name: 'Archived',
      accountIndex: 4,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      derivationState: WalletDerivationState.ready,
      createdAt: DateTime.utc(2026),
    ).archive(DateTime.utc(2026, 10, 5, 12, 30));

    final restored = WalletAccount.fromJson(account.toJson());

    expect(restored.isArchived, isTrue);
    expect(restored.archivedAt, DateTime.utc(2026, 10, 5, 12, 30));
    expect(restored.restore().isArchived, isFalse);
  });

  test('rejects unsupported schemas', () {
    for (final version in [0, 2, 3, 4, 5, 6]) {
      expect(
        () => WalletVault.fromJson({'schemaVersion': version}),
        throwsStateError,
      );
    }
  });
}
