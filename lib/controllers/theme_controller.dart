import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/app_logger.dart';

class ThemeController extends ValueNotifier<ThemeMode> {
  new({
    this.storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
      mOptions: MacOsOptions(
        usesDataProtectionKeychain: false,
        authenticationUIBehavior: 'u_AuthUIF',
      ),
    ),
  }) : super(ThemeMode.system);

  final FlutterSecureStorage storage;
  static const storageKey = 'appearance.theme_mode';
  bool _disposed = false;
  bool _changed = false;
  Future<void> _pendingSave = Future.value();

  Future<void> initialize() async {
    try {
      final saved = await storage.read(key: storageKey);
      if (_disposed || _changed) return;
      value = switch (saved) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (error, stackTrace) {
      AppLogger.warn(
        'Unable to load theme preference',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> setMode(ThemeMode mode) {
    _changed = true;
    value = mode;
    final save = _pendingSave.then((_) async {
      try {
        await storage.write(key: storageKey, value: mode.name);
        return true;
      } catch (error, stackTrace) {
        AppLogger.warn(
          'Unable to save theme preference',
          error: error,
          stackTrace: stackTrace,
        );
        return false;
      }
    });
    _pendingSave = save.then((_) {});
    return save;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
