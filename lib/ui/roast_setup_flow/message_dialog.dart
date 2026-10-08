part of '../roast_setup_flow.dart';

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
                semanticsLabel:
                    'Signatures collected: $collected of $threshold',
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
