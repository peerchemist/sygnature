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
  final setupId = await showDialog<String>(
    context: context,
    builder: (_) => _RoastCreationDialog(controller: controller),
  );
  if (setupId == null || !context.mounted) return;
  final setup = controller.roastSetups.firstWhere((item) => item.id == setupId);
  if (setup.role == RoastSetupRole.host) {
    await _finalizeHostSetup(context, controller, setup);
  }
}

Future<void> showRoastGroupTransition(
  BuildContext context,
  WalletController controller,
  RoastSetup source,
) async {
  final creation = await showDialog<RoastGroupTransitionCreation>(
    context: context,
    builder: (_) =>
        _RoastGroupTransitionDialog(controller: controller, source: source),
  );
  if (creation == null || !context.mounted) return;
  await _showIssuedInvitations(context, creation.invitations);
}

Future<void> showRoastCoordinatorSwitch(
  BuildContext context,
  WalletController controller,
  RoastSetup setup,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      _RoastCoordinatorSwitchDialog(controller: controller, setup: setup),
);

class const _RoastCoordinatorSwitchDialog({
  required final WalletController controller,
  required final RoastSetup setup,
}) extends StatefulWidget {
  @override
  State<_RoastCoordinatorSwitchDialog> createState() =>
      _RoastCoordinatorSwitchDialogState();
}

class _RoastCoordinatorSwitchDialogState
    extends State<_RoastCoordinatorSwitchDialog> {
  final TextEditingController _endpointId = TextEditingController();
  final TextEditingController _relayUrls = TextEditingController();
  final TextEditingController _ipAddrs = TextEditingController();
  bool _approved = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _endpointId.dispose();
    _relayUrls.dispose();
    _ipAddrs.dispose();
    super.dispose();
  }

  List<String> _lines(String value) => value
      .split(RegExp(r'[\r\n]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);

  Future<void> _switch() async {
    if (!_approved) {
      setState(() => _error = 'Approve the exact endpoint ID to continue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final address = widget.controller.parseRoastCoordinatorAddress(
        id: _endpointId.text,
        relayUrls: _lines(_relayUrls.text),
        ipAddrs: _lines(_ipAddrs.text),
      );
      await widget.controller.switchRoastCoordinator(
        widget.setup.id,
        address,
        approved: true,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentId = widget.setup.coordinatorId ?? 'Not configured';
    final proposedId = _endpointId.text.trim();
    final sameIdentity = proposedId.isNotEmpty && proposedId == currentId;
    return AlertDialog(
      title: const Text('Coordinator'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The destination must already serve this exact ROAST group. '
                'An invitation or imported address is not approval.',
                style: TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 16),
              _CoordinatorEndpointBox(
                label: 'CURRENT ENDPOINT ID',
                value: currentId,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('coordinator-endpoint-id'),
                controller: _endpointId,
                onChanged: (_) => setState(() {
                  _approved = false;
                  _error = null;
                }),
                decoration: const InputDecoration(
                  labelText: 'Proposed endpoint ID',
                  helperText: 'Verify this identity through a trusted channel.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('coordinator-relay-urls'),
                controller: _relayUrls,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Relay URLs (optional)',
                  helperText: 'One URL per line.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('coordinator-ip-addresses'),
                controller: _ipAddrs,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Direct IP addresses (optional)',
                  helperText: 'One host:port address per line.',
                ),
              ),
              const SizedBox(height: 14),
              _CoordinatorEndpointBox(
                label: 'PROPOSED ENDPOINT ID',
                value: proposedId.isEmpty ? 'Enter an endpoint ID' : proposedId,
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const Key('approve-coordinator-endpoint'),
                value: _approved,
                onChanged: _busy || proposedId.isEmpty
                    ? null
                    : (value) => setState(() => _approved = value == true),
                contentPadding: EdgeInsets.zero,
                title: const Text('I approve this exact endpoint identity'),
                subtitle: const Text(
                  'This approves only this signer’s local selection. It does '
                  'not approve the coordinator for other group members.',
                ),
              ),
              if (sameIdentity)
                const Text(
                  'The endpoint identity is unchanged. Only reconnect address '
                  'hints will be updated.',
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
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
          key: const Key('switch-coordinator'),
          onPressed: _busy || !_approved ? null : _switch,
          child: Text(
            _busy
                ? 'Switching…'
                : sameIdentity
                ? 'Update address hints'
                : 'Switch coordinator',
          ),
        ),
      ],
    );
  }
}

class const _CoordinatorEndpointBox({
  required final String label,
  required final String value,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.canvas,
      border: Border.all(color: AppColors.line),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.inkMuted,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.7,
          ),
        ),
        const SizedBox(height: 5),
        SelectableText(value, style: const TextStyle(fontFamily: 'monospace')),
      ],
    ),
  );
}

