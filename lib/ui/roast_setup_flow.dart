import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/wallet_controller.dart';
import '../models/roast_setup.dart';
import '../models/wallet_account.dart';
import '../models/wallet_network.dart';
import 'app_theme.dart';

Future<void> showRoastSetupCreation(
  BuildContext context,
  WalletController controller,
) async {
  if (!controller.roastAvailable) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ROAST is currently available on Linux and macOS.'),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _RoastCreationDialog(controller: controller),
  );
}

class const _RoastCreationDialog({required final WalletController controller})
    extends StatefulWidget {
  @override
  State<_RoastCreationDialog> createState() => _RoastCreationDialogState();
}

class _RoastCreationDialogState extends State<_RoastCreationDialog> {
  late final TextEditingController _setupName = TextEditingController(
    text: 'Shared setup',
  );
  late final TextEditingController _walletName = TextEditingController(
    text: 'Shared wallet',
  );
  late final TextEditingController _participantName = TextEditingController(
    text: 'This device',
  );
  late WalletNetwork _network = widget.controller.supportedNetworks.first;
  RoastSetupRole _role = RoastSetupRole.host;
  int _participantCount = 2;
  int _threshold = 2;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _setupName.dispose();
    _walletName.dispose();
    _participantName.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_participantName.text.trim().isEmpty ||
        _walletName.text.trim().isEmpty ||
        (_role == RoastSetupRole.host && _setupName.text.trim().isEmpty)) {
      setState(() => _error = 'Complete all names before continuing.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.createRoastSetupDraft(
        role: _role,
        setupName: _setupName.text,
        walletName: _walletName.text,
        participantName: _participantName.text,
        threshold: _threshold,
        participantCount: _participantCount,
        network: _network,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('ROAST shared wallet'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Create a threshold wallet with authenticated participants over '
              'Iroh. No device ever holds the complete private key.',
            ),
            const SizedBox(height: 18),
            SegmentedButton<RoastSetupRole>(
              segments: const [
                ButtonSegment(
                  value: RoastSetupRole.host,
                  label: Text('Host coordinator'),
                  icon: Icon(Icons.dns_outlined),
                ),
                ButtonSegment(
                  value: RoastSetupRole.member,
                  label: Text('Join setup'),
                  icon: Icon(Icons.link_rounded),
                ),
              ],
              selected: {_role},
              onSelectionChanged: (value) => setState(() {
                _role = value.single;
                _error = null;
              }),
            ),
            const SizedBox(height: 18),
            if (_role == RoastSetupRole.host) ...[
              TextField(
                key: const Key('roast-setup-name'),
                controller: _setupName,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Setup name'),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              key: const Key('roast-wallet-name'),
              controller: _walletName,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Wallet name'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('roast-participant-name'),
              controller: _participantName,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: 'Your participant name',
              ),
            ),
            if (_role == RoastSetupRole.host) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<WalletNetwork>(
                initialValue: _network,
                decoration: const InputDecoration(
                  labelText: 'Blockchain network',
                ),
                items: widget.controller.supportedNetworks
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
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _participantCount,
                      decoration: const InputDecoration(
                        labelText: 'Participants',
                      ),
                      items: [2, 3, 4, 5]
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text('$value'),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) => setState(() {
                        _participantCount = value!;
                        if (_threshold > value) _threshold = value;
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _threshold,
                      decoration: const InputDecoration(
                        labelText: 'Required signers',
                      ),
                      items: [
                        for (var value = 2; value <= _participantCount; value++)
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value of $_participantCount'),
                          ),
                      ],
                      onChanged: (value) => setState(() => _threshold = value!),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              _role == RoastSetupRole.host
                  ? 'This device must stay online while participants create '
                        'keys or sign. The next step exchanges participant '
                        'cards before the coordinator starts.'
                  : 'A participant key is generated on this device. Share its '
                        'public card with the host, then paste the finalized '
                        'invitation.',
              style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('create-roast-draft'),
        onPressed: _busy ? null : _create,
        child: Text(_busy ? 'Creating…' : 'Create setup draft'),
      ),
    ],
  );
}

