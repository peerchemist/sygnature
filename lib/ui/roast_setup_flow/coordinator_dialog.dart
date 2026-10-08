part of '../roast_setup_flow.dart';

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
