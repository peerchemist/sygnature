import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/wallet_controller.dart';
import '../models/wallet_account.dart';
import '../models/wallet_network.dart';
import 'app_theme.dart';
import 'widgets/brand_mark.dart';

class WalletHome extends StatelessWidget {
  const WalletHome({super.key, required this.controller});

  final WalletController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 920;
        if (desktop) {
          return Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 280,
                  child: _WalletSidebar(controller: controller),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _WalletDashboard(controller: controller)),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.canvas,
            surfaceTintColor: Colors.transparent,
            title: const BrandMark(),
            actions: [
              IconButton(
                tooltip: 'Settings',
                onPressed: () => _showSettings(context, controller),
                icon: const Icon(Icons.tune_rounded),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: _WalletDashboard(controller: controller, mobile: true),
        );
      },
    );
  }
}

class _WalletSidebar extends StatelessWidget {
  const _WalletSidebar({required this.controller});
  final WalletController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const BrandMark(),
              const SizedBox(height: 32),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'WALLETS',
                      style: TextStyle(
                        color: AppColors.inkMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  IconButton.outlined(
                    tooltip: 'Add sub-wallet',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showAddWallet(context, controller),
                    icon: const Icon(Icons.add_rounded, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  itemCount: controller.accounts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final account = controller.accounts[index];
                    final selected = index == controller.selectedAccountIndex;
                    return _WalletListTile(
                      account: account,
                      balanceSats: controller.balanceSatsFor(account),
                      syncStatus: controller.syncStatusFor(account),
                      selected: selected,
                      onTap: () => controller.selectAccount(index),
                    );
                  },
                ),
              ),
              const Divider(),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: const Icon(Icons.settings_outlined, size: 21),
                title: const Text('Settings'),
                trailing: const Icon(Icons.chevron_right_rounded, size: 19),
                onTap: () => _showSettings(context, controller),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalletListTile extends StatelessWidget {
  const _WalletListTile({
    required this.account,
    required this.balanceSats,
    required this.syncStatus,
    required this.selected,
    required this.onTap,
  });
  final WalletAccount account;
  final int balanceSats;
  final AccountSyncStatus syncStatus;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.lime : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: selected ? AppColors.surface : AppColors.canvas,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(3),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${account.accountIndex + 1}'.padLeft(2, '0'),
                  style: TextStyle(
                    color: AppColors.forest,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      account.address == null
                          ? 'Pending derivation'
                          : syncStatus == AccountSyncStatus.syncing
                          ? 'Synchronizing…'
                          : '${_formatPpc(balanceSats)} PPC',
                      style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalletDashboard extends StatelessWidget {
  const _WalletDashboard({required this.controller, this.mobile = false});
  final WalletController controller;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final account = controller.selectedAccount;
    if (account == null) return const SizedBox.shrink();
    return SafeArea(
      top: !mobile,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          mobile ? 18 : 40,
          mobile ? 14 : 32,
          mobile ? 18 : 40,
          40,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1050),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (mobile) ...[
                  _MobileWalletPicker(controller: controller),
                  const SizedBox(height: 26),
                ],
                _DashboardHeader(
                  account: account,
                  syncStatus: controller.syncStatusFor(account),
                ),
                const SizedBox(height: 24),
                _BalanceCard(account: account, controller: controller),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final twoColumns = constraints.maxWidth >= 680;
                    if (twoColumns) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _AddressCard(account: account)),
                          const SizedBox(width: 18),
                          Expanded(
                            child: _AccountDetails(
                              account: account,
                              controller: controller,
                            ),
                          ),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        _AddressCard(account: account),
                        const SizedBox(height: 18),
                        _AccountDetails(
                          account: account,
                          controller: controller,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 18),
                const _ActivityCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileWalletPicker extends StatelessWidget {
  const _MobileWalletPicker({required this.controller});
  final WalletController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: controller.accounts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final selected = index == controller.selectedAccountIndex;
                return ChoiceChip(
                  selected: selected,
                  showCheckmark: false,
                  label: Text(controller.accounts[index].name),
                  onSelected: (_) => controller.selectAccount(index),
                  selectedColor: AppColors.forest,
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : AppColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                  side: const BorderSide(color: AppColors.line),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            tooltip: 'Add sub-wallet',
            onPressed: () => _showAddWallet(context, controller),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({required this.account, required this.syncStatus});
  final WalletAccount account;
  final AccountSyncStatus syncStatus;

  @override
  Widget build(BuildContext context) {
    final ready = syncStatus == AccountSyncStatus.synced;
    final statusLabel = switch (syncStatus) {
      AccountSyncStatus.synced => 'Ready',
      AccountSyncStatus.syncing => 'Synchronizing',
      AccountSyncStatus.error => 'Sync failed',
      AccountSyncStatus.unavailable => 'Unavailable',
    };
    final statusColor = ready ? AppColors.greenDark : const Color(0xff795400);
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              account.name,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 5),
            Text(
              'Peercoin account ${account.accountIndex}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: ready
                ? AppColors.green.withValues(alpha: 0.13)
                : AppColors.warning.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ready ? Icons.check_circle_rounded : Icons.schedule_rounded,
                size: 15,
                color: statusColor,
              ),
              const SizedBox(width: 7),
              Text(
                statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.account, required this.controller});
  final WalletAccount account;
  final WalletController controller;

  @override
  Widget build(BuildContext context) {
    final active = account.address != null;
    final syncStatus = controller.syncStatusFor(account);
    final balance = controller.balanceSatsFor(account);
    final utxoCount = controller.utxosFor(account).length;
    return Card(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'BALANCE',
                style: TextStyle(
                  color: AppColors.inkMuted,
                  fontSize: 11,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${_formatPpc(balance)} PPC',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (syncStatus == AccountSyncStatus.syncing) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      switch (syncStatus) {
                        AccountSyncStatus.unavailable =>
                          'Value unavailable until synchronization',
                        AccountSyncStatus.syncing =>
                          'Synchronizing with ElectrumX…',
                        AccountSyncStatus.synced =>
                          '$utxoCount spendable ${utxoCount == 1 ? 'output' : 'outputs'}',
                        AccountSyncStatus.error =>
                          'ElectrumX synchronization failed',
                      },
                      style: const TextStyle(
                        color: AppColors.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (active && syncStatus != AccountSyncStatus.syncing)
                    IconButton(
                      tooltip: 'Refresh balance',
                      visualDensity: VisualDensity.compact,
                      onPressed: controller.refreshBalances,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _BalanceAction(
                    icon: Icons.south_west,
                    label: 'Receive',
                    enabled: active,
                  ),
                  _BalanceAction(
                    icon: Icons.north_east,
                    label: 'Send',
                    enabled: active,
                  ),
                  const _BalanceAction(
                    icon: Icons.history,
                    label: 'History',
                    enabled: false,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatPpc(int satoshis) {
  final whole = satoshis ~/ 1000000;
  var fraction = (satoshis % 1000000).toString().padLeft(6, '0');
  while (fraction.length > 2 && fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  return '$whole.$fraction';
}

class _BalanceAction extends StatelessWidget {
  const _BalanceAction({
    required this.icon,
    required this.label,
    required this.enabled,
  });
  final IconData icon;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? () {} : null,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 13),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.account});
  final WalletAccount account;

  @override
  Widget build(BuildContext context) {
    final address = account.address;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2_rounded, color: AppColors.greenDark),
                const SizedBox(width: 10),
                Text(
                  'Receive address',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: AppColors.canvas,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(4),
              ),
              child: address == null
                  ? const Text(
                      'Address unavailable until coinlib derivation.',
                      style: TextStyle(color: AppColors.inkMuted, fontSize: 13),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Text(
                            address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy address',
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: address),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Address copied.')),
                            );
                          },
                          icon: const Icon(Icons.copy_rounded, size: 18),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountDetails extends StatelessWidget {
  const _AccountDetails({required this.account, required this.controller});
  final WalletAccount account;
  final WalletController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Account details',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 18),
            _DetailRow(
              label: 'Network',
              value: controller.networkForAccount(account).label,
            ),
            const SizedBox(height: 13),
            _DetailRow(
              label: 'Account index',
              value: '${account.accountIndex}',
            ),
            const SizedBox(height: 13),
            _DetailRow(
              label: 'Derivation path',
              value: account.derivationPath ?? 'Not available',
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.end,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent activity',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 30),
            const Center(
              child: Column(
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 38,
                    color: AppColors.inkMuted,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'No transactions',
                    style: TextStyle(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    'History will appear after synchronization.',
                    style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

Future<void> _showAddWallet(
  BuildContext context,
  WalletController controller,
) async {
  final result = await showDialog<({String name, WalletNetwork network})>(
    context: context,
    builder: (context) => _AddWalletDialog(
      initialName: 'Wallet ${controller.accounts.length + 1}',
      networks: controller.supportedNetworks,
    ),
  );
  if (result == null || result.name.trim().isEmpty) return;
  await controller.addAccount(result.name, network: result.network);
}

class _AddWalletDialog extends StatefulWidget {
  const _AddWalletDialog({required this.initialName, required this.networks});
  final String initialName;
  final List<WalletNetwork> networks;

  @override
  State<_AddWalletDialog> createState() => _AddWalletDialogState();
}

class _AddWalletDialogState extends State<_AddWalletDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  late WalletNetwork _network;

  @override
  void initState() {
    super.initState();
    _network = widget.networks.first;
  }

  void _submit() {
    if (_controller.text.trim().isEmpty) return;
    Navigator.pop(context, (name: _controller.text, network: _network));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New sub-wallet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A new account index will be allocated from the same root seed. '
              'Choose the blockchain network for this account.',
            ),
            const SizedBox(height: 18),
            DropdownButtonFormField<WalletNetwork>(
              key: const Key('sub-wallet-network-field'),
              initialValue: _network,
              decoration: const InputDecoration(
                labelText: 'Blockchain network',
              ),
              isExpanded: true,
              items: widget.networks
                  .map(
                    (network) => DropdownMenuItem(
                      value: network,
                      child: Text(network.label),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (network) {
                if (network != null) setState(() => _network = network);
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}

Future<void> _showSettings(
  BuildContext context,
  WalletController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Settings', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Private data is stored in the encrypted Hive CE vault.',
              style: TextStyle(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 20),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.red,
              ),
              title: const Text('Remove local wallet'),
              subtitle: const Text('Delete vault data from this device.'),
              onTap: () async {
                Navigator.pop(sheetContext);
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
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) await controller.resetWallet();
              },
            ),
          ],
        ),
      ),
    ),
  );
}
