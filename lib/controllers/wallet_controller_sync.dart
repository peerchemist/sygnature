part of 'wallet_controller.dart';

typedef WalletBalance = ({
  int totalSats,
  int confirmedSats,
  int pendingSats,
  int availableSats,
  int reservedSats,
  int utxoCount,
});

extension WalletSyncController on WalletController {
  WalletNetwork networkForAccount(WalletAccount account) =>
      _networkById(account.blockchainId, account.networkId);

  List<ElectrumxUtxo> utxosFor(WalletAccount account) {
    return [
      for (final owned in ownedAddressesFor(account))
        ..._utxosByAddress[owned.address] ?? const <ElectrumxUtxo>[],
    ];
  }

  List<WalletOwnedAddress> ownedAddressesFor(WalletAccount account) =>
      _ownedAddressesThrough(account, account.highestAllocatedAddressIndex);

  ({int from, int through}) addressScanRangeFor(WalletAccount account) =>
      (from: 0, through: _addressScanUpperIndex(account));

  int _addressScanUpperIndex(WalletAccount account) {
    final requested = _addressScanUpperIndexByAccount[account.id] ?? 0;
    return requested > account.highestAllocatedAddressIndex
        ? requested
        : account.highestAllocatedAddressIndex;
  }

  Future<void> extendAddressScan(String accountId, int upperIndex) async {
    final account = accounts.where((item) => item.id == accountId).firstOrNull;
    if (account == null) {
      throw ArgumentError.value(accountId, 'accountId', 'Unknown wallet.');
    }
    if (upperIndex <= addressScanRangeFor(account).through ||
        upperIndex > WalletController._maxAddressRecoveryIndex) {
      throw ArgumentError.value(
        upperIndex,
        'upperIndex',
        'Must extend the current scan and be no more than '
            '${WalletController._maxAddressRecoveryIndex}.',
      );
    }
    final derived = _ownedAddressesThrough(account, upperIndex);
    if (derived.length != upperIndex + 1) {
      throw const WalletSigningUnavailable();
    }
    _addressScanUpperIndexByAccount[account.id] = upperIndex;
    await _restartElectrumxSync();
  }

  List<WalletOwnedAddress> _addressesForSync(WalletAccount account) =>
      _ownedAddressesThrough(account, _addressScanUpperIndex(account));

  bool canUseNewChangeAddress(WalletAccount account) =>
      account.keySource != WalletKeySource.watchOnly &&
      account.derivationState == WalletDerivationState.ready &&
      _ownedAddressesThrough(
            account,
            account.highestAllocatedAddressIndex + 1,
          ).length ==
          account.highestAllocatedAddressIndex + 2;

  List<WalletOwnedAddress> _ownedAddressesThrough(
    WalletAccount account,
    int highestIndex,
  ) {
    final receiveAddress = account.address;
    final receivePath = account.derivationPath;
    final pathPrefix = account.addressPathPrefix;
    if (receiveAddress == null) return const [];
    if (account.keySource == WalletKeySource.watchOnly) {
      return [
        (
          index: 0,
          address: receiveAddress,
          derivationPath: receivePath ?? '',
          privateKeyHex: null,
        ),
      ];
    }
    if (receivePath == null) return const [];
    final setup = account.keySource == WalletKeySource.roast
        ? setupForAccount(account)
        : null;
    final cacheIdentity = [
      account.keySource.name,
      account.blockchainId,
      account.networkId,
      account.accountIndex,
      receiveAddress,
      receivePath,
      pathPrefix ?? '',
      setup?.groupKeyHex ?? '',
    ].join('|');
    var cached = _addressDerivationCache[account.id];
    if (cached?.identity != cacheIdentity) {
      cached = (
        identity: cacheIdentity,
        addresses: [
          (
            index: 0,
            address: receiveAddress,
            derivationPath: receivePath,
            privateKeyHex: account.keySource == WalletKeySource.personal
                ? account.privateKeyHex
                : null,
          ),
        ],
      );
      _addressDerivationCache[account.id] = cached;
    }
    final result = cached!.addresses;
    for (var index = result.length; index <= highestIndex; index++) {
      if (pathPrefix == null) break;
      if (account.keySource == WalletKeySource.personal) {
        final mnemonic = _vault?.mnemonic;
        final languageId = _vault?.languageId;
        if (mnemonic == null || languageId == null) {
          break;
        }
        late final DerivedWalletMaterial derived;
        try {
          derived = _keyService.deriveAddress(
            network: networkForAccount(account),
            mnemonic: mnemonic,
            language: MnemonicLanguage.byId(languageId),
            accountIndex: account.accountIndex,
            addressIndex: index,
          );
        } on Object {
          break;
        }
        result.add((
          index: index,
          address: derived.address,
          derivationPath: derived.derivationPath,
          privateKeyHex: derived.privateKeyHex,
        ));
        continue;
      }
      if (setup?.groupKeyHex == null) break;
      late final RoastDerivedAddress derived;
      try {
        derived = _roastKeyService.deriveAddress(
          groupKeyHex: setup!.groupKeyHex!,
          threshold: setup.threshold,
          network: networkForAccount(account),
          accountIndex: account.accountIndex,
          pathLabel: '$pathPrefix$index',
        );
      } on Object {
        break;
      }
      result.add((
        index: index,
        address: derived.address,
        derivationPath: derived.pathLabel,
        privateKeyHex: null,
      ));
    }
    return List.unmodifiable(result.take(highestIndex + 1));
  }

