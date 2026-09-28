import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/wallet_controller.dart';
import '../models/wallet_account.dart';
import '../models/wallet_activity.dart';
import '../models/roast_setup.dart';
import '../models/wallet_network.dart';
import '../models/wallet_transaction.dart';
import '../services/app_logger.dart';
import '../services/app_notifications.dart';
import '../services/peercoin_network_service.dart';
import '../services/roast_runtime_manager.dart';
import '../services/wallet_transaction_service.dart';
import 'app_theme.dart';
import 'onboarding_screen.dart';
import 'roast_setup_flow.dart';
import 'widgets/brand_mark.dart';
import 'widgets/middle_ellipsis_text.dart';

class const WalletHome({
  super.key,
  required final WalletController controller,
  required final AppNotifications notifications,
}) extends StatelessWidget {
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
                  child: _WalletSidebar(
                    controller: controller,
                    notifications: notifications,
                  ),
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
              if (controller.roastSigningRequests.isNotEmpty)
                Badge(
                  label: Text('${controller.roastSigningRequests.length}'),
                  child: IconButton(
                    tooltip: 'Signing requests',
                    onPressed: () => _showRoastRequests(context, controller),
                    icon: const Icon(Icons.approval_outlined),
                  ),
                ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () =>
                    _showSettings(context, controller, notifications),
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

class const _WalletSidebar({
  required final WalletController controller,
  required final AppNotifications notifications,
}) extends StatelessWidget {
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
                      setup: controller.setupForAccount(account),
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
              if (controller.roastSigningRequests.isNotEmpty)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  leading: Badge(
                    label: Text('${controller.roastSigningRequests.length}'),
                    child: const Icon(Icons.approval_outlined, size: 21),
                  ),
                  title: const Text('Signing requests'),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 19),
                  onTap: () => _showRoastRequests(context, controller),
                ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: const Icon(Icons.settings_outlined, size: 21),
                title: const Text('Settings'),
                trailing: const Icon(Icons.chevron_right_rounded, size: 19),
                onTap: () => _showSettings(context, controller, notifications),
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
    required this.setup,
    required this.balanceSats,
    required this.syncStatus,
    required this.selected,
    required this.onTap,
  });
  final WalletAccount account;
  final RoastSetup? setup;
  final int balanceSats;
  final AccountSyncStatus syncStatus;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRoast = account.keySource == WalletKeySource.roast;
    final isCoordinator = setup?.role == RoastSetupRole.host;

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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            account.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: isRoast
                                ? AppColors.forest
                                : AppColors.canvas,
                            border: Border.all(
                              color: isRoast
                                  ? AppColors.forest
                                  : AppColors.line,
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            isRoast
                                ? isCoordinator
                                      ? 'ROAST · HOST'
                                      : 'ROAST'
                                : 'LOCAL',
                            style: TextStyle(
                              color: isRoast
                                  ? Colors.white
                                  : AppColors.inkMuted,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      setup != null && !setup!.isActive
                          ? 'Resume setup · ${setup!.threshold} of ${setup!.participantCount}'
                          : account.address == null
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
    if (account == null) {
      return SafeArea(
        top: !mobile,
        child: Center(
          child: FilledButton.icon(
            onPressed: () => _showAddWallet(context, controller),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add wallet'),
          ),
        ),
      );
    }
    final roastSetup = controller.setupForAccount(account);
    final signingRequests = roastSetup == null
        ? const <RoastSigningInboxItem>[]
        : controller.roastSigningRequestsForSetup(roastSetup.id);
    final hasPendingDkg =
        roastSetup?.status == RoastSetupStatus.awaitingDkgApproval &&
        roastSetup?.pendingDkgProposalHex != null;
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
                if (hasPendingDkg || signingRequests.isNotEmpty) ...[
                  _RoastPriorityRequests(
                    controller: controller,
                    setup: roastSetup!,
                    showDkg: hasPendingDkg,
                    signingRequests: signingRequests,
                  ),
                  const SizedBox(height: 18),
                ],
                _DashboardHeader(
                  account: account,
                  syncStatus: controller.syncStatusFor(account),
                  onDelete: () =>
                      _confirmDeleteWallet(context, controller, account),
                  onRename: () =>
                      _showRenameWallet(context, controller, account),
                ),
                if (roastSetup != null) ...[
                  const SizedBox(height: 18),
                  RoastSetupPanel(controller: controller, account: account),
                ],
                if (roastSetup != null && !roastSetup.isActive) ...[
                  const SizedBox(height: 18),
                  const _PendingRoastNotice(),
                ] else ...[
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
                  _ActivityCard(controller: controller, account: account),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class const _RoastPriorityRequests({
  required final WalletController controller,
  required final RoastSetup setup,
  required final bool showDkg,
  required final List<RoastSigningInboxItem> signingRequests,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
    key: const Key('roast-priority-requests'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Row(
        children: [
          Icon(
            Icons.notifications_active_outlined,
            color: AppColors.danger,
            size: 20,
          ),
          SizedBox(width: 8),
          Text(
            'ROAST ACTION REQUIRED',
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (showDkg) RoastDkgRequestCard(controller: controller, setup: setup),
      for (final (index, request) in signingRequests.indexed) ...[
        if (showDkg || index > 0) const SizedBox(height: 12),
        _RoastRequestCard(controller: controller, item: request),
      ],
    ],
  );
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

class _PendingRoastNotice extends StatelessWidget {
  const _PendingRoastNotice();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.warning.withValues(alpha: 0.13),
      border: Border.all(color: AppColors.warning),
      borderRadius: BorderRadius.circular(4),
    ),
    child: const Text(
      'Balance and receive address appear after every participant approves '
      'the DKG ceremony and the shared key is stored.',
    ),
  );
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.account,
    required this.syncStatus,
    required this.onDelete,
    required this.onRename,
  });
  final WalletAccount account;
  final AccountSyncStatus syncStatus;
  final VoidCallback onDelete;
  final VoidCallback onRename;

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
      key: const Key('wallet-dashboard-header'),
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
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              key: const Key('wallet-settings-button'),
              tooltip: 'Wallet settings',
              icon: const Icon(
                Icons.settings_outlined,
                size: 20,
                color: AppColors.inkMuted,
              ),
              onSelected: (value) {
                if (value == 'rename') onRename();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined),
                      SizedBox(width: 10),
                      Text('Rename wallet'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded, color: Colors.red),
                      SizedBox(width: 10),
                      Text('Delete wallet'),
                    ],
                  ),
                ),
              ],
            ),
          ],
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
    final confirmedBalance = controller.confirmedBalanceSatsFor(account);
    final availableBalance = controller.availableBalanceSatsFor(account);
    final reservedBalance = controller.reservedBalanceSatsFor(account);
    final pendingBalance = controller.pendingBalanceSatsFor(account);
    final utxoCount = controller.utxosFor(account).length;
    final balanceDescription = switch (syncStatus) {
      AccountSyncStatus.unavailable =>
        'Value unavailable until synchronization',
      AccountSyncStatus.syncing => 'Synchronizing with ElectrumX…',
      AccountSyncStatus.synced =>
        reservedBalance > 0
            ? '${_formatPpc(confirmedBalance)} PPC confirmed · '
                  '${_formatPpc(reservedBalance)} PPC reserved by ROAST'
            : pendingBalance == 0
            ? '${_formatPpc(confirmedBalance)} PPC confirmed · '
                  '$utxoCount ${utxoCount == 1 ? 'output' : 'outputs'}'
            : '${_formatPpc(confirmedBalance)} PPC confirmed · '
                  '${_formatPpc(pendingBalance)} PPC pending',
      AccountSyncStatus.error => 'ElectrumX synchronization failed',
    };
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
                      balanceDescription,
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
                    icon: Icons.north_east,
                    label: 'Send',
                    enabled:
                        active &&
                        syncStatus == AccountSyncStatus.synced &&
                        availableBalance > 0,
                    onPressed:
                        active &&
                            syncStatus == AccountSyncStatus.synced &&
                            availableBalance > 0
                        ? () => _showSendDialog(context, controller, account)
                        : null,
                  ),
                  const _BalanceAction(
                    icon: Icons.history,
                    label: 'History',
                    enabled: false,
                    onPressed: null,
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
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onPressed : null,
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
                const Icon(
                  Icons.account_balance_wallet_outlined,
                  color: AppColors.greenDark,
                ),
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
                          child: MiddleEllipsisText(
                            key: const Key('receive-address-value'),
                            value: address,
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
              label: 'Key source',
              value: account.keySource == WalletKeySource.personal
                  ? 'Personal BIP-86 seed'
                  : 'ROAST threshold key',
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
  const _ActivityCard({required this.controller, required this.account});

  final WalletController controller;
  final WalletAccount account;

  @override
  Widget build(BuildContext context) {
    final activities = controller.activitiesFor(account);
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
            if (activities.isEmpty) ...[
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
                      'No activity yet',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Wallet events will appear here.',
                      style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ] else ...[
              const SizedBox(height: 12),
              for (var index = 0; index < activities.length; index++) ...[
                _ActivityRow(activity: activities[index]),
                if (index != activities.length - 1) const Divider(height: 1),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.activity});

  final WalletActivity activity;

  @override
  Widget build(BuildContext context) {
    final presentation = _activityPresentation(activity.type);
    final reference = activity.reference;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: presentation.color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(presentation.icon, size: 20, color: presentation.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  presentation.title,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (activity.details case final details?) ...[
                  const SizedBox(height: 3),
                  Text(
                    details,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.inkMuted,
                      fontSize: 12,
                    ),
                  ),
                ] else if (reference != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    _activityReference(activity.type, reference),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.inkMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _activityTime(activity.occurredAt),
            style: const TextStyle(color: AppColors.inkMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

({String title, IconData icon, Color color}) _activityPresentation(
  WalletActivityType type,
) => switch (type) {
  WalletActivityType.signatureRequestReceived => (
    title: 'Signature request received',
    icon: Icons.mark_email_unread_outlined,
    color: AppColors.greenDark,
  ),
  WalletActivityType.signatureRequestApproved => (
    title: 'Signature request approved',
    icon: Icons.check_circle_outline,
    color: AppColors.success,
  ),
  WalletActivityType.signatureRequestRejected => (
    title: 'Signature request rejected',
    icon: Icons.cancel_outlined,
    color: AppColors.danger,
  ),
  WalletActivityType.signatureRequestExpired => (
    title: 'Signature request expired',
    icon: Icons.schedule_outlined,
    color: AppColors.warningDark,
  ),
  WalletActivityType.dkgStarted => (
    title: 'Shared key creation started',
    icon: Icons.hub_outlined,
    color: AppColors.greenDark,
  ),
  WalletActivityType.dkgCompleted => (
    title: 'Shared key created',
    icon: Icons.key_outlined,
    color: AppColors.success,
  ),
  WalletActivityType.dkgFailed => (
    title: 'Shared key creation failed',
    icon: Icons.error_outline,
    color: AppColors.danger,
  ),
  WalletActivityType.transactionSigned => (
    title: 'Transaction signed',
    icon: Icons.draw_outlined,
    color: AppColors.greenDark,
  ),
  WalletActivityType.transactionBroadcast => (
    title: 'Transaction broadcast',
    icon: Icons.send_outlined,
    color: AppColors.success,
  ),
};

String _activityReference(WalletActivityType type, String value) {
  final label = switch (type) {
    WalletActivityType.dkgStarted ||
    WalletActivityType.dkgCompleted ||
    WalletActivityType.dkgFailed => 'DKG',
    WalletActivityType.transactionSigned ||
    WalletActivityType.transactionBroadcast => 'Transaction',
    _ => 'Request',
  };
  return '$label ${_shortTransactionId(value)}';
}

String _activityTime(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return time;
  }
  return '${local.day}.${local.month}. · $time';
}

Future<void> _showSendDialog(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final result = await showDialog<WalletSendResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SendDialog(controller: controller, account: account),
  );
  if (result == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Transaction submitted: ${_shortTransactionId(result.transactionId)}',
      ),
    ),
  );
}

class _SendDialog extends StatefulWidget {
  const _SendDialog({required this.controller, required this.account});

  final WalletController controller;
  final WalletAccount account;

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  final _formKey = GlobalKey<FormState>();
  final _destinationController = TextEditingController();
  final _amountController = TextEditingController();
  final _signingMessageController = TextEditingController();
  late final int _feeRateSatsPerKb;
  WalletTransactionPreview? _preview;
  String? _error;
  bool _submitting = false;
  bool _maximum = false;

  @override
  void initState() {
    super.initState();
    final network = PeercoinNetworks.fromWalletNetwork(
      widget.controller.networkForAccount(widget.account),
    );
    _feeRateSatsPerKb = network.network.feePerKb.toInt();
    widget.controller.addListener(_refreshMaximumAvailable);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refreshMaximumAvailable);
    _destinationController.dispose();
    _amountController.dispose();
    _signingMessageController.dispose();
    super.dispose();
  }

  void _refreshMaximumAvailable() {
    if (mounted) setState(() {});
  }

  int? _maximumAvailableSats() {
    final address = widget.account.address;
    if (address == null) return null;

    try {
      return widget.controller
          .prepareSend(
            WalletSendRequest(
              destinationAddress: address,
              amountSats: 0,
              feeRateSatsPerKb: _feeRateSatsPerKb,
              maximum: true,
            ),
          )
          .amountSats;
    } on WalletInsufficientFunds {
      return 0;
    } on WalletTransactionFailure {
      return null;
    }
  }

  void _review() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      final preview = widget.controller.prepareSend(
        WalletSendRequest(
          destinationAddress: _destinationController.text,
          amountSats: _maximum ? 0 : _parsePpc(_amountController.text)!,
          feeRateSatsPerKb: _feeRateSatsPerKb,
          maximum: _maximum,
          signingMessage: widget.account.keySource == WalletKeySource.roast
              ? _signingMessageController.text.trim()
              : '',
        ),
      );
      setState(() {
        _preview = preview;
        _error = null;
      });
    } on WalletTransactionFailure catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Unable to prepare the transaction.');
    }
  }

  Future<void> _send() async {
    final preview = _preview;
    if (preview == null || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await widget.controller.sendTransaction(preview);
      if (!mounted) return;
      Navigator.pop(context, result);
    } on WalletTransactionFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stackTrace) {
      AppLogger.error(
        '[WALLET SEND UI] Unhandled transaction submission error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _error = 'Broadcast failed. Verify the network connection and retry.';
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        title: Text(preview == null ? 'Send Peercoin' : 'Review transaction'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: preview == null ? _buildForm() : _buildPreview(preview),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _submitting
                ? null
                : preview == null
                ? () => Navigator.pop(context)
                : () => setState(() {
                    _preview = null;
                    _error = null;
                  }),
            child: Text(preview == null ? 'Cancel' : 'Back'),
          ),
          FilledButton(
            key: Key(
              preview == null ? 'send-review-button' : 'send-confirm-button',
            ),
            onPressed: _submitting
                ? null
                : preview == null
                ? _review
                : _send,
            child: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    preview == null
                        ? 'Review'
                        : widget.account.keySource == WalletKeySource.roast
                        ? 'Request approvals'
                        : 'Sign and send',
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final maximumAvailableSats = _maximumAvailableSats();
    final reservedBalanceSats = widget.controller.reservedBalanceSatsFor(
      widget.account,
    );
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiddleEllipsisTextFormField(
            fieldKey: const Key('send-address-field'),
            collapsedTextKey: const Key('send-address-collapsed-value'),
            controller: _destinationController,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Taproot address'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter a destination address.'
                : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const Key('send-amount-field'),
            controller: _amountController,
            enabled: !_maximum,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount',
              suffixText: 'PPC',
            ),
            validator: (value) {
              if (_maximum) return null;
              final amount = _parsePpc(value ?? '');
              return amount == null || amount <= 0
                  ? 'Enter a valid amount with up to 6 decimals.'
                  : null;
            },
          ),
          if (widget.account.keySource == WalletKeySource.roast) ...[
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('send-signing-message-field'),
              controller: _signingMessageController,
              textCapitalization: TextCapitalization.sentences,
              minLines: 2,
              maxLines: 4,
              maxLength: maxRoastSigningMessageBytes,
              decoration: const InputDecoration(
                labelText: 'Message to signers (optional)',
                helperText: 'Authenticated with the signing request.',
                alignLabelWithHint: true,
              ),
              validator: (value) {
                final byteLength = utf8.encode(value?.trim() ?? '').length;
                return byteLength > maxRoastSigningMessageBytes
                    ? 'Message must be no more than 1 KiB of UTF-8 text.'
                    : null;
              },
            ),
          ],
          CheckboxListTile(
            key: const Key('send-maximum-field'),
            value: _maximum,
            onChanged: (value) => setState(() {
              _maximum = value ?? false;
              _error = null;
            }),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('Send maximum available'),
            subtitle: Text(
              reservedBalanceSats > 0
                  ? '${_formatPpc(maximumAvailableSats ?? 0)} PPC available '
                        'after the network fee · '
                        '${_formatPpc(reservedBalanceSats)} PPC reserved by ROAST'
                  : maximumAvailableSats == null
                  ? 'The network fee is deducted automatically.'
                  : '${_formatPpc(maximumAvailableSats)} PPC available after '
                        'the network fee.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview(WalletTransactionPreview preview) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.account.keySource == WalletKeySource.roast
            ? 'Confirm every detail. The transaction will be sent to the '
                  'other participants for threshold approval.'
            : 'Confirm every detail before the private key signs this transaction.',
        style: TextStyle(color: AppColors.inkMuted),
      ),
      const SizedBox(height: 18),
      _TransactionRow(label: 'From', value: widget.account.name),
      _TransactionRow(
        label: 'To',
        value: preview.destinationAddress,
        monospace: true,
      ),
      _TransactionRow(
        label: 'Amount',
        value: '${_formatPpc(preview.amountSats)} PPC',
      ),
      _TransactionRow(
        label: 'Network fee',
        value: '${_formatPpc(preview.feeSats)} PPC',
      ),
      _TransactionRow(
        label: 'Change',
        value: '${_formatPpc(preview.changeSats)} PPC',
      ),
      if (preview.signingMessage.isNotEmpty)
        _TransactionRow(label: 'Message', value: preview.signingMessage),
      _TransactionRow(
        label: 'Inputs',
        value: '${preview.selectedUtxos.length}',
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: Colors.red)),
      ],
    ],
  );
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: const TextStyle(color: AppColors.inkMuted)),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontFamily: monospace ? 'monospace' : null,
              fontSize: monospace ? 11 : null,
            ),
          ),
        ),
      ],
    ),
  );
}

