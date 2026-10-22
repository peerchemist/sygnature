import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:unique_names_generator/unique_names_generator.dart';

import '../controllers/wallet_controller.dart';
import '../models/roast_setup.dart';
import '../models/wallet_account.dart';
import '../models/wallet_network.dart';
import '../services/roast_runtime_manager.dart';
import '../services/wallet_transaction_service.dart';
import 'app_theme.dart';
import 'widgets/selector_builder.dart';
import 'widgets/share_qr_dialog.dart';

part 'roast_setup_flow/coordinator_dialog.dart';
part 'roast_setup_flow/group_transition_dialog.dart';
part 'roast_setup_flow/creation_dialog.dart';
part 'roast_setup_flow/invite_scanner.dart';
part 'roast_setup_flow/invitations_dialog.dart';
part 'roast_setup_flow/message_dialog.dart';

const _maxRoastParticipants = 32;

bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

final _participantAliasGenerator = UniqueNamesGenerator(
  config: Config(
    length: 2,
    dictionaries: [adjectives, animals],
    separator: ' ',
    style: Style.capital,
  ),
);

List<String> _newParticipantAliases(
  int count, {
  Iterable<String> excluding = const [],
}) {
  final used = excluding.toSet();
  final aliases = <String>[];
  while (aliases.length < count) {
    final alias = _participantAliasGenerator.generate();
    if (used.add(alias)) aliases.add(alias);
  }
  return aliases;
}

