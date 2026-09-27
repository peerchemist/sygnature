import 'dart:async';

import 'package:coinlib/coinlib.dart' show hexToBytes;
import 'package:flutter/foundation.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart'
    show NoosphereWorkerException;

import '../models/electrumx_utxo.dart';
import '../models/mnemonic_seed.dart';
import '../models/roast_setup.dart';
import '../models/roast_signing_operation.dart';
import '../models/wallet_account.dart';
import '../models/wallet_activity.dart';
import '../models/wallet_network.dart';
import '../models/wallet_transaction.dart';
import '../models/wallet_vault.dart';
import '../services/app_logger.dart';
import '../services/electrumx_service.dart';
import '../services/peercoin_network_service.dart';
import '../services/roast_key_service.dart';
import '../services/roast_runtime_manager.dart';
import '../services/wallet_key_service.dart';
import '../services/wallet_transaction_service.dart';
import '../storage/wallet_repository.dart';
import '../storage/roast_storage.dart';

enum AccountSyncStatus { unavailable, syncing, synced, error }

class RoastSigningInboxItem({
  required final String setupId,
  required final String walletName,
  required final RoastSigningRequest request,
});

class RoastIssuedInvitation({
  required final String participantName,
  required final String participantPublicKeyHex,
  required final String encoded,
});

final class _PendingRoastSend({
  required final Completer<_RoastSendOutcome> completer,
});

final class _RoastSendOutcome({
  final SignedWalletTransaction? signed,
  final Object? error,
  final StackTrace? stackTrace,
});

final class _RoastPresence({
  required final bool connected,
  required final bool signerRunning,
});

typedef WalletNetworkServiceFactory = Future<ElectrumxService?> Function(
  WalletNetwork network,
);

class WalletController extends ChangeNotifier {
  static const _maxActivityEntries = 100;

  WalletController(
    this._repository, {
    this.networkServiceFactory,
    this.onCoinsReceived,
    WalletKeyService? keyService,
    WalletTransactionService? transactionService,
    RoastRuntime? roastRuntime,
    RoastKeyService? roastKeyService,
    RoastSigningOperationRepository? roastSigningOperations,
    List<WalletNetwork>? supportedNetworks,
  }) : _keyService = keyService ?? CoinlibWalletKeyService(),
       _transactionService =
           transactionService ?? const CoinlibWalletTransactionService(),
       // ignore: prefer_initializing_formals
       _roastRuntime = roastRuntime,
       _roastKeyService = roastKeyService ?? const RoastKeyService(),
       _roastSigningOperations =
           roastSigningOperations ?? MemoryRoastSigningOperationRepository(),
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
  final VoidCallback? onCoinsReceived;
  final WalletKeyService _keyService;
  final WalletTransactionService _transactionService;
  final RoastRuntime? _roastRuntime;
  final RoastKeyService _roastKeyService;
  final RoastSigningOperationRepository _roastSigningOperations;
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
  final Set<String> _broadcastingTransactionIds = {};
  final Set<String> _broadcastedTransactionIds = {};
  bool _sending = false;
  StreamSubscription<RoastRuntimeEvent>? _roastEvents;
  Future<void> _roastEventQueue = Future.value();
  Future<void> _utxoReconciliationQueue = Future.value();
  final Set<String> _roastOperations = {};
  final Map<String, RoastSigningInboxItem> _roastSigningRequests = {};
  final Map<String, _PendingRoastSend> _pendingRoastSends = {};
  final Map<String, List<RoastIssuedInvitation>> _issuedRoastInvitations = {};
  final Map<String, RoastSigningOperation> _storedRoastSigningOperations = {};
  final Map<String, _RoastPresence> _roastPresence = {};

  WalletVault? get vault => _vault;
  bool get hasWallet => _vault != null;
  bool get busy => _busy;
  List<WalletAccount> get accounts => _vault?.accounts ?? const [];
  List<WalletActivity> activitiesFor(WalletAccount account) =>
      (_vault?.activities ?? const [])
          .where((activity) => activity.accountId == account.id)
          .toList(growable: false);
  List<RoastSetup> get roastSetups => _vault?.roastSetups ?? const [];
  bool get roastAvailable => _roastRuntime != null;
  List<RoastSigningInboxItem> get roastSigningRequests =>
      List.unmodifiable(_roastSigningRequests.values);
  List<RoastSigningOperation> get recoverableRoastSigningOperations =>
      _storedRoastSigningOperations.values
          .where((operation) => operation.canRetryBroadcast)
          .toList(growable: false);
  int get selectedAccountIndex => _selectedAccount;
  WalletAccount? get selectedAccount => accounts.isEmpty
      ? null
      : accounts[_selectedAccount.clamp(0, accounts.length - 1)];
  WalletNetwork? get walletNetwork {
    final account = selectedAccount;
    return account == null ? null : networkForAccount(account);
  }

  RoastSetup? setupForAccount(WalletAccount account) {
    final setupId = account.sourceId;
    if (account.keySource != WalletKeySource.roast || setupId == null) {
      return null;
    }
    return roastSetups.where((setup) => setup.id == setupId).firstOrNull;
  }

  bool roastOperationInProgress(String setupId) =>
      _roastOperations.contains(setupId);

  List<RoastIssuedInvitation> issuedRoastInvitations(String setupId) =>
      _issuedRoastInvitations[setupId] ?? const [];

  RoastSigningOperation? recoverableBroadcastForSetup(String setupId) =>
      recoverableRoastSigningOperations
          .where((operation) => operation.setupId == setupId)
          .firstOrNull;

  int onlineSignerCount(RoastSetup setup) {
    return setup.participants
        .where((participant) => isRoastParticipantOnline(setup, participant))
        .length;
  }

  bool isRoastParticipantOnline(
    RoastSetup setup,
    RoastParticipant participant,
  ) {
    if (participant.cardId == setup.localCardId) {
      final presence = _roastPresence[setup.id];
      return presence?.connected == true && presence?.signerRunning == true;
    }
    return setup.onlineParticipantIds.contains(participant.identifierHex);
  }

