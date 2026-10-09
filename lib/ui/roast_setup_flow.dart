import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:unique_names_generator/unique_names_generator.dart';

import '../controllers/wallet_controller.dart';
import '../models/roast_setup.dart';
import '../models/wallet_account.dart';
import '../models/wallet_network.dart';
import '../services/roast_runtime_manager.dart';
import 'app_theme.dart';
import 'widgets/selector_builder.dart';

part 'roast_setup_flow/coordinator_dialog.dart';
part 'roast_setup_flow/group_transition_dialog.dart';
part 'roast_setup_flow/creation_dialog.dart';
part 'roast_setup_flow/invitations_dialog.dart';
part 'roast_setup_flow/message_dialog.dart';

const _maxRoastParticipants = 32;

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
                    color: AppColors.lime,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.hub_outlined,
                    color: AppColors.greenDark,
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
                        style: const TextStyle(
                          color: AppColors.inkMuted,
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
                  color: AppColors.canvas,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                      child: Row(
                        children: [
                          const Text(
                            'SIGNERS',
                            style: TextStyle(
                              color: AppColors.inkMuted,
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
                              style: const TextStyle(
                                color: AppColors.inkMuted,
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
                  color: AppColors.canvas,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.construction_rounded,
                      color: AppColors.warningDark,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        setup.role == RoastSetupRole.host
                            ? 'Complete the signer roster to start the swarm.'
                            : 'Import your participant-bound invite to join the swarm.',
                        style: const TextStyle(
                          color: AppColors.inkMuted,
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
                  color: AppColors.dangerSurface,
                  border: Border.all(
                    color: AppColors.danger.withValues(alpha: 0.3),
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.danger,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ACTION REQUIRED',
                            style: TextStyle(
                              color: AppColors.danger,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            errorMessage,
                            style: const TextStyle(
                              color: AppColors.ink,
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
                : () => _perform(
                    context,
                    () => controller.startRoastDkg(setup.id),
                  ),
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

  Future<void> _join(BuildContext context, RoastSetup setup) async {
    await _perform(context, () async {
      final invitation = (await Clipboard.getData(Clipboard.kTextPlain))?.text
          ?.trim();
      if (invitation == null || invitation.isEmpty) {
        throw const FormatException(
          'The clipboard does not contain a ROAST invitation.',
        );
      }
      await controller.joinRoastSetup(setup.id, invitation);
    });
  }

  static Future<void> _perform(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
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
        RoastSetupStatus.connecting when setup.role == RoastSetupRole.host =>
          'Room open · $enrolledSigners of '
              '${setup.participantCount} signers joined',
        RoastSetupStatus.connecting => 'Joining room through Iroh…',
        RoastSetupStatus.awaitingDkgApproval =>
          'Review and approve shared-key creation',
        RoastSetupStatus.creatingKey => _creatingKeyStatus(setup),
        RoastSetupStatus.active => 'Shared key secured on this device',
        RoastSetupStatus.interrupted => 'ROAST operation was interrupted',
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
        AppColors.warningDark,
      ),
      RoastCoordinatorLocalState.connected => (
        'Signer connected',
        'This device is connected to its saved coordinator.',
        Icons.link_rounded,
        AppColors.success,
      ),
      RoastCoordinatorLocalState.stopped => (
        'Signer stopped',
        'This device is not currently connected to its saved coordinator.',
        Icons.link_off_rounded,
        AppColors.inkMuted,
      ),
      RoastCoordinatorLocalState.recoveryRequired => (
        'Coordinator recovery required',
        'The signer is stopped. Use the durable selection shown below.',
        Icons.warning_amber_rounded,
        AppColors.danger,
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
                  style: const TextStyle(
                    color: AppColors.inkMuted,
                    fontSize: 12,
                  ),
                ),
                if (widget.endpointId != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Coordinator ID ${RoastSetupPanel._short(widget.endpointId!)}',
                    style: const TextStyle(
                      color: AppColors.inkMuted,
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
      color: AppColors.warning,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppColors.warningDark),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.key_rounded, color: AppColors.warningDark, size: 22),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'DKG REQUEST · ACTION REQUIRED',
                    style: TextStyle(
                      color: AppColors.warningDark,
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
              style: const TextStyle(
                color: AppColors.ink,
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
                      : () => RoastSetupPanel._perform(
                          context,
                          () => controller.acceptRoastDkg(setup.id),
                        ),
                  child: const Text('Approve key creation'),
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
    final color = complete ? AppColors.success : AppColors.forest;
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
            color: complete ? AppColors.successSurface : AppColors.surface,
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
                  const Expanded(
                    child: Text(
                      'SIGNER ENROLLMENT',
                      style: TextStyle(
                        color: AppColors.inkMuted,
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
                style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
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
    color: AppColors.inkMuted,
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
        ? AppColors.success
        : hasQuorum
        ? AppColors.warningDark
        : AppColors.danger;
    final surface = healthy
        ? AppColors.successSurface
        : hasQuorum
        ? AppColors.warning
        : AppColors.dangerSurface;
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
                  const Text(
                    'SWARM HEALTH',
                    style: TextStyle(
                      color: AppColors.inkMuted,
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
                    style: const TextStyle(
                      color: AppColors.ink,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$requiredSigners required to sign',
                    style: const TextStyle(
                      color: AppColors.inkMuted,
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
    final color = online ? AppColors.success : AppColors.danger;
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
                            style: const TextStyle(
                              color: AppColors.ink,
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
                              color: AppColors.lime,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              'YOU',
                              style: TextStyle(
                                color: AppColors.greenDark,
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
                        style: const TextStyle(
                          color: AppColors.inkMuted,
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
      color: AppColors.green.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      setup.isWaitingForInvitation
          ? 'ROAST'
          : 'ROAST · ${setup.threshold} of ${setup.participantCount}',
      style: const TextStyle(
        color: AppColors.greenDark,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
