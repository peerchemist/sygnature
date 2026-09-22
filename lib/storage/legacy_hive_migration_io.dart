import 'dart:io';

import 'package:path/path.dart' as path;

/// Copies the known Hive data files from the old documents location.
///
/// Source files are deliberately retained so migration is recoverable. Lock
/// files are not copied because the target process creates its own lock.
Future<void> migrateLegacyHiveBox({
  required String boxName,
  required String legacyDirectory,
  required String targetDirectory,
}) async {
  if (path.equals(legacyDirectory, targetDirectory)) return;

  final targetHive = File(path.join(targetDirectory, '$boxName.hive'));
  final targetCompacted = File(path.join(targetDirectory, '$boxName.hivec'));
  if (await targetHive.exists() || await targetCompacted.exists()) return;

  final legacyHive = File(path.join(legacyDirectory, '$boxName.hive'));
  final legacyCompacted = File(path.join(legacyDirectory, '$boxName.hivec'));
  if (!await legacyHive.exists() && !await legacyCompacted.exists()) return;

  await Directory(targetDirectory).create(recursive: true);
  await _copyAtomicallyIfPresent(legacyHive, targetHive);
  await _copyAtomicallyIfPresent(legacyCompacted, targetCompacted);
}

Future<void> _copyAtomicallyIfPresent(File source, File target) async {
  if (!await source.exists()) return;
  final temporary = File('${target.path}.migrating');
  if (await temporary.exists()) await temporary.delete();
  await source.copy(temporary.path);
  await temporary.rename(target.path);
}
