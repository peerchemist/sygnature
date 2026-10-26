import 'dart:async';
import 'dart:ui';

import 'package:app_links/app_links.dart';
import 'package:coinlib/coinlib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'controllers/wallet_controller.dart';
import 'controllers/theme_controller.dart';
import 'models/mnemonic_seed.dart';
import 'models/roast_setup.dart';
import 'services/app_diagnostics.dart';
import 'services/app_logger.dart';
import 'services/app_notifications.dart';
import 'services/android_public_feed_work.dart';
import 'services/public_feed_poller.dart';
import 'services/electrumx_service.dart';
import 'services/peercoin_network_service.dart';
import 'services/roast_runtime_manager.dart';
import 'services/wallet_key_service.dart';
import 'storage/wallet_repository.dart';
import 'storage/public_feed_store.dart';
import 'services/wallet_backup_service.dart';
import 'storage/roast_storage.dart';
import 'storage/vault_protection.dart';
import 'ui/app_theme.dart';
import 'ui/onboarding_screen.dart';
import 'ui/wallet_home.dart';
import 'ui/widgets/brand_mark.dart';
import 'ui/widgets/selector_builder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) => AppLogger.fatal(
    'Unhandled Flutter framework error',
    error: details.exception,
    stackTrace: details.stack,
  );
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLogger.fatal(
      'Unhandled root-isolate error',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
  try {
    await AppDiagnostics.initialize(
      (await getApplicationSupportDirectory()).path,
    );
  } on Object {
    // Diagnostics must never prevent the wallet from starting.
  }
  final incomingLinks = AppLinks().uriLinkStream;
  await loadCoinlib();
  runApp(
    SygnatureApp(
      incomingLinks: incomingLinks,
      noosphereInitializer: NoosphereFlutter.initialize,
    ),
  );
  try {
    await initializePublicFeedBackgroundWork();
  } on Object {
    AppLogger.warn('Unable to schedule public feed background work');
  }
}

typedef WalletControllerFactory = Future<WalletController> Function();
typedef NoosphereInitializer = Future<void> Function();

class const SygnatureApp({
  super.key,
  final WalletControllerFactory? controllerFactory,
  final Stream<Uri>? incomingLinks,
  final NoosphereInitializer? noosphereInitializer,
}) extends StatefulWidget {
  @override
  State<SygnatureApp> createState() => _SygnatureAppState();
}

