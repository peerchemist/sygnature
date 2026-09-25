import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../controllers/wallet_controller.dart';
import '../models/wallet_account.dart';
import '../models/wallet_network.dart';
import '../models/wallet_transaction.dart';
import '../services/peercoin_network_service.dart';
import '../services/wallet_transaction_service.dart';
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
                  onDelete: () =>
                      _confirmDeleteWallet(context, controller, account),
                  onRename: () =>
                      _showRenameWallet(context, controller, account),
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
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined),
                      SizedBox(width: 10),
                      Text('Rename wallet'),
                    ],
                  ),
                ),
                PopupMenuItem(
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
    final pendingBalance = controller.pendingBalanceSatsFor(account);
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
                          pendingBalance == 0
                              ? '${_formatPpc(confirmedBalance)} PPC confirmed · '
                                    '$utxoCount ${utxoCount == 1 ? 'output' : 'outputs'}'
                              : '${_formatPpc(confirmedBalance)} PPC confirmed · '
                                    '${_formatPpc(pendingBalance)} PPC pending',
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
                    onPressed: active
                        ? () => _showReceiveAddress(context, account)
                        : null,
                  ),
                  _BalanceAction(
                    icon: Icons.north_east,
                    label: 'Send',
                    enabled:
                        active &&
                        syncStatus == AccountSyncStatus.synced &&
                        confirmedBalance > 0,
                    onPressed:
                        active &&
                            syncStatus == AccountSyncStatus.synced &&
                            confirmedBalance > 0
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

Future<void> _showReceiveAddress(
  BuildContext context,
  WalletAccount account,
) async {
  final address = account.address;
  if (address == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Receive Peercoin'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: 'QR code for receive address',
              child: QrImageView(
                data: address,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
            const SizedBox(height: 18),
            SelectableText(
              address,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: address));
            if (!dialogContext.mounted) return;
            ScaffoldMessenger.of(dialogContext)
                .showSnackBar(const SnackBar(content: Text('Address copied.')));
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Done'),
        ),
      ],
    ),
  );
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
  late final TextEditingController _feeRateController;
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
    _feeRateController = TextEditingController(
      text: network.network.feePerKb.toString(),
    );
  }

  @override
  void dispose() {
    _destinationController.dispose();
    _amountController.dispose();
    _feeRateController.dispose();
    super.dispose();
  }

  void _review() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      final preview = widget.controller.prepareSend(
        WalletSendRequest(
          destinationAddress: _destinationController.text,
          amountSats: _maximum ? 0 : _parsePpc(_amountController.text)!,
          feeRateSatsPerKb: int.parse(_feeRateController.text.trim()),
          maximum: _maximum,
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
    } catch (_) {
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
    return AlertDialog(
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
              : Text(preview == null ? 'Review' : 'Sign and send'),
        ),
      ],
    );
  }

  Widget _buildForm() => Form(
    key: _formKey,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          key: const Key('send-address-field'),
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
          subtitle: const Text('The network fee is deducted automatically.'),
        ),
        const SizedBox(height: 14),
        TextFormField(
          key: const Key('send-fee-rate-field'),
          controller: _feeRateController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Fee rate',
            suffixText: 'sat/kB',
          ),
          validator: (value) {
            final feeRate = int.tryParse(value?.trim() ?? '');
            return feeRate == null || feeRate <= 0
                ? 'Enter a valid fee rate.'
                : null;
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ],
    ),
  );

  Widget _buildPreview(WalletTransactionPreview preview) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Confirm every detail before the private key signs this transaction.',
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
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete ${account.name}?'),
      content: const Text(
        'This wallet will be removed from this device. Its account index will '
        'not be reused.',
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
  if (confirmed == true) await controller.deleteAccount(account.id);
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
