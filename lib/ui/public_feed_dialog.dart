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
  static const _notificationWindows = {
    15: '15 minutes',
    30: '30 minutes',
    60: '1 hour',
    180: '3 hours',
    360: '6 hours',
    720: '12 hours',
    1440: '24 hours',
  };

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
    final host = (data?['hosts'] as Map?)?[group] as Map?;
    final key = (data?['bindings'] as Map?)?[group] as String?;
    final feed = (data?['feeds'] as Map?)?[key] as Map?;
    final hasCurrentFeed =
        feed != null &&
        widget.setup.coordinatorId != null &&
        feed['pin'] == widget.setup.coordinatorId;
    final notificationWindow =
        data?['notificationWindowMinutes'] as int? ??
        publicFeedDefaultNotificationWindow.inMinutes;
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
                'Public events contain no transaction/message details, signer counts or approval actions. Open the wallet’s authenticated requests to review current state. Initial retained history is silent.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: const Key('public-feed-notification-window'),
                initialValue: notificationWindow,
                decoration: const InputDecoration(
                  labelText: 'Notify about requests observed within',
                  helperText:
                      'Applies to this device. Expired requests never notify.',
                ),
                items: [
                  for (final option in _notificationWindows.entries)
                    DropdownMenuItem(
                      value: option.key,
                      child: Text(option.value),
                    ),
                ],
                onChanged: _busy || data == null
                    ? null
                    : (minutes) {
                        if (minutes == null) return;
                        _perform(
                          () => widget.store.setNotificationWindow(
                            Duration(minutes: minutes),
                          ),
                        );
                      },
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
              ],
              if (widget.setup.role == RoastSetupRole.member) ...[
                SwitchListTile(
                  key: const Key('public-feed-member-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Receive notifications on this device'),
                  subtitle: const Text(
                    'Included in this wallet’s onboarding setup.',
                  ),
                  value: hasCurrentFeed,
                  onChanged: _busy || data == null
                      ? null
                      : (value) => _perform(
                          value
                              ? _subscribe
                              : () => widget.store.unsubscribe(group),
                        ),
                ),
              ],
              if (feed != null) ...[
                const SizedBox(height: 12),
                if (feed['pin'] != widget.setup.coordinatorId)
                  const Text(
                    'This subscription belongs to a previous coordinator. Re-enable notifications to use the current coordinator.',
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
                    child: const Text('Retry'),
                  ),
                if (widget.setup.role == RoastSetupRole.host)
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
