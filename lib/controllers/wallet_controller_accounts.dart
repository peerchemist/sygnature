part of 'wallet_controller.dart';

class const WatchOnlyWalletFailure(final String message) implements Exception {
  @override
  String toString() => message;
}

extension WalletAccountsController on WalletController {
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

  Future<void> load() async {
    _vault = await _repository.load();
    _selectedAccount = 0;
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
      for (final setup in roastSetups.where((item) => item.isFinalized)) {
        unawaited(resumeRoastSetup(setup.id));
      }
    }
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

  MnemonicValidationResult validateMnemonic({
    required String mnemonic,
    required MnemonicLanguage language,
    required List<String> wordlist,
  }) => _keyService.validateMnemonic(
    mnemonic: mnemonic,
    language: language,
    wordlist: wordlist,
  );

  Future<void> createVault(MnemonicSession mnemonic) async {
    await _guard(() async {
      final current = _vault;
      final vault = WalletVault(
        mnemonic: mnemonic.phrase,
        languageId: mnemonic.language.id,
        mnemonicWordCount: mnemonic.words.length,
        accounts: current?.accounts ?? const [],
        nextAccountIndex: current?.nextAccountIndex ?? 0,
        roastSetups: current?.roastSetups ?? const [],
        groupTransitions: current?.groupTransitions ?? const [],
        activities: current?.activities ?? const [],
      );
      await _repository.save(vault);
      _vault = vault;
      _selectedAccount = vault.accounts.isEmpty ? 0 : vault.accounts.length - 1;
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
        accountIndex: 0,
      );
      final first = _derivedAccount(
        0,
        'Main wallet',
        selectedNetwork,
        material,
      );
      final current = _vault;
      final vault = WalletVault(
        mnemonic: mnemonic.phrase,
        languageId: mnemonic.language.id,
        mnemonicWordCount: mnemonic.words.length,
        accounts: [...?current?.accounts, first],
        nextAccountIndex: 1,
        roastSetups: current?.roastSetups ?? const [],
        groupTransitions: current?.groupTransitions ?? const [],
        activities: current?.activities ?? const [],
      );
      await _repository.save(vault);
      _vault = vault;
      _selectedAccount = vault.accounts.length - 1;
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
    final current = _vault;
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

    await _guard(() async {
      await _ensureNetworkService(selectedNetwork);
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
      final next = current == null
          ? WalletVault(accounts: [account], nextAccountIndex: 0)
          : current.copyWith(accounts: [...current.accounts, account]);
      await _repository.save(next);
      _vault = next;
      _selectedAccount = next.accounts.length - 1;
      await _restartElectrumxSync();
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
    final remainingAccounts = [...current.accounts]..removeAt(accountIndex);
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
    final selectedId = selectedAccount?.id;
    await _guard(() async {
      final next = current.copyWith(
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
      );
      await _repository.save(next);
      _vault = next;

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
        _issuedRoastInvitations.remove(roastSetupId);
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

      final previousSelection = remainingAccounts.indexWhere(
        (account) => account.id == selectedId,
      );
      _selectedAccount = remainingAccounts.isEmpty
          ? 0
          : previousSelection >= 0
          ? previousSelection
          : accountIndex < remainingAccounts.length
          ? accountIndex
          : remainingAccounts.length - 1;

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
      final next = current.copyWith(
        accounts: [
          for (final account in current.accounts)
            if (account.id == accountId)
              account.copyWith(name: trimmedName)
            else
              account,
        ],
      );
      await _repository.save(next);
      _vault = next;
    });
  }

  void selectAccount(int index) {
    if (index < 0 || index >= accounts.length) return;
    _selectedAccount = index;
    _notifyListeners();
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
