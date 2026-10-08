part of '../wallet_home.dart';

Future<void> _showAddWallet(
  BuildContext context,
  WalletController controller,
) async {
  final type = await showDialog<WalletKeySource>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Add wallet'),
      children: [
        SimpleDialogOption(
          onPressed: () =>
              Navigator.pop(dialogContext, WalletKeySource.personal),
          child: const ListTile(
            leading: Icon(Icons.key_outlined),
            title: Text('Personal wallet'),
            subtitle: Text('Create a wallet you can send and receive with.'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () =>
              Navigator.pop(dialogContext, WalletKeySource.watchOnly),
          child: const ListTile(
            leading: Icon(Icons.visibility_outlined),
            title: Text('Watch-only wallet'),
            subtitle: Text('Track a Taproot address without spending keys.'),
          ),
        ),
        SimpleDialogOption(
          onPressed: controller.roastAvailable
              ? () => Navigator.pop(dialogContext, WalletKeySource.roast)
              : null,
          child: ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('ROAST shared wallet'),
            subtitle: Text(
              controller.roastAvailable
                  ? 'Create or join a threshold signing setup.'
                  : 'Available on Linux and macOS.',
            ),
          ),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (type == WalletKeySource.roast) {
    await showRoastSetupCreation(context, controller);
    return;
  }
  if (type == WalletKeySource.watchOnly) {
    await showWatchOnlyWalletDialog(context, controller);
    return;
  }
  if (type != WalletKeySource.personal) return;
  if (controller.vault?.mnemonic == null) {
    if (context.mounted) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (routeContext) => OnboardingScreen(
            controller: controller,
            onCreated: () => Navigator.pop(routeContext),
          ),
        ),
      );
    }
    return;
  }
  final result = await showDialog<({String name, WalletNetwork network})>(
    context: context,
    builder: (context) => _AddWalletDialog(
      initialName: controller.accounts.isEmpty
          ? 'Main wallet'
          : 'Wallet ${controller.accounts.length + 1}',
      networks: controller.supportedNetworks,
    ),
  );
  if (result == null || result.name.trim().isEmpty) return;
  await controller.addAccount(result.name, network: result.network);
}

class _AddWalletDialog extends StatefulWidget {
  const _AddWalletDialog({required this.initialName, required this.networks});
  final String initialName;
  final List<WalletNetwork> networks;

  @override
  State<_AddWalletDialog> createState() => _AddWalletDialogState();
}

class _AddWalletDialogState extends State<_AddWalletDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  late WalletNetwork _network;

  @override
  void initState() {
    super.initState();
    _network = widget.networks.first;
  }

  void _submit() {
    if (_controller.text.trim().isEmpty) return;
    Navigator.pop(context, (name: _controller.text, network: _network));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New personal wallet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A new account index will be allocated from the same root seed. '
              'Choose the blockchain network for this account.',
            ),
            const SizedBox(height: 18),
            DropdownButtonFormField<WalletNetwork>(
              key: const Key('sub-wallet-network-field'),
              initialValue: _network,
              decoration: const InputDecoration(
                labelText: 'Blockchain network',
              ),
              isExpanded: true,
              items: widget.networks
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
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}

Future<void> _confirmDeleteWallet(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final isRoast = account.keySource == WalletKeySource.roast;
  final isWatchOnly = account.keySource == WalletKeySource.watchOnly;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete ${account.name}?'),
      content: Text(
        isRoast
            ? 'This wallet, its local signer identity and key share will be '
                  'permanently removed from this device. You may lose the '
                  'ability to approve transactions for the shared wallet.'
            : isWatchOnly
            ? 'This watch-only wallet will be removed from this device. '
                  'No private key or funds are stored in it.'
            : 'This wallet will be removed from this device. Its account '
                  'index will not be reused.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete wallet'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await controller.deleteAccount(account.id);
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

Future<void> _showRenameWallet(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final nameController = TextEditingController(text: account.name);
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Rename wallet'),
      content: TextField(
        key: const Key('rename-wallet-field'),
        controller: nameController,
        autofocus: true,
        maxLength: 32,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(dialogContext, value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (nameController.text.trim().isNotEmpty) {
              Navigator.pop(dialogContext, nameController.text);
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  nameController.dispose();
  if (name != null) await controller.renameAccount(account.id, name);
}

Future<void> _showArchivedWallets(
  BuildContext context,
  WalletController controller,
) async {
  await _showAdaptivePanel(
    context,
    builder: (panelContext, desktop) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, desktop ? 20 : 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Archived wallets',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (desktop)
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(panelContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (controller.archivedAccounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No archived wallets.'),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 480),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: controller.archivedAccounts.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final account = controller.archivedAccounts[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.account_balance_wallet_outlined,
                        ),
                        title: Text(account.name),
                        subtitle: Text(
                          account.keySource == WalletKeySource.watchOnly
                              ? 'Watch-only wallet'
                              : account.keySource == WalletKeySource.roast
                              ? 'ROAST shared wallet'
                              : 'Peercoin account ${account.accountIndex}',
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              key: Key('restore-wallet-${account.id}'),
                              tooltip: 'Restore wallet',
                              onPressed: () async {
                                try {
                                  await controller.restoreAccount(account.id);
                                  if (panelContext.mounted) {
                                    Navigator.pop(panelContext);
                                  }
                                } on Object catch (error) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$error')),
                                    );
                                  }
                                }
                              },
                              icon: const Icon(Icons.unarchive_outlined),
                            ),
                            IconButton(
                              key: Key('delete-archived-wallet-${account.id}'),
                              tooltip: 'Delete permanently',
                              onPressed: () => _confirmDeleteWallet(
                                context,
                                controller,
                                account,
                              ),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                color: Colors.red,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
