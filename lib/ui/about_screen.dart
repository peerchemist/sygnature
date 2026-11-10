import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appBuildName, appBuildNumber;

import 'app_theme.dart';
import 'widgets/brand_mark.dart';

String get sygnatureVersionString {
  final name = appBuildName;
  if (name == null || name.isEmpty) return 'Unknown';
  final number = appBuildNumber;
  return number == null || number.isEmpty ? name : '$name+$number';
}

class const AboutScreen({super.key}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.of(context).canvas,
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
                          const SizedBox(height: 8),
                          Text(
                            'Version $sygnatureVersionString',
                            key: const Key('about-version'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: AppColors.of(context).inkMuted,
                                ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'Wallet for Workgroups',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Sygnature is a cross-platform, self-custody '
                            'cryptocoin wallet for individuals and groups. '
                            'Shared wallets combine multi-signature approval '
                            'with multi-party computation (MPC), allowing a '
                            'chosen threshold of participants to authorize '
                            'payments together without ever assembling the '
                            'complete private key. Each participant keeps a '
                            'private signing share on their own device, while '
                            'ElectrumX keeps wallet balances and transactions '
                            'in sync. Personal and watch-only wallets are '
                            'supported too.',
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
