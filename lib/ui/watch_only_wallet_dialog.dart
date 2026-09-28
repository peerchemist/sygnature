import 'package:flutter/material.dart';

import '../controllers/wallet_controller.dart';
import '../models/wallet_network.dart';

Future<bool> showWatchOnlyWalletDialog(
  BuildContext context,
  WalletController controller,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => WatchOnlyWalletDialog(controller: controller),
    ) ??
    false;

class const WatchOnlyWalletDialog({
  super.key,
  required final WalletController controller,
}) extends StatefulWidget {
  @override
  State<WatchOnlyWalletDialog> createState() => _WatchOnlyWalletDialogState();
}

class _WatchOnlyWalletDialogState extends State<WatchOnlyWalletDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController = TextEditingController(
    text: 'Watch-only ${widget.controller.accounts.length + 1}',
  );
  final TextEditingController _addressController = TextEditingController();
  late WalletNetwork _network;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _network =
        widget.controller.walletNetwork ??
        widget.controller.supportedNetworks.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || _formKey.currentState?.validate() != true) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.addWatchOnlyAccount(
        _nameController.text,
        network: _network,
        address: _addressController.text,
      );
      if (mounted) Navigator.pop(context, true);
    } on WatchOnlyWalletFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Unable to add the watch-only wallet.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add watch-only wallet'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Track a Peercoin Taproot address without importing a '
                'recovery phrase or private key. This wallet cannot spend.',
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<WalletNetwork>(
                key: const Key('watch-only-network-field'),
                initialValue: _network,
                decoration: const InputDecoration(
                  labelText: 'Blockchain network',
                ),
                isExpanded: true,
                items: widget.controller.supportedNetworks
                    .map(
                      (network) => DropdownMenuItem(
                        value: network,
                        child: Text(network.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _submitting
                    ? null
                    : (network) {
                        if (network == null) return;
                        setState(() {
                          _network = network;
                          _error = null;
                        });
                      },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('watch-only-address-field'),
                controller: _addressController,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: const InputDecoration(labelText: 'Taproot address'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a Taproot address.'
                    : null,
                onChanged: (_) => setState(() => _error = null),
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('watch-only-name-field'),
                controller: _nameController,
                maxLength: 32,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a wallet name.'
                    : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 8),
                Text(error, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _submitting ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('watch-only-add-button'),
        onPressed: _submitting ? null : _submit,
        child: _submitting
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Add'),
      ),
    ],
  );
}
