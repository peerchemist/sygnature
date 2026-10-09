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
import '../services/electrumx_service.dart';
import '../services/peercoin_network_service.dart';
import '../services/roast_runtime_manager.dart';
import '../services/wallet_transaction_service.dart';
import 'about_screen.dart';
import 'app_theme.dart';
import 'onboarding_screen.dart';
import 'roast_setup_flow.dart';
import 'watch_only_wallet_dialog.dart';
import 'widgets/brand_mark.dart';
import 'widgets/middle_ellipsis_text.dart';
import 'widgets/selector_builder.dart';

part 'wallet_home/activity.dart';
part 'wallet_home/send_dialog.dart';
part 'wallet_home/account_dialogs.dart';
part 'wallet_home/settings.dart';
part 'wallet_home/signing_requests.dart';

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
              SelectorBuilder(
                listenable: controller,
                select: () => [controller.roastSigningRequests.length],
                builder: (context, _) => Badge(
                  isLabelVisible: controller.roastSigningRequests.isNotEmpty,
                  label: Text('${controller.roastSigningRequests.length}'),
                  child: IconButton(
                    tooltip: 'Signing requests',
                    onPressed: () => _showRoastRequests(context, controller),
                    icon: const Icon(Icons.approval_outlined),
                  ),
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
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () => [
      ...controller.accounts,
      controller.selectedAccount?.id,
      controller.roastSigningRequests.length,
    ],
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
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
                    return SelectorBuilder(
                      listenable: controller,
                      select: () {
                        final setup = controller.setupForAccount(account);
                        return [
                          controller.balanceSatsFor(account),
                          controller.syncStatusFor(account),
                          setup?.role,
                          setup?.isActive,
                          setup?.isWaitingForInvitation,
                          setup?.threshold,
                          setup?.participantCount,
                          if (setup != null) ...[
                            controller.activeRoastSigningRequestCount(setup.id),
                            controller
                                .roastSigningRequestsAwaitingLocalApprovalCount(
                                  setup.id,
                                ),
                          ],
                        ];
                      },
                      builder: (context, _) {
                        final setup = controller.setupForAccount(account);
                        final selected =
                            index == controller.selectedAccountIndex;
                        return _WalletListTile(
                          account: account,
                          displayIndex: index,
                          setup: setup,
                          balanceSats: controller.balanceSatsFor(account),
                          syncStatus: controller.syncStatusFor(account),
                          activeSigningRequestCount: setup == null
                              ? 0
                              : controller.activeRoastSigningRequestCount(
                                  setup.id,
                                ),
                          awaitingLocalApprovalCount: setup == null
                              ? 0
                              : controller
                                    .roastSigningRequestsAwaitingLocalApprovalCount(
                                      setup.id,
                                    ),
                          selected: selected,
                          onTap: () => _runWalletAction(
                            context,
                            () => controller.selectAccount(index),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const Divider(),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: Badge(
                  isLabelVisible: controller.roastSigningRequests.isNotEmpty,
                  label: Text('${controller.roastSigningRequests.length}'),
                  child: const Icon(Icons.approval_outlined, size: 21),
                ),
                title: const Text('Signing requests'),
                trailing: const Icon(Icons.chevron_right_rounded, size: 19),
                onTap: () =>
                    _showRoastRequests(context, controller, desktop: true),
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

class const _WalletListTile({
  required final WalletAccount account,
  required final int displayIndex,
  required final RoastSetup? setup,
  required final int balanceSats,
  required final AccountSyncStatus syncStatus,
  required final int activeSigningRequestCount,
  required final int awaitingLocalApprovalCount,
  required final bool selected,
  required final VoidCallback onTap,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isRoast = account.keySource == WalletKeySource.roast;
    final isWatchOnly = account.keySource == WalletKeySource.watchOnly;
    final isCoordinator = setup?.role == RoastSetupRole.host;
    final accountStatus = switch (account.derivationState) {
      WalletDerivationState.pending => 'Pending derivation',
      WalletDerivationState.ready
          when syncStatus == AccountSyncStatus.syncing =>
        'Synchronizing…',
      WalletDerivationState.ready => '${_formatPpc(balanceSats)} PPC',
      WalletDerivationState.watchOnly =>
        'Watch-only · ${_formatPpc(balanceSats)} PPC',
      WalletDerivationState.locked => 'Locked · ${_formatPpc(balanceSats)} PPC',
      WalletDerivationState.error => 'Derivation failed',
    };

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
                  '${displayIndex + 1}'.padLeft(2, '0'),
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
                            isWatchOnly
                                ? 'WATCH ONLY'
                                : isRoast
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            setup != null && account.address == null
                                ? setup!.isWaitingForInvitation
                                      ? 'Resume setup'
                                      : 'Resume setup · ${setup!.threshold} of ${setup!.participantCount}'
                                : accountStatus,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.inkMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (isRoast && setup?.isActive == true) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Tooltip(
                                    message: 'Active signature requests',
                                    child: Text(
                                      '$activeSigningRequestCount active',
                                      key: ValueKey(
                                        'wallet-${account.id}-active-signing-requests',
                                      ),
                                      style: const TextStyle(
                                        color: AppColors.inkMuted,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const Text(
                                    ' · ',
                                    style: TextStyle(
                                      color: AppColors.inkMuted,
                                      fontSize: 10,
                                    ),
                                  ),
                                  Tooltip(
                                    message: 'Waiting for this wallet to sign',
                                    child: Text(
                                      '$awaitingLocalApprovalCount to sign',
                                      key: ValueKey(
                                        'wallet-${account.id}-awaiting-local-approval',
                                      ),
                                      style: TextStyle(
                                        color: awaitingLocalApprovalCount > 0
                                            ? AppColors.danger
                                            : AppColors.inkMuted,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
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
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () => [
      controller.selectedAccount,
      controller.archivedAccounts.isNotEmpty,
      if (controller.selectedAccount case final account?) ...[
        controller.syncStatusFor(account),
        controller.setupForAccount(account)?.status,
        controller.setupForAccount(account)?.isFinalized,
        controller.setupForAccount(account)?.coordinatorId,
      ],
    ],
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final account = controller.selectedAccount;
    if (account == null) {
      return SafeArea(
        top: !mobile,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: () => _showAddWallet(context, controller),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add wallet'),
              ),
              if (controller.archivedAccounts.isNotEmpty) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('show-archived-wallets-empty-state'),
                  onPressed: () => _showArchivedWallets(context, controller),
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Restore archived wallet'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final roastSetup = controller.setupForAccount(account);
    final header = _DashboardHeader(
      account: account,
      syncStatus: controller.syncStatusFor(account),
      onDelete: () => _confirmDeleteWallet(context, controller, account),
      onArchive: () => _confirmArchiveWallet(context, controller, account),
      onRename: () => _showRenameWallet(context, controller, account),
      onChangeSignerGroup:
          roastSetup?.isActive == true && controller.roastAvailable
          ? () => showRoastGroupTransition(
              context,
              controller,
              controller.setupForAccount(account)!,
            )
          : null,
      onSwitchCoordinator:
          roastSetup?.isFinalized == true &&
              roastSetup?.coordinatorId != null &&
              controller.roastCoordinatorSwitchAvailable
          ? () => showRoastCoordinatorSwitch(
              context,
              controller,
              controller.setupForAccount(account)!,
            )
          : null,
    );
    return SafeArea(
      top: !mobile,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          mobile ? 18 : 40,
          mobile ? 14 : 32,
          mobile ? 18 : 40,
          40,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wideDesktop = !mobile && constraints.maxWidth >= 840;
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wideDesktop ? 1320 : 1050,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (mobile) ...[
                      _MobileWalletPicker(controller: controller),
                      const SizedBox(height: 26),
                    ],
                    _WalletPriorityRequests(
                      controller: controller,
                      account: account,
                    ),
                    if (wideDesktop)
                      header
                    else
                      _CompactDashboardHeader(
                        header: header,
                        account: account,
                        controller: controller,
                        showDetails: account.address != null,
                      ),
                    if (roastSetup != null) ...[
                      const SizedBox(height: 18),
                      RoastSetupPanel(controller: controller, account: account),
                    ],
                    if (roastSetup != null && account.address == null) ...[
                      const SizedBox(height: 18),
                      const _PendingRoastNotice(),
                    ] else if (wideDesktop) ...[
                      const SizedBox(height: 24),
                      _DesktopWalletOverview(
                        account: account,
                        controller: controller,
                      ),
                    ] else ...[
                      const SizedBox(height: 24),
                      _BalanceCard(account: account, controller: controller),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth >= 680) {
                            return const SizedBox(height: 18);
                          }
                          return Column(
                            children: [
                              const SizedBox(height: 18),
                              _AddressCard(account: account),
                              const SizedBox(height: 18),
                              _AccountDetails(
                                account: account,
                                controller: controller,
                              ),
                              const SizedBox(height: 18),
                            ],
                          );
                        },
                      ),
                      _ActivityCard(controller: controller, account: account),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class const _CompactDashboardHeader({
  required final Widget header,
  required final WalletAccount account,
  required final WalletController controller,
  required final bool showDetails,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 680 || !showDetails) return header;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 18),
                const Text(
                  'RECEIVE ADDRESS',
                  style: TextStyle(
                    color: AppColors.inkMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 7),
                _ReceiveAddressBox(account: account),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: _AccountDetails(account: account, controller: controller),
          ),
        ],
      );
    },
  );
}

class const _DesktopWalletOverview({
  required final WalletAccount account,
  required final WalletController controller,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Row(
    key: const Key('desktop-wallet-overview'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          key: const Key('desktop-primary-column'),
          children: [
            _BalanceCard(account: account, controller: controller),
            const SizedBox(height: 18),
            _ActivityCard(controller: controller, account: account),
          ],
        ),
      ),
      const SizedBox(width: 20),
      SizedBox(
        key: const Key('desktop-context-column'),
        width: 340,
        child: Column(
          children: [
            _AddressCard(account: account),
            const SizedBox(height: 18),
            _AccountDetails(account: account, controller: controller),
          ],
        ),
      ),
    ],
  );
}

class const _WalletPriorityRequests({
  required final WalletController controller,
  required final WalletAccount account,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () => [
      controller.setupForAccount(account),
      if (account.sourceId case final setupId?) ...[
        controller.roastOperationInProgress(setupId),
        ...controller.roastSigningRequestsForSetup(setupId),
      ],
    ],
    builder: (context, _) {
      final setup = controller.setupForAccount(account);
      if (setup == null) return const SizedBox.shrink();
      final requests = controller.roastSigningRequestsForSetup(setup.id);
      final showDkg =
          setup.status == RoastSetupStatus.awaitingDkgApproval &&
          setup.pendingDkgProposalHex != null;
      if (!showDkg && requests.isEmpty) return const SizedBox.shrink();
      return Column(
        children: [
          _RoastPriorityRequests(
            controller: controller,
            setup: setup,
            showDkg: showDkg,
            signingRequests: requests,
          ),
          const SizedBox(height: 18),
        ],
      );
    },
  );
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
            'ROAST SIGNING REQUESTS',
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
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () => [...controller.accounts, controller.selectedAccount?.id],
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
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
                  onSelected: (_) => _runWalletAction(
                    context,
                    () => controller.selectAccount(index),
                  ),
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
    required this.onArchive,
    required this.onRename,
    this.onChangeSignerGroup,
    this.onSwitchCoordinator,
  });
  final WalletAccount account;
  final AccountSyncStatus syncStatus;
  final VoidCallback onDelete;
  final VoidCallback onArchive;
  final VoidCallback onRename;
  final VoidCallback? onChangeSignerGroup;
  final VoidCallback? onSwitchCoordinator;

  @override
  Widget build(BuildContext context) {
    final awaitsRoastKey =
        account.keySource == WalletKeySource.roast &&
        account.derivationState == WalletDerivationState.pending;
    final ready = syncStatus == AccountSyncStatus.synced;
    final statusLabel = awaitsRoastKey
        ? 'Key setup required'
        : switch (syncStatus) {
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
              account.keySource == WalletKeySource.watchOnly
                  ? 'Watch-only Peercoin address'
                  : 'Peercoin account ${account.accountIndex}',
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
                    awaitsRoastKey
                        ? Icons.key_rounded
                        : ready
                        ? Icons.check_circle_rounded
                        : Icons.schedule_rounded,
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
                if (value == 'signers') onChangeSignerGroup?.call();
                if (value == 'coordinator') onSwitchCoordinator?.call();
                if (value == 'archive') onArchive();
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
                if (onChangeSignerGroup != null)
                  const PopupMenuItem(
                    value: 'signers',
                    child: Row(
                      children: [
                        Icon(Icons.manage_accounts_outlined),
                        SizedBox(width: 10),
                        Text('Change signers'),
                      ],
                    ),
                  ),
                if (onSwitchCoordinator != null)
                  const PopupMenuItem(
                    value: 'coordinator',
                    child: Row(
                      children: [
                        Icon(Icons.swap_horiz_rounded),
                        SizedBox(width: 10),
                        Flexible(child: Text('Change ROAST coordinator')),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'archive',
                  child: Row(
                    children: [
                      Icon(Icons.archive_outlined),
                      SizedBox(width: 10),
                      Text('Archive wallet'),
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

Future<void> _confirmArchiveWallet(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final isRoast = account.keySource == WalletKeySource.roast;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Archive ${account.name}?'),
      content: Text(
        isRoast
            ? 'The wallet will be hidden and its signer will go offline until '
                  'you restore it. Keys and wallet history remain on this device.'
            : 'The wallet will be hidden and stop synchronizing until you '
                  'restore it. Keys and wallet history remain on this device.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-archive-wallet'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Archive wallet'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await controller.archiveAccount(account.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${account.name} archived.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _runWalletAction(
            context,
            () => controller.restoreAccount(account.id),
          ),
        ),
      ),
    );
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.account, required this.controller});
  final WalletAccount account;
  final WalletController controller;

  @override
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () => [
      controller.balanceFor(account),
      controller.syncStatusFor(account),
      controller.setupForAccount(account)?.isActive,
      if (account.sourceId case final setupId?) ...[
        controller.roastTransactionSigningInProgress(setupId),
        controller.roastMessageSigningInProgress(setupId),
        controller.roastOperationInProgress(setupId),
      ],
      controller.hasDismissibleRoastSigningOperation(account.id),
    ],
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final hasAddress = account.address != null;
    final canSign =
        hasAddress && account.derivationState == WalletDerivationState.ready;
    final roastSetup = controller.setupForAccount(account);
    final signingAvailable = roastSetup == null || roastSetup.isActive;
    final transactionSigning =
        roastSetup != null &&
        controller.roastTransactionSigningInProgress(roastSetup.id);
    final messageSigning =
        roastSetup != null &&
        controller.roastMessageSigningInProgress(roastSetup.id);
    final hasDismissibleSigningOperation = controller
        .hasDismissibleRoastSigningOperation(account.id);
    final canSignMessage =
        canSign &&
        roastSetup?.isActive == true &&
        !controller.roastOperationInProgress(roastSetup!.id) &&
        !messageSigning;
    final syncStatus = controller.syncStatusFor(account);
    final balance = controller.balanceFor(account);
    final balanceDescription = switch (syncStatus) {
      AccountSyncStatus.unavailable =>
        'Value unavailable until synchronization',
      AccountSyncStatus.syncing => 'Synchronizing with ElectrumX…',
      AccountSyncStatus.synced when balance.reservedSats > 0 =>
        '${_formatPpc(balance.confirmedSats)} PPC confirmed · '
            '${_formatPpc(balance.reservedSats)} PPC reserved by ROAST',
      AccountSyncStatus.synced when balance.pendingSats == 0 =>
        '${_formatPpc(balance.confirmedSats)} PPC confirmed · '
            '${balance.utxoCount} ${balance.utxoCount == 1 ? 'output' : 'outputs'}',
      AccountSyncStatus.synced =>
        '${_formatPpc(balance.confirmedSats)} PPC confirmed · '
            '${_formatPpc(balance.pendingSats)} PPC pending',
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
                '${_formatPpc(balance.totalSats)} PPC',
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
                  if (hasAddress && syncStatus != AccountSyncStatus.syncing)
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
                        canSign &&
                        signingAvailable &&
                        syncStatus == AccountSyncStatus.synced &&
                        balance.availableSats > 0 &&
                        !transactionSigning,
                    onPressed:
                        canSign &&
                            signingAvailable &&
                            syncStatus == AccountSyncStatus.synced &&
                            balance.availableSats > 0 &&
                            !transactionSigning
                        ? () => _showSendDialog(context, controller, account)
                        : null,
                  ),
                  if (roastSetup?.isActive == true)
                    _BalanceAction(
                      key: const Key('sign-roast-message'),
                      icon: Icons.draw_outlined,
                      label: messageSigning
                          ? 'Signing message…'
                          : 'Sign message',
                      enabled: canSignMessage,
                      onPressed: canSignMessage
                          ? () => showRoastSignMessageDialog(
                              context,
                              controller,
                              account,
                            )
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
              if (transactionSigning) ...[
                const SizedBox(height: 12),
                const Text(
                  'A transaction signature request is already in progress. '
                  'Wait for it to finish before creating another one.',
                  key: Key('transaction-signature-request-warning'),
                  style: TextStyle(color: AppColors.warningDark, fontSize: 12),
                ),
              ] else if (hasDismissibleSigningOperation) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'A failed approval request is still reserving '
                        'transaction inputs.',
                        style: TextStyle(
                          color: AppColors.warningDark,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('dismiss-roast-signing-operation'),
                      onPressed: () => _dismissFailedRoastSigningOperation(
                        context,
                        controller,
                        account,
                      ),
                      child: const Text('Dismiss failed request'),
                    ),
                  ],
                ),
              ],
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

class const _BalanceAction({
  super.key,
  required final IconData icon,
  required final String label,
  required final bool enabled,
  required final VoidCallback? onPressed,
}) extends StatelessWidget {
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

class const _AddressCard({required final WalletAccount account})
    extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
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
            _ReceiveAddressBox(account: account),
          ],
        ),
      ),
    );
  }
}

class const _ReceiveAddressBox({required final WalletAccount account})
    extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final address = account.address;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: address == null
          ? Text(switch (account.derivationState) {
              WalletDerivationState.error =>
                'Address unavailable because derivation failed.',
              WalletDerivationState.locked =>
                'Unlock the wallet to access its address.',
              _ => 'Address unavailable until derivation completes.',
            }, style: const TextStyle(color: AppColors.inkMuted, fontSize: 13))
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
                    await Clipboard.setData(ClipboardData(text: address));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied.')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
              ],
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
      key: const Key('account-details-card'),
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
            if (account.keySource != WalletKeySource.watchOnly) ...[
              const SizedBox(height: 13),
              _DetailRow(
                label: 'Account index',
                value: '${account.accountIndex}',
              ),
            ],
            if (account.keySource == WalletKeySource.personal) ...[
              const SizedBox(height: 13),
              _DetailRow(
                label: 'Derivation path',
                value: account.derivationPath ?? 'Not available',
              ),
            ],
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

Future<void> _showAdaptivePanel(
  BuildContext context, {
  bool? desktop,
  required Widget Function(BuildContext panelContext, bool desktop) builder,
}) async {
  final useDesktop = desktop ?? MediaQuery.sizeOf(context).width >= 920;
  if (!useDesktop) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => builder(sheetContext, false),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      key: const Key('desktop-modal-panel'),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 640,
          maxWidth: 720,
          maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.82,
        ),
        child: builder(dialogContext, true),
      ),
    ),
  );
}
