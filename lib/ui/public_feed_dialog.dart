import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:iroh_quic/iroh_quic.dart';

import '../models/roast_setup.dart';
import '../services/public_feed_poller.dart';
import '../storage/public_feed_store.dart';

class const PublicFeedDialog({
  super.key,
  required final PublicFeedStore store,
  required final RoastSetup setup,
  required final Future<bool> Function(int, String) notify,
  required final Future<bool?> Function() notificationPermission,
}) extends StatefulWidget {
  @override
  State<PublicFeedDialog> createState() => _PublicFeedDialogState();
}

class _PublicFeedDialogState extends State<PublicFeedDialog> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  bool? _permission;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    if (widget.setup.role == RoastSetupRole.member) {
      unawaited(_loadPermission());
    }
    _refresh = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_load()),
    );
  }

  Future<void> _loadPermission() async {
    final permission = await widget.notificationPermission();
    if (mounted) setState(() => _permission = permission);
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

  Future<void> _syncNow(String key) async {
    await widget.store.retry(key);
    await PublicFeedPoller(widget.store, notify: widget.notify).run();
    await _loadPermission();
  }

  String _time(String? value) {
    if (value == null) return 'Never';
    final time = DateTime.parse(value).toLocal();
    final now = DateTime.now();
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return 'Today at $clock';
    }
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} at $clock';
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
    final polls = data?['polls'] as Map?;
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
                if (feed != null) ...[
                  const SizedBox(height: 12),
                  _SyncHealth(
                    feed: feed,
                    foregroundPoll: polls?['foreground'] as String?,
                    backgroundPoll: polls?['background'] as String?,
                    permission: _permission,
                    formatTime: _time,
                    busy: _busy,
                    onSync: () => _perform(() => _syncNow(key!)),
                  ),
                ],
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

class const _SyncHealth({
  required final Map feed,
  required final String? foregroundPoll,
  required final String? backgroundPoll,
  required final bool? permission,
  required final String Function(String?) formatTime,
  required final bool busy,
  required final VoidCallback onSync,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final backgroundTime = backgroundPoll == null
        ? null
        : DateTime.parse(backgroundPoll!);
    final delayed =
        android &&
        (backgroundTime == null ||
            DateTime.now().toUtc().difference(backgroundTime) >
                const Duration(minutes: 45));
    final blocked = feed['blocked'] == true || permission == false;
    final issue = feed['issue'] as String?;
    final status = blocked
        ? 'Needs attention'
        : issue != null || delayed
        ? 'Delayed'
        : 'Healthy';
    final color = blocked
        ? Theme.of(context).colorScheme.error
        : issue != null || delayed
        ? Colors.amber.shade800
        : Colors.green.shade700;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          key: const Key('public-feed-sync-health'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            blocked
                ? Icons.error_outline
                : issue != null || delayed
                ? Icons.schedule
                : Icons.check_circle_outline,
            color: color,
          ),
          title: const Text('Background sync'),
          subtitle: Text(status, style: TextStyle(color: color)),
          trailing: TextButton.icon(
            key: const Key('public-feed-sync-now'),
            onPressed: busy ? null : onSync,
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
        ),
        Text(
          android
              ? 'Android checks periodically in the background. The 15-minute interval is a minimum; battery and system scheduling may delay a check.'
              : 'Background scheduling is not available on this platform. Sygnature checks while the app is open.',
        ),
        const SizedBox(height: 8),
        Text('Last foreground check: ${formatTime(foregroundPoll)}'),
        if (android)
          Text('Last background check: ${formatTime(backgroundPoll)}'),
        Text(
          'Last successful feed update: '
          '${formatTime(feed['lastSuccessfulFetchAt'] as String?)}',
        ),
        Text(
          'Notification permission: '
          '${permission == null
              ? 'Unavailable'
              : permission!
              ? 'Allowed'
              : 'Blocked'}',
        ),
        if (issue != null) ...[
          const SizedBox(height: 8),
          Text(issue),
          if (feed['retryAt'] != null)
            Text('Automatic retry: ${formatTime(feed['retryAt'] as String?)}'),
        ],
        ExpansionTile(
          key: const Key('public-feed-sync-technical-details'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text('Technical details'),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Event cursor: ${feed['cursor']}\n'
                'Pending notifications: ${(feed['outbox'] as Map).length}\n'
                'Consecutive failures: ${feed['failures']}\n'
                'History gap: ${feed['historyGap'] == true ? 'Yes' : 'No'}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
