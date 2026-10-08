part of 'wallet_controller.dart';

class const WatchOnlyWalletFailure(final String message) implements Exception {
  @override
  String toString() => message;
}

extension WalletAccountsController on WalletController {
  WalletVault? get vault => _vault;
  bool get hasWallet => _vault != null;
  bool get busy => _busy;
  List<WalletAccount> get accounts =>
      _vault?.accounts
          .where((account) => !account.isArchived)
          .toList(growable: false) ??
      const [];
  List<WalletAccount> get archivedAccounts =>
      _vault?.accounts
          .where((account) => account.isArchived)
          .toList(growable: false) ??
      const [];
  int get selectedAccountIndex {
    final index = accounts.indexWhere(
      (account) => account.id == _selectedAccountId,
    );
    return index < 0 ? 0 : index;
  }

  WalletAccount? get selectedAccount {
    for (final account in accounts) {
      if (account.id == _selectedAccountId) return account;
    }
    return null;
  }

  WalletNetwork? get walletNetwork {
    final account = selectedAccount;
    return account == null ? null : networkForAccount(account);
  }

  Future<void> load() async {
    _vault = await _repository.load();
    final storedAccountId = _vault?.selectedAccountId;
    _selectedAccountId =
        accounts.any((account) => account.id == storedAccountId)
        ? storedAccountId
        : accounts.firstOrNull?.id;
    await _restoreRoastSigningOperations();
    final runtime = _roastRuntime;
    if (runtime != null) {
      _roastEvents = runtime.events.listen(
        _queueRoastEvent,
        onError: (Object error, StackTrace stackTrace) =>
            _queueRoastStreamFailure(error),
        onDone: () => _queueRoastStreamFailure(
          StateError('The ROAST worker event stream stopped.'),
        ),
      );
    }
    for (final network in accounts.map(networkForAccount).toSet()) {
      await _ensureNetworkService(network);
    }
    await _restartElectrumxSync();
    if (runtime != null) {
      final activeSetupIds = accounts
          .where((account) => account.keySource == WalletKeySource.roast)
          .map((account) => account.sourceId)
          .nonNulls
          .toSet();
      for (final setup in roastSetups.where(
        (item) => item.isFinalized && activeSetupIds.contains(item.id),
      )) {
        unawaited(resumeRoastSetup(setup.id));
      }
    }
  }

  MnemonicSession generateMnemonic({
    required MnemonicLanguage language,
    required int wordCount,
  }) => _keyService.generateMnemonic(language: language, wordCount: wordCount);

  MnemonicValidationResult validateMnemonic({
    required String mnemonic,
    required MnemonicLanguage language,
  }) => _keyService.validateMnemonic(mnemonic: mnemonic, language: language);

