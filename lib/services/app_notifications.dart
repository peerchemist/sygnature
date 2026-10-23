import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_logger.dart';
import 'public_feed_notifications.dart';
import 'ui_sounds.dart';

/// User-configurable wallet event sounds and system notifications.
class AppNotifications({
  FlutterSecureStorage? storage,
  UiSounds? sounds,
  FlutterLocalNotificationsPlugin? plugin,
  final void Function(String category)? onPublicFeedOpened,
}) extends ChangeNotifier {
  // Keep the original key so existing notification preferences migrate.
  static const _systemEnabledKey = 'notifications.desktop_enabled';
  static const _systemPreferenceSetKey = 'notifications.system_preference_set';
  static const _soundEnabledKey = 'notifications.sound_enabled';
  static const _soundVolumeKey = 'notifications.sound_volume';

  final FlutterSecureStorage _storage =
      storage ??
      const FlutterSecureStorage(
        aOptions: AndroidOptions(resetOnError: false),
        mOptions: MacOsOptions(
          usesDataProtectionKeychain: false,
          // Raw kSecUseAuthenticationUIFail; the plugin forwards it unchanged.
          authenticationUIBehavior: 'u_AuthUIF',
        ),
      );
  UiSounds? _sounds = sounds;
  UiSounds get _uiSounds => _sounds ??= UiSounds();
  final FlutterLocalNotificationsPlugin _plugin =
      plugin ?? FlutterLocalNotificationsPlugin();

  bool _systemEnabled = true;
  bool _systemPreferenceSet = false;
  bool _soundEnabled = true;
  double _soundVolume = 0.5;
  bool _loaded = false;
  bool _pluginInitialized = false;
  bool _disposed = false;
  bool _launchChecked = false;
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

  Future<void> initialize({bool requestPermission = true}) async {
    await _load(failOnError: !requestPermission);
    if (onPublicFeedOpened != null && supportsSystemNotifications) {
      await _ensurePluginInitialized();
    }
    final permissionReady = await _restoreAutomaticallyDisabledSetting();
    if (_systemEnabled && supportsSystemNotifications) {
      final ready =
          permissionReady ||
          await _ensurePluginInitialized(requestPermission: requestPermission);
      if (!ready && !requestPermission) {
        throw StateError('Notification plugin initialization failed');
      }
      if (!ready &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.macOS)) {
        _systemEnabled = false;
        notifyListeners();
        _save(_systemEnabledKey, 'false');
      }
    }
  }

  Future<void> refreshSystemPermission() async {
    await _restoreAutomaticallyDisabledSetting();
  }

  Future<bool> _restoreAutomaticallyDisabledSetting() async {
    if (!_systemEnabled &&
        !_systemPreferenceSet &&
        defaultTargetPlatform == TargetPlatform.android) {
      final permissionReady = await _ensurePluginInitialized(
        checkPermission: true,
      );
      if (permissionReady) {
        _systemEnabled = true;
        notifyListeners();
        _save(_systemEnabledKey, 'true');
      }
      return permissionReady;
    }
    return false;
  }

  Future<void> _load({bool failOnError = false}) async {
    if (_loaded) return;
    _loaded = true;
    final storage = _storage;
    try {
      final values = await Future.wait([
        storage.read(key: _systemEnabledKey),
        storage.read(key: _systemPreferenceSetKey),
        storage.read(key: _soundEnabledKey),
        storage.read(key: _soundVolumeKey),
      ]);
      _systemEnabled = _parseBool(values[0], fallback: true);
      _systemPreferenceSet = _parseBool(values[1], fallback: false);
      _soundEnabled = _parseBool(values[2], fallback: true);
      _soundVolume = (double.tryParse(values[3] ?? '') ?? 0.5).clamp(0.0, 1.0);
    } catch (error, stackTrace) {
      if (failOnError) {
        _loaded = false;
        rethrow;
      }
      AppLogger.warn(
        'Unable to load notification settings',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> setSystemEnabled(bool enabled) async {
    if (enabled && !supportsSystemNotifications) return false;
    if (enabled) {
      final ready = await _ensurePluginInitialized(requestPermission: true);
      if (!ready) return false;
    }
    if (_systemEnabled == enabled) {
      if (!_systemPreferenceSet) {
        _systemPreferenceSet = true;
        _save(_systemPreferenceSetKey, 'true');
      }
      return true;
    }
    _systemEnabled = enabled;
    _systemPreferenceSet = true;
    notifyListeners();
    _save(_systemEnabledKey, '$enabled');
    _save(_systemPreferenceSetKey, 'true');
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
    sound: _uiSounds.coinsReceived,
  );

  void roastSigningRequest() => _deliver(
    title: 'Signing request',
    body: 'A ROAST signing request is waiting for your approval.',
    sound: _uiSounds.signingRequest,
  );

  void dkgRequest() => _deliver(
    title: 'Key generation request',
    body: 'A DKG request is waiting for your approval.',
    sound: _uiSounds.dkgRequest,
  );

  void roastGroupCreated() => _deliver(
    title: 'ROAST group ready',
    body: 'The new ROAST group was created successfully.',
    sound: _uiSounds.roastGroupCreated,
  );

  /// Public metadata never identifies a transaction or an approval action.
  Future<bool> publicFeedRequested(int id, String category) async {
    if (!_systemEnabled || !supportsSystemNotifications) return true;
    return _show(
      id: id,
      title: category == 'dkg'
          ? 'New key generation request'
          : 'New signing request',
      body: 'Open Sygnature and unlock your wallet to review current requests.',
      payload: '$publicFeedNotificationPayloadPrefix$category',
    );
  }

  Future<bool> sendTest() async {
    if (_soundEnabled) _uiSounds.notificationTest(volume: _soundVolume);
    if (!_systemEnabled || !supportsSystemNotifications) return false;
    return _show(
      title: 'Sygnature notifications',
      body: 'System notifications are configured correctly.',
    );
  }

  void _deliver({
    required String title,
    required String body,
    required void Function({double volume}) sound,
  }) {
    if (_soundEnabled) sound(volume: _soundVolume);
    if (_systemEnabled && supportsSystemNotifications) {
      unawaited(_show(title: title, body: body));
    }
  }

  Future<bool> _show({
    required String title,
    required String body,
    int? id,
    String? payload,
  }) async {
    if (!await _ensurePluginInitialized()) return false;
    try {
      await _plugin.show(
        id: id ?? (_notificationId++ & 0x3fffffff),
        title: title,
        body: body,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: const AndroidNotificationDetails(
            'sygnature_wallet_events',
            'Wallet events',
            channelDescription:
                'Incoming funds and ROAST requests requiring attention.',
            importance: Importance.high,
            priority: Priority.high,
            playSound: false,
            onlyAlertOnce: true,
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
      AppLogger.warn(
        'Unable to show system notification',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _ensurePluginInitialized({
    bool requestPermission = false,
    bool checkPermission = false,
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
          onDidReceiveNotificationResponse: _handleNotificationResponse,
        );
        // On macOS this result describes permission, not initialization.
        // With all automatic permission requests disabled, the native plugin
        // initializes successfully but returns false. Request permission below
        // when needed instead of treating that response as a startup failure.
        _pluginInitialized =
            defaultTargetPlatform == TargetPlatform.macOS ||
            (initialized ?? false);
      }
      if (_pluginInitialized && !_launchChecked && onPublicFeedOpened != null) {
        _launchChecked = true;
        final launch = await _plugin.getNotificationAppLaunchDetails();
        final response = launch?.notificationResponse;
        if (launch?.didNotificationLaunchApp == true && response != null) {
          _handleNotificationResponse(response);
        }
      }
      if (!_pluginInitialized) return false;
      if (defaultTargetPlatform == TargetPlatform.android &&
          (requestPermission || checkPermission)) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (android == null) return false;
        if (requestPermission) {
          final granted = await android.requestNotificationsPermission();
          if (granted == true) return true;
        }
        return await android.areNotificationsEnabled() ?? false;
      }
      if (requestPermission) {
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
      AppLogger.warn(
        'System notifications unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null ||
        !payload.startsWith(publicFeedNotificationPayloadPrefix)) {
      return;
    }
    final category = payload.substring(
      publicFeedNotificationPayloadPrefix.length,
    );
    if (category != 'signing' && category != 'dkg') return;
    onPublicFeedOpened?.call(category);
  }

  void _save(String key, String value) {
    final storage = _storage;
    _pendingSave = _pendingSave.then((_) async {
      try {
        await storage.write(key: key, value: value);
      } catch (error, stackTrace) {
        AppLogger.warn(
          'Unable to save notification settings',
          error: error,
          stackTrace: stackTrace,
        );
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
    unawaited(_sounds?.dispose());
    super.dispose();
  }
}
