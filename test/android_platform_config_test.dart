import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android manifest and themes enable modern platform behavior', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/network/noosphere/sygnature/MainActivity.kt',
    ).readAsStringSync();

    expect(manifest, contains('android:enableOnBackInvokedCallback="true"'));
    expect(manifest, contains('<intent-filter android:autoVerify="true">'));
    expect(manifest, contains('android:scheme="https"'));
    expect(manifest, contains('android:host="noosphere.network"'));
    expect(manifest, contains('android:path="/roast"'));
    expect(activity, contains('setDecorFitsSystemWindows(window, false)'));
    for (final directory in ['values-v31', 'values-night-v31']) {
      final splash = File('android/app/src/main/res/$directory/styles.xml')
          .readAsStringSync();
      expect(splash, contains('android:windowSplashScreenBackground'));
      expect(splash, contains('android:windowSplashScreenAnimatedIcon'));
    }

    for (final capability in [
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_SHORT_SERVICE',
      'androidx.work.impl.foreground.SystemForegroundService',
    ]) {
      expect(
        manifest,
        contains(
          RegExp('${RegExp.escape(capability)}[^>]+tools:node="remove"'),
        ),
        reason: capability,
      );
    }
  });
}