  String roastOutputAddress(
    RoastSigningInboxItem item,
    RoastSigningOutput output,
  ) {
    final setup = _setupById(item.setupId);
    final network = _networkById(setup.blockchainId, setup.networkId);
    return _roastKeyService.addressForScript(network, output.scriptHex);
  }

  bool isRoastChangeOutput(
    RoastSigningInboxItem item,
    RoastSigningOutput output,
  ) {
    final account = accounts.firstWhere(
      (account) => account.sourceId == item.setupId,
    );
    final address = account.address;
    if (address == null) return false;
    return output.scriptHex ==
        _roastKeyService.scriptHexForAddress(
          networkForAccount(account),
          address,
        );
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
        .where((utxo) => !reservedOutpoints.contains(_utxoKey(utxo)))
        .toList(growable: false);
  }

  int availableBalanceSatsFor(WalletAccount account) =>
      availableUtxosFor(account).fold(0, (total, utxo) => total + utxo.value);

  int reservedBalanceSatsFor(WalletAccount account) {
    final reservedOutpoints = _reservedOutpointsFor(account.id);
    return spendableUtxosFor(account)
        .where((utxo) => reservedOutpoints.contains(_utxoKey(utxo)))
        .fold(0, (total, utxo) => total + utxo.value);
  }

  Set<String> _reservedOutpointsFor(String accountId) =>
      _storedRoastSigningOperations.values
          .where(
            (operation) =>
                operation.accountId == accountId && operation.reservesUtxos,
          )
          .expand((operation) => operation.reservedOutpoints)
          .toSet();

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

  Future<void> _restoreRoastSigningOperations() async {
    final operations = await _roastSigningOperations.loadSigningOperations();
    for (var operation in operations) {
      if (operation.state == RoastSigningOperationState.broadcasting) {
        operation = operation.copyWith(
          state: RoastSigningOperationState.broadcastUnknown,
          errorMessage: 'The previous broadcast outcome is unknown.',
        );
        await _saveRoastSigningOperation(operation);
      } else if (operation.rawTransactionHex == null &&
          operation.signaturesHex.isNotEmpty) {
        try {
          operation = await _completeRoastSigningOperation(operation);
        } on Object catch (error) {
          operation = operation.copyWith(
            state: RoastSigningOperationState.interrupted,
            errorMessage: '$error',
          );
          await _saveRoastSigningOperation(operation);
        }
      } else if (operation.rawTransactionHex == null &&
          operation.expiry.isBefore(DateTime.now())) {
        operation = operation.copyWith(
          state: RoastSigningOperationState.expired,
          errorMessage: 'The ROAST signing request expired.',
        );
        await _saveRoastSigningOperation(operation);
        await _recordActivity(
          id: 'signature-request-expired:${operation.storageId}',
          accountId: operation.accountId,
          type: WalletActivityType.signatureRequestExpired,
          reference: operation.requestIdHex,
        );
      } else if (operation.rawTransactionHex == null &&
          (operation.state == RoastSigningOperationState.prepared ||
              operation.state == RoastSigningOperationState.requesting ||
              operation.state ==
                  RoastSigningOperationState.awaitingSignatures)) {
        operation = operation.copyWith(
          state: RoastSigningOperationState.interrupted,
          errorMessage: 'The previous signing request outcome is unknown.',
        );
        await _saveRoastSigningOperation(operation);
      } else {
        _storedRoastSigningOperations[operation.storageId] = operation;
      }
    }
  }

  Future<void> _saveRoastSigningOperation(
    RoastSigningOperation operation,
  ) async {
    await _roastSigningOperations.putSigningOperation(operation);
    _storedRoastSigningOperations[operation.storageId] = operation;
    notifyListeners();
  }

