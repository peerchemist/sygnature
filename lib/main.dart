import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:coinlib/coinlib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';

import 'controllers/wallet_controller.dart';
import 'models/mnemonic_seed.dart';
import 'models/roast_setup.dart';
import 'services/app_logger.dart';
import 'services/app_notifications.dart';
import 'services/electrumx_service.dart';
import 'services/peercoin_network_service.dart';
import 'services/roast_runtime_manager.dart';
import 'services/wallet_key_service.dart';
import 'storage/wallet_repository.dart';
import 'storage/roast_storage.dart';
import 'storage/vault_protection.dart';
import 'ui/app_theme.dart';
import 'ui/onboarding_screen.dart';
import 'ui/vault_protection_screen.dart';
import 'ui/wallet_home.dart';
import 'ui/widgets/brand_mark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final incomingLinks = AppLinks().uriLinkStream;
  await loadCoinlib();
  if (_roastSupported) {
    AppLogger.info('[NOOSPHERE] Initializing native runtime');
    try {
      await NoosphereFlutter.initialize();
      AppLogger.info('[NOOSPHERE] Native runtime initialized');
    } catch (error, stackTrace) {
      AppLogger.fatal(
        '[NOOSPHERE] Native runtime initialization failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
  runApp(SygnatureApp(incomingLinks: incomingLinks));
}

typedef WalletControllerFactory = Future<WalletController> Function();

class const SygnatureApp({
  super.key,
  final WalletControllerFactory? controllerFactory,
  final Stream<Uri>? incomingLinks,
}) extends StatefulWidget {
  @override
  State<SygnatureApp> createState() => _SygnatureAppState();
}

class _SygnatureAppState extends State<SygnatureApp> {
  final AppNotifications _notifications = AppNotifications();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final Future<void> _notificationsReady = _notifications.initialize();
  late final Future<VaultProtectionStore>? _protectionStore;
  Future<WalletController>? _controller;
  StreamSubscription<Uri>? _incomingLinkSubscription;
  Future<void> _incomingLinkWork = Future.value();

  @override
  void initState() {
    super.initState();
    final controllerFactory = widget.controllerFactory;
    if (controllerFactory == null) {
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

  Future<VaultProtectionStore> _initializeVault() async {
    final store = await VaultProtectionStore.open();
    if (!await HiveWalletRepository.boxExists()) return store;

    late final (HiveWalletRepository, SecureKeyStore)? existingVault;
    try {
      existingVault = await _openExistingSystemVault();
    } catch (_) {
      if (store.config == null) rethrow;
      return store;
    }
    if (existingVault == null) {
      if (store.config == null) {
        throw StateError('The existing vault encryption key is unavailable.');
      }
      return store;
    }

    final (repository, secureKeyStore) = existingVault;
    await _notificationsReady;
    final roastPersistence = _roastSupported
        ? RoastPersistenceFactory(secureKeyStore: secureKeyStore)
        : null;
    final controller = await _loadController(repository, roastPersistence);
    await store.configureSystem();
    _controller = Future.value(controller);
    return store;
  }

  SecureKeyStore _systemKeyStore({bool allowMacOS = false}) {
    final platformStore = PlatformSecureKeyStore(
      allowUnavailablePlatform: allowMacOS,
    );
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? KeyringSecureKeyStore(platformStore)
        : platformStore;
  }

  Future<(HiveWalletRepository, SecureKeyStore)?>
  _openExistingSystemVault() async {
    final secureKeyStore = _systemKeyStore(allowMacOS: true);
    final repository = await HiveWalletRepository.openExisting(
      secureKeyStore: secureKeyStore,
    );
    if (repository == null) return null;
    return (repository, secureKeyStore);
  }

  Future<WalletController> _createSystemController() async {
    await _notificationsReady;
    final secureKeyStore = _systemKeyStore();
    final repository = await HiveWalletRepository.open(
      secureKeyStore: secureKeyStore,
    );
    final roastPersistence = _roastSupported
        ? RoastPersistenceFactory(secureKeyStore: secureKeyStore)
        : null;
    return _loadController(repository, roastPersistence);
  }

  Future<VaultKeyMaterial> _derivePasswordKeys(
    String password,
    VaultProtectionConfig config,
  ) async {
    final keys = await deriveVaultKeyMaterial(password, config);
    if (!config.matchesVerifier(keys.verifier)) {
      throw StateError('The vault password is incorrect.');
    }
    return keys;
  }

  Future<WalletController> _createPasswordController(
    VaultKeyMaterial keys,
  ) async {
    await _notificationsReady;
    final repository = await HiveWalletRepository.openWithCipherKey(
      keys.walletKey,
    );
    final roastPersistence = _roastSupported
        ? RoastPersistenceFactory(cipherKey: keys.roastKey)
        : null;
    return _loadController(repository, roastPersistence);
  }

  Future<WalletController> _loadController(
    WalletRepository repository,
    RoastPersistenceFactory? roastPersistence,
  ) async {
    final controller = WalletController(
      repository,
      roastRuntime: _roastSupported
          ? RoastRuntimeManager(
              roastPersistence!,
              getWalletBip39Seed: () => _walletBip39Seed(repository),
            )
          : null,
      roastSigningOperations: roastPersistence,
      networkServiceFactory: (network) =>
          PeercoinElectrumxService.createForPreset(
            PeercoinNetworks.fromWalletNetwork(network),
          ),
      onCoinsReceived: _notifications.coinsReceived,
      onRoastActionRequired: _notifications.roastActionRequired,
    );
    await controller.load();
    return controller;
  }

  Future<void> _setUpSystemVault(VaultProtectionStore store) async {
    if (!systemVaultAvailable()) {
      throw UnsupportedError('System vault is unavailable on macOS.');
    }
    final controller = await _createSystemController();
    await store.configureSystem();
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _controller = Future.value(controller);
    });
  }

  Future<void> _setUpPasswordVault(
    VaultProtectionStore store,
    String password,
  ) async {
    try {
      var config = store.config;
      late final VaultKeyMaterial keys;
      if (config == null) {
        config = store.createPasswordConfig();
        keys = await deriveVaultKeyMaterial(password, config);
        config = config.withVerifier(keys.verifier);
        await store.configurePassword(config);
      } else {
        keys = await _derivePasswordKeys(password, config);
      }
      final controller = await _createPasswordController(keys);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = Future.value(controller);
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        '[VAULT] Password-protected vault setup failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _unlockPasswordVault(
    String password,
    VaultProtectionConfig config,
  ) async {
    try {
      final keys = await _derivePasswordKeys(password, config);
      final controller = await _createPasswordController(keys);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = Future.value(controller);
      });
    } catch (error, stackTrace) {
      AppLogger.warn(
        '[VAULT] Password unlock failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
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

  void _queueIncomingLink(Uri uri) {
    _incomingLinkWork = _incomingLinkWork.then(
      (_) => _handleIncomingLinkSafely(uri),
    );
  }

  Future<void> _handleIncomingLinkSafely(Uri uri) async {
    if (uri.scheme != RoastExchangeCodec.uriScheme) return;
    try {
      await _handleRoastInvitation(uri.toString());
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
    final decoded = RoastExchangeCodec.decodeInvitation(invitation);
    final participantPublicKey = decoded['participantPublicKeyHex'];
    if (participantPublicKey is! String || participantPublicKey.isEmpty) {
      throw const FormatException(
        'The invitation does not contain a participant public key.',
      );
    }
    final controllerFuture = _controller;
    if (controllerFuture == null) {
      throw StateError('Unlock the vault before opening an invitation.');
    }
    final controller = await controllerFuture;
    if (!controller.roastAvailable) {
      throw UnsupportedError(
        'ROAST invitations are not supported on this platform.',
      );
    }
    final matchingDrafts = controller.roastSetups
        .where(
          (setup) =>
              setup.role == RoastSetupRole.member &&
              setup.status == RoastSetupStatus.draft &&
              setup.localParticipant.publicKeyHex == participantPublicKey,
        )
        .toList(growable: false);
    final transitionSourceGroupId = decoded['transitionSourceGroupId'];
    final matchingSources = transitionSourceGroupId is String
        ? controller.roastSetups
              .where(
                (setup) =>
                    setup.groupId == transitionSourceGroupId &&
                    setup.isActive &&
                    setup.localParticipant.publicKeyHex == participantPublicKey,
              )
              .toList(growable: false)
        : const <RoastSetup>[];
    if (matchingDrafts.length > 1 ||
        (matchingDrafts.isEmpty && matchingSources.length != 1)) {
      throw const FormatException(
        'This invitation is bound to a different signer. Open the member '
        'wallet whose public key was shared with the host.',
      );
    }
    var setup = matchingDrafts.firstOrNull;
    final setupName = decoded['setupName'] is String
        ? decoded['setupName']! as String
        : 'Shared wallet';
    final threshold = decoded['threshold'];
    final participantCount = decoded['participantCount'];
    final signerSummary = threshold is int && participantCount is int
        ? '$threshold of $participantCount signers required'
        : 'Participant-bound ROAST invitation';
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
              setupName,
              style: Theme.of(dialogContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(signerSummary),
            const SizedBox(height: 12),
            const Text(
              'This invitation matches the signer identity stored on this '
              'device.',
            ),
            if (setup == null) ...[
              const SizedBox(height: 8),
              const Text(
                'The existing signer identity will be reused in a new '
                'successor wallet.',
              ),
            ],
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
    if (setup == null) {
      if (threshold is! int || participantCount is! int) {
        throw const FormatException(
          'The successor invitation is missing its signing policy.',
        );
      }
      final setupId = await controller.createRoastTransitionJoinDraft(
        sourceSetupId: matchingSources.single.id,
        walletName: setupName,
        threshold: threshold,
        participantCount: participantCount,
      );
      setup = controller.roastSetups.singleWhere((item) => item.id == setupId);
    }
    final accountIndex = controller.accounts.indexWhere(
      (account) => account.sourceId == setup!.id,
    );
    if (accountIndex >= 0) await controller.selectAccount(accountIndex);
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

  static String _displayError(Object error) => error.toString().replaceFirst(
    RegExp(r'^(FormatException|Unsupported operation): '),
    '',
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Sygnature',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: _buildHome(),
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
        if (snapshot.hasError) return _StartupError(error: snapshot.error);
        final store = snapshot.data;
        if (store == null) return const _StartupLoading();
        final existingController = _controller;
        if (existingController != null) {
          return _buildController(existingController);
        }
        final config = store.config;
        if (config == null) {
          return VaultProtectionScreen(
            setup: true,
            systemVaultEnabled: systemVaultAvailable(),
            onSystem: () => _setUpSystemVault(store),
            onPassword: (password) => _setUpPasswordVault(store, password),
          );
        }
        if (config.mode == VaultProtectionMode.password) {
          return VaultProtectionScreen(
            setup: false,
            systemVaultEnabled: false,
            onPassword: (password) => _unlockPasswordVault(password, config),
          );
        }
        if (!systemVaultAvailable()) {
          return const _StartupError(
            error: 'System vault access is disabled on macOS.',
          );
        }
        return _buildController(_controller ??= _createSystemController());
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
          return AnimatedBuilder(
            animation: controller,
            builder: (context, _) => controller.hasWallet
                ? WalletHome(
                    controller: controller,
                    notifications: _notifications,
                  )
                : OnboardingScreen(controller: controller),
          );
        },
      );
}

bool get _roastSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

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
  const _StartupError({required this.error});
  final Object? error;

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
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 42,
                    color: AppColors.greenDark,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Unable to open vault',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Check secure storage support on this device and restart '
                    'the application.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '$error',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.inkMuted,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
