import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:coinlib/coinlib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';

import 'controllers/wallet_controller.dart';
import 'models/roast_setup.dart';
import 'services/app_logger.dart';
import 'services/app_notifications.dart';
import 'services/electrumx_service.dart';
import 'services/peercoin_network_service.dart';
import 'services/roast_runtime_manager.dart';
import 'storage/wallet_repository.dart';
import 'storage/roast_storage.dart';
import 'ui/app_theme.dart';
import 'ui/onboarding_screen.dart';
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
  late final Future<WalletController> _controller =
      (widget.controllerFactory ?? _createController)();
  StreamSubscription<Uri>? _incomingLinkSubscription;
  Future<void> _incomingLinkWork = Future.value();

  @override
  void initState() {
    super.initState();
    _incomingLinkSubscription = widget.incomingLinks?.listen(
      _queueIncomingLink,
      onError: (Object error, StackTrace stackTrace) => AppLogger.error(
        '[APP LINK] Incoming link stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  Future<WalletController> _createController() async {
    await _notifications.initialize();
    final platformKeyStore = PlatformSecureKeyStore();
    final secureKeyStore =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? KeyringSecureKeyStore(platformKeyStore)
        : platformKeyStore;
    final repository = await HiveWalletRepository.open(
      secureKeyStore: secureKeyStore,
    );
    final roastPersistence = _roastSupported
        ? RoastPersistenceFactory(secureKeyStore: secureKeyStore)
        : null;
    final controller = WalletController(
      repository,
      roastRuntime: _roastSupported
          ? RoastRuntimeManager(roastPersistence!)
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

  @override
  void dispose() {
    unawaited(_incomingLinkSubscription?.cancel());
    unawaited(_controller.then((controller) => controller.dispose()));
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
    final controller = await _controller;
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
    if (accountIndex >= 0) controller.selectAccount(accountIndex);
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
      home: FutureBuilder<WalletController>(
        future: _controller,
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
      ),
    );
  }
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
