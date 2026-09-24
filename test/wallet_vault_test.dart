import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
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
    );

    final restored = WalletVault.fromJson(vault.toJson());

    expect(restored.accounts.single.blockchainId, 'peercoin');
    expect(restored.accounts.single.networkId, 'testnet');
  });

  test('rejects unsupported schemas', () {
    expect(() => WalletVault.fromJson({'schemaVersion': 0}), throwsStateError);
  });
}
