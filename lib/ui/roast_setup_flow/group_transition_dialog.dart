part of '../roast_setup_flow.dart';

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
  await _showIssuedInvitations(context, controller, creation.successorSetupId);
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
    if (_participantCount >= _maxRoastParticipants) return;
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
                onPressed: _busy || _participantCount >= _maxRoastParticipants
                    ? null
                    : _addSigner,
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
