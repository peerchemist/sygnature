import 'dart:io';
import 'dart:typed_data';

import 'package:sygnature_ng/services/backup_envelope.dart';

/// Synthetic data only. Run with: dart run tool/benchmark_wallet_backup.dart
/// On mobile, measure the same calls from a profile build on physical hardware.
Future<void> main() async {
  final timer = Stopwatch()..start();
  final baseline = ProcessInfo.currentRss;
  final file = await BackupEnvelope.encrypt(
    Uint8List.fromList([0xa0]),
    'synthetic benchmark passphrase',
  );
  final exportMs = timer.elapsedMilliseconds;
  timer.reset();
  await BackupEnvelope.decrypt(file, 'synthetic benchmark passphrase');
  stdout.writeln(
    'OS: ${Platform.operatingSystem}; CPUs: ${Platform.numberOfProcessors}; '
    'export+verification: ${exportMs}ms; import: ${timer.elapsedMilliseconds}ms; '
    'baseline RSS: $baseline; current RSS: ${ProcessInfo.currentRss}; peak RSS: ${ProcessInfo.maxRss}. '
    'Argon2id: 65536 KiB, 3 iterations, 1 lane.',
  );
}