class const RoastSetupPanel({
  super.key,
  required final WalletController controller,
  required final WalletAccount account,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final setup = controller.setupForAccount(account);
    if (setup == null) return const SizedBox.shrink();
    final busy = controller.roastOperationInProgress(setup.id);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.hub_outlined, color: AppColors.greenDark),
                Text(
                  setup.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _RoastBadge(setup: setup),
              ],
            ),
            const SizedBox(height: 10),
            Text(_statusText(setup), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Text(
              '${controller.onlineSignerCount(setup)} of '
              '${setup.participantCount} signers online · '
              '${setup.threshold} required',
              style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
            ),
            if (setup.isFinalized) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Group ${_short(setup.groupFingerprintHex ?? 'pending')}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final participant in setup.participants)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${participant.name} · '
                          '${_short(participant.publicKeyHex)}',
                          style: const TextStyle(
                            color: AppColors.inkMuted,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (setup.errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                setup.errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
            if (setup.status == RoastSetupStatus.awaitingDkgApproval) ...[
              const SizedBox(height: 12),
              Text(
                'Proposal ${setup.pendingDkgName ?? 'unknown'} · '
                '${setup.pendingDkgThreshold ?? 0} required · creator '
                '${_short(setup.pendingDkgCreatorId ?? 'unknown')} · expires '
                '${setup.pendingDkgExpiry?.toLocal() ?? 'unknown'}',
                style: const TextStyle(
                  color: AppColors.inkMuted,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _actions(context, setup, busy),
            ),
            if (busy) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(minHeight: 2),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context, RoastSetup setup, bool busy) {
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
      return [
        OutlinedButton.icon(
          onPressed: () => _copy(
            context,
            controller.participantCard(setup.id),
            'Participant card copied.',
          ),
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy participant card'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : setup.role == RoastSetupRole.host
              ? () => _finalizeHost(context, setup)
              : () => _join(context, setup),
          child: Text(
            setup.role == RoastSetupRole.host
                ? 'Enter participant cards'
                : 'Paste invitation',
          ),
        ),
      ];
    }
    if (setup.status == RoastSetupStatus.awaitingDkgApproval) {
      return [
        OutlinedButton(
          onPressed: busy
              ? null
              : () => _perform(
                  context,
                  () => controller.rejectRoastDkg(setup.id),
                ),
          child: const Text('Reject key creation'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () => _perform(
                  context,
                  () => controller.acceptRoastDkg(setup.id),
                ),
          child: const Text('Approve key creation'),
        ),
      ];
    }
    if (setup.status == RoastSetupStatus.ready &&
        setup.role == RoastSetupRole.host) {
      return [
        OutlinedButton.icon(
          onPressed: () => _copy(
            context,
            controller.roastInvitation(setup.id),
            'Finalized invitation copied.',
          ),
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy invitation'),
        ),
        FilledButton(
          onPressed:
              busy ||
                  controller.onlineSignerCount(setup) < setup.participantCount
              ? null
              : () =>
                    _perform(context, () => controller.startRoastDkg(setup.id)),
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

  Future<void> _finalizeHost(BuildContext context, RoastSetup setup) async {
    final controllers = [
      for (var i = 1; i < setup.participantCount; i++) TextEditingController(),
    ];
    final cards = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finalize participant roster'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Paste each participant card received through a trusted '
                  'channel. Verify names and key fingerprints together before '
                  'creating the shared key.',
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < controllers.length; i++) ...[
                  TextField(
                    controller: controllers[i],
                    minLines: 2,
                    maxLines: 4,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Participant ${i + 2} card',
                    ),
                  ),
                  const SizedBox(height: 12),
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
            onPressed: () => Navigator.pop(
              dialogContext,
              controllers.map((item) => item.text).toList(growable: false),
            ),
            child: const Text('Start coordinator'),
          ),
        ],
      ),
    );
    for (final item in controllers) {
      item.dispose();
    }
    if (cards != null && context.mounted) {
      await _perform(
        context,
        () => controller.finalizeHostedRoastSetup(setup.id, cards),
      );
    }
  }

  Future<void> _join(BuildContext context, RoastSetup setup) async {
    final input = TextEditingController();
    final invitation = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Join finalized setup'),
        content: SizedBox(
          width: 540,
          child: TextField(
            key: const Key('roast-invitation-field'),
            controller: input,
            minLines: 4,
            maxLines: 8,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Invitation'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text),
            child: const Text('Verify and connect'),
          ),
        ],
      ),
    );
    input.dispose();
    if (invitation != null && context.mounted) {
      await _perform(
        context,
        () => controller.joinRoastSetup(setup.id, invitation),
      );
    }
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

  static String _statusText(RoastSetup setup) => switch (setup.status) {
    RoastSetupStatus.draft =>
      setup.role == RoastSetupRole.host
          ? 'Waiting for participant cards'
          : 'Waiting for a finalized invitation from the host',
    RoastSetupStatus.ready =>
      setup.role == RoastSetupRole.host
          ? 'Coordinator online · share the finalized invitation'
          : 'Connected · waiting for the host to create the shared key',
    RoastSetupStatus.connecting => 'Connecting through Iroh…',
    RoastSetupStatus.awaitingDkgApproval =>
      'Review and approve shared-key creation',
    RoastSetupStatus.creatingKey => 'Creating shared key with ROAST…',
    RoastSetupStatus.active => 'Shared key secured on this device',
    RoastSetupStatus.interrupted => 'ROAST operation was interrupted',
    RoastSetupStatus.error => 'ROAST setup needs attention',
  };

  static String _short(String value) => value.length <= 18
      ? value
      : '${value.substring(0, 8)}…${value.substring(value.length - 8)}';
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
      'ROAST · ${setup.threshold} of ${setup.participantCount}',
      style: const TextStyle(
        color: AppColors.greenDark,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
