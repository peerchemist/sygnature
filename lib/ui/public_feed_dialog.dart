import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
        setState(() => _error = 'Could not update public feed settings.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _subscribe() async {
    final setup = widget.setup;
    if (setup.coordinatorId == null) {
      throw StateError('Coordinator not enrolled');
    }
    await initializePublicFeedNative();
    final address = EndpointAddr(
      EndpointId.fromZ32(setup.coordinatorId!),
      relayUrls: setup.coordinatorRelayUrls.map(RelayUrl.parse).toList(),
      ipAddrs: setup.coordinatorIpAddrs,
    );
    await widget.store.subscribe(
      groupId: setup.groupId,
      address: base64UrlEncode(address.canonical().encode()),
      pin: address.id.toZ32(),
      feedId: await publicFeedIdForGroup(setup.groupId),
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
    final isMember = widget.setup.role == RoastSetupRole.member;
    final host = (data?['hosts'] as Map?)?[group] as Map?;
    final key = (data?['bindings'] as Map?)?[group] as String?;
    final feed = (data?['feeds'] as Map?)?[key] as Map?;
    final notificationsEnabled =
        !((data?['disabledGroups'] as List?) ?? const []).contains(group);
    final events = ((feed?['events'] as Map?) ?? {}).entries.toList()
      ..sort(
        (a, b) =>
            (b.value['cursor'] as int).compareTo(a.value['cursor'] as int),
      );
    return AlertDialog(
      title: Text(
        isMember ? 'Receive background notifications' : 'Public operation feed',
      ),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isMember) ...[
                const Text(
                  'Get notified when this shared wallet has a new signing or key-setup request. On Android, Sygnature checks periodically in the background, so delivery may be delayed; on other platforms it checks while the app is open. Notifications contain no transaction or message details—open and unlock the wallet to review the request.',
                ),
                const SizedBox(height: 12),
              ] else ...[
                const Text(
                  'Publishes basic request status so wallet members can receive background notifications. Transaction, message, signer and approval details are not shared.',
                ),
                const SizedBox(height: 12),
              ],
              if (widget.setup.role == RoastSetupRole.host) ...[
                SwitchListTile(
                  key: const Key('public-feed-host-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Publish this group’s public feed'),
                  subtitle: const Text(
                    'Restart Sygnature after changing this setting.',
                  ),
                  value: host?['enabled'] != false,
                  onChanged: _busy || data == null
                      ? null
                      : (value) => _perform(() async {
                          await widget.store.configureHost(group, value);
                          if (!value) await widget.store.unsubscribe(group);
                        }),
                ),
              ],
              if (widget.setup.role == RoastSetupRole.member) ...[
                SwitchListTile(
                  key: const Key('public-feed-member-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Background notifications'),
                  value: notificationsEnabled,
                  onChanged: _busy || data == null
                      ? null
                      : (value) => _perform(
                          value
                              ? _subscribe
                              : () => widget.store.unsubscribe(group),
                        ),
                ),
              ],
              if (!isMember && feed != null) ...[
                const SizedBox(height: 12),
                if (feed['pin'] != widget.setup.coordinatorId)
                  const Text(
                    'This subscription belongs to a previous coordinator. Re-enable notifications to use the current coordinator.',
                  ),
                if (events.isNotEmpty) const Text('Recent events'),
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
                    child: const Text('Retry'),
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
