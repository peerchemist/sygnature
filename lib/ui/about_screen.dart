import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'widgets/brand_mark.dart';

class const AboutScreen({super.key}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        title: const Text('About'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const BrandMark(),
                          const SizedBox(height: 24),
                          Text(
                            'A Peercoin wallet built for individual and shared '
                            'ownership.',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Sygnature is a cross-platform Peercoin light '
                            'wallet for managing personal, watch-only, and '
                            'ROAST threshold wallets. Private keys and signer '
                            'shares stay on your device while ElectrumX keeps '
                            'wallet balances and transactions in sync.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 32),
                  ListTile(
                    key: const Key('licenses-button'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('Licenses'),
                    subtitle: const Text('Open-source software licenses'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'Sygnature',
                      applicationIcon: const BrandMark(compact: true),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
