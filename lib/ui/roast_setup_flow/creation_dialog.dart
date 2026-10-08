part of '../roast_setup_flow.dart';

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
  final TextEditingController _participantCount = TextEditingController(
    text: '2',
  );
  final TextEditingController _threshold = TextEditingController(text: '2');
  bool _busy = false;
  String? _error;

  int? get _parsedParticipantCount =>
      int.tryParse(_participantCount.text.trim());

  void _thresholdValuesChanged(String _) {
    var participantCount = _parsedParticipantCount;
    if (participantCount != null && participantCount > _maxRoastParticipants) {
      participantCount = _maxRoastParticipants;
      _setParticipantCount(participantCount);
    }
    final threshold = int.tryParse(_threshold.text.trim());
    if (participantCount != null &&
        participantCount >= 2 &&
        threshold != null &&
        threshold > participantCount) {
      _setThreshold(participantCount);
    }
    setState(() => _error = null);
  }

  void _setParticipantCount(int value) {
    final text = '$value';
    _participantCount.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _setThreshold(int value) {
    final text = '$value';
    _threshold.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  void dispose() {
    _walletName.dispose();
    _participantCount.dispose();
    _threshold.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
    if (_walletName.text.trim().isEmpty) {
      setState(() => _error = 'Enter a wallet name before continuing.');
      return;
    }
    final participantCount = _parsedParticipantCount;
    if (participantCount == null ||
        participantCount < 2 ||
        participantCount > _maxRoastParticipants) {
      setState(
        () => _error =
            'Participants must be between 2 and $_maxRoastParticipants.',
      );
      return;
    }
    final threshold = int.tryParse(_threshold.text.trim());
    if (threshold == null || threshold < 2 || threshold > participantCount) {
      setState(
        () => _error =
            'Required signers must be between 2 and the participant count.',
      );
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
        threshold: threshold,
        participantCount: participantCount,
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
              'Create a threshold wallet with ROAST. '
              'No device ever holds the complete private key.',
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
                    child: TextFormField(
                      key: const Key('roast-participant-count'),
                      controller: _participantCount,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(5),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Participants',
                      ),
                      onChanged: _thresholdValuesChanged,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      key: const Key('roast-required-signers'),
                      controller: _threshold,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(5),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Required signers',
                        suffixText: 'of ${_parsedParticipantCount ?? 'n'}',
                      ),
                      onChanged: _thresholdValuesChanged,
                      onFieldSubmitted: (_) => _create(),
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
    await controller.createHostedRoastInvitations(setup.id, invitees);
    if (context.mounted) {
      await _showIssuedInvitations(context, controller, setup.id);
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
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
