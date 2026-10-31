part of '../roast_setup_flow.dart';

Future<void> showRoastSetupCreation(
  BuildContext context,
  WalletController controller,
) async {
  if (!controller.roastAvailable) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ROAST is unavailable in this application session.'),
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

  void _setParticipantCount(double value) {
    setState(() {
      _participantCount = value.round();
      _threshold = _threshold.clamp(2, _participantCount);
      _error = null;
    });
  }

  @override
  void dispose() {
    _walletName.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
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
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to create the shared wallet.');
      }
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
              'A ROAST wallet lets multiple people approve transactions '
              'without any device holding the complete private key.',
            ),
            const SizedBox(height: 18),
            Text(
              'How would you like to get started?',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<RoastSetupRole>(
              segments: const [
                ButtonSegment(
                  value: RoastSetupRole.host,
                  label: Text('Create wallet'),
                  icon: Icon(Icons.add_circle_outline_rounded),
                ),
                ButtonSegment(
                  value: RoastSetupRole.member,
                  label: Text('Join wallet'),
                  icon: Icon(Icons.link_rounded),
                ),
              ],
              selected: {_role},
              onSelectionChanged: (value) => setState(() {
                _role = value.single;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            Row(
              key: const Key('roast-role-hint'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: AppColors.of(context).inkMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _role == RoastSetupRole.host
                        ? 'Start a new shared wallet. Choose how many people '
                              'will participate and how many approvals are '
                              'required, then invite each signer. This device '
                              'will coordinate setup and signing and must stay '
                              'online.'
                        : 'Choose this when someone else is creating the '
                              'wallet. Send them the public key generated on '
                              'this device, then paste the personal invitation '
                              'they send back.',
                    style: TextStyle(
                      color: AppColors.of(context).inkMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            if (_role == RoastSetupRole.host && _isMobilePlatform) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('mobile-coordinator-warning'),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.of(context).warning,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: AppColors.of(context).warningDark,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Mobile operating systems may suspend this app in the '
                        'background, making the coordinator unavailable. For '
                        'reliable ROAST coordination, run the coordinator on '
                        'a desktop or server.',
                        style: TextStyle(
                          color: AppColors.of(context).warningDark,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                decoration: BoxDecoration(
                  color: AppColors.of(context).surface,
                  border: Border.all(color: AppColors.of(context).line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Approval policy',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$_threshold of $_participantCount signers must approve',
                      style: TextStyle(
                        color: AppColors.of(context).inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _RoastPolicySlider(
                      key: const Key('roast-participant-count'),
                      label: 'Participants',
                      value: _participantCount,
                      min: 2,
                      max: _maxRoastParticipants,
                      onChanged: _setParticipantCount,
                    ),
                    const SizedBox(height: 10),
                    _RoastPolicySlider(
                      key: const Key('roast-required-signers'),
                      label: 'Required signers',
                      value: _threshold,
                      min: 2,
                      max: _participantCount,
                      onChanged: _participantCount == 2
                          ? null
                          : (value) => setState(() {
                              _threshold = value.round();
                              _error = null;
                            }),
                    ),
                  ],
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: AppColors.of(context).danger),
              ),
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
        child: Text(
          _busy
              ? 'Creating…'
              : _role == RoastSetupRole.host
              ? 'Create wallet setup'
              : 'Prepare to join',
        ),
      ),
    ],
  );
}

class const _RoastPolicySlider({
  super.key,
  required this.label,
  required this.value,
  required this.min,
  required this.max,
  required this.onChanged,
}) extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Container(
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.of(context).lime,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.of(context).forest,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      Row(
        children: [
          Text('$min', style: Theme.of(context).textTheme.bodySmall),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max == min ? null : max - min,
              label: '$value',
              onChanged: onChanged,
            ),
          ),
          Text('$max', style: Theme.of(context).textTheme.bodySmall),
        ],
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
    await controller.createHostedRoastInvitations(setup.id, invitees);
    if (context.mounted) {
      await _showIssuedInvitations(context, controller, setup.id);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Unable to create ROAST invitations. Use Retry creating '
            'invitations to try again.',
          ),
        ),
      );
    }
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
    } on Object catch (_) {
      setState(() => _error = 'Enter a valid signer public key.');
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
                      Text(
                        _error!,
                        style: TextStyle(color: AppColors.of(context).danger),
                      ),
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
}