  Future<void> _recordActivity({
    required String id,
    required String accountId,
    required WalletActivityType type,
    String? reference,
    String? details,
  }) async {
    final current = _vault;
    if (current == null || current.activities.any((item) => item.id == id)) {
      return;
    }
    final activity = WalletActivity(
      id: id,
      accountId: accountId,
      type: type,
      occurredAt: DateTime.now().toUtc(),
      reference: reference,
      details: details,
    );
    final next = current.copyWith(
      activities: [
        activity,
        ...current.activities,
      ].take(_maxActivityEntries).toList(growable: false),
    );
    try {
      await _repository.save(next);
      _vault = next;
      notifyListeners();
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Unable to persist wallet activity',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _recordSetupActivity(
    RoastSetup setup, {
    required String id,
    required WalletActivityType type,
    String? reference,
    String? details,
  }) async {
    final account = accounts
        .where((item) => item.sourceId == setup.id)
        .firstOrNull;
    if (account == null) return;
    await _recordActivity(
      id: id,
      accountId: account.id,
      type: type,
      reference: reference,
      details: details,
    );
  }

  Future<RoastSigningOperation> _completeRoastSigningOperation(
    RoastSigningOperation operation,
  ) async {
    final signed = _transactionService.completeThresholdSigning(
      transaction: ThresholdWalletTransaction.fromJson(
        operation.thresholdTransaction,
      ),
      signatures: [
        for (final signature in operation.signaturesHex) hexToBytes(signature),
      ],
      expectedInternalKeyHex: operation.expectedInternalKeyHex,
    );
    final completed = operation.copyWith(
      state: RoastSigningOperationState.signed,
      rawTransactionHex: signed.rawTransactionHex,
      transactionId: signed.transactionId,
      clearError: true,
    );
    await _saveRoastSigningOperation(completed);
    await _recordActivity(
      id: 'transaction-signed:${operation.storageId}',
      accountId: operation.accountId,
      type: WalletActivityType.transactionSigned,
      reference: signed.transactionId,
    );
    return completed;
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

  Future<String> createRoastSetupDraft({
    required RoastSetupRole role,
    required String walletName,
    required String participantName,
    required int threshold,
    required int participantCount,
    required WalletNetwork network,
  }) async {
    if (_roastRuntime == null) {
      throw UnsupportedError(
        'ROAST is available on supported desktop platforms only.',
      );
    }
    final cleanParticipantName = participantName.trim();
    if (cleanParticipantName.isEmpty) {
      throw ArgumentError('Participant name cannot be empty.');
    }
    if (threshold < 2 || threshold > participantCount) {
      throw ArgumentError('Threshold must be between 2 and participant count.');
    }
    final cleanWalletName = walletName.trim().isEmpty
        ? 'Shared wallet'
        : walletName.trim();
    final material = _roastKeyService.generateParticipant();
    final setupId = _roastKeyService.newSetupId();
    final groupId = _roastKeyService.newSetupId();
    final selectedNetwork = _networkById(
      network.blockchainId,
      network.networkId,
    );
    final setup = RoastSetup(
      id: setupId,
      groupId: groupId,
      name: cleanWalletName,
      role: role,
      status: RoastSetupStatus.draft,
      threshold: threshold,
      participantCount: participantCount,
      blockchainId: selectedNetwork.blockchainId,
      networkId: selectedNetwork.networkId,
      localCardId: material.cardId,
      localParticipantPrivateKeyHex: material.privateKeyHex,
      participants: [
        RoastParticipant(
          cardId: material.cardId,
          name: cleanParticipantName,
          identifierHex: '',
          publicKeyHex: material.publicKeyHex,
        ),
      ],
      onlineParticipantIds: const [],
      keyName: roastKeyName(groupId),
      createdAt: DateTime.now().toUtc(),
      usesRoomEnrollment: true,
    );
    final account = WalletAccount(
      id: 'roast-$setupId-${selectedNetwork.storageId}-0',
      name: cleanWalletName,
      accountIndex: 0,
      blockchainId: selectedNetwork.blockchainId,
      networkId: selectedNetwork.networkId,
      keySource: WalletKeySource.roast,
      sourceId: setupId,
      keyId: setup.keyName,
      createdAt: DateTime.now().toUtc(),
    );
    final current = _vault;
    final next = current == null
        ? WalletVault(
            accounts: [account],
            nextAccountIndex: 0,
            roastSetups: [setup],
          )
        : current.copyWith(
            accounts: [...current.accounts, account],
            roastSetups: [...current.roastSetups, setup],
          );
    await _repository.save(next);
    _vault = next;
    _selectedAccount = next.accounts.length - 1;
    notifyListeners();
    return setupId;
  }

  String participantCard(String setupId) {
    final setup = _setupById(setupId);
    final participant = setup.localParticipant;
    return RoastExchangeCodec.encodeParticipantCard(
      cardId: participant.cardId,
      name: participant.name,
      publicKeyHex: participant.publicKeyHex,
    );
  }

  String participantPublicKey(String setupId) =>
      _setupById(setupId).localParticipant.publicKeyHex;

  String normalizeRoastParticipantPublicKey(String value) =>
      _roastKeyService.normalizeParticipantPublicKey(value);

  Future<List<RoastIssuedInvitation>> createHostedRoastInvitations(
    String setupId,
    List<({String name, String publicKeyHex})> invitees,
  ) => finalizeHostedRoastSetup(setupId, [
    for (final invitee in invitees)
      _roastKeyService.participantCardFromPublicKey(
        name: invitee.name,
        publicKeyHex: invitee.publicKeyHex,
      ),
  ]);

  Future<List<RoastIssuedInvitation>> finalizeHostedRoastSetup(
    String setupId,
    List<String> participantCards,
  ) async {
    final draft = _setupById(setupId);
    if (draft.role != RoastSetupRole.host) {
      throw StateError('Only a host can finalize this participant roster.');
    }
    final participants = _roastKeyService.finalizeRoster(
      draft,
      participantCards,
    );
    var setup = draft.copyWith(
      participants: participants,
      hostParticipantId: participants
          .singleWhere((participant) => participant.cardId == draft.localCardId)
          .identifierHex,
      status: RoastSetupStatus.connecting,
      clearError: true,
    );
    setup = setup.copyWith(
      groupFingerprintHex: _roastKeyService.groupFingerprint(setup),
    );
    await _replaceSetup(setup);
    try {
      final room = await _roastRuntime!.createRoom(setup);
      setup = setup.copyWith(
        coordinatorId: room.coordinatorId,
        coordinatorRelayUrls: room.coordinatorRelayUrls,
        coordinatorIpAddrs: room.coordinatorIpAddrs,
      );
      await _replaceSetup(setup);
      final invitations = [
        for (final invite in room.invites)
          RoastIssuedInvitation(
            participantName: participants
                .singleWhere(
                  (participant) =>
                      participant.publicKeyHex ==
                      invite.participantPublicKeyHex,
                )
                .name,
            participantPublicKeyHex: invite.participantPublicKeyHex,
            encoded: RoastExchangeCodec.encodeInvitation(
              setup,
              roomInvite: invite.encoded,
              participantPublicKeyHex: invite.participantPublicKeyHex,
              expiresAt: invite.expiresAt,
            ),
          ),
      ];
      _issuedRoastInvitations[setup.id] = invitations;
      notifyListeners();
      return invitations;
    } catch (error) {
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.error,
          errorMessage: _cleanRoastError(error),
        ),
      );
      rethrow;
    }
  }

