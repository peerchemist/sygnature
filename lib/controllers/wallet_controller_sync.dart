part of 'wallet_controller.dart';

extension WalletSyncController on WalletController {
  WalletNetwork networkForAccount(WalletAccount account) =>
      _networkById(account.blockchainId, account.networkId);

  List<ElectrumxUtxo> utxosFor(WalletAccount account) {
    final address = account.address;
    return address == null ? const [] : _utxosByAddress[address] ?? const [];
  }

  int balanceSatsFor(WalletAccount account) {
    return utxosFor(account).fold(0, (total, utxo) => total + utxo.value);
  }

  int confirmedBalanceSatsFor(WalletAccount account) =>
      utxosFor(account)
          .where((utxo) => utxo.isConfirmed)
          .fold(0, (total, utxo) => total + utxo.value);

  int pendingBalanceSatsFor(WalletAccount account) =>
      utxosFor(account)
          .where((utxo) => !utxo.isConfirmed)
          .fold(0, (total, utxo) => total + utxo.value);

  List<ElectrumxUtxo> spendableUtxosFor(WalletAccount account) =>
      utxosFor(account)
          .where((utxo) => utxo.isConfirmed)
          .toList(growable: false);

  List<ElectrumxUtxo> availableUtxosFor(WalletAccount account) {
    final reservedOutpoints = _reservedOutpointsFor(account.id);
    return spendableUtxosFor(account)
        .where(
          (utxo) => !reservedOutpoints.contains(
            WalletSigningController._utxoKey(utxo),
          ),
        )
        .toList(growable: false);
  }

  int availableBalanceSatsFor(WalletAccount account) =>
      availableUtxosFor(account).fold(0, (total, utxo) => total + utxo.value);

  int reservedBalanceSatsFor(WalletAccount account) {
    final reservedOutpoints = _reservedOutpointsFor(account.id);
    return spendableUtxosFor(account)
        .where(
          (utxo) => reservedOutpoints.contains(
            WalletSigningController._utxoKey(utxo),
          ),
        )
        .fold(0, (total, utxo) => total + utxo.value);
  }

  Set<String> _reservedOutpointsFor(
    String accountId, {
    bool includeIncomingRequests = true,
  }) {
    final reserved = _storedRoastSigningOperations.values
        .where(
          (operation) =>
              operation.accountId == accountId && operation.reservesUtxos,
        )
        .expand((operation) => operation.reservedOutpoints)
        .toSet();
    if (!includeIncomingRequests) return reserved;

    final setupIds = accounts
        .where((account) => account.id == accountId)
        .map((account) => account.sourceId)
        .nonNulls
        .toSet();
    reserved.addAll(
      _roastSigningRequests.values
          .where(
            (item) =>
                setupIds.contains(item.setupId) &&
                item.request.kind == RoastSigningRequestKind.transaction &&
                item.request.status != 'rejected' &&
                item.request.progress.stage != 'failed' &&
                item.request.expiry.isAfter(DateTime.now()),
          )
          .expand((item) => item.request.inputOutpoints),
    );
    return reserved;
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
    _notifyListeners();
    try {
      await operation();
    } finally {
      _busy = false;
      _notifyListeners();
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
      _notifyListeners();
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
              final previousUtxos = _utxosByAddress[snapshot.address];
              final balanceIncreased =
                  previousUtxos != null &&
                  _balanceOf(snapshot.utxos) > _balanceOf(previousUtxos);
              _utxosByAddress[snapshot.address] = List.unmodifiable(
                snapshot.utxos,
              );
              _syncingAddresses.remove(snapshot.address);
              _syncErrorsByAddress.remove(snapshot.address);
              _queueBroadcastReservationReconciliation(
                snapshot.address,
                snapshot.utxos,
                snapshot.history,
              );
              if (balanceIncreased) onCoinsReceived?.call();
              _notifyListeners();
            },
            onError: (Object error) {
              if (_disposed || generation != _syncGeneration) return;
              for (final address in networkAddresses) {
                _syncErrorsByAddress[address] = error;
                _syncingAddresses.remove(address);
              }
              _notifyListeners();
            },
          );
    }
    _notifyListeners();
  }

  Future<void> reconnectElectrumx() => _guard(() async {
    await _closeNetworkServices();
    for (final network in accounts.map(networkForAccount).toSet()) {
      await _ensureNetworkService(network);
    }
    await _restartElectrumxSync();
  });

  void _queueBroadcastReservationReconciliation(
    String address,
    List<ElectrumxUtxo> utxos,
    List<ElectrumxTransactionHistoryEntry> history,
  ) {
    final outpoints = utxos.map(WalletSigningController._utxoKey).toSet();
    _utxoReconciliationQueue = _utxoReconciliationQueue
        .then((_) async {
          if (_disposed) return;
          await _reconcileTransactionStatuses(address, history);
          final accountIds = accounts
              .where((account) => account.address == address)
              .map((account) => account.id)
              .toSet();
          final completed = _storedRoastSigningOperations.values
              .where(
                (operation) =>
                    accountIds.contains(operation.accountId) &&
                    operation.state == RoastSigningOperationState.broadcasted &&
                    !operation.reservationsReleased &&
                    operation.reservedOutpoints.every(
                      (outpoint) => !outpoints.contains(outpoint),
                    ),
              )
              .toList(growable: false);
          for (final operation in completed) {
            await _saveRoastSigningOperation(
              operation.copyWith(reservationsReleased: true),
            );
          }
        })
        .catchError((Object _) {
          // A sync snapshot should keep running even if persistence is unavailable.
        });
  }

  Future<void> _cancelSyncSubscriptions() {
    final pending = _syncCancellation;
    if (pending != null) return pending;
    final subscriptions = _syncSubscriptions.values.toList(growable: false);
    _syncSubscriptions.clear();
    late final Future<void> cancellation;
    cancellation =
        Future.wait(subscriptions.map((subscription) => subscription.cancel()))
            .then<void>((_) {})
            .whenComplete(() {
              if (identical(_syncCancellation, cancellation)) {
                _syncCancellation = null;
              }
            });
    return _syncCancellation = cancellation;
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

  Future<void> _closeUnusedNetworkServices() async {
    final activeNetworkIds = accounts
        .map((account) => networkForAccount(account).storageId)
        .toSet();
    final unusedNetworkIds = _networkServices.keys
        .where((networkId) => !activeNetworkIds.contains(networkId))
        .toList(growable: false);
    for (final networkId in unusedNetworkIds) {
      await _networkServices.remove(networkId)?.close();
    }
  }

  void _clearSyncState() {
    _utxosByAddress.clear();
    _syncErrorsByAddress.clear();
    _syncingAddresses.clear();
  }

  int _balanceOf(Iterable<ElectrumxUtxo> utxos) =>
      utxos.fold(0, (total, utxo) => total + utxo.value);
}