int? _parsePpc(String input) {
  final value = input.trim();
  if (!RegExp(r'^\d+(?:\.\d{1,6})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  final whole = BigInt.tryParse(parts.first);
  final fraction = BigInt.tryParse(
    parts.length == 1 ? '0' : parts[1].padRight(6, '0'),
  );
  if (whole == null || fraction == null) return null;
  final satoshis = whole * BigInt.from(1000000) + fraction;
  // Dart's JavaScript backend represents integers exactly up to 2^53 - 1.
  if (satoshis > BigInt.parse('9007199254740991')) return null;
  return satoshis.toInt();
}

String _shortTransactionId(String transactionId) => transactionId.length <= 16
    ? transactionId
    : '${transactionId.substring(0, 8)}…${transactionId.substring(transactionId.length - 8)}';

Future<void> _showAddWallet(
  BuildContext context,
  WalletController controller,
) async {
  final type = await showDialog<WalletKeySource>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Add wallet'),
      children: [
        SimpleDialogOption(
          onPressed: () =>
              Navigator.pop(dialogContext, WalletKeySource.personal),
          child: const ListTile(
            leading: Icon(Icons.key_outlined),
            title: Text('Personal wallet'),
            subtitle: Text('Use the local BIP-39 recovery phrase.'),
          ),
        ),
        SimpleDialogOption(
          onPressed: controller.roastAvailable
              ? () => Navigator.pop(dialogContext, WalletKeySource.roast)
              : null,
          child: ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('ROAST shared wallet'),
            subtitle: Text(
              controller.roastAvailable
                  ? 'Create or join a threshold signing setup.'
                  : 'Available on Linux and macOS.',
            ),
          ),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (type == WalletKeySource.roast) {
    await showRoastSetupCreation(context, controller);
    return;
  }
  if (type != WalletKeySource.personal) return;
  if (controller.vault?.mnemonic == null) {
    if (context.mounted) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (routeContext) => OnboardingScreen(
            controller: controller,
            onCreated: () => Navigator.pop(routeContext),
          ),
        ),
      );
    }
    return;
  }
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

Future<void> _confirmDeleteWallet(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final isRoast = account.keySource == WalletKeySource.roast;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete ${account.name}?'),
      content: Text(
        isRoast
            ? 'This wallet, its local signer identity and key share will be '
                  'permanently removed from this device. You may lose the '
                  'ability to approve transactions for the shared wallet.'
            : 'This wallet will be removed from this device. Its account '
                  'index will not be reused.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete wallet'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await controller.deleteAccount(account.id);
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

Future<void> _showRenameWallet(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final nameController = TextEditingController(text: account.name);
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Rename wallet'),
      content: TextField(
        key: const Key('rename-wallet-field'),
        controller: nameController,
        autofocus: true,
        maxLength: 32,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(dialogContext, value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (nameController.text.trim().isNotEmpty) {
              Navigator.pop(dialogContext, nameController.text);
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  nameController.dispose();
  if (name != null) await controller.renameAccount(account.id, name);
}

Future<void> _showSettings(
  BuildContext context,
  WalletController controller,
  AppNotifications notifications,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => AnimatedBuilder(
      animation: notifications,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
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
                Text(
                  'NOTIFICATIONS',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.inkMuted,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                SwitchListTile.adaptive(
                  key: const Key('desktop-notifications-toggle'),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Desktop notifications'),
                  subtitle: Text(
                    notifications.supportsDesktopNotifications
                        ? 'Show wallet events in the system notification center.'
                        : 'Available on Linux, macOS, and Windows.',
                  ),
                  value:
                      notifications.supportsDesktopNotifications &&
                      notifications.desktopEnabled,
                  onChanged: notifications.supportsDesktopNotifications
                      ? (enabled) async {
                          final accepted = await notifications
                              .setDesktopEnabled(enabled);
                          if (!accepted && sheetContext.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Desktop notifications could not be enabled.',
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
                        notifications.supportsDesktopNotifications &&
                            notifications.desktopEnabled
                        ? () async {
                            final shown = await notifications.sendTest();
                            if (!shown && sheetContext.mounted) {
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
                const Divider(height: 32),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.red,
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
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red,
                                  ),
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, true),
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
      ),
    ),
  );
}

Future<void> _showRoastRequests(
  BuildContext context,
  WalletController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Signing requests',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Approve only after verifying every recipient, amount, fee '
                  'and change output.',
                  style: TextStyle(color: AppColors.inkMuted),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: controller.roastSigningRequests.isEmpty
                      ? const Center(child: Text('No pending requests.'))
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: controller.roastSigningRequests.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) => _RoastRequestCard(
                            controller: controller,
                            item: controller.roastSigningRequests[index],
                          ),
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

class const _RoastRequestCard({
  required final WalletController controller,
  required final RoastSigningInboxItem item,
}) extends StatefulWidget {
  @override
  State<_RoastRequestCard> createState() => _RoastRequestCardState();
}

class _RoastRequestCardState extends State<_RoastRequestCard> {
  bool _busy = false;
  String? _error;

  Future<void> _perform(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.item.request;
    return Card(
      key: ValueKey('roast-signing-request-${request.idHex}'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.approval_outlined,
                  color: AppColors.danger,
                  size: 20,
                ),
                SizedBox(width: 8),
                Text(
                  'SIGNATURE REQUEST · ACTION REQUIRED',
                  style: TextStyle(
                    color: AppColors.danger,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              widget.item.walletName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Requested by ${_shortTransactionId(request.creator)} · '
              '${request.masterGroupKeys.length} input(s)',
              style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
            ),
            if (request.message.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('roast-signing-request-message'),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.35),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'REQUEST MESSAGE · AUTHENTICATED',
                      style: TextStyle(
                        color: AppColors.warningDark,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(request.message),
                  ],
                ),
              ),
            ],
            const Divider(height: 24),
            for (var i = 0; i < request.outputs.length; i++)
              _TransactionRow(
                label:
                    widget.controller.isRoastChangeOutput(
                      widget.item,
                      request.outputs[i],
                    )
                    ? 'Change'
                    : 'Recipient',
                value:
                    '${widget.controller.roastOutputAddress(widget.item, request.outputs[i])}\n'
                    '${_formatPpc(request.outputs[i].valueSats)} PPC',
                monospace: true,
              ),
            _TransactionRow(
              label: 'Network fee',
              value: '${_formatPpc(request.feeSats)} PPC',
            ),
            _TransactionRow(
              label: 'Expires',
              value: request.expiry.toLocal().toString(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(
                          () => widget.controller.rejectRoastSigningRequest(
                            widget.item,
                          ),
                        ),
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(
                          () => widget.controller.acceptRoastSigningRequest(
                            widget.item,
                          ),
                        ),
                  child: Text(_busy ? 'Submitting…' : 'Approve and sign'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