class const _RoastGroupTransitionDialog({
  required final WalletController controller,
  required final RoastSetup source,
}) extends StatefulWidget {
  @override
  State<_RoastGroupTransitionDialog> createState() =>
      _RoastGroupTransitionDialogState();
}

class _RoastGroupTransitionDialogState
    extends State<_RoastGroupTransitionDialog> {
  late final TextEditingController _walletName = TextEditingController(
    text: '${widget.source.name} successor',
  );
  late final Set<String> _retainedPublicKeys = {
    for (final participant in widget.source.participants)
      if (participant.cardId != widget.source.localCardId)
        participant.publicKeyHex,
  };
  final List<_TransitionSignerFields> _added = [];
  late int _threshold = widget.source.threshold;
  bool _busy = false;
  String? _error;

  int get _participantCount => 1 + _retainedPublicKeys.length + _added.length;

  @override
  void dispose() {
    _walletName.dispose();
    for (final fields in _added) {
      fields.dispose();
    }
    super.dispose();
  }

  void _normalizeThreshold() {
    if (_threshold > _participantCount) _threshold = _participantCount;
    if (_threshold < 2) _threshold = 2;
  }

  void _addSigner() {
    if (_participantCount >= 5) return;
    final name = _newParticipantAliases(
      1,
      excluding: widget.source.participants.map((item) => item.name),
    ).single;
    setState(() {
      _added.add(_TransitionSignerFields(name: name));
      _normalizeThreshold();
      _error = null;
    });
  }

  void _removeAddedSigner(int index) {
    setState(() {
      _added.removeAt(index).dispose();
      _normalizeThreshold();
      _error = null;
    });
  }

  Future<void> _create() async {
    if (_walletName.text.trim().isEmpty) {
      setState(() => _error = 'Enter a name for the successor wallet.');
      return;
    }
    if (_participantCount < 2) {
      setState(() => _error = 'Keep or add at least one other signer.');
      return;
    }
    final rosterChanged =
        _retainedPublicKeys.length != widget.source.participantCount - 1 ||
        _added.isNotEmpty;
    if (!rosterChanged && _threshold == widget.source.threshold) {
      setState(() => _error = 'Change the signer group or signing threshold.');
      return;
    }
    final added = <({String name, String publicKeyHex})>[];
    try {
      for (final fields in _added) {
        final name = fields.name.text.trim();
        if (name.isEmpty) throw const FormatException('Enter a signer name.');
        added.add((
          name: name,
          publicKeyHex: widget.controller.normalizeRoastParticipantPublicKey(
            fields.publicKey.text,
          ),
        ));
      }
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final creation = await widget.controller.proposeRoastGroupTransition(
        sourceSetupId: widget.source.id,
        successorWalletName: _walletName.text,
        successorThreshold: _threshold,
        otherParticipants: [
          for (final participant in widget.source.participants)
            if (_retainedPublicKeys.contains(participant.publicKeyHex))
              (name: participant.name, publicKeyHex: participant.publicKeyHex),
          ...added,
        ],
      );
      if (mounted) Navigator.pop(context, creation);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final local = widget.source.localParticipant;
    return AlertDialog(
      title: const Text('Change signer group'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This creates a successor wallet with a new shared key. The '
                'current wallet stays active and its balance is not moved '
                'automatically.',
                style: TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('transition-wallet-name'),
                controller: _walletName,
                maxLength: 32,
                decoration: const InputDecoration(
                  labelText: 'Successor wallet name',
                ),
              ),
              const SizedBox(height: 8),
              Text('Signers', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              CheckboxListTile(
                value: true,
                onChanged: null,
                contentPadding: EdgeInsets.zero,
                title: Text('${local.name} (this device)'),
                subtitle: const Text(
                  'The signer starting the change must remain in the group.',
                ),
              ),
              for (final participant in widget.source.participants)
                if (participant.cardId != widget.source.localCardId)
                  CheckboxListTile(
                    key: Key('retain-signer-${participant.cardId}'),
                    value: _retainedPublicKeys.contains(
                      participant.publicKeyHex,
                    ),
                    onChanged: _busy
                        ? null
                        : (selected) => setState(() {
                            if (selected == true) {
                              _retainedPublicKeys.add(participant.publicKeyHex);
                            } else {
                              _retainedPublicKeys.remove(
                                participant.publicKeyHex,
                              );
                            }
                            _normalizeThreshold();
                            _error = null;
                          }),
                    contentPadding: EdgeInsets.zero,
                    title: Text(participant.name),
                    subtitle: Text(
                      RoastSetupPanel._short(participant.publicKeyHex),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
              for (final (index, fields) in _added.indexed) ...[
                const Divider(height: 24),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: Key('transition-new-signer-name-$index'),
                        controller: fields.name,
                        decoration: const InputDecoration(
                          labelText: 'New signer name',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        key: Key('transition-new-signer-key-$index'),
                        controller: fields.publicKey,
                        decoration: const InputDecoration(
                          labelText: 'Signer public key',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove new signer',
                      onPressed: _busy ? null : () => _removeAddedSigner(index),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('transition-add-signer'),
                onPressed: _busy || _participantCount >= 5 ? null : _addSigner,
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Add signer'),
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<int>(
                key: const Key('transition-threshold'),
                initialValue: _participantCount >= 2 ? _threshold : null,
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
                onChanged: _busy || _participantCount < 2
                    ? null
                    : (value) => setState(() => _threshold = value!),
              ),
              const SizedBox(height: 12),
              const Text(
                'Share the generated participant-bound invitations. Once '
                'everyone is online, start key creation from the successor '
                'wallet.',
                style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
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
          key: const Key('create-group-transition'),
          onPressed: _busy ? null : _create,
          child: Text(_busy ? 'Creating…' : 'Create successor'),
        ),
      ],
    );
  }
}

class _TransitionSignerFields {
  _TransitionSignerFields({required String name})
    : name = TextEditingController(text: name),
      publicKey = TextEditingController();

  final TextEditingController name;
  final TextEditingController publicKey;

  void dispose() {
    name.dispose();
    publicKey.dispose();
  }
}

class const _RoastCreationDialog({required final WalletController controller})
    extends StatefulWidget {
  @override
  State<_RoastCreationDialog> createState() => _RoastCreationDialogState();
}

class _RoastCreationDialogState extends State<_RoastCreationDialog> {
  late final TextEditingController _walletName = TextEditingController(
    text: 'Shared wallet',
  );
  late final String _participantAlias = _newParticipantAliases(1).single;
  late WalletNetwork _network = widget.controller.supportedNetworks.first;
  RoastSetupRole _role = RoastSetupRole.host;
  int _participantCount = 2;
  int _threshold = 2;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _walletName.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_walletName.text.trim().isEmpty) {
      setState(() => _error = 'Enter a wallet name before continuing.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final setupId = await widget.controller.createRoastSetupDraft(
        role: _role,
        walletName: _walletName.text,
        participantName: _participantAlias,
        threshold: _threshold,
        participantCount: _participantCount,
        network: _network,
      );
      if (mounted) Navigator.pop(context, setupId);
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
            TextField(
              key: const Key('roast-wallet-name'),
              controller: _walletName,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Wallet name'),
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
                        'keys or sign. Collect participant cards, then create '
                        'a separate pubkey-bound invite for each signer.'
                  : 'A participant key is generated on this device. Share its '
                        'public card with the host, then paste the invite '
                        'created specifically for this key.',
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
        key: const Key('roast-setup-back'),
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Back'),
      ),
      FilledButton(
        key: const Key('create-roast-draft'),
        onPressed: _busy ? null : _create,
        child: Text(_busy ? 'Creating…' : 'Create setup draft'),
      ),
    ],
  );
}

Future<void> _finalizeHostSetup(
  BuildContext context,
  WalletController controller,
  RoastSetup setup,
) async {
  final invitees = await showDialog<List<({String name, String publicKeyHex})>>(
    context: context,
    builder: (_) => _RoastInviteWizard(controller: controller, setup: setup),
  );
  if (invitees == null || !context.mounted) return;
  try {
    final invitations = await controller.createHostedRoastInvitations(
      setup.id,
      invitees,
    );
    if (context.mounted) {
      await _showIssuedInvitations(context, invitations);
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

Future<void> _showIssuedInvitations(
  BuildContext context,
  List<RoastIssuedInvitation> invitations,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Participant invitations'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Send each invitation only to the named participant. Each '
              'invite works exclusively with the public key shown below.',
            ),
            const SizedBox(height: 16),
            for (final invitation in invitations)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(invitation.participantName),
                subtitle: Text(
                  RoastSetupPanel._short(invitation.participantPublicKeyHex),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                trailing: IconButton(
                  tooltip: 'Copy bound invitation',
                  onPressed: () => RoastSetupPanel._copy(
                    dialogContext,
                    invitation.encoded,
                    'Invitation copied for ${invitation.participantName}.',
                  ),
                  icon: const Icon(Icons.copy_rounded),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Back to wallet'),
      ),
    ],
  ),
);

Future<void> showRoastSignMessageDialog(
  BuildContext context,
  WalletController controller,
  WalletAccount account, {
  RoastSignedMessage? result,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SignMessageDialog(
    controller: controller,
    account: account,
    initialResult: result,
  ),
);

class const _SignMessageDialog({
  required final WalletController controller,
  required final WalletAccount account,
  final RoastSignedMessage? initialResult,
}) extends StatefulWidget {
  @override
  State<_SignMessageDialog> createState() => _SignMessageDialogState();
}

class _SignMessageDialogState extends State<_SignMessageDialog> {
  final _formKey = GlobalKey<FormState>();
  final _textController = TextEditingController();
  final _noteController = TextEditingController();
  final _timeoutController = TextEditingController(
    text: '${defaultRoastSigningRequestTimeout.inMinutes}',
  );
  bool _reviewing = false;
  bool _submitting = false;
  String? _error;
  late RoastSignedMessage? _result;
  Duration _requestTimeout = defaultRoastSigningRequestTimeout;

  @override
  void initState() {
    super.initState();
    _result = widget.initialResult;
  }

  @override
  void dispose() {
    _textController.dispose();
    _noteController.dispose();
    _timeoutController.dispose();
    super.dispose();
  }

  void _review() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _requestTimeout = Duration(
        minutes: int.parse(_timeoutController.text.trim()),
      );
      _reviewing = true;
      _error = null;
    });
  }

  Future<void> _sign() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await widget.controller.signRoastMessage(
        widget.account,
        text: _textController.text,
        message: _noteController.text.trim(),
        requestTimeout: _requestTimeout,
      );
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _copyResult() async {
    await Clipboard.setData(ClipboardData(text: _result!.encoded));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Signed message copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return PopScope(
      canPop: true,
      child: AlertDialog(
        title: Text(
          result != null
              ? 'Message signed'
              : _submitting
              ? 'Waiting for signatures'
              : 'Sign message with ROAST',
        ),
        content: SizedBox(
          width: 560,
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) => SingleChildScrollView(
              child: result != null
                  ? _buildResult(result)
                  : _submitting
                  ? _buildSigningProgress()
                  : _reviewing
                  ? _buildReview()
                  : _buildForm(),
            ),
          ),
        ),
        actions: [
          if (result != null) ...[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              key: const Key('copy-signed-message'),
              onPressed: _copyResult,
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy signed message'),
            ),
          ] else if (_submitting) ...[
            TextButton(
              key: const Key('close-message-signing'),
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ] else ...[
            TextButton(
              onPressed: _reviewing
                  ? () => setState(() {
                      _reviewing = false;
                      _error = null;
                    })
                  : () => Navigator.pop(context),
              child: Text(_reviewing ? 'Back' : 'Cancel'),
            ),
            FilledButton(
              key: Key(
                _reviewing
                    ? 'request-message-signatures'
                    : 'review-message-signature',
              ),
              onPressed: _reviewing ? _sign : _review,
              child: Text(_reviewing ? 'Request signatures' : 'Review'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildForm() => Form(
    key: _formKey,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'The exact text is signed by the shared group key. It is not a '
          'Peercoin transaction or an address-ownership proof.',
          style: TextStyle(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('roast-signed-message-field'),
          controller: _textController,
          autofocus: true,
          minLines: 4,
          maxLines: 10,
          maxLength: maxRoastSignedMessageBytes,
          decoration: const InputDecoration(
            labelText: 'Message to sign',
            alignLabelWithHint: true,
          ),
          validator: (value) {
            if (value == null || value.isEmpty) return 'Enter a message.';
            return utf8.encode(value).length > maxRoastSignedMessageBytes
                ? 'Message must be no more than 1 KiB of UTF-8 text.'
                : null;
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('roast-message-note-field'),
          controller: _noteController,
          minLines: 2,
          maxLines: 4,
          maxLength: maxRoastSigningMessageBytes,
          decoration: const InputDecoration(
            labelText: 'Note to signers (optional)',
            helperText: 'Authenticated context; not part of the signed text.',
            alignLabelWithHint: true,
          ),
          validator: (value) =>
              utf8.encode(value?.trim() ?? '').length >
                  maxRoastSigningMessageBytes
              ? 'Note must be no more than 1 KiB of UTF-8 text.'
              : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('roast-message-timeout-field'),
          controller: _timeoutController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Request timeout',
            suffixText: 'minutes',
            helperText: 'Maximum 1440 minutes (24 hours).',
          ),
          validator: _validateSigningRequestTimeoutMinutes,
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppColors.danger)),
        ],
      ],
    ),
  );

  Widget _buildReview() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Confirm the exact text below. Whitespace and line endings are part '
        'of the signature.',
        style: TextStyle(color: AppColors.inkMuted),
      ),
      const SizedBox(height: 16),
      _MessageBox(label: 'EXACT TEXT TO SIGN', text: _textController.text),
      if (_noteController.text.trim().isNotEmpty) ...[
        const SizedBox(height: 12),
        _MessageBox(
          label: 'NOTE TO SIGNERS · AUTHENTICATED, NOT SIGNED TEXT',
          text: _noteController.text.trim(),
        ),
      ],
      const SizedBox(height: 12),
      _MessageBox(
        label: 'REQUEST TIMEOUT',
        text: '${_requestTimeout.inMinutes} minutes',
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: AppColors.danger)),
      ],
    ],
  );

  Widget _buildSigningProgress() {
    final setup = widget.controller.setupForAccount(widget.account);
    final progress = setup == null
        ? null
        : widget.controller.roastMessageSigningProgress(setup.id);
    final threshold = progress?.threshold ?? setup?.threshold ?? 1;
    final collected = progress?.contributingParticipants.length ?? 0;
    final sent = progress?.stage != 'sending';
    final gaugeValue = (collected / threshold).clamp(0, 1).toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const Key('message-signing-progress'),
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.greenDark.withValues(alpha: 0.07),
            border: Border.all(
              color: AppColors.greenDark.withValues(alpha: 0.25),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    sent ? Icons.outgoing_mail : Icons.sync_rounded,
                    color: AppColors.greenDark,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    sent ? 'Signature request sent' : 'Sending request…',
                    style: const TextStyle(
                      color: AppColors.greenDark,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                sent
                    ? 'The request was sent to the other signers. Waiting '
                          'for enough responses to complete the signature.'
                    : 'Submitting the request to the signer group.',
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    '$collected of $threshold signatures',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    progress?.stage == 'signing'
                        ? 'SIGNING'
                        : sent
                        ? 'WAITING'
                        : 'SENDING',
                    style: const TextStyle(
                      color: AppColors.inkMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.7,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              LinearProgressIndicator(
                value: gaugeValue,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                semanticsLabel: 'Signatures collected',
                semanticsValue: '$collected of $threshold',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _MessageBox(label: 'EXACT TEXT TO SIGN', text: _textController.text),
        if (_noteController.text.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          _MessageBox(
            label: 'NOTE TO SIGNERS · AUTHENTICATED, NOT SIGNED TEXT',
            text: _noteController.text.trim(),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'The request remains active for up to '
          '${_requestTimeout.inMinutes} minutes. You can close this window; '
          'signing will continue in the background.',
          style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppColors.danger)),
        ],
      ],
    );
  }

  Widget _buildResult(RoastSignedMessage result) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Row(
        children: [
          Icon(Icons.verified_rounded, color: AppColors.success),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Threshold signature completed and verified.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _MessageBox(label: 'SIGNED TEXT', text: result.text),
      const SizedBox(height: 12),
      _MessageBox(label: 'PUBLIC KEY', text: result.publicKeyHex),
      const SizedBox(height: 12),
      _MessageBox(label: 'SIGNATURE', text: result.signatureHex),
      const SizedBox(height: 12),
      _MessageBox(label: 'PORTABLE SIGNED MESSAGE', text: result.encoded),
    ],
  );
}

