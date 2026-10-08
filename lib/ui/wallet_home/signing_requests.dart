part of '../wallet_home.dart';

Future<void> _showRoastRequests(
  BuildContext context,
  WalletController controller, {
  bool? desktop,
}) async {
  await _showAdaptivePanel(
    context,
    desktop: desktop,
    builder: (panelContext, desktop) => SelectorBuilder(
      listenable: controller,
      select: () => [
        ...controller.roastSigningRequests,
        for (final item in controller.roastSigningRequests)
          controller.roastSetups
              .where((setup) => setup.id == item.setupId)
              .firstOrNull,
      ],
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
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
                        'Signing requests',
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
                const Text(
                  'Approve only after verifying the exact signed message or '
                  'every transaction recipient, amount, fee and change output.',
                  style: TextStyle(color: AppColors.inkMuted),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: controller.roastSigningRequests.isEmpty
                      ? const Center(child: Text('No pending requests.'))
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: controller.roastSigningRequests.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) => _RoastRequestCard(
                            controller: controller,
                            item: controller.roastSigningRequests[index],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class const _RoastRequestCard({
  required final WalletController controller,
  required final RoastSigningInboxItem item,
}) extends StatefulWidget {
  @override
  State<_RoastRequestCard> createState() => _RoastRequestCardState();
}

class _RoastRequestCardState extends State<_RoastRequestCard> {
  bool _busy = false;
  String? _error;

  Future<void> _perform(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.item.request;
    final requester = widget.controller.roastSetups
        .where((setup) => setup.id == widget.item.setupId)
        .firstOrNull
        ?.participants
        .where((participant) => participant.identifierHex == request.creator)
        .firstOrNull;
    final requesterLabel = requester == null
        ? _shortTransactionId(request.creator)
        : '${_shortTransactionId(requester.publicKeyHex)} (${requester.name})';
    final signsMessage = request.kind == RoastSigningRequestKind.message;
    final waitingForDecision = request.status == 'waiting';
    final progress = request.progress;
    final progressColor = switch (progress.stage) {
      'completed' => AppColors.success,
      'failed' => AppColors.danger,
      _ => AppColors.warningDark,
    };
    return Card(
      key: ValueKey('roast-signing-request-${request.idHex}'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.approval_outlined,
                  color: AppColors.danger,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '${signsMessage ? 'MESSAGE' : 'TRANSACTION'} SIGNATURE · '
                  '${switch (request.status) {
                    'accepted' => 'ACCEPTED',
                    'rejected' => 'REJECTED',
                    _ => 'ACTION REQUIRED',
                  }}',
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              widget.item.walletName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              signsMessage
                  ? 'Requested by $requesterLabel · '
                        'shared group key'
                  : 'Requested by $requesterLabel · '
                        '${request.masterGroupKeys.length} input(s)',
              style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Container(
              key: Key('roast-signing-progress-${request.idHex}'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: progressColor.withValues(alpha: 0.08),
                border: Border.all(
                  color: progressColor.withValues(alpha: 0.35),
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    switch (progress.stage) {
                      'signing' => 'Signing',
                      'completed' => 'Signature complete',
                      'failed' => 'Signing failed',
                      _ => 'Collecting approvals',
                    },
                    style: TextStyle(
                      color: progressColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${progress.contributingParticipants.length}/'
                    '${progress.threshold} required signers',
                    style: const TextStyle(color: AppColors.ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Local status: ${switch (request.status) {
                      'accepted' => 'accepted',
                      'rejected' => 'rejected',
                      _ => 'awaiting decision',
                    }}',
                    style: const TextStyle(
                      color: AppColors.inkMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (request.signedMessageText case final signedText?) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('roast-signed-message-request-text'),
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
                    const Text(
                      'EXACT MESSAGE TO SIGN',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(signedText),
                  ],
                ),
              ),
            ],
            if (request.message.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('roast-signing-request-message'),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.35),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'REQUEST NOTE · AUTHENTICATED',
                      style: TextStyle(
                        color: AppColors.warningDark,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(request.message),
                  ],
                ),
              ),
            ],
            if (!signsMessage) ...[
              const Divider(height: 24),
              for (var i = 0; i < request.outputs.length; i++)
                _TransactionRow(
                  label:
                      widget.controller.isRoastChangeOutput(
                        widget.item,
                        request.outputs[i],
                      )
                      ? 'Change'
                      : 'Recipient',
                  value:
                      '${widget.controller.roastOutputAddress(widget.item, request.outputs[i])}\n'
                      '${_formatPpc(request.outputs[i].valueSats)} PPC',
                  monospace: true,
                ),
              _TransactionRow(
                label: 'Network fee',
                value: '${_formatPpc(request.feeSats)} PPC',
              ),
            ] else
              const SizedBox(height: 12),
            _TransactionRow(
              label: 'Expires',
              value: request.expiry.toLocal().toString(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (waitingForDecision) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _perform(
                            () => widget.controller.rejectRoastSigningRequest(
                              widget.item,
                            ),
                          ),
                    child: const Text('Reject'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _perform(
                            () => widget.controller.acceptRoastSigningRequest(
                              widget.item,
                            ),
                          ),
                    child: Text(_busy ? 'Submitting…' : 'Approve and sign'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
