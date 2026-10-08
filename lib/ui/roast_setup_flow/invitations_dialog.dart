part of '../roast_setup_flow.dart';

Future<void> _showIssuedInvitations(
  BuildContext context,
  WalletController controller,
  String setupId,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _RoastInvitationsDialog(controller: controller, setupId: setupId),
);

class const _RoastInvitationsDialog({
  required final WalletController controller,
  required final String setupId,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () => [
      for (final invitation in controller.issuedRoastInvitations(setupId))
        (invitation, invitation.statusAt(DateTime.now().toUtc())),
    ],
    builder: (context, _) {
      final invitations = controller.issuedRoastInvitations(setupId);
      final now = DateTime.now().toUtc();
      final joined = invitations
          .where(
            (invitation) =>
                invitation.statusAt(now) == RoastInvitationDisplayStatus.joined,
          )
          .length;
      final unshared = invitations.where((invitation) {
        final status = invitation.statusAt(now);
        return status == RoastInvitationDisplayStatus.ready ||
            status == RoastInvitationDisplayStatus.copied;
      }).length;
      final next = invitations
          .where(
            (invitation) =>
                invitation.statusAt(now) == RoastInvitationDisplayStatus.ready,
          )
          .firstOrNull;
      return AlertDialog(
        title: const Text('Signer invitations'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$joined of ${invitations.length} invitees joined · '
                  '$unshared not shared',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Copied means the invitation was placed on this device\'s '
                  'clipboard. Mark it as sent after sharing it through your '
                  'trusted channel. Joined is verified by the coordinator.',
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                ),
                if (next != null) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('copy-next-roast-invitation'),
                    onPressed: () => _copy(context, next),
                    icon: const Icon(Icons.copy_rounded),
                    label: Text('Copy next: ${next.participantName}'),
                  ),
                ],
                const SizedBox(height: 12),
                for (final invitation in invitations)
                  _RoastInvitationRow(
                    invitation: invitation,
                    status: invitation.statusAt(now),
                    onCopy: () => _copy(context, invitation),
                    onMarkSent: () => controller.markRoastInvitationSent(
                      setupId,
                      invitation.participantPublicKeyHex,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back to wallet'),
          ),
        ],
      );
    },
  );

  Future<void> _copy(
    BuildContext context,
    RoastIssuedInvitation invitation,
  ) async {
    await Clipboard.setData(ClipboardData(text: invitation.encoded));
    await controller.markRoastInvitationCopied(
      setupId,
      invitation.participantPublicKeyHex,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invitation copied for ${invitation.participantName}.'),
        ),
      );
    }
  }
}

class const _RoastInvitationRow({
  required final RoastIssuedInvitation invitation,
  required final RoastInvitationDisplayStatus status,
  required final VoidCallback onCopy,
  required final Future<void> Function() onMarkSent,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (status) {
      RoastInvitationDisplayStatus.ready => (
        'INVITE READY',
        Icons.mail_outline_rounded,
        AppColors.inkMuted,
      ),
      RoastInvitationDisplayStatus.copied => (
        'COPIED',
        Icons.copy_rounded,
        AppColors.warningDark,
      ),
      RoastInvitationDisplayStatus.sent => (
        'SENT',
        Icons.outgoing_mail,
        AppColors.warningDark,
      ),
      RoastInvitationDisplayStatus.joined => (
        'JOINED',
        Icons.check_circle_outline_rounded,
        AppColors.success,
      ),
      RoastInvitationDisplayStatus.expired => (
        'EXPIRED',
        Icons.schedule_rounded,
        AppColors.danger,
      ),
      RoastInvitationDisplayStatus.revoked => (
        'REVOKED',
        Icons.block_rounded,
        AppColors.danger,
      ),
    };
    final canCopy =
        status != RoastInvitationDisplayStatus.joined &&
        status != RoastInvitationDisplayStatus.expired &&
        status != RoastInvitationDisplayStatus.revoked;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(invitation.participantName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            RoastSetupPanel._short(invitation.participantPublicKeyHex),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
      trailing: Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (status == RoastInvitationDisplayStatus.copied)
            TextButton(onPressed: onMarkSent, child: const Text('Mark sent')),
          if (canCopy)
            IconButton(
              tooltip: status == RoastInvitationDisplayStatus.ready
                  ? 'Copy invitation'
                  : 'Copy again',
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded),
            ),
        ],
      ),
    );
  }
}
