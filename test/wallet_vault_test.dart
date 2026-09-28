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
      activities: [
        WalletActivity(
          id: 'signed:1',
          accountId: 'peercoin-testnet-0',
          type: WalletActivityType.transactionSigned,
          occurredAt: DateTime.utc(2026, 1, 2, 3, 4),
          reference: 'transaction-id',
        ),
      ],
    );

    final restored = WalletVault.fromJson(vault.toJson());

    expect(restored.accounts.single.blockchainId, 'peercoin');
    expect(restored.accounts.single.networkId, 'testnet');
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
      restored.activities.single.occurredAt,
      DateTime.utc(2026, 1, 2, 3, 4),
    );
  });

  test('migrates older vaults with an empty activity feed', () {
    final json = WalletVault(accounts: const [], nextAccountIndex: 0).toJson()
      ..['schemaVersion'] = 3
      ..remove('activities');

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
      'schemaVersion': 4,
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
  });

  test('round trips every explicit derivation state', () {
    for (final state in WalletDerivationState.values) {
      final account = WalletAccount(
        id: state.name,
        name: state.name,
        accountIndex: 0,
        blockchainId: 'peercoin',
        networkId: 'mainnet',
        derivationState: state,
        createdAt: DateTime.utc(2026),
      );

      expect(WalletAccount.fromJson(account.toJson()).derivationState, state);
    }
  });

  test('rejects unsupported schemas', () {
    expect(() => WalletVault.fromJson({'schemaVersion': 0}), throwsStateError);
  });
}
