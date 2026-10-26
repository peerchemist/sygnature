import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

enum AppDiagnosticEvent {
  backgroundWorkStarted,
  backgroundWorkSucceeded,
  backgroundWorkFailed,
  notificationInitializationSucceeded,
  notificationInitializationFailed,
  notificationDelivered,
  notificationDeliveryFailed,
  nativeInitializationStarted,
  nativeInitializationSucceeded,
  nativeInitializationFailed,
}

abstract final class AppDiagnostics {
  static const _maxFileBytes = 128 * 1024;
  static File? _file;
  static Future<void> _writes = Future.value();

  static Future<void> initialize(String directory) async {
    try {
      await Directory(directory).create(recursive: true);
      _file = File(p.join(directory, 'sygnature-diagnostics.jsonl'));
    } on Object {
      _file = null;
    }
  }

  static Future<void> record(AppDiagnosticEvent event, {Object? error}) {
    final file = _file;
    if (file == null) return Future.value();
    final line = jsonEncode({
      'at': DateTime.now().toUtc().toIso8601String(),
      'event': event.name,
      if (error != null) 'errorType': '${error.runtimeType}',
    });
    _writes = _writes.then((_) => _append(file, line)).catchError((_) {});
    return _writes;
  }

  static Future<Uint8List> exportReport({
    required String appVersion,
    required String platform,
    required bool notificationEnabled,
    required bool? notificationPermissionGranted,
    required int? backgroundFrequencyMinutes,
  }) async {
    await _writes;
    final report = {
      'format': 'sygnature-diagnostics-v1',
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
      'platform': platform,
      'configuration': {
        'notificationsEnabled': notificationEnabled,
        'notificationPermissionGranted': notificationPermissionGranted,
        'backgroundFrequencyMinutes': backgroundFrequencyMinutes,
      },
      'events': await _readEvents(),
    };
    return Uint8List.fromList(
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(report)}\n'),
    );
  }

  static Future<void> _append(File file, String line) async {
    final reset = await file.exists() && await file.length() >= _maxFileBytes;
    await file.writeAsString(
      '$line\n',
      mode: reset ? FileMode.write : FileMode.append,
      flush: true,
    );
  }

  static Future<List<Map<String, Object?>>> _readEvents() async {
    final file = _file;
    if (file == null || !await file.exists()) return [];
    try {
      final events = <Map<String, Object?>>[];
      for (final line in await file.readAsLines()) {
        try {
          final event = jsonDecode(line);
          if (event is Map<String, dynamic>) {
            events.add(event.cast<String, Object?>());
          }
        } on FormatException {
          // Ignore a partial line from an interrupted write.
        }
      }
      return events;
    } on Object {
      return [];
    }
  }
}
