import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../controllers/wallet_controller.dart';
import '../models/wallet_account.dart';
import '../models/wallet_activity.dart';
import '../models/roast_setup.dart';
import '../models/wallet_network.dart';
import '../models/wallet_transaction.dart';
import '../services/app_logger.dart';
import '../services/app_notifications.dart';
import '../services/android_public_feed_work.dart';
import '../services/electrumx_service.dart';
import '../services/peercoin_network_service.dart';
import '../services/roast_runtime_manager.dart';
import '../services/wallet_transaction_service.dart';
import '../storage/public_feed_store.dart';
import 'about_screen.dart';
import 'app_theme.dart';
import 'onboarding_screen.dart';
import 'public_feed_dialog.dart';
import 'roast_setup_flow.dart';
import 'watch_only_wallet_dialog.dart';
import 'wallet_backup_screen.dart';
import 'widgets/brand_mark.dart';
import 'widgets/middle_ellipsis_text.dart';
import 'widgets/selector_builder.dart';
import 'widgets/share_qr_dialog.dart';

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
                Expanded(
                  child: _WalletDashboard(
                    controller: controller,
                    notifications: notifications,
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.of(context).canvas,
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
          body: _WalletDashboard(
            controller: controller,
            notifications: notifications,
            mobile: true,
          ),
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
      color: AppColors.of(context).surface,
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
                  Expanded(
                    child: Text(
                      'WALLETS',
                      style: TextStyle(
                        color: AppColors.of(context).inkMuted,
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
                          currencyShortName: controller
                              .networkForAccount(account)
                              .currency
                              .shortName,
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
  required final String currencyShortName,
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
      WalletDerivationState.error => 'Derivation failed',
      _ when syncStatus == AccountSyncStatus.syncing => 'Synchronizing…',
      _ when syncStatus == AccountSyncStatus.offline => 'Offline',
      _ when syncStatus == AccountSyncStatus.stale =>
        'Stale data · ${_formatPpc(balanceSats)} $currencyShortName',
      _ when syncStatus == AccountSyncStatus.error => 'Sync failed',
      WalletDerivationState.ready =>
        '${_formatPpc(balanceSats)} $currencyShortName',
      WalletDerivationState.watchOnly =>
        'Watch-only · ${_formatPpc(balanceSats)} $currencyShortName',
      WalletDerivationState.locked =>
        'Locked · ${_formatPpc(balanceSats)} $currencyShortName',
    };
    final showSyncStatus =
        account.address != null &&
        (syncStatus == AccountSyncStatus.syncing ||
            syncStatus == AccountSyncStatus.error);

    return Material(
      color: selected ? AppColors.of(context).lime : Colors.transparent,
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
                  color: selected
                      ? AppColors.of(context).surface
                      : AppColors.of(context).canvas,
                  border: Border.all(color: AppColors.of(context).line),
                  borderRadius: BorderRadius.circular(3),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${displayIndex + 1}'.padLeft(2, '0'),
                  style: TextStyle(
                    color: AppColors.of(context).forest,
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
                        if (showSyncStatus) ...[
                          _WalletSyncIndicator(
                            key: ValueKey(
                              'wallet-${account.id}-${syncStatus.name}',
                            ),
                            status: syncStatus,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            account.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.of(context).ink,
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
                                ? AppColors.pastelGreen
                                : AppColors.of(context).canvas,
                            border: Border.all(
                              color: isRoast
                                  ? AppColors.pastelGreen
                                  : AppColors.of(context).line,
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
                                  ? AppColors.charcoal
                                  : AppColors.of(context).inkMuted,
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
                            key: ValueKey('wallet-${account.id}-status'),
                            setup != null && account.address == null
                                ? setup!.isWaitingForInvitation
                                      ? 'Resume setup'
                                      : 'Resume setup · ${setup!.threshold} of ${setup!.participantCount}'
                                : accountStatus,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: syncStatus == AccountSyncStatus.error
                                  ? AppColors.of(context).danger
                                  : AppColors.of(context).inkMuted,
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
                                      style: TextStyle(
                                        color: AppColors.of(context).inkMuted,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    ' · ',
                                    style: TextStyle(
                                      color: AppColors.of(context).inkMuted,
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
                                            ? AppColors.of(context).danger
                                            : AppColors.of(context).inkMuted,
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
  const _WalletDashboard({
    required this.controller,
    required this.notifications,
    this.mobile = false,
  });
  final WalletController controller;
  final AppNotifications notifications;
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
      networkLabel: controller.networkForAccount(account).label,
      syncStatus: controller.syncStatusFor(account),
      onDelete: () => _confirmDeleteWallet(context, controller, account),
      onArchive: () => _confirmArchiveWallet(context, controller, account),
      onRename: () => _showRenameWallet(context, controller, account),
      onExtendRecoveryScan: account.keySource != WalletKeySource.watchOnly
          ? () => _showExtendAddressScanDialog(context, controller, account)
          : null,
      publicFeedLabel: roastSetup?.role == RoastSetupRole.member
          ? 'Receive background notifications'
          : 'Public operation feed',
      onOpenPublicFeed: roastSetup != null && controller.publicFeedStore != null
          ? () async {
              final store = await controller.publicFeedStore!;
              if (!context.mounted) return;
              await showDialog<void>(
                context: context,
                builder: (_) => PublicFeedDialog(
                  store: store,
                  setup: roastSetup,
                  notify: notifications.publicFeedRequested,
                  notificationPermission: notifications.systemPermissionGranted,
                ),
              );
            }
          : null,
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
                        controller: controller,
                        header: header,
                        account: account,
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
                              _AddressCard(
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
  required final WalletController controller,
  required final Widget header,
  required final WalletAccount account,
  required final bool showDetails,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 680 || !showDetails) return header;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 18),
          Text(
            'RECEIVE ADDRESS',
            style: TextStyle(
              color: AppColors.of(context).inkMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 7),
          _ReceiveAddressBox(account: account, controller: controller),
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
          children: [_AddressCard(account: account, controller: controller)],
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
      Row(
        children: [
          Icon(
            Icons.notifications_active_outlined,
            color: AppColors.of(context).danger,
            size: 20,
          ),
          SizedBox(width: 8),
          Text(
            'ROAST SIGNING REQUESTS',
            style: TextStyle(
              color: AppColors.of(context).danger,
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
    select: () => [
      for (final account in controller.accounts) ...[
        account,
        controller.syncStatusFor(account),
      ],
      controller.selectedAccount?.id,
    ],
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
                final account = controller.accounts[index];
                final selected = index == controller.selectedAccountIndex;
                final syncStatus = controller.syncStatusFor(account);
                final showSyncStatus =
                    account.address != null &&
                    (syncStatus == AccountSyncStatus.syncing ||
                        syncStatus == AccountSyncStatus.error);
                return ChoiceChip(
                  selected: selected,
                  showCheckmark: false,
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(account.name),
                      if (showSyncStatus) ...[
                        const SizedBox(width: 7),
                        _WalletSyncIndicator(
                          key: ValueKey(
                            'wallet-${account.id}-${syncStatus.name}',
                          ),
                          status: syncStatus,
                        ),
                      ],
                    ],
                  ),
                  onSelected: (_) => _runWalletAction(
                    context,
                    () => controller.selectAccount(index),
                  ),
                  selectedColor: AppColors.pastelGreen,
                  labelStyle: TextStyle(
                    color: selected
                        ? AppColors.charcoal
                        : AppColors.of(context).ink,
                    fontWeight: FontWeight.w700,
                  ),
                  side: BorderSide(color: AppColors.of(context).line),
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

class const _WalletSyncIndicator({
  super.key,
  required final AccountSyncStatus status,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => switch (status) {
    AccountSyncStatus.syncing => Tooltip(
      message: 'Wallet is synchronizing',
      child: SizedBox.square(
        dimension: 13,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: AppColors.of(context).warningDark,
        ),
      ),
    ),
    AccountSyncStatus.error => Tooltip(
      message: 'Wallet synchronization failed',
      child: Icon(
        Icons.error_outline_rounded,
        size: 15,
        color: AppColors.of(context).danger,
      ),
    ),
    _ => const SizedBox.shrink(),
  };
}

class _PendingRoastNotice extends StatelessWidget {
  const _PendingRoastNotice();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.of(context).warning.withValues(alpha: 0.13),
      border: Border.all(color: AppColors.of(context).warning),
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
    required this.networkLabel,
    required this.syncStatus,
    required this.onDelete,
    required this.onArchive,
    required this.onRename,
    this.onExtendRecoveryScan,
    this.publicFeedLabel = 'Public operation feed',
    this.onOpenPublicFeed,
    this.onChangeSignerGroup,
    this.onSwitchCoordinator,
  });
  final WalletAccount account;
  final String networkLabel;
  final AccountSyncStatus syncStatus;
  final VoidCallback onDelete;
  final VoidCallback onArchive;
  final VoidCallback onRename;
  final VoidCallback? onExtendRecoveryScan;
  final String publicFeedLabel;
  final VoidCallback? onOpenPublicFeed;
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
            AccountSyncStatus.offline => 'Offline',
            AccountSyncStatus.stale => 'Data stale',
            AccountSyncStatus.error => 'Sync failed',
            AccountSyncStatus.unavailable => 'Unavailable',
          };
    final statusColor = ready
        ? AppColors.of(context).greenDark
        : AppColors.of(context).warningDark;
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
              '${switch (account.keySource) {
                WalletKeySource.personal => 'Personal wallet',
                WalletKeySource.roast => 'Shared wallet',
                WalletKeySource.watchOnly => 'Watch-only wallet',
              }} · $networkLabel',
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
                    ? AppColors.of(context).lime
                    : AppColors.of(context).warning.withValues(alpha: 0.2),
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
              icon: Icon(
                Icons.settings_outlined,
                size: 20,
                color: AppColors.of(context).inkMuted,
              ),
              onSelected: (value) {
                if (value == 'rename') onRename();
                if (value == 'public-feed') onOpenPublicFeed?.call();
                if (value == 'signers') onChangeSignerGroup?.call();
                if (value == 'coordinator') onSwitchCoordinator?.call();
                if (value == 'recovery-scan') onExtendRecoveryScan?.call();
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
                if (onOpenPublicFeed != null)
                  PopupMenuItem(
                    key: const Key('open-public-feed'),
                    value: 'public-feed',
                    child: Row(
                      children: [
                        const Icon(Icons.notifications_outlined),
                        const SizedBox(width: 10),
                        Flexible(child: Text(publicFeedLabel)),
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
                if (onExtendRecoveryScan != null)
                  const PopupMenuItem(
                    key: Key('open-recovery-scan'),
                    value: 'recovery-scan',
                    child: Row(
                      children: [
                        Icon(Icons.manage_search_rounded),
                        SizedBox(width: 10),
                        Text('Recovery scan'),
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
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline_rounded,
                        color: AppColors.of(context).danger,
                      ),
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
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _runWalletAction(
            context,
            () => controller.restoreAccount(account.id),
          ),
        ),
      ),
    );
  } on Object catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to archive the wallet.')),
      );
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
      controller.lastSuccessfulSyncFor(account),
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
    final lastSuccessfulSync = controller.lastSuccessfulSyncFor(account);
    final balance = controller.balanceFor(account);
    final currencyShortName = controller
        .networkForAccount(account)
        .currency
        .shortName;
    final baseDescription = switch (syncStatus) {
      AccountSyncStatus.unavailable =>
        'Value unavailable until synchronization',
      AccountSyncStatus.syncing => 'Synchronizing with ElectrumX…',
      AccountSyncStatus.offline => 'Offline · Waiting for ElectrumX',
      AccountSyncStatus.stale =>
        'Showing last known balance · Synchronization pending',
      AccountSyncStatus.synced when balance.reservedSats > 0 =>
        '${_formatPpc(balance.confirmedSats)} $currencyShortName confirmed · '
            '${_formatPpc(balance.reservedSats)} $currencyShortName reserved by ROAST',
      AccountSyncStatus.synced when balance.pendingSats == 0 =>
        '${_formatPpc(balance.confirmedSats)} $currencyShortName confirmed · '
            '${balance.utxoCount} ${balance.utxoCount == 1 ? 'output' : 'outputs'}',
      AccountSyncStatus.synced =>
        '${_formatPpc(balance.confirmedSats)} $currencyShortName confirmed · '
            '${_formatPpc(balance.pendingSats)} $currencyShortName pending',
      AccountSyncStatus.error => 'ElectrumX synchronization failed',
    };
    final localSync = lastSuccessfulSync?.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final balanceDescription = localSync == null
        ? baseDescription
        : '$baseDescription\nLast synchronized '
              '${localizations.formatMediumDate(localSync)} at '
              '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(localSync))}';
    return Card(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'BALANCE',
                style: TextStyle(
                  color: AppColors.of(context).inkMuted,
                  fontSize: 11,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${_formatPpc(balance.totalSats)} $currencyShortName',
                style: TextStyle(
                  color: AppColors.of(context).ink,
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
                      style: TextStyle(
                        color: AppColors.of(context).inkMuted,
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
                Text(
                  'A transaction signature request is already in progress. '
                  'Wait for it to finish before creating another one.',
                  key: Key('transaction-signature-request-warning'),
                  style: TextStyle(
                    color: AppColors.of(context).warningDark,
                    fontSize: 12,
                  ),
                ),
              ] else if (hasDismissibleSigningOperation) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'A failed approval request is still reserving '
                        'transaction inputs.',
                        style: TextStyle(
                          color: AppColors.of(context).warningDark,
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

class const _AddressCard({
  required final WalletAccount account,
  required final WalletController controller,
}) extends StatelessWidget {
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
                Icon(
                  Icons.account_balance_wallet_outlined,
                  color: AppColors.of(context).greenDark,
                ),
                const SizedBox(width: 10),
                Text(
                  'Receive address',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 18),
            _ReceiveAddressBox(account: account, controller: controller),
          ],
        ),
      ),
    );
  }
}

class const _ReceiveAddressBox({
  required final WalletAccount account,
  required final WalletController controller,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final address = account.address;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.of(context).canvas,
        border: Border.all(color: AppColors.of(context).line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: address == null
          ? Text(
              switch (account.derivationState) {
                WalletDerivationState.error =>
                  'Address unavailable because derivation failed.',
                WalletDerivationState.locked =>
                  'Unlock the wallet to access its address.',
                _ => 'Address unavailable until derivation completes.',
              },
              style: TextStyle(
                color: AppColors.of(context).inkMuted,
                fontSize: 13,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                    IconButton(
                      tooltip: 'Show address QR code',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => showShareQrDialog(
                        context,
                        title: 'Receive address',
                        data: address,
                      ),
                      icon: const Icon(Icons.qr_code_rounded, size: 18),
                    ),
                    if (defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS)
                      Builder(
                        builder: (shareContext) => IconButton(
                          tooltip: 'Share address',
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            final renderObject = shareContext
                                .findRenderObject();
                            final origin = renderObject is RenderBox
                                ? renderObject.localToGlobal(Offset.zero) &
                                      renderObject.size
                                : null;
                            try {
                              await SharePlus.instance.share(
                                ShareParams(
                                  text: address,
                                  sharePositionOrigin: origin,
                                ),
                              );
                            } catch (error, stackTrace) {
                              AppLogger.warn(
                                'Unable to share receive address',
                                error: error,
                                stackTrace: stackTrace,
                              );
                              if (!shareContext.mounted) return;
                              ScaffoldMessenger.of(shareContext).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    "Couldn't open sharing. The address is still available to copy.",
                                  ),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.share_outlined, size: 18),
                        ),
                      ),
                  ],
                ),
                Tooltip(
                  message: 'Address details',
                  child: TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => _AddressDetailsDialog(
                        controller: controller,
                        accountId: account.id,
                      ),
                    ),
                    icon: const Icon(Icons.list_alt, size: 18),
                    label: const Text('Address details'),
                  ),
                ),
              ],
            ),
    );
  }
}

Future<void> _showExtendAddressScanDialog(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final input = TextEditingController(
    text: '${controller.addressScanRangeFor(account).through}',
  );
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Extend recovery scan'),
      content: TextField(
        key: const Key('address-scan-upper-index-field'),
        controller: input,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Highest address index',
          helperText: 'Scans indexes 0 through this value (maximum 10000).',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-address-scan-range'),
          onPressed: () => Navigator.pop(context, input.text.trim()),
          child: const Text('Scan'),
        ),
      ],
    ),
  );
  input.dispose();
  if (value == null || !context.mounted) return;
  try {
    await controller.extendAddressScan(account.id, int.parse(value));
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid recovery scan range.')),
      );
    }
  }
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

class const _AddressDetailsDialog({
  required final WalletController controller,
  required final String accountId,
}) extends StatefulWidget {
  @override
  State<_AddressDetailsDialog> createState() => _AddressDetailsDialogState();
}

class _AddressDetailsDialogState extends State<_AddressDetailsDialog> {
  bool _includeUnused = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final account = widget.controller.accounts
          .where((account) => account.id == widget.accountId)
          .firstOrNull;
      final addresses = account == null
          ? <WalletAddressDetails>[]
          : widget.controller.addressDetailsFor(
              account,
              includeUnused: _includeUnused,
            );
      return AlertDialog(
        title: const Text('Address details'),
        content: SizedBox(
          width: 560,
          height: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Used means activity was observed during this session. '
                'Allocation does not imply usage. Balances include pending outputs.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show unused addresses'),
                subtitle: const Text(
                  'Include addresses with no known transactions.',
                ),
                value: _includeUnused,
                onChanged: (value) =>
                    setState(() => _includeUnused = value ?? false),
              ),
              Expanded(
                child: addresses.isEmpty
                    ? Text(
                        _includeUnused ? 'No addresses available.' : 'No used addresses found. Turn on “Show unused addresses” to see more.',
                      )
                    : ListView.builder(
                        itemCount: addresses.length,
                        itemBuilder: (context, index) {
                          final details = addresses[index];
                          final usage = switch (details.usage) {
                            WalletAddressUsage.unknown => 'Unknown',
                            WalletAddressUsage.noHistory => 'No history found',
                            WalletAddressUsage.used => 'Used',
                          };
                          return ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text(
                              'Index ${details.index ?? "not available"} · '
                              '${details.isReceive ? "Receive" : "Change"}',
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                MiddleEllipsisText(value: details.address),
                                Text(
                                  '$usage · '
                                  '${details.isAllocated ? "Allocated" : "Not allocated"}'
                                  '${details.isStale ? " · Sync pending or unavailable" : ""}',
                                ),
                              ],
                            ),
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(details.address),
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  'Path: ${details.derivationPath ?? "Not available"}',
                                ),
                                subtitle: Text(
                                  'Balance: ${details.balanceSats == null ? "Unknown" : "${_formatPpc(details.balanceSats!)} PPC"}',
                                ),
                                trailing: IconButton(
                                  tooltip: 'Copy address',
                                  icon: const Icon(Icons.copy_rounded),
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: details.address),
                                    );
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Address copied.'),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
