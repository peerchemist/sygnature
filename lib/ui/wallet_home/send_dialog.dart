part of '../wallet_home.dart';

Future<void> _showSendDialog(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final result = await showDialog<WalletSendResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SendDialog(controller: controller, account: account),
  );
  if (result == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Transaction submitted: ${_shortTransactionId(result.transactionId)}',
      ),
    ),
  );
}

Future<bool> _dismissFailedRoastSigningOperation(
  BuildContext context,
  WalletController controller,
  WalletAccount account,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Dismiss failed request?'),
      content: const Text(
        'This releases the transaction inputs reserved by the failed request '
        'so you can create a new one. Only continue if the old request should '
        'be abandoned.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-dismiss-roast-signing-operation'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Dismiss request'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  try {
    await controller.dismissRoastSigningOperation(account.id);
    return true;
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not dismiss the failed request.')),
      );
    }
    return false;
  }
}

class _SendDialog extends StatefulWidget {
  const _SendDialog({required this.controller, required this.account});

  final WalletController controller;
  final WalletAccount account;

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  final _formKey = GlobalKey<FormState>();
  final _destinationController = TextEditingController();
  final _amountController = TextEditingController();
  final _signingMessageController = TextEditingController();
  final _signatureRequestTimeoutController = TextEditingController(
    text: '${defaultRoastSigningRequestTimeout.inMinutes}',
  );
  late final int _feeRateSatsPerKb;
  Duration _signatureRequestTimeout = defaultRoastSigningRequestTimeout;
  WalletTransactionPreview? _preview;
  String? _error;
  bool _submitting = false;
  bool _maximum = false;

