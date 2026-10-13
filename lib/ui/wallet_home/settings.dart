part of '../wallet_home.dart';

const _publicFeedNotificationWindows = {
  15: '15 minutes',
  30: '30 minutes',
  60: '1 hour',
  180: '3 hours',
  360: '6 hours',
  720: '12 hours',
  1440: '24 hours',
};

Future<void> _showSettings(
  BuildContext context,
  WalletController controller,
  AppNotifications notifications,
) {
  final publicFeedNotificationWindow =
      defaultTargetPlatform == TargetPlatform.android
      ? controller.publicFeedStore?.then((store) => store.notificationWindow())
      : null;
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _SettingsScreen(
        controller: controller,
        notifications: notifications,
        publicFeedNotificationWindow: publicFeedNotificationWindow,
      ),
    ),
  );
}

class const _SettingsScreen({
  required final WalletController controller,
  required final AppNotifications notifications,
  required final Future<Duration>? publicFeedNotificationWindow,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: Listenable.merge([notifications, controller]),
    select: () => [
      controller.archivedAccounts.length,
      controller.roastSetups.isEmpty,
      notifications.supportsSystemNotifications,
      notifications.systemEnabled,
      notifications.soundEnabled,
      notifications.soundVolume,
    ],
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.of(context).canvas,
        surfaceTintColor: Colors.transparent,
        title: const Text('Settings'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (AppThemeScope.maybeOf(context) case final theme?) ...[
                    Text(
                      'Appearance',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Choose a theme, or follow your device settings.',
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<ThemeMode>(
                      key: const Key('theme-mode-toggle'),
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('System'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Dark'),
                        ),
                      ],
                      selected: {theme.value},
                      onSelectionChanged: (selection) async {
                        final saved = await theme.setMode(selection.single);
                        if (!saved && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Theme changed, but the preference could not be saved.',
                              ),
                            ),
                          );
                        }
                      },
                    ),
                    const Divider(height: 32),
                  ],
                  ListTile(
                    key: const Key('backup-button'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.backup_outlined),
                    title: const Text('Encrypted backup and restore'),
                    subtitle: const Text(
                      'Save mnemonics, ROAST groups and local signing shares.',
                    ),
                    onTap: controller.backupAvailable
                        ? () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  WalletBackupScreen(controller: controller),
                            ),
                          )
                        : null,
                  ),
                  ListTile(
                    key: const Key('archived-wallets-button'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.archive_outlined),
                    title: const Text('Archived wallets'),
                    subtitle: Text(
                      controller.archivedAccounts.isEmpty
                          ? 'No archived wallets'
                          : '${controller.archivedAccounts.length} archived',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _showArchivedWallets(context, controller),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'NETWORK',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.of(context).inkMuted,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  ListTile(
                    key: const Key('electrum-endpoints-button'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('Electrum endpoints'),
                    subtitle: const Text(
                      'Configure the mainnet and testnet WebSocket servers.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        _showElectrumEndpointSettings(context, controller),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'NOTIFICATIONS',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.of(context).inkMuted,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  SwitchListTile.adaptive(
                    key: const Key('system-notifications-toggle'),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.notifications_outlined),
                    title: const Text('System notifications'),
                    subtitle: Text(
                      notifications.supportsSystemNotifications
                          ? 'Show wallet events in the system notification center.'
                          : 'Available on Android, Linux, macOS, and Windows.',
                    ),
                    value:
                        notifications.supportsSystemNotifications &&
                        notifications.systemEnabled,
                    onChanged: notifications.supportsSystemNotifications
                        ? (enabled) async {
                            final accepted = await notifications
                                .setSystemEnabled(enabled);
                            if (!accepted && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'System notifications could not be enabled.',
                                  ),
                                ),
                              );
                            }
                          }
                        : null,
                  ),
                  SwitchListTile.adaptive(
                    key: const Key('notification-sound-toggle'),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.volume_up_outlined),
                    title: const Text('Notification sound'),
                    subtitle: const Text(
                      'Play a tone for incoming wallet events.',
                    ),
                    value: notifications.soundEnabled,
                    onChanged: notifications.setSoundEnabled,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 56),
                    child: Row(
                      children: [
                        const Text('Volume'),
                        Expanded(
                          child: Slider(
                            key: const Key('notification-volume-slider'),
                            value: notifications.soundVolume,
                            divisions: 10,
                            label:
                                '${(notifications.soundVolume * 100).round()}%',
                            onChanged: notifications.soundEnabled
                                ? notifications.setSoundVolume
                                : null,
                          ),
                        ),
                        SizedBox(
                          width: 42,
                          child: Text(
                            '${(notifications.soundVolume * 100).round()}%',
                            textAlign: TextAlign.end,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed:
                          notifications.supportsSystemNotifications &&
                              notifications.systemEnabled
                          ? () async {
                              final shown = await notifications.sendTest();
                              if (!shown && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'The test notification could not be shown.',
                                    ),
                                  ),
                                );
                              }
                            }
                          : null,
                      icon: const Icon(Icons.send_outlined),
                      label: const Text('Send test notification'),
                    ),
                  ),
                  if (publicFeedNotificationWindow != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      'ROAST EVENT NOTIFICATIONS',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.of(context).inkMuted,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'How old can ROAST events be and still notify you?',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<Duration>(
                      future: publicFeedNotificationWindow,
                      builder: (context, snapshot) => KeyedSubtree(
                        key: const Key('public-feed-notification-window'),
                        child: DropdownButtonFormField<int>(
                          key: ValueKey(snapshot.data?.inMinutes),
                          initialValue:
                              snapshot.data?.inMinutes ??
                              publicFeedDefaultNotificationWindow.inMinutes,
                          decoration: InputDecoration(
                            labelText: 'Maximum event age',
                            helperText: snapshot.hasError
                                ? 'Event age setting unavailable.'
                                : 'When Android catches up, older events are ignored. '
                                      'Expired requests never notify.',
                          ),
                          items: [
                            for (final option
                                in _publicFeedNotificationWindows.entries)
                              DropdownMenuItem(
                                value: option.key,
                                child: Text(option.value),
                              ),
                          ],
                          onChanged: snapshot.hasData
                              ? (minutes) async =>
                                    (await controller.publicFeedStore!)
                                        .setNotificationWindow(
                                          Duration(minutes: minutes!),
                                        )
                              : null,
                        ),
                      ),
                    ),
                  ],
                  const Divider(height: 32),
                  ListTile(
                    key: const Key('about-button'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline_rounded),
                    title: const Text('About'),
                    subtitle: Text(
                      'Version $sygnatureVersionString',
                      key: const Key('settings-version'),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AboutScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 32),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: AppColors.of(context).danger,
                    ),
                    title: const Text('Remove local wallet'),
                    subtitle: Text(
                      controller.roastSetups.isEmpty
                          ? 'Delete vault data from this device.'
                          : 'Unavailable while this device holds ROAST setups. '
                                'Signer removal requires a separate recovery-safe '
                                'workflow.',
                    ),
                    onTap: controller.roastSetups.isNotEmpty
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Remove wallet?'),
                                content: const Text(
                                  'This deletes the local vault. Recovery verification will '
                                  'be added with the coinlib integration.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .error,
                                      foregroundColor: Theme.of(context)
                                          .colorScheme
                                          .onError,
                                    ),
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, true),
                                    child: const Text('Remove'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true || !context.mounted) return;
                            Navigator.pop(context);
                            await controller.resetWallet();
                          },
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