Future<bool> _confirmRoastManifest(
  BuildContext context,
  RoastSetup setup, {
  required String confirmLabel,
}) async {
  final fingerprint = setup.groupFingerprintHex;
  final manifest = [
    'Network: ${setup.blockchainId} / ${setup.networkId}',
    'Threshold: ${setup.threshold} of ${setup.participantCount}',
    'Group ID: ${setup.groupId}',
    'Fingerprint: ${fingerprint ?? 'unavailable'}',
    '',
    'Signers:',
    for (final participant in setup.participants) ...[
      '${participant.name}${participant.cardId == setup.localCardId ? ' (you)' : ''}',
      '  Participant ID: ${participant.identifierHex}',
      '  Public key: ${participant.publicKeyHex}',
    ],
  ].join('\n');
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('roast-manifest-confirmation'),
          title: const Text('Verify group manifest'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Compare the fingerprint and signer keys with every '
                    'participant over a trusted channel. Do not continue if '
                    'any value differs.',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    manifest,
                    key: const Key('roast-manifest-details'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-roast-manifest'),
              onPressed: fingerprint == null
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

class const RoastSetupPanel({
  super.key,
  required final WalletController controller,
  required final WalletAccount account,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SelectorBuilder(
    listenable: controller,
    select: () {
      final setup = controller.setupForAccount(account);
      return [
        setup,
        if (setup != null) ...[
          controller.roastOperationInProgress(setup.id),
          controller.roastMessageSigningInProgress(setup.id),
          controller.roastCoordinatorState(setup.id),
          controller.roastCoordinatorRecovery(setup.id),
          controller.recoverableBroadcastForSetup(setup.id),
          for (final participant in setup.participants)
            controller.isRoastParticipantOnline(setup, participant),
        ],
      ];
    },
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final setup = controller.setupForAccount(account);
    if (setup == null) return const SizedBox.shrink();
    final messageSigning = controller.roastMessageSigningInProgress(setup.id);
    final busy =
        controller.roastOperationInProgress(setup.id) || messageSigning;
    final onlineSigners = controller.onlineSignerCount(setup);
    final enrolledSigners = controller.enrolledRoastParticipantCount(setup);
    final coordinatorState = controller.roastCoordinatorState(setup.id);
    final actions = _actions(context, setup, busy);
    final errorMessage = _displayError(setup);
    final memberInstructions = _isMobilePlatform
        ? 'Copy your public key and share it with the person creating the '
              'wallet. When they send back your personal invitation, scan its '
              'QR code or paste it from the clipboard.'
        : 'Copy your public key and share it with the person creating the '
              'wallet. When they send back your personal invitation, copy it '
              'and choose Paste invite from clipboard.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.of(context).lime,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.hub_outlined,
                    color: AppColors.of(context).greenDark,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        setup.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _statusText(setup, enrolledSigners),
                        style: TextStyle(
                          color: AppColors.of(context).inkMuted,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _RoastBadge(setup: setup),
              ],
            ),
            if (setup.isFinalized) ...[
              const SizedBox(height: 14),
              _CoordinatorConnectionStatus(
                key: ValueKey('${setup.id}-${coordinatorState.name}'),
                state: coordinatorState,
                endpointId: setup.coordinatorId,
              ),
              if (setup.role == RoastSetupRole.host &&
                  setup.invitations.isNotEmpty) ...[
                _RoastEnrollmentProgress(
                  key: ValueKey(setup.id),
                  joined: enrolledSigners,
                  total: setup.participantCount,
                ),
              ],
              const SizedBox(height: 18),
              _SwarmHealth(
                online: onlineSigners,
                total: setup.participantCount,
                requiredSigners: setup.threshold,
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.of(context).canvas,
                  border: Border.all(color: AppColors.of(context).line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                      child: Row(
                        children: [
                          Text(
                            'SIGNERS',
                            style: TextStyle(
                              color: AppColors.of(context).inkMuted,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.9,
                            ),
                          ),
                          const Spacer(),
                          Tooltip(
                            message: setup.groupFingerprintHex ?? 'Pending',
                            child: Text(
                              'GROUP  ${_short(setup.groupFingerprintHex ?? 'pending')}',
                              style: TextStyle(
                                color: AppColors.of(context).inkMuted,
                                fontFamily: 'monospace',
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    for (
                      var index = 0;
                      index < setup.participants.length;
                      index++
                    ) ...[
                      _RoastParticipantRow(
                        participant: setup.participants[index],
                        online: controller.isRoastParticipantOnline(
                          setup,
                          setup.participants[index],
                        ),
                        local:
                            setup.participants[index].cardId ==
                            setup.localCardId,
                      ),
                      if (index < setup.participants.length - 1)
                        const Padding(
                          padding: EdgeInsets.only(left: 42),
                          child: Divider(height: 1),
                        ),
                    ],
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.of(context).canvas,
                  border: Border.all(color: AppColors.of(context).line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.construction_rounded,
                      color: AppColors.of(context).warningDark,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        setup.role == RoastSetupRole.host
                            ? 'Complete the signer roster to start the swarm.'
                            : memberInstructions,
                        style: TextStyle(
                          color: AppColors.of(context).inkMuted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (errorMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                key: const Key('roast-setup-error'),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.of(context).dangerSurface,
                  border: Border.all(
                    color: AppColors.of(context).danger.withValues(alpha: 0.3),
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.of(context).danger,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ACTION REQUIRED',
                            style: TextStyle(
                              color: AppColors.of(context).danger,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            errorMessage,
                            style: TextStyle(
                              color: AppColors.of(context).ink,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 10, runSpacing: 10, children: actions),
            ],
            if (busy) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context, RoastSetup setup, bool busy) {
    if (setup.requiresBackupReconciliation) {
      return [
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Reconcile restored group'),
                      content: SingleChildScrollView(
                        child: Text(
                          'Compare these values with authenticated live participants before continuing. '
                          'A backup cannot prove that this is the latest group. If any value differs, '
                          'cancel and reconcile with the live group. Stop other copies of this signer.\n\n'
                          'Group: ${setup.groupId}\nFingerprint: ${setup.groupFingerprintHex}\n'
                          'Threshold: ${setup.threshold} of ${setup.participantCount}\n'
                          'Group key: ${setup.groupKeyHex}\nCoordinator: ${setup.coordinatorId}\n\n'
                          '${setup.participants.map((p) => '${p.name}: ${p.identifierHex} / ${p.publicKeyHex}').join('\n')}',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Live group matches'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true && context.mounted) {
                    await _perform(
                      context,
                      () =>
                          controller.confirmBackupGroupReconciliation(setup.id),
                    );
                  }
                },
          child: const Text('Verify restored group'),
        ),
      ];
    }
    final coordinatorRecovery = controller.roastCoordinatorRecovery(setup.id);
    if (coordinatorRecovery != null) {
      return [
        FilledButton.icon(
          key: const Key('retry-coordinator-connection'),
          onPressed: busy
              ? null
              : () => _perform(
                  context,
                  () => controller.resumeRoastSetup(setup.id),
                ),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Restart signer with saved coordinator'),
        ),
      ];
    }
    final recoverableBroadcast = controller.recoverableBroadcastForSetup(
      setup.id,
    );
    if (recoverableBroadcast != null) {
      return [
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => _perform(
                  context,
                  () => controller.retryRoastBroadcast(recoverableBroadcast),
                ),
          icon: const Icon(Icons.send_rounded),
          label: const Text('Retry saved broadcast'),
        ),
      ];
    }
    if (setup.needsInvitationCreation) {
      return [
        FilledButton.icon(
          key: const Key('retry-roast-invitations'),
          onPressed: busy
              ? null
              : () => _perform(context, () async {
                  await controller.retryHostedRoastInvitations(setup.id);
                  if (context.mounted) {
                    await _showIssuedInvitations(context, controller, setup.id);
                  }
                }),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry creating invitations'),
        ),
      ];
    }
    if (setup.status == RoastSetupStatus.draft) {
      if (setup.role == RoastSetupRole.host) {
        return [
          FilledButton.icon(
            key: const Key('create-roast-invitations'),
            onPressed: busy
                ? null
                : () => _finalizeHostSetup(context, controller, setup),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Create signer invitations'),
          ),
        ];
      }
      return [
        OutlinedButton.icon(
          onPressed: () => _copy(
            context,
            controller.participantPublicKey(setup.id),
            'Signer public key copied.',
          ),
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy my public key'),
        ),
        if (_isMobilePlatform)
          OutlinedButton.icon(
            key: const Key('scan-roast-invitation'),
            onPressed: busy ? null : () => _scanAndJoin(context, setup),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan invite QR code'),
          ),
        FilledButton(
          onPressed: busy ? null : () => _join(context, setup),
          child: const Text('Paste invite from clipboard'),
        ),
      ];
    }
    if (setup.role == RoastSetupRole.host &&
        (setup.status == RoastSetupStatus.connecting ||
            setup.status == RoastSetupStatus.ready)) {
      final invitations = controller.issuedRoastInvitations(setup.id);
      return [
        if (invitations.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () =>
                _showIssuedInvitations(context, controller, setup.id),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Manage invitations'),
          ),
        if (setup.status == RoastSetupStatus.ready)
          FilledButton(
            onPressed:
                busy ||
                    controller.enrolledRoastParticipantCount(setup) <
                        setup.participantCount ||
                    controller.onlineSignerCount(setup) < setup.participantCount
                ? null
                : () async {
                    final confirmed = await _confirmRoastManifest(
                      context,
                      setup,
                      confirmLabel: 'I verified — create request',
                    );
                    if (confirmed && context.mounted) {
                      await _perform(
                        context,
                        () => controller.startRoastDkg(
                          setup.id,
                          confirmedGroupFingerprintHex:
                              setup.groupFingerprintHex!,
                        ),
                      );
                    }
                  },
            child: const Text('Create shared key'),
          ),
      ];
    }
    if (setup.status == RoastSetupStatus.error ||
        setup.status == RoastSetupStatus.interrupted) {
      return [
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => _perform(
                  context,
                  () => controller.resumeRoastSetup(setup.id),
                ),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Reconnect'),
        ),
      ];
    }
    return const [];
  }

  Future<void> _scanAndJoin(BuildContext context, RoastSetup setup) async {
    final invitation = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _RoastInviteScanner(),
      ),
    );
    if (invitation != null && context.mounted) {
      await _join(context, setup, invitation: invitation);
    }
  }

  Future<void> _join(
    BuildContext context,
    RoastSetup setup, {
    String? invitation,
  }) async {
    await _perform(context, () async {
      final encoded =
          invitation?.trim() ??
          (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
      if (encoded == null || encoded.isEmpty) {
        throw const FormatException(
          'The clipboard does not contain a ROAST invitation.',
        );
      }
      await controller.joinRoastSetup(setup.id, encoded);
    });
  }

  static Future<void> _perform(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The ROAST operation failed.')),
        );
      }
    }
  }

  static Future<void> _copy(
    BuildContext context,
    String value,
    String message,
  ) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  static String _statusText(RoastSetup setup, int enrolledSigners) =>
      switch (setup.status) {
        RoastSetupStatus.draft when setup.role == RoastSetupRole.host =>
          'Add signers and create their invitations',
        RoastSetupStatus.draft =>
          'Share your signer public key, then wait for your bound invite',
        RoastSetupStatus.ready
            when setup.role == RoastSetupRole.host &&
                enrolledSigners >= setup.participantCount =>
          'All $enrolledSigners signers joined · coordinator online',
        RoastSetupStatus.ready when setup.role == RoastSetupRole.host =>
          'Room open · $enrolledSigners of '
              '${setup.participantCount} signers joined',
        RoastSetupStatus.ready =>
          'Connected · waiting for the host to create the shared key',
        RoastSetupStatus.connecting when setup.needsInvitationCreation =>
          'Signer invitations are waiting to be created',
        RoastSetupStatus.connecting when setup.role == RoastSetupRole.host =>
          'Room open · $enrolledSigners of '
              '${setup.participantCount} signers joined',
        RoastSetupStatus.connecting => 'Joining room through Iroh…',
        RoastSetupStatus.awaitingDkgApproval =>
          'Review and approve shared-key creation',
        RoastSetupStatus.creatingKey => _creatingKeyStatus(setup),
        RoastSetupStatus.active => 'Shared key secured on this device',
        RoastSetupStatus.interrupted => 'ROAST operation was interrupted',
        RoastSetupStatus.error when setup.needsInvitationCreation =>
          'Signer invitations need attention',
        RoastSetupStatus.error => 'ROAST setup needs attention',
      };

  static String _creatingKeyStatus(RoastSetup setup) {
    if (setup.pendingDkgProposalHex == null) {
      return 'Submitting shared-key request…';
    }
    if (setup.pendingDkgStage == 'round1') {
      final confirmed = setup.pendingDkgCompletedParticipantIds.length;
      if (confirmed < setup.participantCount) {
        return 'Waiting for DKG approvals · '
            '$confirmed of ${setup.participantCount} confirmed';
      }
      return 'All signers approved · preparing shared key…';
    }
    if (setup.pendingDkgStage == 'round2') {
      return 'All signers approved · generating shared key…';
    }
    return 'Creating shared key with ROAST…';
  }

  static String? _displayError(RoastSetup setup) {
    final message = setup.errorMessage?.trim();
    if (message != null &&
        message.isNotEmpty &&
        message.toLowerCase() != 'null') {
      if (message == 'Worker exited; in-flight mutations were not replayed.') {
        return 'The ROAST signing service stopped unexpectedly. Reconnect, '
            'then review any pending signing request before trying again.';
      }
      return message;
    }
    return switch (setup.status) {
      RoastSetupStatus.error =>
        'The last ROAST operation failed. Reconnect and try again.',
      RoastSetupStatus.interrupted =>
        'The ROAST connection was interrupted. Reconnect to restore it.',
      _ => null,
    };
  }

  static String _short(String value) => value.length <= 18
      ? value
      : '${value.substring(0, 8)}…${value.substring(value.length - 8)}';

  static String _creatorLabel(RoastSetup setup) {
    final creatorId = setup.pendingDkgCreatorId;
    if (creatorId == null) return 'unknown';
    for (final participant in setup.participants) {
      if (participant.identifierHex != creatorId) continue;
      return participant.cardId == setup.localCardId
          ? '${participant.name} (you)'
          : participant.name;
    }
    return _short(creatorId);
  }
}

class const _CoordinatorConnectionStatus({
  super.key,
  required final RoastCoordinatorLocalState state,
  required final String? endpointId,
}) extends StatefulWidget {
  @override
  State<_CoordinatorConnectionStatus> createState() =>
      _CoordinatorConnectionStatusState();
}

class _CoordinatorConnectionStatusState
    extends State<_CoordinatorConnectionStatus> {
  var _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final (label, detail, icon, color) = switch (widget.state) {
      RoastCoordinatorLocalState.switching => (
        'Switching coordinator',
        'The signer is stopped while the approved selection is saved.',
        Icons.sync_rounded,
        AppColors.of(context).warningDark,
      ),
      RoastCoordinatorLocalState.connected => (
        'Signer connected',
        'This device is connected to its saved coordinator.',
        Icons.link_rounded,
        AppColors.of(context).success,
      ),
      RoastCoordinatorLocalState.stopped => (
        'Signer stopped',
        'This device is not currently connected to its saved coordinator.',
        Icons.link_off_rounded,
        AppColors.of(context).inkMuted,
      ),
      RoastCoordinatorLocalState.recoveryRequired => (
        'Coordinator recovery required',
        'The signer is stopped. Use the durable selection shown below.',
        Icons.warning_amber_rounded,
        AppColors.of(context).danger,
      ),
    };
    return Container(
      key: ValueKey('coordinator-${widget.state.name}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: AppColors.of(context).inkMuted,
                    fontSize: 12,
                  ),
                ),
                if (widget.endpointId != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Coordinator ID ${RoastSetupPanel._short(widget.endpointId!)}',
                    style: TextStyle(
                      color: AppColors.of(context).inkMuted,
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          _DismissButton(
            tooltip: 'Dismiss coordinator status',
            onPressed: () => setState(() => _dismissed = true),
          ),
        ],
      ),
    );
  }
}

class const RoastDkgRequestCard({
  super.key,
  required final WalletController controller,
  required final RoastSetup setup,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final busy = controller.roastOperationInProgress(setup.id);
    return Card(
      key: const Key('roast-dkg-request-card'),
      color: AppColors.of(context).warning,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.of(context).warningDark),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.key_rounded,
                  color: AppColors.of(context).warningDark,
                  size: 22,
                ),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'DKG REQUEST · ACTION REQUIRED',
                    style: TextStyle(
                      color: AppColors.of(context).warningDark,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.7,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Approve shared-key creation for ${setup.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Proposal ${setup.pendingDkgName ?? 'unknown'} · '
              '${setup.pendingDkgThreshold ?? 0} required · creator '
              '${RoastSetupPanel._creatorLabel(setup)} · expires '
              '${setup.pendingDkgExpiry?.toLocal() ?? 'unknown'}',
              style: TextStyle(
                color: AppColors.of(context).ink,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => RoastSetupPanel._perform(
                          context,
                          () => controller.rejectRoastDkg(setup.id),
                        ),
                  child: const Text('Reject key creation'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final confirmed = await _confirmRoastManifest(
                            context,
                            setup,
                            confirmLabel: 'I verified — approve',
                          );
                          if (confirmed && context.mounted) {
                            await RoastSetupPanel._perform(
                              context,
                              () => controller.acceptRoastDkg(
                                setup.id,
                                confirmedGroupFingerprintHex:
                                    setup.groupFingerprintHex!,
                              ),
                            );
                          }
                        },
                  child: const Text('Review group manifest'),
                ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }
}

class const _RoastEnrollmentProgress({
  super.key,
  required final int joined,
  required final int total,
}) extends StatefulWidget {
  @override
  State<_RoastEnrollmentProgress> createState() =>
      _RoastEnrollmentProgressState();
}

class _RoastEnrollmentProgressState extends State<_RoastEnrollmentProgress> {
  var _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final complete = widget.joined >= widget.total;
    final color = complete
        ? AppColors.of(context).success
        : AppColors.of(context).forest;
    final progress = widget.total == 0
        ? 0.0
        : (widget.joined / widget.total).clamp(0.0, 1.0).toDouble();

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Semantics(
        label: 'Signer enrollment: ${widget.joined} of ${widget.total} joined.',
        child: Container(
          key: const Key('roast-enrollment-progress'),
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: complete
                ? AppColors.of(context).successSurface
                : AppColors.of(context).surface,
            border: Border.all(color: color.withValues(alpha: 0.28)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    complete ? Icons.how_to_reg : Icons.group_add_outlined,
                    size: 18,
                    color: color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'SIGNER ENROLLMENT',
                      style: TextStyle(
                        color: AppColors.of(context).inkMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.joined}/${widget.total}',
                    style: TextStyle(color: color, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 6),
                  _DismissButton(
                    tooltip: 'Dismiss signer enrollment',
                    onPressed: () => setState(() => _dismissed = true),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                color: color,
                backgroundColor: color.withValues(alpha: 0.14),
              ),
              const SizedBox(height: 8),
              Text(
                complete
                    ? 'All signers have joined the room.'
                    : '${widget.joined} of ${widget.total} signers have joined the room.',
                style: TextStyle(
                  color: AppColors.of(context).inkMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class const _DismissButton({
  required final String tooltip,
  required final VoidCallback onPressed,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: const Icon(Icons.close_rounded),
    iconSize: 16,
    color: AppColors.of(context).inkMuted,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 24, height: 24),
  );
}

class const _SwarmHealth({
  required final int online,
  required final int total,
  required final int requiredSigners,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final healthy = online == total;
    final hasQuorum = online >= requiredSigners;
    final color = healthy
        ? AppColors.of(context).success
        : hasQuorum
        ? AppColors.of(context).warningDark
        : AppColors.of(context).danger;
    final surface = healthy
        ? AppColors.of(context).successSurface
        : hasQuorum
        ? AppColors.of(context).warning
        : AppColors.of(context).dangerSurface;
    final label = healthy
        ? 'Healthy'
        : hasQuorum
        ? 'Degraded'
        : 'Unavailable';
    final missingForQuorum = (requiredSigners - online).clamp(
      0,
      requiredSigners,
    );
    final offline = (total - online).clamp(0, total);
    final detail = healthy
        ? 'All $total signers are online.'
        : hasQuorum
        ? '$offline ${offline == 1 ? 'signer is' : 'signers are'} offline. Quorum is still available.'
        : '$missingForQuorum more ${missingForQuorum == 1 ? 'signer is' : 'signers are'} needed for quorum.';
    final progress = total == 0
        ? 0.0
        : (online / total).clamp(0.0, 1.0).toDouble();

    return Semantics(
      label:
          'ROAST swarm health: $label. $online of $total signers online. '
          '$requiredSigners required.',
      child: Container(
        key: ValueKey('roast-swarm-health-${label.toLowerCase()}'),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: surface,
          border: Border.all(color: color.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 80,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.square(
                    dimension: 72,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 8,
                      strokeCap: StrokeCap.round,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.14),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$online/$total',
                        style: TextStyle(
                          color: color,
                          fontSize: 19,
                          height: 1,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'ONLINE',
                        style: TextStyle(
                          color: color,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SWARM HEALTH',
                    style: TextStyle(
                      color: AppColors.of(context).inkMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.9,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          color: color,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: TextStyle(
                      color: AppColors.of(context).ink,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$requiredSigners required to sign',
                    style: TextStyle(
                      color: AppColors.of(context).inkMuted,
                      fontSize: 10,
                    ),
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

class const _RoastParticipantRow({
  required final RoastParticipant participant,
  required final bool online,
  required final bool local,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final color = online
        ? AppColors.of(context).success
        : AppColors.of(context).danger;
    return Semantics(
      label: '${participant.name}, ${online ? 'online' : 'offline'}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.22),
                    blurRadius: 0,
                    spreadRadius: 3,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: InkWell(
                key: ValueKey(
                  'copy-roast-participant-public-key-${participant.cardId}',
                ),
                onTap: () => RoastSetupPanel._copy(
                  context,
                  participant.publicKeyHex,
                  'Signer public key copied.',
                ),
                borderRadius: BorderRadius.circular(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            participant.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.of(context).ink,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (local) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.of(context).lime,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              'YOU',
                              style: TextStyle(
                                color: AppColors.of(context).greenDark,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Tooltip(
                      message: participant.publicKeyHex,
                      child: Text(
                        RoastSetupPanel._short(participant.publicKeyHex),
                        style: TextStyle(
                          color: AppColors.of(context).inkMuted,
                          fontFamily: 'monospace',
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              online ? 'ONLINE' : 'OFFLINE',
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class const _RoastBadge({required final RoastSetup setup})
    extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.of(context).lime,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      setup.isWaitingForInvitation
          ? 'ROAST'
          : 'ROAST · ${setup.threshold} of ${setup.participantCount}',
      style: TextStyle(
        color: AppColors.of(context).greenDark,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
