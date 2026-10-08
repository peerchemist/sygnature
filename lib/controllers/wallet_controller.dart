import 'dart:async';

import 'package:coinlib/coinlib.dart'
    show
        Address,
        ECCompressedPublicKey,
        ECPrivateKey,
        P2TRAddress,
        bytesToHex,
        generateRandomBytes,
        hexToBytes;
import 'package:flutter/foundation.dart';
import 'package:noosphere/config.dart' show GroupConfig;
import 'package:noosphere/domain.dart'
    show
        Expiry,
        GroupTransitionApproval,
        GroupTransitionKeyPlan,
        GroupTransitionProposal,
        Identifier,
        NewDkgDetails,
        thresholdBip86DerivationPath;
import 'package:noosphere_flutter/noosphere_flutter.dart'
    show NoosphereWorkerException;

import '../models/electrumx_utxo.dart';
import '../models/group_transition.dart';
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

// Functional slices stay in this library so they can share private state.
part 'wallet_controller_accounts.dart';
part 'wallet_controller_activity.dart';
part 'wallet_controller_roast_events.dart';
part 'wallet_controller_roast_setup.dart';
part 'wallet_controller_signing.dart';
part 'wallet_controller_sync.dart';

enum AccountSyncStatus { unavailable, syncing, synced, error }

enum RoastCoordinatorLocalState {
  switching,
  connected,
  stopped,
  recoveryRequired,
}

class RoastSigningInboxItem({
  required final String setupId,
  required final String walletName,
  required final RoastSigningRequest request,
});

class RoastGroupTransitionCreation({
  required final String transitionId,
  required final String successorSetupId,
  required final List<RoastIssuedInvitation> invitations,
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
    this.onRoastActionRequired,
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
  final VoidCallback? onRoastActionRequired;
  final WalletKeyService _keyService;
  final WalletTransactionService _transactionService;
  final RoastRuntime? _roastRuntime;
  final RoastKeyService _roastKeyService;
  final RoastSigningOperationRepository _roastSigningOperations;
  final List<WalletNetwork> supportedNetworks;
  final Map<String, ElectrumxService> _networkServices = {};
  WalletVault? _vault;
  Future<void> _vaultMutations = Future.value();
  bool _vaultNeedsReload = false;
  String? _selectedAccountId;
  bool _busy = false;
  bool _disposed = false;
  int _syncGeneration = 0;
  final Map<String, StreamSubscription<PeercoinElectrumxUtxoSnapshot>>
  _syncSubscriptions = {};
  Future<void>? _syncCancellation;
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
  final Set<String> _roastCoordinatorSwitches = {};
  final Map<String, RoastCoordinatorSwitchFailure> _roastCoordinatorRecovery =
      {};
  final Map<String, RoastSigningInboxItem> _roastSigningRequests = {};
  final Map<String, _PendingRoastSend> _pendingRoastSends = {};
  final Map<String, RoastSigningOperation> _storedRoastSigningOperations = {};
  final Map<String, Completer<RoastSignedMessage>> _pendingRoastMessages = {};
  final Map<String, RoastSigningProgress> _pendingRoastMessageProgress = {};
  final Map<String, RoastSignedMessage> _completedRoastMessages = {};
  final Map<String, _RoastPresence> _roastPresence = {};
  final Set<String> _announcedRoastActions = {};

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _queueVaultMutation<T>(Future<T> Function() operation) {
    final result = _vaultMutations.then((_) => operation());
    // Report failure to the caller while allowing later mutations to proceed.
    _vaultMutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _updateVault(
    WalletVault? Function(WalletVault? current) update, {
    bool updateSelection = false,
  }) => _queueVaultMutation(() async {
    if (_vaultNeedsReload) {
      _vault = await _repository.load();
      _selectedAccountId =
          _vault?.selectedAccountId ?? accounts.firstOrNull?.id;
      _vaultNeedsReload = false;
      _notifyListeners();
    }
    final current = _vault;
    final next = update(current);
    if (identical(current, next)) return;
    try {
      if (next == null) {
        await _repository.delete();
      } else {
        await _repository.save(next);
      }
    } catch (_) {
      // A failed write may have committed. Reconcile before another mutation.
      _vaultNeedsReload = true;
      rethrow;
    }
    _vault = next;
    if (updateSelection) _selectedAccountId = next?.selectedAccountId;
    _notifyListeners();
  });

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
    for (final pending in _pendingRoastMessages.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const WalletTransactionRejected('ROAST signer stopped.'),
        );
      }
    }
    _pendingRoastMessages.clear();
    _pendingRoastMessageProgress.clear();
    _completedRoastMessages.clear();
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
