import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const publicFeedNotificationPayloadPrefix = 'public-feed:';
const androidWalletAlerts = AndroidNotificationDetails(
  'sygnature_wallet_alerts',
  'Wallet alerts',
  channelDescription: 'Incoming funds and ROAST requests requiring attention.',
  importance: Importance.high,
  priority: Priority.high,
  playSound: true,
  enableVibration: true,
  onlyAlertOnce: true,
);
const appleWalletAlerts = DarwinNotificationDetails(
  presentAlert: true,
  presentSound: true,
  threadIdentifier: 'sygnature-wallet-events',
);

/// Notification delivery for the headless Android/iOS public-feed worker.
///
/// Public-feed subscriptions decide whether delivery is enabled. This class
/// deliberately has no dependency on wallet storage or foreground settings.
class PublicFeedNotifications({FlutterLocalNotificationsPlugin? plugin}) {
  final FlutterLocalNotificationsPlugin _plugin =
      plugin ?? FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    try {
      final initialized = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      // Darwin reports notification authorization from initialize. A headless
      // catch-up worker deliberately does not request it, so false does not
      // mean that plugin setup failed on iOS.
      _initialized =
          defaultTargetPlatform == TargetPlatform.iOS || (initialized ?? false);
    } on Object {
      _initialized = false;
    }
    if (!_initialized) {
      throw StateError('Notification plugin initialization failed');
    }
  }

  Future<bool> publicFeedRequested(int id, String category) async {
    if (!_initialized) return false;
    try {
      await _plugin.show(
        id: id,
        title: category == 'dkg'
            ? 'New key generation request'
            : 'New signing request',
        body:
            'Open Sygnature and unlock your wallet to review current requests.',
        payload: '$publicFeedNotificationPayloadPrefix$category',
        notificationDetails: const NotificationDetails(
          android: androidWalletAlerts,
          iOS: appleWalletAlerts,
        ),
      );
      return true;
    } on Object {
      return false;
    }
  }
}