  @override
  void initState() {
    super.initState();
    final network = PeercoinNetworks.fromWalletNetwork(
      widget.controller.networkForAccount(widget.account),
    );
    _feeRateSatsPerKb = network.network.feePerKb.toInt();
    widget.controller.addListener(_refreshMaximumAvailable);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refreshMaximumAvailable);
    _destinationController.dispose();
    _amountController.dispose();
    _signingMessageController.dispose();
    _signatureRequestTimeoutController.dispose();
    super.dispose();
  }

  void _refreshMaximumAvailable() {
    if (mounted) setState(() {});
  }

  bool get _canRequestRoastApprovals {
    if (widget.account.keySource != WalletKeySource.roast) return true;
    final setup = widget.controller.setupForAccount(widget.account);
    if (setup == null || !setup.isActive) return false;
    return widget.controller.roastCoordinatorState(setup.id) ==
        RoastCoordinatorLocalState.connected;
  }

  int? _maximumAvailableSats() {
    final address = widget.account.address;
    if (address == null) return null;

    try {
      return widget.controller
          .prepareSend(
            WalletSendRequest(
              destinationAddress: address,
              amountSats: 0,
              feeRateSatsPerKb: _feeRateSatsPerKb,
              maximum: true,
            ),
          )
          .amountSats;
    } on WalletInsufficientFunds {
      return 0;
    } on WalletTransactionFailure {
      return null;
    }
  }

  void _review() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      final signatureRequestTimeout = Duration(
        minutes: int.parse(_signatureRequestTimeoutController.text.trim()),
      );
      final preview = widget.controller.prepareSend(
        WalletSendRequest(
          destinationAddress: _destinationController.text,
          amountSats: _maximum ? 0 : _parsePpc(_amountController.text)!,
          feeRateSatsPerKb: _feeRateSatsPerKb,
          maximum: _maximum,
          signingMessage: widget.account.keySource == WalletKeySource.roast
              ? _signingMessageController.text.trim()
              : '',
        ),
      );
      setState(() {
        _preview = preview;
        _signatureRequestTimeout = signatureRequestTimeout;
        _error = null;
      });
    } on WalletTransactionFailure catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Unable to prepare the transaction.');
    }
  }

  Future<void> _send() async {
    final preview = _preview;
    if (preview == null || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await widget.controller.sendTransaction(
        preview,
        signatureRequestTimeout: _signatureRequestTimeout,
      );
      if (!mounted) return;
      Navigator.pop(context, result);
    } on WalletTransactionFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stackTrace) {
      AppLogger.error(
        '[WALLET SEND UI] Unhandled transaction submission error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _error = 'Broadcast failed. Verify the network connection and retry.';
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final canClosePendingRequest =
        _submitting && widget.account.keySource == WalletKeySource.roast;
    final canDismissFailedRequest =
        preview != null &&
        widget.controller.hasDismissibleRoastSigningOperation(
          widget.account.id,
        );
    final canSubmit = preview == null || _canRequestRoastApprovals;
    return PopScope(
      canPop: !_submitting || canClosePendingRequest,
      child: AlertDialog(
        title: Text(preview == null ? 'Send Peercoin' : 'Review transaction'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: preview == null ? _buildForm() : _buildPreview(preview),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('send-dismiss-button'),
            onPressed: _submitting
                ? canClosePendingRequest
                      ? () => Navigator.pop(context)
                      : null
                : preview == null
                ? () => Navigator.pop(context)
                : () => setState(() {
                    _preview = null;
                    _error = null;
                  }),
            child: Text(
              canClosePendingRequest
                  ? 'Close'
                  : preview == null
                  ? 'Cancel'
                  : 'Back',
            ),
          ),
          if (canDismissFailedRequest)
            TextButton(
              key: const Key('send-dismiss-failed-request-button'),
              onPressed: () async {
                final dismissed = await _dismissFailedRoastSigningOperation(
                  context,
                  widget.controller,
                  widget.account,
                );
                if (dismissed && mounted) setState(() => _error = null);
              },
              child: const Text('Dismiss failed request'),
            ),
          FilledButton(
            key: Key(
              preview == null ? 'send-review-button' : 'send-confirm-button',
            ),
            onPressed: _submitting
                ? null
                : preview == null
                ? _review
                : canSubmit
                ? _send
                : null,
            child: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    preview == null
                        ? 'Review'
                        : widget.account.keySource == WalletKeySource.roast
                        ? 'Request approvals'
                        : 'Sign and send',
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final maximumAvailableSats = _maximumAvailableSats();
    final reservedBalanceSats = widget.controller.reservedBalanceSatsFor(
      widget.account,
    );
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiddleEllipsisTextFormField(
            fieldKey: const Key('send-address-field'),
            collapsedTextKey: const Key('send-address-collapsed-value'),
            controller: _destinationController,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Destination address'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter a destination address.'
                : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const Key('send-amount-field'),
            controller: _amountController,
            enabled: !_maximum,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount',
              suffixText: 'PPC',
            ),
            validator: (value) {
              if (_maximum) return null;
              final amount = _parsePpc(value ?? '');
              return amount == null || amount <= 0
                  ? 'Enter a valid amount with up to 6 decimals.'
                  : null;
            },
          ),
          if (widget.account.keySource == WalletKeySource.roast) ...[
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('send-signing-message-field'),
              controller: _signingMessageController,
              textCapitalization: TextCapitalization.sentences,
              minLines: 2,
              maxLines: 4,
              maxLength: maxRoastSigningMessageBytes,
              decoration: const InputDecoration(
                labelText: 'Message to signers (optional)',
                helperText: 'Authenticated with the signing request.',
                alignLabelWithHint: true,
              ),
              validator: (value) {
                final byteLength = utf8.encode(value?.trim() ?? '').length;
                return byteLength > maxRoastSigningMessageBytes
                    ? 'Message must be no more than 1 KiB of UTF-8 text.'
                    : null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('send-signature-timeout-field'),
              controller: _signatureRequestTimeoutController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Request timeout',
                suffixText: 'minutes',
                helperText: 'Maximum 1440 minutes (24 hours).',
              ),
              validator: _validateSigningRequestTimeoutMinutes,
            ),
          ],
          CheckboxListTile(
            key: const Key('send-maximum-field'),
            value: _maximum,
            onChanged: (value) => setState(() {
              _maximum = value ?? false;
              _error = null;
            }),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('Send maximum available'),
            subtitle: Text(
              reservedBalanceSats > 0
                  ? '${_formatPpc(maximumAvailableSats ?? 0)} PPC available '
                        'after the network fee · '
                        '${_formatPpc(reservedBalanceSats)} PPC reserved by ROAST'
                  : maximumAvailableSats == null
                  ? 'The network fee is deducted automatically.'
                  : '${_formatPpc(maximumAvailableSats)} PPC available after '
                        'the network fee.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview(WalletTransactionPreview preview) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.account.keySource == WalletKeySource.roast
            ? 'Confirm every detail. The transaction will be sent to the '
                  'other participants for threshold approval.'
            : 'Confirm every detail before the private key signs this transaction.',
        style: TextStyle(color: AppColors.inkMuted),
      ),
      const SizedBox(height: 18),
      _TransactionRow(label: 'From', value: widget.account.name),
      _TransactionRow(
        label: 'To',
        value: preview.destinationAddress,
        monospace: true,
      ),
      _TransactionRow(
        label: 'Amount',
        value: '${_formatPpc(preview.amountSats)} PPC',
      ),
      _TransactionRow(
        label: 'Network fee',
        value: '${_formatPpc(preview.feeSats)} PPC',
      ),
      _TransactionRow(
        label: 'Change',
        value: '${_formatPpc(preview.changeSats)} PPC',
      ),
      if (preview.signingMessage.isNotEmpty)
        _TransactionRow(label: 'Message', value: preview.signingMessage),
      if (widget.account.keySource == WalletKeySource.roast)
        _TransactionRow(
          label: 'Request timeout',
          value: '${_signatureRequestTimeout.inMinutes} minutes',
        ),
      _TransactionRow(
        label: 'Inputs',
        value: '${preview.selectedUtxos.length}',
      ),
      if (_submitting && widget.account.keySource == WalletKeySource.roast) ...[
        const SizedBox(height: 12),
        const Text(
          'You can close this window. The approval request will continue in '
          'the wallet.',
          style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
        ),
      ],
      if (widget.account.keySource == WalletKeySource.roast &&
          !_canRequestRoastApprovals) ...[
        const SizedBox(height: 12),
        const Text(
          'Request approvals is unavailable because the ROAST signer is not '
          'connected to the coordinator.',
          key: Key('request-approvals-unavailable'),
          style: TextStyle(color: AppColors.warningDark, fontSize: 12),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: Colors.red)),
      ],
    ],
  );
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: const TextStyle(color: AppColors.inkMuted)),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontFamily: monospace ? 'monospace' : null,
              fontSize: monospace ? 11 : null,
            ),
          ),
        ),
      ],
    ),
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

int? _parsePpc(String input) {
  final value = input.trim();
  if (!RegExp(r'^\d+(?:\.\d{1,6})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  final whole = BigInt.tryParse(parts.first);
  final fraction = BigInt.tryParse(
    parts.length == 1 ? '0' : parts[1].padRight(6, '0'),
  );
  if (whole == null || fraction == null) return null;
  final satoshis = whole * BigInt.from(1000000) + fraction;
  // Dart's JavaScript backend represents integers exactly up to 2^53 - 1.
  if (satoshis > BigInt.parse('9007199254740991')) return null;
  return satoshis.toInt();
}

String _shortTransactionId(String transactionId) => transactionId.length <= 16
    ? transactionId
    : '${transactionId.substring(0, 8)}…${transactionId.substring(transactionId.length - 8)}';
