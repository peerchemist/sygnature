import 'package:flutter/foundation.dart';

import '../models/wallet_account.dart';
import '../models/wallet_vault.dart';
import '../storage/wallet_repository.dart';

/// Presentation controller only. Coin-specific derivation belongs behind the
/// future coinlib adapter, not in this class.
class WalletController extends ChangeNotifier {
  WalletController(this._repository);

  final WalletRepository _repository;
  WalletVault? _vault;
  int _selectedAccount = 0;
  bool _busy = false;

  WalletVault? get vault => _vault;
  bool get hasWallet => _vault != null;
  bool get busy => _busy;
  List<WalletAccount> get accounts => _vault?.accounts ?? const [];
  int get selectedAccountIndex => _selectedAccount;
  WalletAccount? get selectedAccount => accounts.isEmpty
      ? null
      : accounts[_selectedAccount.clamp(0, accounts.length - 1)];

  Future<void> load() async {
    _vault = await _repository.load();
    _selectedAccount = 0;
    notifyListeners();
  }

  /// Creates the persistent multi-wallet shell. The first account intentionally
  /// has no address/key until coinlib supplies derived material.
  Future<void> createWalletShell({
    String? languageId,
    int? mnemonicWordCount,
  }) async {
    await _guard(() async {
      final first = _emptyAccount(0, 'Main wallet');
      final vault = WalletVault(
        languageId: languageId,
        mnemonicWordCount: mnemonicWordCount,
        accounts: [first],
        nextAccountIndex: 1,
      );
      await _repository.save(vault);
      _vault = vault;
      _selectedAccount = 0;
    });
  }

  Future<void> addAccount(String name) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Wallet name cannot be empty.');
    }
    await _guard(() async {
      final account = _emptyAccount(current.nextAccountIndex, trimmedName);
      final next = current.copyWith(
        accounts: [...current.accounts, account],
        nextAccountIndex: current.nextAccountIndex + 1,
      );
      await _repository.save(next);
      _vault = next;
      _selectedAccount = next.accounts.length - 1;
    });
  }

  /// Integration seam for coinlib: atomically stores derived public and secret
  /// material in the already encrypted vault.
  ///
  /// TODO(coinlib): accept only Taproot BIP-86 material. Legacy P2PKH, nested
  /// SegWit and native SegWit accounts are intentionally out of scope.
  Future<void> attachDerivedMaterial({
    required int accountIndex,
    required String address,
    required String privateKeyHex,
    required String derivationPath,
  }) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    await _guard(() async {
      var found = false;
      final updated = current.accounts
          .map((account) {
            if (account.accountIndex != accountIndex) return account;
            found = true;
            return WalletAccount(
              id: account.id,
              name: account.name,
              accountIndex: account.accountIndex,
              derivationPath: derivationPath,
              address: address,
              privateKeyHex: privateKeyHex,
              createdAt: account.createdAt,
            );
          })
          .toList(growable: false);
      if (!found) throw ArgumentError('Unknown account index: $accountIndex');
      final next = current.copyWith(accounts: updated);
      await _repository.save(next);
      _vault = next;
    });
  }

  void selectAccount(int index) {
    if (index < 0 || index >= accounts.length) return;
    _selectedAccount = index;
    notifyListeners();
  }

  Future<void> resetWallet() async {
    await _guard(() async {
      await _repository.delete();
      _vault = null;
      _selectedAccount = 0;
    });
  }

  WalletAccount _emptyAccount(int index, String name) => WalletAccount(
    id: 'ppc-$index',
    name: name,
    accountIndex: index,
    createdAt: DateTime.now().toUtc(),
  );

  Future<void> _guard(Future<void> Function() operation) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await operation();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