String? _validateSigningRequestTimeoutMinutes(String? value) {
  final minutes = int.tryParse(value?.trim() ?? '');
  if (minutes == null || minutes <= 0) {
    return 'Enter a timeout in whole minutes.';
  }
  if (minutes > maxRoastSigningRequestTimeout.inMinutes) {
    return 'Timeout cannot exceed 24 hours.';
  }
  return null;
}

class const _MessageBox({
  required final String label,
  required final String text,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.canvas,
      border: Border.all(color: AppColors.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.inkMuted,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 6),
        SelectableText(text),
      ],
    ),
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
    final messageSigning = controller.roastMessageSigningInProgress(setup.id);
    final busy =
        controller.roastOperationInProgress(setup.id) || messageSigning;
    final onlineSigners = controller.onlineSignerCount(setup);
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
                        _statusText(setup),
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
                state: coordinatorState,
                endpointId: setup.coordinatorId,
              ),
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
            onPressed: () => _showIssuedInvitations(context, invitations),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Show participant invites'),
          ),
        if (setup.status == RoastSetupStatus.ready)
          FilledButton(
            onPressed:
                busy ||
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

  static String _statusText(RoastSetup setup) => switch (setup.status) {
    RoastSetupStatus.draft =>
      setup.role == RoastSetupRole.host
          ? 'Add signers and create their invitations'
          : 'Share your signer public key, then wait for your bound invite',
    RoastSetupStatus.ready =>
      setup.role == RoastSetupRole.host
          ? 'Room roster frozen · coordinator online'
          : 'Connected · waiting for the host to create the shared key',
    RoastSetupStatus.connecting =>
      setup.role == RoastSetupRole.host
          ? 'Room open · waiting for invited participants'
          : 'Joining room through Iroh…',
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
  required final RoastCoordinatorLocalState state,
  required final String? endpointId,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final (label, detail, icon, color) = switch (state) {
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
      key: ValueKey('coordinator-${state.name}'),
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
                if (endpointId != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Coordinator ID ${RoastSetupPanel._short(endpointId!)}',
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

class const _RoastInviteWizard({
  required final WalletController controller,
  required final RoastSetup setup,
}) extends StatefulWidget {
  @override
  State<_RoastInviteWizard> createState() => _RoastInviteWizardState();
}

class _RoastInviteWizardState extends State<_RoastInviteWizard> {
  late final List<String> _names = _newParticipantAliases(
    widget.setup.participantCount - 1,
    excluding: [widget.setup.localParticipant.name],
  );
  late final List<String> _publicKeys = List.filled(
    widget.setup.participantCount - 1,
    '',
  );
  int _signerIndex = 0;
  bool _reviewing = false;
  String? _error;

  void _continue() {
    final name = _names[_signerIndex].trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name for this signer.');
      return;
    }
    try {
      _publicKeys[_signerIndex] = widget.controller
          .normalizeRoastParticipantPublicKey(_publicKeys[_signerIndex]);
    } on Object catch (error) {
      setState(() => _error = _message(error));
      return;
    }
    setState(() {
      _names[_signerIndex] = name;
      _error = null;
      if (_signerIndex == _names.length - 1) {
        _reviewing = true;
      } else {
        _signerIndex++;
      }
    });
  }

  void _back() {
    if (!_reviewing && _signerIndex == 0) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _error = null;
      if (_reviewing) {
        _reviewing = false;
        _signerIndex = _names.length - 1;
      } else {
        _signerIndex--;
      }
    });
  }

  void _finish() => Navigator.pop(context, [
    for (var i = 0; i < _names.length; i++)
      (name: _names[i], publicKeyHex: _publicKeys[i]),
  ]);

  @override
  Widget build(BuildContext context) {
    final signerIndex = _signerIndex;
    return AlertDialog(
      title: const Text('Create signer invitations'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: _reviewing
              ? _review()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Signer ${signerIndex + 2} of '
                      '${widget.setup.participantCount}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: (signerIndex + 1) / _names.length,
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      key: Key('roast-signer-name-$signerIndex'),
                      initialValue: _names[signerIndex],
                      maxLength: 32,
                      textInputAction: TextInputAction.next,
                      onChanged: (value) => _names[signerIndex] = value,
                      decoration: const InputDecoration(
                        labelText: 'Signer name',
                        hintText: 'For example: Alice laptop',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      key: Key('roast-signer-public-key-$signerIndex'),
                      initialValue: _publicKeys[signerIndex],
                      minLines: 2,
                      maxLines: 3,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (value) => _publicKeys[signerIndex] = value,
                      decoration: const InputDecoration(
                        labelText: 'Signer public key',
                        hintText: '02… or 03…',
                        helperText:
                            'Paste the key copied from the signer wallet. '
                            'A Peercoin payment address cannot be used here.',
                      ),
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
          key: const Key('roast-invite-wizard-back'),
          onPressed: _back,
          child: const Text('Back'),
        ),
        FilledButton(
          key: const Key('roast-invite-wizard-continue'),
          onPressed: _reviewing ? _finish : _continue,
          child: Text(_reviewing ? 'Create invitations' : 'Continue'),
        ),
      ],
    );
  }

  Widget _review() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Verify each signer and key fingerprint through the trusted channel '
        'you used to receive it. Creating the invitations freezes the roster.',
      ),
      const SizedBox(height: 16),
      for (var i = 0; i < _names.length; i++)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.key_rounded),
          title: Text(_names[i]),
          subtitle: Text(
            RoastSetupPanel._short(_publicKeys[i]),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
    ],
  );

  static String _message(Object error) =>
      '$error'.replaceFirst(RegExp(r'^(FormatException|ArgumentError): '), '');
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
