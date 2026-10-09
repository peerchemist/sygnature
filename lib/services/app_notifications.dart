import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ui_sounds.dart';

/// User-configurable wallet event sounds and system notifications.
class AppNotifications({
  FlutterSecureStorage? storage,
  UiSounds? sounds,
  FlutterLocalNotificationsPlugin? plugin,
}) extends ChangeNotifier {
  // Keep the original key so existing notification preferences migrate.
  static const _systemEnabledKey = 'notifications.desktop_enabled';
  static const _soundEnabledKey = 'notifications.sound_enabled';
  static const _soundVolumeKey = 'notifications.sound_volume';

  final FlutterSecureStorage? _storage =
      storage ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
          ? null
          : const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: true),
            ));
  final UiSounds _sounds = sounds ?? UiSounds();
  final FlutterLocalNotificationsPlugin _plugin =
      plugin ?? FlutterLocalNotificationsPlugin();

  bool _systemEnabled = true;
  bool _soundEnabled = true;
  double _soundVolume = 0.5;
  bool _loaded = false;
  bool _pluginInitialized = false;
  bool _disposed = false;
  int _notificationId = 0;
  Future<void> _pendingSave = Future<void>.value();

  bool get systemEnabled => _systemEnabled;
  bool get soundEnabled => _soundEnabled;
  double get soundVolume => _soundVolume;

  bool get supportsSystemNotifications =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<void> initialize() async {
    await _load();
    if (_systemEnabled && supportsSystemNotifications) {
      final ready = await _ensurePluginInitialized(requestPermission: true);
      if (!ready &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.macOS)) {
        _systemEnabled = false;
        notifyListeners();
        _save(_systemEnabledKey, 'false');
      }
    }
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final storage = _storage;
    if (storage == null) return;
    try {
      final values = await Future.wait([
        storage.read(key: _systemEnabledKey),
        storage.read(key: _soundEnabledKey),
        storage.read(key: _soundVolumeKey),
      ]);
      _systemEnabled = _parseBool(values[0], fallback: true);
      _soundEnabled = _parseBool(values[1], fallback: true);
      _soundVolume = (double.tryParse(values[2] ?? '') ?? 0.5).clamp(0.0, 1.0);
    } catch (error, stackTrace) {
      debugPrint('Unable to load notification settings: $error\n$stackTrace');
    }
  }

  Future<bool> setSystemEnabled(bool enabled) async {
    if (enabled && !supportsSystemNotifications) return false;
    if (enabled) {
      final ready = await _ensurePluginInitialized(requestPermission: true);
      if (!ready) return false;
    }
    if (_systemEnabled == enabled) return true;
    _systemEnabled = enabled;
    notifyListeners();
    _save(_systemEnabledKey, '$enabled');
    return true;
  }

  void setSoundEnabled(bool enabled) {
    if (_soundEnabled == enabled) return;
    _soundEnabled = enabled;
    notifyListeners();
    _save(_soundEnabledKey, '$enabled');
  }

  void setSoundVolume(double volume) {
    final normalized = volume.clamp(0.0, 1.0);
    if (_soundVolume == normalized) return;
    _soundVolume = normalized;
    notifyListeners();
    _save(_soundVolumeKey, '$normalized');
  }

  void coinsReceived() => _deliver(
    title: 'Coins received',
    body: 'New funds were received by your wallet.',
  );

  void roastActionRequired() => _deliver(
    title: 'Action required',
    body: 'A ROAST signing request is waiting for your approval.',
  );

  Future<bool> sendTest() async {
    if (_soundEnabled) _sounds.message(volume: _soundVolume);
    if (!_systemEnabled || !supportsSystemNotifications) return false;
    return _show(
      title: 'Sygnature notifications',
      body: 'System notifications are configured correctly.',
    );
  }

  void _deliver({required String title, required String body}) {
    if (_soundEnabled) _sounds.message(volume: _soundVolume);
    if (_systemEnabled && supportsSystemNotifications) {
      unawaited(_show(title: title, body: body));
    }
  }

  Future<bool> _show({required String title, required String body}) async {
    if (!await _ensurePluginInitialized()) return false;
    try {
      await _plugin.show(
        id: _notificationId++ & 0x7fffffff,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: const AndroidNotificationDetails(
            'sygnature_wallet_events',
            'Wallet events',
            channelDescription:
                'Incoming funds and ROAST requests requiring attention.',
            importance: Importance.high,
            priority: Priority.high,
            playSound: false,
          ),
          macOS: const DarwinNotificationDetails(
            presentSound: false,
            threadIdentifier: 'sygnature-wallet-events',
          ),
          linux: const LinuxNotificationDetails(suppressSound: true),
          windows: WindowsNotificationDetails(
            audio: WindowsNotificationAudio.silent(),
          ),
        ),
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint('Unable to show system notification: $error\n$stackTrace');
      return false;
    }
  }

  Future<bool> _ensurePluginInitialized({
    bool requestPermission = false,
  }) async {
    if (!supportsSystemNotifications) return false;
    try {
      if (!_pluginInitialized) {
        final initialized = await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('ic_notification'),
            macOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
              defaultPresentSound: false,
            ),
            linux: LinuxInitializationSettings(
              defaultActionName: 'Open Sygnature',
              defaultSuppressSound: true,
            ),
            windows: WindowsInitializationSettings(
              appName: 'Sygnature',
              appUserModelId: 'Peerchemist.Sygnature.Wallet',
              guid: '2d6d6872-d9db-48fa-8519-d21396406f56',
            ),
          ),
        );
        _pluginInitialized = initialized ?? false;
      }
      if (!_pluginInitialized) return false;
      if (requestPermission) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin
                  >()
                  ?.requestNotificationsPermission() ??
              false;
        }
        if (defaultTargetPlatform == TargetPlatform.macOS) {
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin
                  >()
                  ?.requestPermissions(alert: true) ??
              false;
        }
      }
      return true;
    } catch (error, stackTrace) {
      debugPrint('System notifications unavailable: $error\n$stackTrace');
      return false;
    }
  }

  void _save(String key, String value) {
    final storage = _storage;
    if (storage == null) return;
    _pendingSave = _pendingSave.then((_) async {
      try {
        await storage.write(key: key, value: value);
      } catch (error, stackTrace) {
        debugPrint('Unable to save notification settings: $error\n$stackTrace');
      }
    });
  }

  static bool _parseBool(String? value, {required bool fallback}) =>
      switch (value) {
        'true' => true,
        'false' => false,
        _ => fallback,
      };

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_sounds.dispose());
    super.dispose();
  }
}
