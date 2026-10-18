import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android excludes all app storage from backup and device transfer', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final legacyRules = File('android/app/src/main/res/xml/backup_rules.xml')
        .readAsStringSync();
    final extractionRules = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    expect(extractionRules, contains('<cloud-backup>'));
    expect(extractionRules, contains('<device-transfer>'));

    for (final domain in [
      'root',
      'file',
      'database',
      'sharedpref',
      'external',
      'device_root',
      'device_file',
      'device_database',
      'device_sharedpref',
    ]) {
      final exclusion = '<exclude domain="$domain" path="." />';
      expect(legacyRules, contains(exclusion), reason: domain);
      expect(
        extractionRules.split(exclusion),
        hasLength(3),
        reason: '$domain must be excluded from cloud and device transfer',
      );
    }
  });
}
