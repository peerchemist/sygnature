import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const identifier = 'network.noosphere.sygnature.public-feed.refresh';

  test('iOS declares the public-feed BGAppRefresh task and fetch mode', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(plist, contains('<key>BGTaskSchedulerPermittedIdentifiers</key>'));
    expect(plist, contains('<string>$identifier</string>'));
    expect(plist, contains('<key>UIBackgroundModes</key>'));
    expect(plist, contains('<string>fetch</string>'));
    expect(plist, isNot(contains('<string>remote-notification</string>')));
    expect(delegate, contains('WorkmanagerPlugin.registerPeriodicTask'));
    expect(delegate, contains(identifier));
    expect(delegate, contains('15 * 60'));
  });

  test('iOS push capability uses environment-specific signing values', () {
    final entitlements = File('ios/Runner/Runner.entitlements')
        .readAsStringSync();
    final project = File('ios/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();

    expect(entitlements, contains('<key>aps-environment</key>'));
    expect(entitlements, contains(r'<string>$(APS_ENVIRONMENT)</string>'));
    expect(project, contains('APS_ENVIRONMENT = development;'));
    expect(project, contains('APS_ENVIRONMENT = production;'));
    expect(
      project,
      contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'),
    );
  });

  test('documented APNs alert is generic and has no private routing data', () {
    final architecture = File('ARCHITECTURE.md').readAsStringSync();
    final payloadStart = architecture.indexOf('{\n  "aps"');
    final payloadEnd = architecture.indexOf('\n```', payloadStart);
    expect(payloadStart, greaterThanOrEqualTo(0));
    expect(payloadEnd, greaterThan(payloadStart));
    final payload = architecture.substring(payloadStart, payloadEnd);

    expect(payload, contains('Open Sygnature and unlock your wallet'));
    for (final forbidden in [
      '"group"',
      '"wallet"',
      'requestId',
      'transaction',
      'signer',
      'coordinator',
      'capability',
      'approval',
      'content-available',
    ]) {
      expect(payload, isNot(contains(forbidden)));
    }
  });
}
