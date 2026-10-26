import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/app_diagnostics.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-diagnostics-');
    await AppDiagnostics.initialize(directory.path);
  });

  tearDown(() => directory.delete(recursive: true));

  test('exports structured events without exception messages', () async {
    await AppDiagnostics.record(
      AppDiagnosticEvent.nativeInitializationFailed,
      error: StateError('wallet-secret coordinator-id request-id'),
    );

    final bytes = await AppDiagnostics.exportReport(
      appVersion: '0.9.53+39',
      platform: 'android',
      notificationEnabled: true,
      notificationPermissionGranted: true,
      backgroundFrequencyMinutes: 60,
    );
    final text = utf8.decode(bytes);
    final report = jsonDecode(text) as Map<String, dynamic>;
    final events = report['events'] as List;

    expect(text, isNot(contains('wallet-secret')));
    expect(text, isNot(contains('coordinator-id')));
    expect(text, isNot(contains('request-id')));
    expect(report['format'], 'sygnature-diagnostics-v1');
    expect(report['platform'], 'android');
    expect((report['configuration'] as Map)['backgroundFrequencyMinutes'], 60);
    expect(events, hasLength(1));
    expect(events.single['event'], 'nativeInitializationFailed');
    expect(events.single['errorType'], 'StateError');
  });
}
