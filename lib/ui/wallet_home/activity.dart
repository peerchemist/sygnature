part of '../wallet_home.dart';

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.controller, required this.account});

  final WalletController controller;
  final WalletAccount account;

  @override
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () => controller.activitiesFor(account),
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
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
                _ActivityRow(
                  activity: activities[index],
                  account: account,
                  controller: controller,
                ),
                if (index != activities.length - 1) const Divider(height: 1),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class const _ActivityRow({
  required final WalletActivity activity,
  required final WalletAccount account,
  required final WalletController controller,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final presentation = _activityPresentation(activity);
    final reference = activity.reference;
    final signedMessage = _signedMessageFromActivity(activity);
    return InkWell(
      key: Key('activity-${activity.id}'),
      onTap: () => signedMessage == null
          ? _showActivityDetails(
              context,
              activity: activity,
              account: account,
              controller: controller,
            )
          : showRoastSignMessageDialog(
              context,
              controller,
              account,
              result: signedMessage,
            ),
      child: Padding(
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
              child: Icon(
                presentation.icon,
                size: 20,
                color: presentation.color,
              ),
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
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.inkMuted,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

RoastSignedMessage? _signedMessageFromActivity(WalletActivity activity) {
  final publicKeyHex = activity.signedMessagePublicKeyHex;
  final signatureHex = activity.signedMessageSignatureHex;
  final encoded = activity.signedMessageEncoded;
  if (activity.type != WalletActivityType.messageSigned ||
      publicKeyHex == null ||
      signatureHex == null ||
      encoded == null) {
    return null;
  }
  return RoastSignedMessage(
    text: activity.details ?? '',
    publicKeyHex: publicKeyHex,
    signatureHex: signatureHex,
    encoded: encoded,
  );
}

Future<void> _showActivityDetails(
  BuildContext context, {
  required WalletActivity activity,
  required WalletAccount account,
  required WalletController controller,
}) {
  final presentation = _activityPresentation(activity);
  final setup = controller.setupForAccount(account);
  final reference = switch (activity.type) {
    WalletActivityType.messageSignatureRequested ||
    WalletActivityType.messageSigned => null,
    _ => activity.reference,
  };
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('activity-details-dialog'),
      title: Text(presentation.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ActivityDetail(label: 'Wallet', value: account.name),
              _ActivityDetail(
                label: 'Created',
                value: _activityDateTime(activity.occurredAt),
              ),
              if (setup != null) ...[
                _ActivityDetail(label: 'Signer group', value: setup.name),
                _ActivityDetail(
                  label: 'Signers required',
                  value: '${setup.threshold} of ${setup.participantCount}',
                ),
              ],
              if (activity.transactionStatus case final status?)
                _ActivityDetail(
                  label: 'Transaction status',
                  value: _transactionStatusLabel(status),
                ),
              if (activity.blockHeight case final height?)
                _ActivityDetail(label: 'Block height', value: '$height'),
              for (
                var index = 0;
                index < activity.transactionRecipients.length;
                index++
              )
                _ActivityDetail(
                  label: activity.transactionRecipients.length == 1
                      ? 'Recipient'
                      : 'Recipient ${index + 1}',
                  value:
                      '${activity.transactionRecipients[index].address}\n'
                      '${_formatPpc(activity.transactionRecipients[index].amountSats)} PPC',
                ),
              if (activity.transactionFeeSats case final feeSats?)
                _ActivityDetail(
                  label: 'Network fee',
                  value: '${_formatPpc(feeSats)} PPC',
                ),
              if (activity.details case final details?)
                _ActivityDetail(
                  label:
                      activity.type ==
                              WalletActivityType.messageSignatureRequested ||
                          activity.type == WalletActivityType.messageSigned
                      ? 'Message'
                      : 'Details',
                  value: details,
                ),
              if (reference != null)
                _ActivityDetail(
                  label: _activityReferenceLabel(activity.type),
                  value: reference,
                ),
              _ActivityDetail(label: 'Event ID', value: activity.id),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class const _ActivityDetail({
  required final String label,
  required final String value,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: AppColors.inkMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(
          value,
          style: const TextStyle(color: AppColors.ink, fontSize: 13),
        ),
      ],
    ),
  );
}

({String title, IconData icon, Color color}) _activityPresentation(
  WalletActivity activity,
) => switch (activity.type) {
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
  WalletActivityType.transactionSignatureRequested => (
    title: 'Transaction signature requested',
    icon: Icons.pending_actions_outlined,
    color: AppColors.greenDark,
  ),
  WalletActivityType.transactionSigned => (
    title: 'Transaction signed',
    icon: Icons.draw_outlined,
    color: AppColors.greenDark,
  ),
  WalletActivityType.transactionBroadcast => (
    title: switch (activity.transactionStatus) {
      WalletTransactionStatus.broadcasting => 'Broadcasting transaction…',
      WalletTransactionStatus.mempool => 'Transaction in mempool',
      WalletTransactionStatus.confirmed => 'Transaction confirmed',
      WalletTransactionStatus.failed => 'Transaction failed',
      WalletTransactionStatus.broadcast || null => 'Transaction broadcast',
    },
    icon: switch (activity.transactionStatus) {
      WalletTransactionStatus.broadcasting => Icons.sync_rounded,
      WalletTransactionStatus.mempool => Icons.hourglass_top_rounded,
      WalletTransactionStatus.confirmed => Icons.verified_outlined,
      WalletTransactionStatus.failed => Icons.error_outline,
      WalletTransactionStatus.broadcast || null => Icons.send_outlined,
    },
    color: switch (activity.transactionStatus) {
      WalletTransactionStatus.broadcasting ||
      WalletTransactionStatus.mempool => AppColors.warningDark,
      WalletTransactionStatus.failed => AppColors.danger,
      WalletTransactionStatus.broadcast ||
      WalletTransactionStatus.confirmed ||
      null => AppColors.success,
    },
  ),
  WalletActivityType.messageSignatureRequested => (
    title: 'Message signature requested',
    icon: Icons.pending_actions_outlined,
    color: AppColors.greenDark,
  ),
  WalletActivityType.messageSigned => (
    title: 'Message signed',
    icon: Icons.verified_outlined,
    color: AppColors.success,
  ),
};

String _activityReference(WalletActivityType type, String value) {
  return '${_activityReferenceLabel(type)} ${_shortTransactionId(value)}';
}

String _activityReferenceLabel(WalletActivityType type) => switch (type) {
  WalletActivityType.dkgStarted ||
  WalletActivityType.dkgCompleted ||
  WalletActivityType.dkgFailed => 'DKG',
  WalletActivityType.transactionSignatureRequested => 'Transaction request',
  WalletActivityType.transactionSigned ||
  WalletActivityType.transactionBroadcast => 'Transaction',
  WalletActivityType.messageSignatureRequested ||
  WalletActivityType.messageSigned => 'Message request',
  _ => 'Request',
};

String _transactionStatusLabel(WalletTransactionStatus status) =>
    switch (status) {
      WalletTransactionStatus.broadcasting => 'Broadcasting',
      WalletTransactionStatus.broadcast => 'Broadcast',
      WalletTransactionStatus.mempool => 'In mempool',
      WalletTransactionStatus.confirmed => 'Confirmed',
      WalletTransactionStatus.failed => 'Failed',
    };

String _activityDateTime(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.'
      '${local.month.toString().padLeft(2, '0')}.${local.year}. · '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
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
