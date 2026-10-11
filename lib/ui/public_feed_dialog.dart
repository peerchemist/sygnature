import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iroh_quic/iroh_quic.dart';

import '../models/roast_setup.dart';
import '../services/public_feed_poller.dart';
import '../storage/public_feed_store.dart';

class const PublicFeedDialog({
  super.key,
  required final PublicFeedStore store,
  required final RoastSetup setup,
}) extends StatefulWidget {
  @override
  State<PublicFeedDialog> createState() => _PublicFeedDialogState();
}

class _PublicFeedDialogState extends State<PublicFeedDialog> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  bool _trusted = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _refresh = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_load()),
    );
  }

  Future<void> _load() async {
    try {
      final data = await widget.store.snapshot();
      if (mounted) setState(() => _data = data);
    } on Object {
      if (mounted) setState(() => _error = 'Public feed settings unavailable.');
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } on Object {
      if (mounted) {
        setState(
          () => _error = 'Could not update feed settings. Verify the trusted share and coordinator identity.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (!_trusted) return;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final share = RoastExchangeCodec.decodePublicFeed(clipboard?.text ?? '');
    // Pin is already trusted through wallet enrollment/explicit coordinator
    // approval. Never learn an endpoint identity from a feed response/share.
    if (widget.setup.coordinatorId == null ||
        share.pin != widget.setup.coordinatorId) {
      throw const FormatException(
        'Feed pin does not match enrolled coordinator',
      );
    }
    await initializePublicFeedNative();
    final pin = EndpointId.fromZ32(share.pin);
    final address = EndpointAddr.decode(base64Url.decode(share.address));
    if (address.id != pin) throw const FormatException('Address pin mismatch');
    await widget.store.subscribe(
      groupId: widget.setup.groupId,
      address: base64UrlEncode(address.canonical().encode()),
      pin: pin.toZ32(),
      feedId: share.feedId,
    );
  }

  Future<void> _export(String feedId) async {
    final setup = widget.setup;
    if (setup.coordinatorId == null) {
      throw StateError('Coordinator not started');
    }
    await initializePublicFeedNative();
    final address = EndpointAddr(
      EndpointId.fromZ32(setup.coordinatorId!),
      relayUrls: setup.coordinatorRelayUrls.map(RelayUrl.parse).toList(),
      ipAddrs: setup.coordinatorIpAddrs,
    );
    await Clipboard.setData(
      ClipboardData(
        text: RoastExchangeCodec.encodePublicFeed(
          address: base64UrlEncode(address.encode()),
          pin: address.id.toZ32(),
          feedId: feedId,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final group = widget.setup.groupId;
    final host = (data?['hosts'] as Map?)?[group] as Map?;
    final key = (data?['bindings'] as Map?)?[group] as String?;
    final feed = (data?['feeds'] as Map?)?[key] as Map?;
    final events = ((feed?['events'] as Map?) ?? {}).entries.toList()
      ..sort(
        (a, b) =>
            (b.value['cursor'] as int).compareTo(a.value['cursor'] as int),
      );
    return AlertDialog(
      title: const Text('Public operation feed'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Anyone who knows the feed ID can see operation type, timing and outcome. There is no directory, but unlisted metadata is not private to people who know the ID.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Public events contain no transaction/message details, signer counts or approval actions. Open the wallet’s authenticated requests to review current state. Initial retained history is silent; only new requests observed within five minutes can notify.',
              ),
              if (widget.setup.role == RoastSetupRole.host) ...[
                SwitchListTile(
                  key: const Key('public-feed-host-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Publish this group’s public feed'),
                  subtitle: const Text(
                    'Saved before coordinator startup. Restart Sygnature to apply publishing changes. Enrollment groups opt in separately from the bootstrap group.',
                  ),
                  value: host?['enabled'] == true,
                  onChanged: _busy || data == null
                      ? null
                      : (value) => _perform(() async {
                          await widget.store.configureHost(group, value);
                          if (!value) await widget.store.unsubscribe(group);
                        }),
                ),
                if (host?['feedId'] != null)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _perform(
                            () => _export(host!['feedId'] as String),
                          ),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy public feed share'),
                  ),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _trusted,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _trusted = value == true),
                title: const Text(
                  'I obtained this feed share through the trusted enrollment/share channel',
                ),
                subtitle: const Text(
                  'The coordinator pin must match this wallet’s already enrolled/approved identity. Verify the feed ID with the coordinator owner.',
                ),
              ),
              OutlinedButton(
                onPressed: _busy || !_trusted ? null : () => _perform(_import),
                child: const Text('Subscribe from clipboard'),
              ),
              if (feed != null) ...[
                const SizedBox(height: 12),
                SelectableText('Pinned coordinator: ${feed['pin']}'),
                if (feed['pin'] != widget.setup.coordinatorId)
                  const Text(
                    'This feed belongs to a previously selected coordinator. Import a trusted share for the current coordinator.',
                  ),
                Text('Processed cursor: ${feed['cursor']}'),
                const Text(
                  'Recent public observations (bounded cache; not a complete operation history).',
                ),
                if (feed['historyGap'] == true)
                  const Text(
                    'History gap: some coordinator history is no longer available.',
                  ),
                if (feed['issue'] != null) Text(feed['issue'] as String),
                if (feed['issue'] != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _perform(() => widget.store.retry(key!)),
                    child: const Text('Retry with the same pin and cursor'),
                  ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(() => widget.store.unsubscribe(group)),
                  child: const Text('Stop polling on this device'),
                ),
                for (final event in events.take(20))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${event.value['category']} · ${event.value['state']}',
                    ),
                    subtitle: Text(
                      '${event.value['observedAt']}\nPublic event ${event.key}',
                    ),
                  ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
