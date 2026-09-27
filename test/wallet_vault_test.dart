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

  test('rejects unsupported schemas', () {
    expect(() => WalletVault.fromJson({'schemaVersion': 0}), throwsStateError);
  });
}