Future<void> _showElectrumEndpointSettings(
  BuildContext context,
  WalletController controller,
) async {
  final presets = PeercoinNetworks.values;
  late final List<Uri> selectedEndpoints;
  try {
    selectedEndpoints = await Future.wait(
      presets.map(PeercoinElectrumxService.selectedBackend),
    );
  } on Object catch (error, stackTrace) {
    AppLogger.error(
      'Could not load ElectrumX endpoint settings',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Electrum settings could not be opened.')),
      );
    }
    return;
  }
  if (!context.mounted) return;

  final formKey = GlobalKey<FormState>();
  final textControllers = [
    for (final endpoint in selectedEndpoints)
      TextEditingController(text: endpoint.toString()),
  ];
  final endpoints = await showDialog<List<Uri>>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Electrum endpoints'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Use a ws:// or wss:// endpoint. The current built-in servers '
                'remain available as failover servers.',
              ),
              const SizedBox(height: 20),
              for (var index = 0; index < presets.length; index++) ...[
                TextFormField(
                  key: Key('electrum-endpoint-${presets[index].id}'),
                  controller: textControllers[index],
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        '${_capitalized(presets[index].networkLabel)} endpoint',
                    suffixIcon: IconButton(
                      tooltip: 'Use default',
                      onPressed: () => textControllers[index].text =
                          PeercoinElectrumxService.defaultBackend(
                            presets[index],
                          ).toString(),
                      icon: const Icon(Icons.restore_rounded),
                    ),
                  ),
                  validator: (value) {
                    try {
                      PeercoinElectrumxService.parseEndpoint(value ?? '');
                      return null;
                    } on FormatException catch (error) {
                      return error.message;
                    }
                  },
                ),
                if (index < presets.length - 1) const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-electrum-endpoints'),
          onPressed: () {
            if (!(formKey.currentState?.validate() ?? false)) return;
            Navigator.pop(dialogContext, [
              for (final textController in textControllers)
                PeercoinElectrumxService.parseEndpoint(textController.text),
            ]);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  for (final textController in textControllers) {
    textController.dispose();
  }
  if (endpoints == null) return;

  try {
    for (var index = 0; index < presets.length; index++) {
      await PeercoinElectrumxService.setSelectedBackend(
        presets[index],
        endpoints[index],
      );
    }
    await controller.reconnectElectrumx();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Electrum endpoints saved.')),
      );
    }
  } on Object catch (error, stackTrace) {
    AppLogger.error(
      'Could not save ElectrumX endpoint settings',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Electrum endpoints could not be saved.')),
      );
    }
  }
}

String _capitalized(String value) =>
    '${value.substring(0, 1).toUpperCase()}${value.substring(1)}';
