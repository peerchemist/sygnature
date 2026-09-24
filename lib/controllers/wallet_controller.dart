import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/electrumx_utxo.dart';
import '../models/mnemonic_seed.dart';
import '../models/wallet_account.dart';
import '../models/wallet_network.dart';
import '../models/wallet_vault.dart';
import '../services/electrumx_service.dart';
import '../services/peercoin_network_service.dart';
import '../services/wallet_key_service.dart';
import '../storage/wallet_repository.dart';

enum AccountSyncStatus { unavailable, syncing, synced, error }

typedef WalletNetworkServiceFactory = Future<ElectrumxService?> Function(
  WalletNetwork network,
);

class WalletController extends ChangeNotifier {
  WalletController(
    this._repository, {
    this.networkServiceFactory,
    WalletKeyService? keyService,
    List<WalletNetwork>? supportedNetworks,
  }) : _keyService = keyService ?? CoinlibWalletKeyService(),
       supportedNetworks = List.unmodifiable(
         supportedNetworks ?? PeercoinNetworks.values,
       ) {
    if (this.supportedNetworks.isEmpty) {
      throw ArgumentError.value(
        supportedNetworks,
        'supportedNetworks',
        'At least one blockchain network must be configured.',
      );
    }
  }

  final WalletRepository _repository;
  final WalletNetworkServiceFactory? networkServiceFactory;
  final WalletKeyService _keyService;
  final List<WalletNetwork> supportedNetworks;
  final Map<String, ElectrumxService> _networkServices = {};
  WalletVault? _vault;
  int _selectedAccount = 0;
  bool _busy = false;
  bool _disposed = false;
  int _syncGeneration = 0;
  final Map<String, StreamSubscription<PeercoinElectrumxUtxoSnapshot>>
  _syncSubscriptions = {};
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
  WalletNetwork? get walletNetwork {
    final account = selectedAccount;
    return account == null ? null : networkForAccount(account);
  }

  WalletNetwork networkForAccount(WalletAccount account) =>
      _networkById(account.blockchainId, account.networkId);

  List<ElectrumxUtxo> utxosFor(WalletAccount account) {
    final address = account.address;
    return address == null ? const [] : _utxosByAddress[address] ?? const [];
  }

  int balanceSatsFor(WalletAccount account) {
    return utxosFor(account).fold(0, (total, utxo) => total + utxo.value);
  }