class _SygnatureAppState extends State<SygnatureApp>
    with WidgetsBindingObserver {
  final ThemeController _themeController = ThemeController();
  late final AppNotifications _notifications;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();
  late final Future<void> _notificationsReady;
  Future<VaultProtectionStore>? _protectionStore;
  Future<WalletController>? _controller;
  StreamSubscription<Uri>? _incomingLinkSubscription;
  Future<PublicFeedStore>? _publicFeedStore;
  PublicFeedPoller? _publicFeedPoller;
  bool _disposed = false;
  Future<void> _noosphereInitialization = Future.value();
  Future<void> _incomingLinkWork = Future.value();

  @override
  void initState() {
    super.initState();
    _notifications = AppNotifications(
      onPublicFeedOpened: _showPublicFeedWakeReason,
    );
    _notificationsReady = _notifications.initialize();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_themeController.initialize());
    if (widget.noosphereInitializer != null) {
      _startNoosphereInitialization();
    }
    final controllerFactory = widget.controllerFactory;
    if (controllerFactory == null) {
      _publicFeedStore = getApplicationSupportDirectory().then(
        (directory) => PublicFeedStore.open(directory.path),
      );
      unawaited(_startPublicFeedPolling());
      _protectionStore = _initializeVault();
    } else {
      _protectionStore = null;
      _controller = controllerFactory();
    }
    _incomingLinkSubscription = widget.incomingLinks?.listen(
      _queueIncomingLink,
      onError: (Object error, StackTrace stackTrace) => AppLogger.error(
        '[APP LINK] Incoming link stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  void _startNoosphereInitialization({bool reconnect = false}) {
    final initialization = _initializeNoosphere();
    _noosphereInitialization = initialization;
    final completion = reconnect
        ? initialization.then((_) => _reconnectActiveRoastSetups())
        : initialization;
    unawaited(
      completion.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  Future<void> _reconnectActiveRoastSetups() async {
    final controllerFuture = _controller;
    if (controllerFuture == null) return;
    await (await controllerFuture).resumeActiveRoastSetups();
  }

  Future<void> _initializeNoosphere() async {
    AppLogger.info('[NOOSPHERE] Initializing native runtime');
    await AppDiagnostics.record(AppDiagnosticEvent.nativeInitializationStarted);
    try {
      await widget.noosphereInitializer!();
      await AppDiagnostics.record(
        AppDiagnosticEvent.nativeInitializationSucceeded,
      );
      AppLogger.info('[NOOSPHERE] Native runtime initialized');
    } catch (error, stackTrace) {
      await AppDiagnostics.record(
        AppDiagnosticEvent.nativeInitializationFailed,
        error: error,
      );
      AppLogger.error(
        '[NOOSPHERE] Native runtime initialization failed',
        error: error,
        stackTrace: stackTrace,
      );
      _showNoosphereInitializationError();
      rethrow;
    }
  }

  void _showNoosphereInitializationError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final messenger = _messengerKey.currentState;
      if (messenger == null) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'Shared wallets could not start. Personal wallets and backups '
              'remain available.',
            ),
            action: SnackBarAction(
              key: const Key('noosphere-initialization-retry'),
              label: 'Try again',
              onPressed: () => _startNoosphereInitialization(reconnect: true),
            ),
          ),
        );
    });
  }

  void _showPublicFeedWakeReason(String category) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final messenger = _messengerKey.currentState;
      if (messenger == null) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('public-feed-wake-reason'),
            duration: const Duration(seconds: 12),
            content: Text(
              category == 'dkg'
                  ? 'Key generation request received. Connecting to coordinator…'
                  : 'Signing request received. Connecting to coordinator…',
            ),
          ),
        );
    });
  }

  Future<void> _startPublicFeedPolling() async {
    try {
      final store = await _publicFeedStore!;
      await _notificationsReady;
      if (_disposed) return;
      _publicFeedPoller = PublicFeedPoller(
        store,
        notify: _notifications.publicFeedRequested,
      )..start();
    } on Object {
      AppLogger.warn('Public feed notification storage unavailable.');
    }
  }

  Future<VaultProtectionStore> _initializeVault() async {
    final store = await VaultProtectionStore.open();
    if (desktopVaultAvailable()) {
      final mode = store.config?.mode;
      if (mode != null && mode != VaultProtectionMode.system) {
        throw StateError(
          'This vault requires migration to the desktop system keyring. '
          'Its existing encryption keys and data have been preserved.',
        );
      }
      final controller = await _createSystemController();
      await store.configureSystem();
      _controller = Future.value(controller);
      return store;
    }
    if (deviceVaultAvailable()) {
      final mode = store.config?.mode;
      if (mode != VaultProtectionMode.device &&
          (mode != null || await HiveWalletRepository.boxExists())) {
        throw StateError(
          'This Android vault uses unsupported legacy protection. '
          'Clear the application data to create a device-protected vault.',
        );
      }
      try {
        final keyStore = PlatformSecureKeyStore.device();
        late final WalletController controller;
        if (mode == VaultProtectionMode.device) {
          final keys = await loadDeviceVaultKeys(keyStore: keyStore);
          controller = await _createCipherKeyController(keys);
        } else {
          controller = await _createDeferredDeviceController(store, keyStore);
        }
        _controller = Future.value(controller);
      } on VaultOpenFailure catch (error) {
        AppLogger.warn('[VAULT] Device vault failed (${error.name}).');
        rethrow;
      } on Object catch (error) {
        AppLogger.warn(
          '[VAULT] Device secure storage failed (${error.runtimeType}).',
        );
        throw VaultOpenFailure.secureStorageUnavailable;
      }
      return store;
    }
    throw UnsupportedError('Vault storage is unsupported on this platform.');
  }

  SecureKeyStore _systemKeyStore() {
    final platformStore = PlatformSecureKeyStore();
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? KeyringSecureKeyStore(platformStore)
        : platformStore;
  }

  Future<WalletController> _createSystemController() async {
    await _notificationsReady;
    final secureKeyStore = _systemKeyStore();
    final repository = await HiveWalletRepository.open(
      secureKeyStore: secureKeyStore,
    );
    final roastPersistence = RoastPersistenceFactory(
      secureKeyStore: secureKeyStore,
    );
    return _loadController(repository, roastPersistence);
  }

  Future<WalletController> _createCipherKeyController(
    VaultKeyMaterial keys,
  ) async {
    await _notificationsReady;
    final repository = await HiveWalletRepository.openWithCipherKey(
      keys.walletKey,
    );
    final roastPersistence = RoastPersistenceFactory(cipherKey: keys.roastKey);
    return _loadController(repository, roastPersistence);
  }

  Future<WalletController> _createDeferredDeviceController(
    VaultProtectionStore protectionStore,
    SecureKeyStore keyStore,
  ) async {
    await _notificationsReady;
    final deviceVault = _DeferredDeviceVault(protectionStore, keyStore);
    final repository = DeferredWalletRepository(() async {
      final keys = await deviceVault.initialize();
      return HiveWalletRepository.openWithCipherKey(keys.walletKey);
    });
    final roastPersistence = RoastPersistenceFactory(
      cipherKeyLoader: () async => (await deviceVault.initialize()).roastKey,
    );
    return _loadController(
      repository,
      roastPersistence,
      restorePrivateState: false,
    );
  }

  Future<WalletController> _loadController(
    WalletRepository repository,
    RoastPersistenceFactory roastPersistence, {
    bool restorePrivateState = true,
  }) async {
    if (restorePrivateState) {
      await roastPersistence.recoverBackupImport(repository);
    }
    final controller = WalletController(
      repository,
      publicFeedStore: _publicFeedStore,
      backupService: WalletBackupService(repository, roastPersistence),
      roastRuntime: RoastRuntimeManager(
        roastPersistence,
        publicFeedStore: _publicFeedStore,
        getWalletBip39Seed: () => _walletBip39Seed(repository),
        initializeNative: () => _noosphereInitialization,
      ),
      roastSigningOperations: roastPersistence,
      networkServiceFactory: (network) =>
          PeercoinElectrumxService.createForPreset(
            PeercoinNetworks.fromWalletNetwork(network),
          ),
      onCoinsReceived: _notifications.coinsReceived,
      onRoastSigningRequest: _notifications.roastSigningRequest,
      onDkgRequest: _notifications.dkgRequest,
      onRoastGroupCreated: _notifications.roastGroupCreated,
    );
    await controller.load(restoreSigningOperations: restorePrivateState);
    return controller;
  }

  Future<Uint8List> _walletBip39Seed(WalletRepository repository) async {
    final vault = await repository.load();
    final mnemonic = vault?.mnemonic;
    final languageId = vault?.languageId;
    if (mnemonic == null || languageId == null) {
      throw StateError('The wallet mnemonic is required for Iroh identity.');
    }
    final language = MnemonicLanguage.byId(languageId);
    final validation = CoinlibWalletKeyService().validateMnemonic(
      mnemonic: mnemonic,
      language: language,
    );
    if (!validation.isValid) {
      throw StateError('The stored wallet mnemonic is invalid.');
    }
    return CoinlibWalletKeyService.mnemonicToSeed(mnemonic, language: language);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _themeController.dispose();
    unawaited(_closePublicFeedPolling());
    unawaited(_incomingLinkSubscription?.cancel());
    final controller = _controller;
    if (controller != null) {
      unawaited(
        controller.then<void>(
          (value) => value.dispose(),
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
    _notifications.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(
      _notificationsReady.then((_) async {
        if (!_disposed) await _notifications.refreshSystemPermission();
      }),
    );
  }

  Future<void> _closePublicFeedPolling() async {
    try {
      final store = await _publicFeedStore;
      await _publicFeedPoller?.stop();
      await store?.close();
    } on Object {
      // Initialization can fail independently of the wallet lifecycle.
    }
  }

  void _queueIncomingLink(Uri uri) {
    _incomingLinkWork = _incomingLinkWork.then(
      (_) => _handleIncomingLinkSafely(uri),
    );
  }

  Future<void> _handleIncomingLinkSafely(Uri uri) async {
    final invitation = sygnatureRoomInviteFromUri(uri);
    if (invitation == null) return;
    try {
      await _handleRoastInvitation(invitation);
    } catch (error, stackTrace) {
      AppLogger.error(
        '[APP LINK] Failed to handle ROAST invitation',
        error: error,
        stackTrace: stackTrace,
      );
      await _showInvitationMessage(
        title: 'Could not open invitation',
        message: _displayError(error),
      );
    }
  }

  Future<void> _handleRoastInvitation(String invitation) async {
    try {
      await _noosphereInitialization;
    } on Object {
      throw _InvitationFailure.runtimeUnavailable;
    }
    final link = NoosphereRoomInvite.decode(
      invitation,
      prefix: sygnatureRoomInvitePrefix,
    );
    final participantPublicKey = link.invite.expectedParticipantPublicKey.hex;
    final controllerFuture = _controller;
    if (controllerFuture == null) {
      throw _InvitationFailure.vaultLocked;
    }
    final controller = await controllerFuture;
    if (!controller.roastAvailable) {
      throw _InvitationFailure.unsupported;
    }
    final matchingSetups = controller.roastSetups
        .where(
          (setup) =>
              setup.role == RoastSetupRole.member &&
              setup.localParticipant.publicKeyHex == participantPublicKey,
        )
        .toList(growable: false);
    final configured = matchingSetups
        .where((setup) => !setup.isWaitingForInvitation)
        .firstOrNull;
    if (configured != null) {
      await _selectRoastAccount(controller, configured.id);
      return;
    }
    final matchingDrafts = matchingSetups
        .where((setup) => setup.isWaitingForInvitation)
        .toList(growable: false);
    if (matchingDrafts.length != 1) {
      throw _InvitationFailure.signerMismatch;
    }
    final setup = matchingDrafts.single;
    final context = await _navigatorContext();
    if (context == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Join shared wallet?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              setup.name,
              style: Theme.of(dialogContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '${setup.threshold} of ${setup.participantCount} signers '
              'required',
            ),
            const SizedBox(height: 12),
            const Text(
              'This invitation matches the signer identity stored on this '
              'device.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('roast-invite-link-join'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _selectRoastAccount(controller, setup.id);
    try {
      await controller.joinRoastSetup(setup.id, invitation);
    } catch (error, stackTrace) {
      AppLogger.error(
        '[APP LINK] Failed to join ROAST invitation',
        error: error,
        stackTrace: stackTrace,
      );
      await _showInvitationMessage(
        title: 'Could not join shared wallet',
        message: _displayError(error),
      );
    }
  }

  Future<void> _selectRoastAccount(
    WalletController controller,
    String setupId,
  ) async {
    final index = controller.accounts.indexWhere(
      (account) => account.sourceId == setupId,
    );
    if (index >= 0) await controller.selectAccount(index);
  }

  Future<BuildContext?> _navigatorContext() async {
    if (!mounted) return null;
    await WidgetsBinding.instance.endOfFrame;
    return mounted ? _navigatorKey.currentContext : null;
  }

  Future<void> _showInvitationMessage({
    required String title,
    required String message,
  }) async {
    final context = await _navigatorContext();
    if (context == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  static String _displayError(Object error) => switch (error) {
    _InvitationFailure.runtimeUnavailable =>
      'Shared wallets are unavailable until the native service starts. '
          'Use Try again in the application notice, then reopen this invitation.',
    _InvitationFailure.unsupported =>
      'ROAST invitations are unavailable in this application session.',
    _InvitationFailure.vaultLocked =>
      'Unlock the matching wallet before opening this invitation.',
    _InvitationFailure.signerMismatch =>
      'This invitation is bound to a different signer. Open the member wallet '
          'whose public key was shared with the host.',
    _ => 'The invitation is invalid, expired or belongs to another wallet.',
  };

  void _retryVaultOpen() {
    setState(() {
      _protectionStore = _initializeVault();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppThemeScope(
      notifier: _themeController,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: _themeController,
        builder: (context, mode, _) => MaterialApp(
          navigatorKey: _navigatorKey,
          scaffoldMessengerKey: _messengerKey,
          title: 'Sygnature',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          darkTheme: buildAppTheme(brightness: Brightness.dark),
          themeMode: mode,
          home: _buildHome(),
        ),
      ),
    );
  }

  Widget _buildHome() {
    final controller = _controller;
    if (controller != null) return _buildController(controller);

    final protectionStore = _protectionStore;
    if (protectionStore == null) return const _StartupLoading();
    return FutureBuilder<VaultProtectionStore>(
      future: protectionStore,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error;
          return _StartupError(
            error: error,
            onRetry: error is VaultOpenFailure && error.canRetry
                ? _retryVaultOpen
                : null,
          );
        }
        final store = snapshot.data;
        if (store == null) return const _StartupLoading();
        final existingController = _controller;
        if (existingController != null) {
          return _buildController(existingController);
        }
        return const _StartupError(
          error: 'Vault initialization completed without a controller.',
        );
      },
    );
  }

  Widget _buildController(Future<WalletController> controller) =>
      FutureBuilder<WalletController>(
        future: controller,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _StartupError(error: snapshot.error);
          }
          final controller = snapshot.data;
          if (controller == null) return const _StartupLoading();
          return SelectorBuilder(
            listenable: controller,
            select: () => [
              controller.hasWallet,
              if (!controller.hasWallet) controller.busy,
            ],
            child: WalletHome(
              controller: controller,
              notifications: _notifications,
            ),
            builder: (context, child) => controller.hasWallet
                ? child!
                : OnboardingScreen(controller: controller),
          );
        },
      );
}

class _StartupLoading extends StatelessWidget {
  const _StartupLoading();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BrandMark(),
          SizedBox(height: 24),
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ],
      ),
    ),
  );
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error, this.onRetry});
  final Object? error;
  final VoidCallback? onRetry;

  String get title => switch (error) {
    VaultOpenFailure.keyMissing ||
    VaultOpenFailure.keyInvalid ||
    VaultOpenFailure.vaultCorrupt ||
    VaultOpenFailure.unsupportedSchema => 'Vault recovery required',
    VaultOpenFailure.authenticationCancelled => 'Unlock cancelled',
    VaultOpenFailure _ => 'Vault unavailable',
    _ => 'Unable to open vault',
  };

  String get message => switch (error) {
    VaultOpenFailure.authenticationCancelled =>
      'Device authentication was cancelled.',
    VaultOpenFailure.secureStorageUnavailable =>
      'Secure storage is temporarily unavailable.',
    VaultOpenFailure.keyMissing ||
    VaultOpenFailure.keyInvalid ||
    VaultOpenFailure.vaultCorrupt =>
      'The encrypted vault cannot be opened. Keep the application data intact '
          'until you can restore it from backup.',
    VaultOpenFailure.unsupportedSchema =>
      'This vault was created with an unsupported storage version.',
    _ =>
      'Check secure storage support on this device and restart the '
          'application.',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 42,
                    color: AppColors.of(context).greenDark,
                  ),
                  const SizedBox(height: 18),
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 10),
                  Text(message, textAlign: TextAlign.center),
                  if (onRetry case final retry?) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const Key('device-vault-retry'),
                      onPressed: retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Try again'),
                    ),
                  ] else ...[
                    const SizedBox(height: 16),
                    Text(
                      'Failure type: ${error.runtimeType}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.of(context).inkMuted,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

final class _DeferredDeviceVault(this._protectionStore, this._keyStore) {
  final VaultProtectionStore _protectionStore;
  final SecureKeyStore _keyStore;
  Future<VaultKeyMaterial>? _initializing;

  Future<VaultKeyMaterial> initialize() => _initializing ??= _initialize();

  Future<VaultKeyMaterial> _initialize() async {
    try {
      final keys = await createDeviceVaultKeys(keyStore: _keyStore);
      await _protectionStore.configureDevice();
      return keys;
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }
}

enum _InvitationFailure {
  vaultLocked,
  runtimeUnavailable,
  unsupported,
  signerMismatch,
}