  WalletBalance balanceFor(WalletAccount account) {
    final utxos = utxosFor(account);
    final reservedOutpoints = _reservedOutpointsFor(account.id);
    var confirmed = 0;
    var pending = 0;
    var reserved = 0;
    for (final utxo in utxos) {
      if (!utxo.isConfirmed) {
        pending += utxo.value;
        continue;
      }
      confirmed += utxo.value;
      if (reservedOutpoints.contains(WalletSigningController._utxoKey(utxo))) {
        reserved += utxo.value;
      }
    }
    return (
      totalSats: confirmed + pending,
      confirmedSats: confirmed,
      pendingSats: pending,
      availableSats: confirmed - reserved,
      reservedSats: reserved,
      utxoCount: utxos.length,
    );
  }

  int balanceSatsFor(WalletAccount account) => _balanceOf(utxosFor(account));

  int confirmedBalanceSatsFor(WalletAccount account) =>
      balanceFor(account).confirmedSats;

  int pendingBalanceSatsFor(WalletAccount account) =>
      balanceFor(account).pendingSats;

  List<ElectrumxUtxo> spendableUtxosFor(WalletAccount account) =>
      utxosFor(account)
          .where((utxo) => utxo.isConfirmed)
          .toList(growable: false);

  List<ElectrumxUtxo> availableUtxosFor(WalletAccount account) {
    final reservedOutpoints = _reservedOutpointsFor(account.id);
    return utxosFor(account)
        .where(
          (utxo) =>
              utxo.isConfirmed &&
              !reservedOutpoints.contains(
                WalletSigningController._utxoKey(utxo),
              ),
        )
        .toList(growable: false);
  }

  int availableBalanceSatsFor(WalletAccount account) =>
      balanceFor(account).availableSats;

  int reservedBalanceSatsFor(WalletAccount account) =>
      balanceFor(account).reservedSats;

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

    final setupId = accounts
        .where((account) => account.id == accountId)
        .firstOrNull
        ?.sourceId;
    if (setupId == null) return reserved;
    final now = DateTime.now();
    reserved.addAll(
      _roastSigningRequests.values
          .where(
            (item) =>
                item.setupId == setupId &&
                item.request.kind == RoastSigningRequestKind.transaction &&
                item.request.status != 'rejected' &&
                item.request.progress.stage != 'failed' &&
                item.request.expiry.isAfter(now),
          )
          .expand((item) => item.request.inputOutpoints),
    );
    return reserved;
  }

  AccountSyncStatus syncStatusFor(WalletAccount account) {
    final addresses = ownedAddressesFor(account)
        .map((owned) => owned.address)
        .toList(growable: false);
    if (addresses.isEmpty ||
        !_networkServices.containsKey(networkForAccount(account).storageId)) {
      return AccountSyncStatus.unavailable;
    }
    if (addresses.any(_syncErrorsByAddress.containsKey)) {
      return AccountSyncStatus.error;
    }
    if (addresses.any(_syncingAddresses.contains)) {
      return AccountSyncStatus.syncing;
    }
    return addresses.every(_utxosByAddress.containsKey)
        ? AccountSyncStatus.synced
        : AccountSyncStatus.syncing;
  }

  Object? syncErrorFor(WalletAccount account) {
    for (final owned in ownedAddressesFor(account)) {
      if (_syncErrorsByAddress[owned.address] case final error?) return error;
    }
    return null;
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
    if (_busy) throw const WalletBusyFailure();
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
      final networkId = networkForAccount(account).storageId;
      for (final owned in _addressesForSync(account)) {
        addressesByNetwork.putIfAbsent(networkId, () => {}).add(owned.address);
      }
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
          await _retainDiscoveredAddress(address, utxos, history);
          await _reconcileTransactionStatuses(address, history);
          final accountIds = accounts
              .where(
                (account) =>
                    ownedAddressesFor(account)
                        .any((owned) => owned.address == address),
              )
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

  Future<void> _retainDiscoveredAddress(
    String address,
    List<ElectrumxUtxo> utxos,
    List<ElectrumxTransactionHistoryEntry> history,
  ) async {
    if (utxos.isEmpty && history.isEmpty) return;
    for (final account in accounts) {
      final discovered = _addressesForSync(account)
          .where((owned) => owned.address == address)
          .firstOrNull;
      if (discovered == null ||
          discovered.index <= account.highestAllocatedAddressIndex) {
        continue;
      }
      await _updateVault((current) {
        if (current == null) return current;
        return current.copyWith(
          accounts: [
            for (final item in current.accounts)
              if (item.id == account.id)
                item.copyWith(highestAllocatedAddressIndex: discovered.index)
              else
                item,
          ],
        );
      });
      final nextUpperIndex =
          (discovered.index + WalletController._defaultAddressRecoveryLookahead)
              .clamp(0, WalletController._maxAddressRecoveryIndex);
      if (nextUpperIndex > _addressScanUpperIndex(account)) {
        _addressScanUpperIndexByAccount[account.id] = nextUpperIndex;
        await _restartElectrumxSync();
      }
      return;
    }
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
    _addressScanUpperIndexByAccount.clear();
    _addressDerivationCache.clear();
  }

  int _balanceOf(Iterable<ElectrumxUtxo> utxos) =>
      utxos.fold(0, (total, utxo) => total + utxo.value);
}