  Future<void> joinRoastSetup(String setupId, String invitation) async {
    final draft = _setupById(setupId);
    if (draft.role != RoastSetupRole.member) {
      throw StateError('This setup is not waiting for an invitation.');
    }
    final decoded = _roastKeyService.applyInvitation(draft, invitation);
    final setup = decoded.setup.copyWith(
      status: RoastSetupStatus.connecting,
      clearError: true,
    );
    final current = _vault!;
    final account = current.accounts.firstWhere(
      (item) => item.sourceId == setupId,
    );
    final replacementAccount = WalletAccount(
      id: 'roast-$setupId-${setup.blockchainId}:${setup.networkId}-0',
      name: account.name,
      accountIndex: 0,
      blockchainId: setup.blockchainId,
      networkId: setup.networkId,
      keySource: WalletKeySource.roast,
      sourceId: setupId,
      keyId: setup.keyName,
      createdAt: account.createdAt,
    );
    final next = current.copyWith(
      roastSetups: [
        for (final item in current.roastSetups)
          if (item.id == setupId) setup else item,
      ],
      accounts: [
        for (final item in current.accounts)
          if (item.sourceId == setupId) replacementAccount else item,
      ],
    );
    await _repository.save(next);
    _vault = next;
    notifyListeners();
    try {
      final snapshot = await _roastRuntime!.joinRoom(setup, decoded.roomInvite);
      _roastPresence[setup.id] = _RoastPresence(
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
      );
      await _replaceSetup(
        setup.copyWith(
          status: snapshot.connected
              ? RoastSetupStatus.ready
              : RoastSetupStatus.connecting,
          onlineParticipantIds: snapshot.onlineParticipantIds,
          coordinatorId: snapshot.coordinatorId,
          coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
          coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
          clearError: true,
        ),
      );
    } catch (error) {
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.error,
          errorMessage: _cleanRoastError(error),
        ),
      );
      rethrow;
    }
  }

  Future<void> resumeRoastSetup(String setupId) async {
    final setup = _setupById(setupId);
    if (!setup.isFinalized || _roastOperations.contains(setupId)) return;
    await _startRoastRuntime(
      setup.copyWith(status: RoastSetupStatus.connecting),
    );
  }

  Future<void> startRoastDkg(String setupId) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      if (setup.role != RoastSetupRole.host) {
        throw StateError('Only the setup host can start key creation.');
      }
      if (onlineSignerCount(setup) < setup.participantCount) {
        throw StateError(
          'All participants must be online before key creation.',
        );
      }
      final dkgSetup = setup.copyWith(
        keyName: normalizeRoastKeyName(setup.groupId, setup.keyName),
      );
      await _replaceSetup(
        dkgSetup.copyWith(
          status: RoastSetupStatus.creatingKey,
          clearError: true,
        ),
      );
      try {
        await _roastRuntime!.requestDkg(dkgSetup);
      } on Object catch (error) {
        await _recordSetupActivity(
          dkgSetup,
          id:
              'dkg-failed:${dkgSetup.id}:request:'
              '${DateTime.now().microsecondsSinceEpoch}',
          type: WalletActivityType.dkgFailed,
          reference: dkgSetup.keyName,
          details: _cleanRoastError(error),
        );
        rethrow;
      }
    });
  }

  Future<void> acceptRoastDkg(String setupId) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      final proposal = setup.pendingDkgProposalHex;
      if (proposal == null ||
          setup.pendingDkgName != setup.keyName ||
          setup.pendingDkgThreshold != setup.threshold ||
          setup.pendingDkgCreatorId != setup.hostParticipantId ||
          setup.pendingDkgExpiry?.isAfter(DateTime.now()) != true) {
        throw StateError('There is no DKG proposal to accept.');
      }
      await _replaceSetup(
        setup.copyWith(status: RoastSetupStatus.creatingKey, clearError: true),
      );
      await _roastRuntime!.acceptDkg(setupId, proposal);
    });
  }

  Future<void> rejectRoastDkg(String setupId) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      final proposal = setup.pendingDkgProposalHex;
      if (proposal == null) {
        throw StateError('There is no DKG proposal to reject.');
      }
      await _roastRuntime!.rejectDkg(setupId, proposal);
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.ready,
          clearPendingDkgProposal: true,
        ),
      );
    });
  }

  Future<void> _guardRoastOperation(
    String setupId,
    Future<void> Function() operation,
  ) async {
    if (!_roastOperations.add(setupId)) return;
    notifyListeners();
    try {
      await operation();
    } catch (error) {
      if (roastSetups.any((setup) => setup.id == setupId)) {
        await _replaceSetup(
          _setupById(setupId).copyWith(
            status: RoastSetupStatus.error,
            errorMessage: _cleanRoastError(error),
          ),
        );
      }
      rethrow;
    } finally {
      _roastOperations.remove(setupId);
      notifyListeners();
    }
  }

  Future<void> _startRoastRuntime(RoastSetup setup) async {
    final runtime = _roastRuntime;
    if (runtime == null || !_roastOperations.add(setup.id)) return;
    notifyListeners();
    try {
      await _replaceSetup(setup.copyWith(status: RoastSetupStatus.connecting));
      final snapshot = await runtime.startSetup(setup);
      _roastPresence[setup.id] = _RoastPresence(
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
      );
      final connected = setup.copyWith(
        status: snapshot.groupKeyHex == null
            ? snapshot.pendingDkgProposalHex == null
                  ? RoastSetupStatus.ready
                  : snapshot.pendingDkgStage != 'waiting'
                  ? RoastSetupStatus.creatingKey
                  : RoastSetupStatus.awaitingDkgApproval
            : RoastSetupStatus.active,
        onlineParticipantIds: snapshot.onlineParticipantIds,
        coordinatorId: snapshot.coordinatorId,
        coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
        coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
        groupKeyHex: snapshot.groupKeyHex,
        pendingDkgProposalHex: snapshot.pendingDkgProposalHex,
        pendingDkgStage: snapshot.pendingDkgStage,
        pendingDkgCompletedParticipantIds:
            snapshot.pendingDkgCompletedParticipantIds,
        pendingDkgName: snapshot.pendingDkgName,
        pendingDkgThreshold: snapshot.pendingDkgThreshold,
        pendingDkgCreatorId: snapshot.pendingDkgCreator,
        pendingDkgExpiry: snapshot.pendingDkgExpiry,
        clearPendingDkgProposal: snapshot.pendingDkgProposalHex == null,
        clearError: true,
      );
      await _replaceSetup(connected);
      if (snapshot.groupKeyHex != null) {
        await _activateRoastAccount(connected, snapshot.groupKeyHex!);
      }
    } catch (error) {
      _roastPresence.remove(setup.id);
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.error,
          errorMessage: _cleanRoastError(error),
        ),
      );
    } finally {
      _roastOperations.remove(setup.id);
      notifyListeners();
    }
  }

  RoastSetup _setupById(String setupId) => roastSetups.firstWhere(
    (setup) => setup.id == setupId,
    orElse: () => throw ArgumentError.value(setupId, 'setupId'),
  );

  Future<void> _replaceSetup(RoastSetup replacement) async {
    final current = _vault;
    if (current == null) return;
    final previous = current.roastSetups
        .where((setup) => setup.id == replacement.id)
        .firstOrNull;
    if (previous != null && previous.status != replacement.status) {
      AppLogger.info(
        '${_roastLogScope(replacement.id)} State '
        '${previous.status.name} -> ${replacement.status.name}; '
        'dkgStage=${replacement.pendingDkgStage ?? '-'}, '
        'confirmed=${replacement.pendingDkgCompletedParticipantIds.length}/'
        '${replacement.participantCount}',
      );
    }
    final next = current.copyWith(
      roastSetups: [
        for (final setup in current.roastSetups)
          if (setup.id == replacement.id) replacement else setup,
      ],
    );
    await _repository.save(next);
    _vault = next;
    notifyListeners();
  }

  void _queueRoastEvent(RoastRuntimeEvent event) {
    _roastEventQueue = _roastEventQueue.then(
      (_) => _handleRoastEventSafely(event),
    );
  }

  void _queueRoastStreamFailure(Object error) {
    _roastEventQueue = _roastEventQueue.then(
      (_) => _handleRoastStreamFailure(error),
    );
  }

  Future<void> _handleRoastEventSafely(RoastRuntimeEvent event) async {
    try {
      await _handleRoastEvent(event);
    } catch (error, stackTrace) {
      if (event case RoastRuntimeSigningResultEvent()) {
        final pending =
            _pendingRoastSends['${event.setupId}:${event.requestIdHex}'];
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(
            _RoastSendOutcome(error: error, stackTrace: stackTrace),
          );
        }
      }
      if (_disposed || !roastSetups.any((item) => item.id == event.setupId)) {
        return;
      }
      try {
        final setup = _setupById(event.setupId);
        await _replaceSetup(
          setup.copyWith(
            status: RoastSetupStatus.error,
            errorMessage: _cleanRoastError(error),
          ),
        );
      } on Object {
        // A persistence failure must not poison the serialized event queue.
      }
    }
  }

  Future<void> _handleRoastStreamFailure(Object error) async {
    if (_disposed) return;
    for (final pending in _pendingRoastSends.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(_RoastSendOutcome(error: error));
      }
    }
    for (final setup in [...roastSetups]) {
      _roastPresence.remove(setup.id);
      try {
        await _replaceSetup(
          _setupById(setup.id).copyWith(
            status: RoastSetupStatus.interrupted,
            errorMessage: _cleanRoastError(error),
          ),
        );
      } on Object {
        // Keep processing the remaining setups even if one save fails.
      }
    }
  }

  Future<void> _handleRoastEvent(RoastRuntimeEvent event) async {
    if (_disposed || !roastSetups.any((setup) => setup.id == event.setupId)) {
      return;
    }
    final setup = _setupById(event.setupId);
    switch (event) {
      case RoastRuntimeSnapshotEvent():
        _roastPresence[event.setupId] = _RoastPresence(
          connected: event.connected,
          signerRunning: event.signerRunning,
        );
        await _replaceSetup(
          setup.copyWith(
            onlineParticipantIds: event.onlineParticipantIds,
            coordinatorId: event.coordinatorId,
            coordinatorRelayUrls: event.coordinatorRelayUrls,
            coordinatorIpAddrs: event.coordinatorIpAddrs,
            status:
                setup.status == RoastSetupStatus.connecting && event.connected
                ? RoastSetupStatus.ready
                : setup.status,
          ),
        );
      case RoastRuntimeDkgEvent():
        if (event.rejected) {
          if (_dkgDefinitionMatchesSetup(event, setup) &&
              (setup.pendingDkgProposalHex == null ||
                  setup.pendingDkgProposalHex == event.proposalHex)) {
            await _replaceSetup(
              setup.copyWith(
                status: RoastSetupStatus.ready,
                clearPendingDkgProposal: true,
                errorMessage: event.failure ?? 'The DKG proposal was rejected.',
              ),
            );
            await _recordSetupActivity(
              setup,
              id: 'dkg-failed:${setup.id}:${event.proposalHex}',
              type: WalletActivityType.dkgFailed,
              reference: event.proposalHex,
              details: event.failure ?? 'The DKG proposal was rejected.',
            );
          }
          return;
        }
        if (!_dkgMatchesSetup(event, setup)) {
          await _roastRuntime?.rejectDkg(event.setupId, event.proposalHex);
          return;
        }
        await _replaceSetup(
          setup.copyWith(
            status: event.failure != null
                ? RoastSetupStatus.error
                : event.stage != 'waiting'
                ? RoastSetupStatus.creatingKey
                : RoastSetupStatus.awaitingDkgApproval,
            pendingDkgProposalHex: event.proposalHex,
            pendingDkgStage: event.stage,
            pendingDkgCompletedParticipantIds: event.completedParticipantIds,
            pendingDkgName: event.name,
            pendingDkgThreshold: event.threshold,
            pendingDkgCreatorId: event.creator,
            pendingDkgExpiry: event.expiry,
            errorMessage: event.failure,
          ),
        );
        await _recordSetupActivity(
          setup,
          id: event.failure == null
              ? 'dkg-started:${setup.id}:${event.proposalHex}'
              : 'dkg-failed:${setup.id}:${event.proposalHex}',
          type: event.failure == null
              ? WalletActivityType.dkgStarted
              : WalletActivityType.dkgFailed,
          reference: event.proposalHex,
          details: event.failure,
        );
      case RoastRuntimeKeyEvent():
        if (event.keyName != setup.keyName) return;
        final active = setup.copyWith(
          status: RoastSetupStatus.active,
          groupKeyHex: event.groupKeyHex,
          clearPendingDkgProposal: true,
          clearError: true,
        );
        await _replaceSetup(active);
        await _activateRoastAccount(active, event.groupKeyHex);
        await _recordSetupActivity(
          active,
          id: 'dkg-completed:${setup.id}:${event.keyName}',
          type: WalletActivityType.dkgCompleted,
          reference: event.keyName,
        );
      case RoastRuntimeFailureEvent():
        if (event.operation == 'signatures' ||
            event.operation == 'signingPersistence') {
          final error = WalletTransactionRejected(event.message);
          final pendingEntries = event.requestIdHex == null
              ? _pendingRoastSends.entries.where(
                  (entry) => entry.key.startsWith('${event.setupId}:'),
                )
              : _pendingRoastSends.entries.where(
                  (entry) =>
                      entry.key == '${event.setupId}:${event.requestIdHex}',
                );
          for (final entry in pendingEntries) {
            if (!entry.value.completer.isCompleted) {
              entry.value.completer.complete(_RoastSendOutcome(error: error));
            }
          }
          if (event.requestIdHex case final requestId?) {
            _roastSigningRequests.remove('${event.setupId}:$requestId');
          }
          notifyListeners();
          return;
        }
        if (event.operation.toLowerCase().contains('dkg') ||
            event.operation == 'keyReadiness') {
          await _recordSetupActivity(
            setup,
            id:
                'dkg-failed:${setup.id}:'
                '${setup.pendingDkgProposalHex ?? setup.keyName}:'
                '${event.operation}',
            type: WalletActivityType.dkgFailed,
            reference: setup.pendingDkgProposalHex ?? setup.keyName,
            details: event.message,
          );
        }
        if (event.interrupted) _roastPresence.remove(event.setupId);
        await _replaceSetup(
          setup.copyWith(
            status: event.interrupted
                ? RoastSetupStatus.interrupted
                : RoastSetupStatus.error,
            errorMessage: event.message,
          ),
        );
      case RoastRuntimeSigningRequestEvent():
        final requestKey = '${setup.id}:${event.request.idHex}';
        if (event.request.status != 'waiting') {
          final removed = _roastSigningRequests.remove(requestKey);
          final type = switch (event.request.status) {
            'accepted' => WalletActivityType.signatureRequestApproved,
            'rejected' => WalletActivityType.signatureRequestRejected,
            _ => null,
          };
          if (type != null &&
              (removed != null ||
                  event.request.creator ==
                      setup.localParticipant.identifierHex)) {
            await _recordSetupActivity(
              setup,
              id: event.request.status == 'accepted'
                  ? 'signature-request-approved:$requestKey'
                  : 'signature-request-rejected:$requestKey',
              type: type,
              reference: event.request.idHex,
            );
          }
          notifyListeners();
          return;
        }
        if (event.request.creator == setup.localParticipant.identifierHex) {
          return;
        }
        try {
          _validateRoastSigningRequest(setup, event.request);
          final account = accounts.firstWhere(
            (item) => item.sourceId == setup.id,
          );
          _roastSigningRequests[requestKey] = RoastSigningInboxItem(
            setupId: setup.id,
            walletName: account.name,
            request: event.request,
          );
          await _recordActivity(
            id: 'signature-request-received:$requestKey',
            accountId: account.id,
            type: WalletActivityType.signatureRequestReceived,
            reference: event.request.idHex,
          );
          notifyListeners();
        } on Object {
          // Unsupported or foreign proposals are deliberately not rendered.
        }
      case RoastRuntimeSigningRequestRemovedEvent():
        final removed = _roastSigningRequests.remove(
          '${event.setupId}:${event.requestIdHex}',
        );
        if (event.expired && removed != null) {
          await _recordSetupActivity(
            setup,
            id:
                'signature-request-expired:${event.setupId}:'
                '${event.requestIdHex}',
            type: WalletActivityType.signatureRequestExpired,
            reference: event.requestIdHex,
          );
        }
        notifyListeners();
      case RoastRuntimeSigningResultEvent():
        final pendingKey = '${setup.id}:${event.requestIdHex}';
        if (event.creator != setup.localParticipant.identifierHex) return;
        var operation = await _roastSigningOperations.getSigningOperation(
          pendingKey,
        );
        if (operation == null || operation.proposalHex != event.proposalHex) {
          throw StateError(
            'The completed ROAST proposal does not match local state.',
          );
        }
        _storedRoastSigningOperations[pendingKey] = operation;
        if (operation.rawTransactionHex == null) {
          operation = await _completeRoastSigningOperation(operation);
        }
        final pending = _pendingRoastSends[pendingKey];
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(
            _RoastSendOutcome(
              signed: SignedWalletTransaction(
                transactionId: operation.transactionId!,
                rawTransactionHex: operation.rawTransactionHex!,
              ),
            ),
          );
        }
    }
  }

  static bool _dkgMatchesSetup(RoastRuntimeDkgEvent event, RoastSetup setup) =>
      _dkgDefinitionMatchesSetup(event, setup) &&
      event.creator == setup.hostParticipantId &&
      event.expiry.isAfter(DateTime.now());

  static bool _dkgDefinitionMatchesSetup(
    RoastRuntimeDkgEvent event,
    RoastSetup setup,
  ) =>
      event.name == setup.keyName &&
      event.threshold == setup.threshold &&
      event.description == roastKeyDescription(setup);

  Future<void> _activateRoastAccount(
    RoastSetup setup,
    String groupKeyHex,
  ) async {
    final current = _vault;
    if (current == null) return;
    final network = _networkById(setup.blockchainId, setup.networkId);
    final derived = _roastKeyService.deriveAddress(
      groupKeyHex: groupKeyHex,
      threshold: setup.threshold,
      network: network,
      accountIndex: 0,
    );
    final next = current.copyWith(
      accounts: [
        for (final account in current.accounts)
          if (account.sourceId == setup.id)
            account.copyWith(
              keyId: setup.keyName,
              derivationPath: derived.pathLabel,
              address: derived.address,
            )
          else
            account,
      ],
    );
    await _ensureNetworkService(network);
    await _repository.save(next);
    _vault = next;
    await _restartElectrumxSync();
  }

  static String _cleanRoastError(Object error) => switch (error) {
    NoosphereWorkerException(:final message) => message,
    ArgumentError() => error.toString(),
    StateError(:final message) => message,
    _ => 'Unable to connect to the ROAST coordinator.',
  };

  static String _roastLogScope(String setupId) {
    final shortId = setupId.length <= 8 ? setupId : setupId.substring(0, 8);
    return '[ROAST $shortId]';
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

  WalletTransactionPreview prepareSend(WalletSendRequest request) {
    final account = selectedAccount;
    final address = account?.address;
    if (account == null || address == null) {
      throw const WalletSigningUnavailable();
    }
    return _transactionService.prepare(
      accountId: account.id,
      network: networkForAccount(account),
      sourceAddress: address,
      availableUtxos: availableUtxosFor(account),
      request: request,
    );
  }

  static String _utxoKey(ElectrumxUtxo utxo) => '${utxo.txHash}:${utxo.txPos}';

  Future<WalletSendResult> sendTransaction(
    WalletTransactionPreview preview,
  ) async {
    if (_sending) {
      throw const WalletTransactionRejected(
        'Another transaction is already being submitted.',
      );
    }
    _sending = true;
    try {
      final account = accounts
          .where((candidate) => candidate.id == preview.accountId)
          .firstOrNull;
      if (account == null) {
        throw const WalletSigningUnavailable();
      }
      final SignedWalletTransaction signed;
      RoastSigningOperation? signingOperation;
      if (account.keySource == WalletKeySource.personal) {
        final privateKeyHex = account.privateKeyHex;
        if (privateKeyHex == null) throw const WalletSigningUnavailable();
        signed = _transactionService.sign(
          network: networkForAccount(account),
          preview: preview,
          privateKeyHex: privateKeyHex,
        );
        await _recordActivity(
          id: 'transaction-signed:${account.id}:${signed.transactionId}',
          accountId: account.id,
          type: WalletActivityType.transactionSigned,
          reference: signed.transactionId,
        );
      } else {
        final setup = setupForAccount(account);
        final runtime = _roastRuntime;
        if (setup == null ||
            runtime == null ||
            !setup.isActive ||
            setup.groupKeyHex == null) {
          throw const WalletSigningUnavailable();
        }
        if (onlineSignerCount(setup) < setup.threshold) {
          throw const WalletTransactionRejected(
            'The ROAST signing quorum is not online.',
          );
        }
        final network = networkForAccount(account);
        final derived = _roastKeyService.deriveAddress(
          groupKeyHex: setup.groupKeyHex!,
          threshold: setup.threshold,
          network: network,
          accountIndex: account.accountIndex,
        );
        final transaction = _transactionService.prepareThresholdSigning(
          network: network,
          preview: preview,
        );
        final proposal = runtime.createTransactionSigningProposal(
          setup,
          transaction,
          derived.path,
        );
        final pendingKey = '${setup.id}:${proposal.idHex}';
        final completer = Completer<_RoastSendOutcome>();
        _pendingRoastSends[pendingKey] = _PendingRoastSend(
          completer: completer,
        );
        signingOperation = RoastSigningOperation(
          setupId: setup.id,
          accountId: account.id,
          requestIdHex: proposal.idHex,
          proposalHex: proposal.proposalHex,
          expectedInternalKeyHex: derived.internalKeyHex,
          derivationPath: List.unmodifiable(derived.path),
          thresholdTransaction: transaction.toJson(),
          reservedOutpoints: [
            for (final utxo in preview.selectedUtxos) _utxoKey(utxo),
          ],
          expiry: proposal.expiry,
          state: RoastSigningOperationState.prepared,
          updatedAt: DateTime.now().toUtc(),
        );
        await _saveRoastSigningOperation(signingOperation);
        try {
          signingOperation = signingOperation.copyWith(
            state: RoastSigningOperationState.requesting,
          );
          await _saveRoastSigningOperation(signingOperation);
          signingOperation = signingOperation.copyWith(
            state: RoastSigningOperationState.awaitingSignatures,
          );
          await _saveRoastSigningOperation(signingOperation);
          await runtime.requestTransactionSignatures(setup, proposal);
          final outcome = await completer.future.timeout(
            proposal.expiry.difference(DateTime.now()),
          );
          if (outcome.error case final error?) {
            Error.throwWithStackTrace(
              error,
              outcome.stackTrace ?? StackTrace.current,
            );
          }
          signed = outcome.signed!;
          signingOperation = _storedRoastSigningOperations[pendingKey];
        } on Object catch (error) {
          final current = _storedRoastSigningOperations[pendingKey];
          if (current != null && current.rawTransactionHex == null) {
            final expired =
                current.expiry.isBefore(DateTime.now()) ||
                error.toString().toLowerCase().contains('expired');
            final rejected =
                error is WalletTransactionRejected &&
                error.message == 'Signing request failed.';
            await _saveRoastSigningOperation(
              current.copyWith(
                state: expired
                    ? RoastSigningOperationState.expired
                    : rejected
                    ? RoastSigningOperationState.rejected
                    : RoastSigningOperationState.interrupted,
                errorMessage: '$error',
              ),
            );
            if (expired) {
              await _recordActivity(
                id: 'signature-request-expired:${current.storageId}',
                accountId: current.accountId,
                type: WalletActivityType.signatureRequestExpired,
                reference: current.requestIdHex,
              );
            }
          }
          rethrow;
        } finally {
          _pendingRoastSends.remove(pendingKey);
          notifyListeners();
        }
      }
      return signingOperation == null
          ? await _broadcastSigned(account, signed)
          : await _broadcastRoastOperation(account, signingOperation, signed);
    } finally {
      _sending = false;
    }
  }

  Future<WalletSendResult> _broadcastRoastOperation(
    WalletAccount account,
    RoastSigningOperation operation,
    SignedWalletTransaction signed,
  ) async {
    var current = operation.copyWith(
      state: RoastSigningOperationState.broadcasting,
      rawTransactionHex: signed.rawTransactionHex,
      transactionId: signed.transactionId,
      clearError: true,
    );
    await _saveRoastSigningOperation(current);
    try {
      final result = await _broadcastSigned(account, signed);
      current = current.copyWith(
        state: RoastSigningOperationState.broadcasted,
        serverTransactionId: result.serverTransactionId,
        clearError: true,
      );
      await _saveRoastSigningOperation(current);
      return result;
    } on Object catch (error) {
      await _saveRoastSigningOperation(
        current.copyWith(
          state: RoastSigningOperationState.broadcastUnknown,
          errorMessage: '$error',
        ),
      );
      rethrow;
    }
  }

  Future<WalletSendResult> retryRoastBroadcast(
    RoastSigningOperation operation,
  ) async {
    final current = _storedRoastSigningOperations[operation.storageId];
    if (current == null || !current.canRetryBroadcast) {
      throw const WalletTransactionRejected(
        'This ROAST transaction cannot be rebroadcast.',
      );
    }
    final account = accounts
        .where((candidate) => candidate.id == current.accountId)
        .firstOrNull;
    if (account == null) throw const WalletSigningUnavailable();
    return _broadcastRoastOperation(
      account,
      current,
      SignedWalletTransaction(
        transactionId: current.transactionId!,
        rawTransactionHex: current.rawTransactionHex!,
      ),
    );
  }

  Future<WalletSendResult> _broadcastSigned(
    WalletAccount account,
    SignedWalletTransaction signed,
  ) async {
    if (_broadcastedTransactionIds.contains(signed.transactionId) ||
        !_broadcastingTransactionIds.add(signed.transactionId)) {
      throw const WalletTransactionRejected(
        'This transaction has already been submitted.',
      );
    }
    try {
      final service = _networkServices[networkForAccount(account).storageId];
      if (service == null) throw StateError('ElectrumX is not configured.');
      final serverTransactionId = await service.broadcastTransaction(
        signed.rawTransactionHex,
      );
      _broadcastedTransactionIds.add(signed.transactionId);
      await _recordActivity(
        id: 'transaction-broadcast:${account.id}:${signed.transactionId}',
        accountId: account.id,
        type: WalletActivityType.transactionBroadcast,
        reference: signed.transactionId,
      );
      await _restartElectrumxSync();
      return WalletSendResult(
        transactionId: signed.transactionId,
        serverTransactionId: serverTransactionId,
      );
    } finally {
      _broadcastingTransactionIds.remove(signed.transactionId);
    }
  }

  Future<void> acceptRoastSigningRequest(RoastSigningInboxItem item) async {
    final setup = _setupById(item.setupId);
    _validateRoastSigningRequest(setup, item.request);
    await _roastRuntime!.acceptSignatures(setup.id, item.request.idHex);
    _roastSigningRequests.remove('${setup.id}:${item.request.idHex}');
    await _recordSetupActivity(
      setup,
      id: 'signature-request-approved:${setup.id}:${item.request.idHex}',
      type: WalletActivityType.signatureRequestApproved,
      reference: item.request.idHex,
    );
    notifyListeners();
  }

  Future<void> rejectRoastSigningRequest(RoastSigningInboxItem item) async {
    final setup = _setupById(item.setupId);
    await _roastRuntime!.rejectSignatures(item.setupId, item.request.idHex);
    _roastSigningRequests.remove('${item.setupId}:${item.request.idHex}');
    await _recordSetupActivity(
      setup,
      id: 'signature-request-rejected:${setup.id}:${item.request.idHex}',
      type: WalletActivityType.signatureRequestRejected,
      reference: item.request.idHex,
    );
    notifyListeners();
  }

  void _validateRoastSigningRequest(
    RoastSetup setup,
    RoastSigningRequest request,
  ) {
    if (!request.hasTransactionMetadata ||
        !request.usesSupportedSighash ||
        !request.usesExpectedTaprootTweak ||
        request.expiry.isBefore(DateTime.now())) {
      throw const WalletTransactionRejected(
        'The signing request is expired or has unsupported metadata.',
      );
    }
    final account = accounts.firstWhere(
      (item) => item.sourceId == setup.id && item.accountIndex == 0,
    );
    final network = networkForAccount(account);
    final derived = _roastKeyService.deriveAddress(
      groupKeyHex: setup.groupKeyHex!,
      threshold: setup.threshold,
      network: network,
      accountIndex: account.accountIndex,
    );
    final expectedScript = _roastKeyService.scriptHexForAddress(
      network,
      derived.address,
    );
    final validKeys =
        request.masterGroupKeys.isNotEmpty &&
        request.masterGroupKeys.every((key) => key == setup.groupKeyHex);
    final validPaths =
        request.derivationPaths.length == request.masterGroupKeys.length &&
        request.derivationPaths.every((path) => _samePath(path, derived.path));
    final validInputs =
        request.previousOutputScripts.length == request.transactionInputCount &&
        request.previousOutputScripts.every(
          (script) => script == expectedScript,
        );
    final signsEveryInput =
        request.transactionInputCount == request.signedInputIndexes.length &&
        request.transactionInputCount == request.masterGroupKeys.length &&
        request.signedInputIndexes.indexed.every(
          (entry) => entry.$1 == entry.$2,
        );
    final knownOutpoints = spendableUtxosFor(account).map(_utxoKey).toSet();
    final reservedOutpoints = _reservedOutpointsFor(account.id);
    final validOutpoints =
        request.inputOutpoints.length == request.transactionInputCount &&
        request.inputOutpoints.every(knownOutpoints.contains) &&
        request.inputOutpoints.every(
          (outpoint) => !reservedOutpoints.contains(outpoint),
        );
    if (!validKeys ||
        !validPaths ||
        !validInputs ||
        !validOutpoints ||
        !signsEveryInput ||
        request.outputs.isEmpty ||
        request.feeSats < 0) {
      throw const WalletTransactionRejected(
        'The signing request does not belong to this wallet.',
      );
    }
  }

  static bool _samePath(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  void selectAccount(int index) {
    if (index < 0 || index >= accounts.length) return;
    _selectedAccount = index;
    notifyListeners();
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
              );
              if (balanceIncreased) onCoinsReceived?.call();
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

  void _queueBroadcastReservationReconciliation(
    String address,
    List<ElectrumxUtxo> utxos,
  ) {
    final outpoints = utxos.map(_utxoKey).toSet();
    _utxoReconciliationQueue = _utxoReconciliationQueue
        .then((_) async {
          if (_disposed) return;
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

  @override
  void dispose() {
    _disposed = true;
    _syncGeneration++;
    unawaited(_roastEvents?.cancel());
    final roastRuntime = _roastRuntime;
    if (roastRuntime != null) unawaited(roastRuntime.close());
    for (final pending in _pendingRoastSends.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          _RoastSendOutcome(
            error: const WalletTransactionRejected('ROAST signer stopped.'),
          ),
        );
      }
    }
    _pendingRoastSends.clear();
    _storedRoastSigningOperations.clear();
    _roastPresence.clear();
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
