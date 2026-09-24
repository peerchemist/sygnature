import 'dart:async';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';

import 'controllers/wallet_controller.dart';
import 'services/electrumx_service.dart';
import 'services/peercoin_network_service.dart';
import 'storage/wallet_repository.dart';
import 'ui/app_theme.dart';
import 'ui/onboarding_screen.dart';
import 'ui/wallet_home.dart';
import 'ui/widgets/brand_mark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  runApp(const SygnatureApp());
}

typedef WalletControllerFactory = Future<WalletController> Function();

class SygnatureApp extends StatefulWidget {
  const SygnatureApp({super.key, this.controllerFactory});

  final WalletControllerFactory? controllerFactory;

  @override
  State<SygnatureApp> createState() => _SygnatureAppState();
}

class _SygnatureAppState extends State<SygnatureApp> {
  late final Future<WalletController> _controller =
      (widget.controllerFactory ?? _createController)();

  static Future<WalletController> _createController() async {
    final repository = await HiveWalletRepository.open();
    final electrumx = await PeercoinElectrumxService.createForPreset(
      PeercoinNetworks.mainnet,
    );
    final controller = WalletController(
      repository,
      electrumxService: electrumx,
    );
    await controller.load();
    return controller;
  }

  @override
  void dispose() {
    unawaited(_controller.then((controller) => controller.dispose()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
                ? WalletHome(controller: controller)
                : OnboardingScreen(controller: controller),
          );
        },
      ),
    );
  }
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