  Future<void> createVault(MnemonicSession mnemonic) async {
    await _guard(() async {
      await _updateVault((current) {
        final selectedAccountId =
            _selectedAccountId ??
            current?.accounts
                .where((account) => !account.isArchived)
                .lastOrNull
                ?.id;
        return WalletVault(
          mnemonic: mnemonic.phrase,
          languageId: mnemonic.language.id,
          mnemonicWordCount: mnemonic.words.length,
          accounts: current?.accounts ?? const [],
          nextAccountIndex: current?.nextAccountIndex ?? 0,
          roastSetups: current?.roastSetups ?? const [],
          groupTransitions: current?.groupTransitions ?? const [],
          activities: current?.activities ?? const [],
          selectedAccountId: selectedAccountId,
        );
      }, updateSelection: true);
    });
  }

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
        language: mnemonic.language,
        accountIndex: 0,
      );
      final first = _derivedAccount(
        0,
        'Main wallet',
        selectedNetwork,
        material,
      );
      await _updateVault(
        (current) => WalletVault(
          mnemonic: mnemonic.phrase,
          languageId: mnemonic.language.id,
          mnemonicWordCount: mnemonic.words.length,
          accounts: [...?current?.accounts, first],
          nextAccountIndex: 1,
          roastSetups: current?.roastSetups ?? const [],
          groupTransitions: current?.groupTransitions ?? const [],
          activities: current?.activities ?? const [],
          selectedAccountId: first.id,
        ),
        updateSelection: true,
      );
      await _restartElectrumxSync();
    });
  }

  Future<void> addAccount(String name, {required WalletNetwork network}) async {
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
      await _updateVault((current) {
        if (current == null) throw StateError('Wallet is not initialized.');
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
            language: MnemonicLanguage.byId(current.languageId!),
            accountIndex: index,
          ),
        );
        return current.copyWith(
          accounts: [...current.accounts, account],
          nextAccountIndex: current.nextAccountIndex + 1,
          selectedAccountId: account.id,
        );
      }, updateSelection: true);
      await _restartElectrumxSync();
    });
  }

  Future<void> addWatchOnlyAccount(
    String name, {
    required WalletNetwork network,
    required String address,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const WatchOnlyWalletFailure('Enter a wallet name.');
    }
    final selectedNetwork = _networkById(
      network.blockchainId,
      network.networkId,
    );
    final normalizedAddress = _watchOnlyAddress(address, selectedNetwork);
    await _guard(() async {
      await _ensureNetworkService(selectedNetwork);
      await _updateVault((current) {
        if (current?.accounts.any(
              (account) =>
                  account.blockchainId == selectedNetwork.blockchainId &&
                  account.networkId == selectedNetwork.networkId &&
                  account.address == normalizedAddress,
            ) ==
            true) {
          throw const WatchOnlyWalletFailure(
            'This address is already in the wallet.',
          );
        }

        final account = WalletAccount(
          id: 'watch-${bytesToHex(generateRandomBytes(16))}',
          name: trimmedName,
          accountIndex: current?.accounts.length ?? 0,
          blockchainId: selectedNetwork.blockchainId,
          networkId: selectedNetwork.networkId,
          derivationState: WalletDerivationState.watchOnly,
          keySource: WalletKeySource.watchOnly,
          address: normalizedAddress,
          createdAt: DateTime.now().toUtc(),
        );
        return current == null
            ? WalletVault(
                accounts: [account],
                nextAccountIndex: 0,
                selectedAccountId: account.id,
              )
            : current.copyWith(
                accounts: [...current.accounts, account],
                selectedAccountId: account.id,
              );
      }, updateSelection: true);
      await _restartElectrumxSync();
    });
  }

  Future<void> archiveAccount(String accountId) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final account = current.accounts
        .where((item) => item.id == accountId)
        .firstOrNull;
    if (account == null) {
      throw ArgumentError.value(accountId, 'accountId', 'Unknown wallet.');
    }
    if (account.isArchived) return;
    if (_sending) {
      throw StateError(
        'Finish the active transaction before archiving a wallet.',
      );
    }
    _assertRoastAccountCanBeDeactivated(account, action: 'archiving');

    await _guard(() async {
      await _updateVault((current) {
        if (current == null) throw StateError('Wallet is not initialized.');
        final activeIndex = accounts.indexWhere((item) => item.id == accountId);
        final wasSelected = _selectedAccountId == accountId;
        final remainingActive = current.accounts
            .where((item) => !item.isArchived && item.id != accountId)
            .toList(growable: false);
        final nextSelectedAccountId = wasSelected
            ? remainingActive.isEmpty
                  ? null
                  : remainingActive[activeIndex.clamp(
                          0,
                          remainingActive.length - 1,
                        )]
                        .id
            : _selectedAccountId;
        return current.copyWith(
          accounts: [
            for (final item in current.accounts)
              if (item.id == accountId) item.archive(DateTime.now()) else item,
          ],
          selectedAccountId: nextSelectedAccountId,
          clearSelectedAccountId: nextSelectedAccountId == null,
        );
      }, updateSelection: true);

      Object? runtimeError;
      StackTrace? runtimeStack;
      final setupId = account.keySource == WalletKeySource.roast
          ? account.sourceId
          : null;
      final setupStillActive =
          setupId != null && accounts.any((item) => item.sourceId == setupId);
      if (setupId != null && !setupStillActive) {
        try {
          await _roastRuntime?.stopSetup(setupId);
        } on Object catch (error, stackTrace) {
          runtimeError = error;
          runtimeStack = stackTrace;
        }
        _roastPresence.remove(setupId);
        _roastSigningRequests.removeWhere(
          (_, request) => request.setupId == setupId,
        );
      }

      await _restartElectrumxSync();
      await _closeUnusedNetworkServices();
      if (runtimeError != null) {
        Error.throwWithStackTrace(runtimeError, runtimeStack!);
      }
    });
  }

  Future<void> restoreAccount(String accountId) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final account = current.accounts
        .where((item) => item.id == accountId)
        .firstOrNull;
    if (account == null) {
      throw ArgumentError.value(accountId, 'accountId', 'Unknown wallet.');
    }
    if (!account.isArchived) return;

    await _guard(() async {
      await _ensureNetworkService(networkForAccount(account));
      await _updateVault((current) {
        if (current == null) throw StateError('Wallet is not initialized.');
        return current.copyWith(
          accounts: [
            for (final item in current.accounts)
              if (item.id == accountId) item.restore() else item,
          ],
          selectedAccountId: account.id,
        );
      }, updateSelection: true);
      await _restartElectrumxSync();

      final setupId = account.keySource == WalletKeySource.roast
          ? account.sourceId
          : null;
      if (setupId != null &&
          !current.accounts.any(
            (item) => !item.isArchived && item.sourceId == setupId,
          )) {
        await resumeRoastSetup(setupId);
      }
    });
  }

  Future<void> deleteAccount(String accountId) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final accountIndex = current.accounts.indexWhere(
      (account) => account.id == accountId,
    );
    if (accountIndex == -1) {
      throw ArgumentError.value(accountId, 'accountId', 'Unknown wallet.');
    }
    final removedAccount = current.accounts[accountIndex];
    final remainingAccounts = current.accounts
        .where((account) => account.id != accountId)
        .toList(growable: false);
    final roastSetupId =
        removedAccount.keySource == WalletKeySource.roast &&
            !remainingAccounts.any(
              (account) => account.sourceId == removedAccount.sourceId,
            )
        ? removedAccount.sourceId
        : null;
    if (roastSetupId != null &&
        (_roastOperations.contains(roastSetupId) ||
            _pendingRoastSends.keys.any(
              (key) => key.startsWith('$roastSetupId:'),
            ) ||
            _pendingRoastMessages.keys.any(
              (key) => key.startsWith('$roastSetupId:'),
            ))) {
      throw StateError(
        'Finish the active ROAST operation before deleting this wallet.',
      );
    }
    await _guard(() async {
      await _updateVault((current) {
        if (current == null) throw StateError('Wallet is not initialized.');
        final remainingAccounts = current.accounts
            .where((account) => account.id != accountId)
            .toList(growable: false);
        final selectedId = selectedAccount?.id;
        final activeIndex = accounts.indexWhere(
          (account) => account.id == accountId,
        );
        final remainingActive = remainingAccounts
            .where((account) => !account.isArchived)
            .toList(growable: false);
        final nextSelectedAccountId = selectedId == removedAccount.id
            ? remainingActive.isEmpty
                  ? null
                  : remainingActive[activeIndex.clamp(
                          0,
                          remainingActive.length - 1,
                        )]
                        .id
            : selectedId;
        return current.copyWith(
          accounts: remainingAccounts,
          activities: [
            for (final activity in current.activities)
              if (activity.accountId != removedAccount.id) activity,
          ],
          roastSetups: roastSetupId == null
              ? current.roastSetups
              : [
                  for (final setup in current.roastSetups)
                    if (setup.id != roastSetupId) setup,
                ],
          selectedAccountId: nextSelectedAccountId,
          clearSelectedAccountId: nextSelectedAccountId == null,
        );
      }, updateSelection: true);

      Object? cleanupError;
      StackTrace? cleanupStack;
      if (roastSetupId != null) {
        try {
          await _roastRuntime?.deleteSetup(roastSetupId);
        } on Object catch (error, stackTrace) {
          cleanupError = error;
          cleanupStack = stackTrace;
        }
        try {
          await _roastSigningOperations.deleteSigningOperationsForSetup(
            roastSetupId,
          );
        } on Object catch (error, stackTrace) {
          cleanupError ??= error;
          cleanupStack ??= stackTrace;
        }
        _roastPresence.remove(roastSetupId);
        _roastOperations.remove(roastSetupId);
        _roastSigningRequests.removeWhere(
          (_, item) => item.setupId == roastSetupId,
        );
        _storedRoastSigningOperations.removeWhere(
          (_, operation) => operation.setupId == roastSetupId,
        );
        _pendingRoastMessages.removeWhere(
          (key, _) => key.startsWith('$roastSetupId:'),
        );
        _completedRoastMessages.remove(roastSetupId);
      }

      await _restartElectrumxSync();
      await _closeUnusedNetworkServices();
      if (cleanupError != null) {
        Error.throwWithStackTrace(cleanupError, cleanupStack!);
      }
    });
  }

  Future<void> renameAccount(String accountId, String name) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Wallet name cannot be empty.');
    }
    if (!current.accounts.any((account) => account.id == accountId)) {
      throw ArgumentError.value(accountId, 'accountId', 'Unknown wallet.');
    }
    await _guard(() async {
      await _updateVault((current) {
        if (current == null) throw StateError('Wallet is not initialized.');
        return current.copyWith(
          accounts: [
            for (final account in current.accounts)
              if (account.id == accountId)
                account.copyWith(name: trimmedName)
              else
                account,
          ],
        );
      });
    });
  }

  Future<void> selectAccount(int index) async {
    if (index < 0 || index >= accounts.length) return;
    final accountId = accounts[index].id;
    if (accountId == _selectedAccountId) return;
    await _guard(() async {
      await _updateVault(
        (current) => current?.copyWith(selectedAccountId: accountId),
        updateSelection: true,
      );
    });
  }

  Future<void> resetWallet() async {
    await _guard(() async {
      final runtime = _roastRuntime;
      if (runtime != null) {
        for (final setup in roastSetups) {
          await runtime.stopSetup(setup.id);
          _roastPresence.remove(setup.id);
        }
      }
      await _updateVault((_) => null, updateSelection: true);
      await _closeNetworkServices();
      _clearSyncState();
    });
  }

  void _assertRoastAccountCanBeDeactivated(
    WalletAccount account, {
    required String action,
  }) {
    final setupId = account.keySource == WalletKeySource.roast
        ? account.sourceId
        : null;
    if (setupId == null) return;
    if (_roastOperations.contains(setupId) ||
        _roastCoordinatorRecovery.containsKey(setupId) ||
        _pendingRoastSends.keys.any((key) => key.startsWith('$setupId:')) ||
        _pendingRoastMessages.keys.any((key) => key.startsWith('$setupId:'))) {
      throw StateError(
        'Finish the active ROAST operation before $action this wallet.',
      );
    }
  }

  bool _hasActiveAccountForSetup(String setupId) => accounts.any(
    (account) =>
        account.keySource == WalletKeySource.roast &&
        account.sourceId == setupId,
  );

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
    derivationState: WalletDerivationState.ready,
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

  String _watchOnlyAddress(String value, WalletNetwork network) {
    try {
      final parsed = Address.fromString(
        value.trim(),
        PeercoinNetworks.fromWalletNetwork(network).network,
      );
      if (parsed is P2TRAddress) return parsed.toString();
    } on Exception {
      // The caller receives the stable validation failure below.
    }
    throw const WatchOnlyWalletFailure(
      'Enter a valid Taproot address for the selected network.',
    );
  }
}
