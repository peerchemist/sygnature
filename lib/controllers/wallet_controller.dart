import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/electrumx_utxo.dart';
import '../models/wallet_account.dart';
import '../models/wallet_vault.dart';
import '../services/electrumx_service.dart';
import '../storage/wallet_repository.dart';

enum AccountSyncStatus { unavailable, syncing, synced, error }

class WalletController extends ChangeNotifier {
  WalletController(this._repository, {this.electrumxService});

  final WalletRepository _repository;
  final ElectrumxService? electrumxService;
  WalletVault? _vault;
  int _selectedAccount = 0;
  bool _busy = false;
  bool _disposed = false;
  int _syncGeneration = 0;
  StreamSubscription<PeercoinElectrumxUtxoSnapshot>? _syncSubscription;
  final Map<String, List<ElectrumxUtxo>> _utxosByAddress = {};
  final Map<String, Object> _syncErrorsByAddress = {};
  final Set<String> _syncingAddresses = {};

  WalletVault? get vault => _vault;
  bool get hasWallet => _vault != null;
  bool get busy => _busy;
  List<WalletAccount> get accounts => _vault?.accounts ?? const [];
  int get selectedAccountIndex => _selectedAccount;
  WalletAccount? get selectedAccount => accounts.isEmpty
      ? null
      : accounts[_selectedAccount.clamp(0, accounts.length - 1)];

  List<ElectrumxUtxo> utxosFor(WalletAccount account) {
    final address = account.address;
    return address == null ? const [] : _utxosByAddress[address] ?? const [];
  }

  int balanceSatsFor(WalletAccount account) {
    return utxosFor(account).fold(0, (total, utxo) => total + utxo.value);
  }

  AccountSyncStatus syncStatusFor(WalletAccount account) {
    final address = account.address;
    if (address == null || electrumxService == null) {
      return AccountSyncStatus.unavailable;
    }
    if (_syncErrorsByAddress.containsKey(address)) {
      return AccountSyncStatus.error;
    }
    if (_syncingAddresses.contains(address)) {
      return AccountSyncStatus.syncing;
    }
    return _utxosByAddress.containsKey(address)
        ? AccountSyncStatus.synced
        : AccountSyncStatus.syncing;
  }

  Object? syncErrorFor(WalletAccount account) {
    final address = account.address;
    return address == null ? null : _syncErrorsByAddress[address];
  }

  Future<void> load() async {
    _vault = await _repository.load();
    _selectedAccount = 0;
    await _restartElectrumxSync();
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
      await _restartElectrumxSync();
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
      await _restartElectrumxSync();
    });
  }

  Future<void> refreshBalances() => _restartElectrumxSync();

  Future<String> broadcastTransaction(String rawTransactionHex) {
    final service = electrumxService;
    if (service == null) {
      throw StateError('ElectrumX is not configured.');
    }
    return service.broadcastTransaction(rawTransactionHex);
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
      await _restartElectrumxSync();
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

  Future<void> _restartElectrumxSync() async {
    final generation = ++_syncGeneration;
    final previousSubscription = _syncSubscription;
    _syncSubscription = null;
    await previousSubscription?.cancel();
    if (_disposed || generation != _syncGeneration) return;

    final addresses = accounts
        .map((account) => account.address?.trim())
        .whereType<String>()
        .where((address) => address.isNotEmpty)
        .toSet();
    _utxosByAddress.removeWhere((address, _) => !addresses.contains(address));
    _syncErrorsByAddress.removeWhere(
      (address, _) => !addresses.contains(address),
    );
    _syncingAddresses
      ..clear()
      ..addAll(addresses);

    final service = electrumxService;
    if (service == null || addresses.isEmpty) {
      _syncingAddresses.clear();
      notifyListeners();
      return;
    }

    for (final address in addresses) {
      _syncErrorsByAddress.remove(address);
    }
    notifyListeners();
    _syncSubscription = service
        .watchUtxosForAddresses(addresses)
        .listen(
          (snapshot) {
            if (_disposed || generation != _syncGeneration) return;
            _utxosByAddress[snapshot.address] = List.unmodifiable(
              snapshot.utxos,
            );
            _syncingAddresses.remove(snapshot.address);
            _syncErrorsByAddress.remove(snapshot.address);
            notifyListeners();
          },
          onError: (Object error) {
            if (_disposed || generation != _syncGeneration) return;
            for (final address in addresses) {
              _syncErrorsByAddress[address] = error;
              _syncingAddresses.remove(address);
            }
            notifyListeners();
          },
        );
  }

  @override
  void dispose() {
    _disposed = true;
    _syncGeneration++;
    unawaited(_syncSubscription?.cancel());
    unawaited(electrumxService?.close());
    super.dispose();
  }
}