  AccountSyncStatus syncStatusFor(WalletAccount account) {
    final address = account.address;
    if (address == null ||
        !_networkServices.containsKey(networkForAccount(account).storageId)) {
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
    for (final network in accounts.map(networkForAccount).toSet()) {
      await _ensureNetworkService(network);
    }
    await _restartElectrumxSync();
  }

  MnemonicSession generateMnemonic({
    required MnemonicLanguage language,
    required int wordCount,
    required List<String> wordlist,
  }) => _keyService.generateMnemonic(
    language: language,
    wordCount: wordCount,
    wordlist: wordlist,
  );

  /// Derives the first account and persists the complete wallet in one
  /// encrypted repository write.
  Future<void> createWallet(
    MnemonicSession mnemonic, {
    required WalletNetwork network,
  }) async {
    final selectedNetwork = _networkById(
      network.blockchainId,
      network.networkId,
    );
    await _guard(() async {
      await _ensureNetworkService(selectedNetwork);
      final material = _keyService.deriveAccount(
        network: selectedNetwork,
        mnemonic: mnemonic.phrase,
        accountIndex: 0,
      );
      final first = _derivedAccount(
        0,
        'Main wallet',
        selectedNetwork,
        material,
      );
      final vault = WalletVault(
        mnemonic: mnemonic.phrase,
        languageId: mnemonic.language.id,
        mnemonicWordCount: mnemonic.words.length,
        accounts: [first],
        nextAccountIndex: 1,
      );
      await _repository.save(vault);
      _vault = vault;
      _selectedAccount = 0;
      await _restartElectrumxSync();
    });
  }

  Future<void> addAccount(String name, {required WalletNetwork network}) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Wallet name cannot be empty.');
    }
    final selectedNetwork = _networkById(
      network.blockchainId,
      network.networkId,
    );
    await _guard(() async {
      await _ensureNetworkService(selectedNetwork);
      final index = current.nextAccountIndex;
      final mnemonic = current.mnemonic;
      if (mnemonic == null) {
        throw StateError('Wallet mnemonic is missing.');
      }
      final account = _derivedAccount(
        index,
        trimmedName,
        selectedNetwork,
        _keyService.deriveAccount(
          network: selectedNetwork,
          mnemonic: mnemonic,
          accountIndex: index,
        ),
      );
      final next = current.copyWith(
        accounts: [...current.accounts, account],
        nextAccountIndex: current.nextAccountIndex + 1,
      );
      await _repository.save(next);
      _vault = next;
      _selectedAccount = next.accounts.length - 1;
      await _restartElectrumxSync();
    });
  }

  Future<void> refreshBalances() => _restartElectrumxSync();

  Future<String> broadcastTransaction(String rawTransactionHex) {
    final account = selectedAccount;
    final service = account == null
        ? null
        : _networkServices[networkForAccount(account).storageId];
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
      await _closeNetworkServices();
      _clearSyncState();
    });
  }

  WalletAccount _derivedAccount(
    int index,
    String name,
    WalletNetwork network,
    DerivedWalletMaterial material,
  ) => WalletAccount(
    id: '${network.blockchainId}-${network.networkId}-$index',
    name: name,
    accountIndex: index,
    blockchainId: network.blockchainId,
    networkId: network.networkId,
    derivationPath: material.derivationPath,
    address: material.address,
    privateKeyHex: material.privateKeyHex,
    createdAt: DateTime.now().toUtc(),
  );

  WalletNetwork _networkById(String blockchainId, String networkId) {
    return supportedNetworks.firstWhere(
      (network) =>
          network.matches(blockchainId: blockchainId, networkId: networkId),
      orElse: () => throw StateError(
        'Unsupported wallet network: $blockchainId:$networkId.',
      ),
    );
  }

  Future<void> _ensureNetworkService(WalletNetwork network) async {
    final factory = networkServiceFactory;
    if (factory == null || _networkServices.containsKey(network.storageId)) {
      return;
    }
    final service = await factory(network);
    if (service != null) _networkServices[network.storageId] = service;
  }

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
    await _cancelSyncSubscriptions();
    if (_disposed || generation != _syncGeneration) return;

    final addressesByNetwork = <String, Set<String>>{};
    for (final account in accounts) {
      final address = account.address?.trim();
      if (address == null || address.isEmpty) continue;
      final networkId = networkForAccount(account).storageId;
      addressesByNetwork.putIfAbsent(networkId, () => {}).add(address);
    }
    final addresses = addressesByNetwork.values
        .expand((items) => items)
        .toSet();
    _utxosByAddress.removeWhere((address, _) => !addresses.contains(address));
    _syncErrorsByAddress.removeWhere(
      (address, _) => !addresses.contains(address),
    );
    _syncingAddresses.clear();

    if (addresses.isEmpty) {
      notifyListeners();
      return;
    }

    for (final entry in addressesByNetwork.entries) {
      final service = _networkServices[entry.key];
      if (service == null) continue;
      final networkAddresses = entry.value;
      for (final address in networkAddresses) {
        _syncErrorsByAddress.remove(address);
        _syncingAddresses.add(address);
      }
      _syncSubscriptions[entry.key] = service
          .watchUtxosForAddresses(networkAddresses)
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
              for (final address in networkAddresses) {
                _syncErrorsByAddress[address] = error;
                _syncingAddresses.remove(address);
              }
              notifyListeners();
            },
          );
    }
    notifyListeners();
  }

  Future<void> _cancelSyncSubscriptions() async {
    final subscriptions = _syncSubscriptions.values.toList(growable: false);
    _syncSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  Future<void> _closeNetworkServices() async {
    _syncGeneration++;
    await _cancelSyncSubscriptions();
    final services = _networkServices.values.toList(growable: false);
    _networkServices.clear();
    for (final service in services) {
      await service.close();
    }
  }

  void _clearSyncState() {
    _utxosByAddress.clear();
    _syncErrorsByAddress.clear();
    _syncingAddresses.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncGeneration++;
    for (final subscription in _syncSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _syncSubscriptions.clear();
    for (final service in _networkServices.values) {
      unawaited(service.close());
    }
    _networkServices.clear();
    super.dispose();
  }
}
