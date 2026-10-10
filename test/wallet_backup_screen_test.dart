import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/wallet_backup.dart';
import 'package:sygnature_ng/services/backup_envelope.dart';
import 'package:sygnature_ng/services/wallet_backup_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';
import 'package:sygnature_ng/ui/wallet_backup_screen.dart';

import 'fixtures/wallet_backup_fixture.dart';

final class _SavePicker extends FilePickerPlatform {
  Uint8List? saved;
  String? name;
  Object? failure;
  int pickCalls = 0;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    pickCalls++;
    return null;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    void Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (failure != null) throw failure!;
    saved = bytes;
    name = fileName;
    expect(initialDirectory, isNull);
    return Uri.file('/synthetic/wallet.sygnaturebkp');
  }
}

void main() {
  setUpAll(NoosphereFlutter.initializeNative);
  late _SavePicker picker;
  late FilePickerPlatform previous;
  late WalletController controller;
  late MemoryWalletRepository repository;

  setUp(() async {
    previous = FilePickerPlatform.instance;
    picker = _SavePicker();
    FilePickerPlatform.instance = picker;
    final fixture = WalletBackupFixture();
    repository = MemoryWalletRepository();
    await repository.save(fixture.vault.copyWith(roastSetups: []));
    // Keep only the mnemonic-derived account, with no ROAST reference.
    repository.value = repository.value!.copyWith(
      accounts: [fixture.vault.accounts.first],
    );
    controller = WalletController(
      repository,
      backupService: WalletBackupService(repository, null),
    );
    await controller.load();
  });
  tearDown(() {
    controller.dispose();
    FilePickerPlatform.instance = previous;
  });

  Future<void> enterPassword(WidgetTester tester, String password) async {
    await tester.pumpWidget(
      MaterialApp(home: WalletBackupScreen(controller: controller)),
    );
    await tester.enterText(
      find.byKey(const Key('backup-passphrase')),
      password,
    );
    await tester.enterText(
      find.byKey(const Key('backup-passphrase-confirmation')),
      password,
    );
    await tester.ensureVisible(find.byKey(const Key('export-backup')));
    // Crypto runs in a real isolate and cannot complete with fake-async time.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('export-backup')));
      for (var i = 0; i < 200 && controller.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('rejects seven characters before exporting', (tester) async {
    await enterPassword(tester, '1234567');
    expect(
      find.text(
        'Use at least 8 characters and enter the same passphrase twice.',
      ),
      findsOneWidget,
    );
    expect(picker.saved, isNull);
  });

  testWidgets('existing wallet warns before opening an import file picker', (
    tester,
  ) async {
    final original = repository.value;
    await tester.pumpWidget(
      MaterialApp(home: WalletBackupScreen(controller: controller)),
    );
    await tester.ensureVisible(find.byKey(const Key('import-backup')));
    await tester.tap(find.byKey(const Key('import-backup')));
    await tester.pumpAndSettle();

    expect(find.text('Wallet already exists'), findsOneWidget);
    expect(
      find.textContaining('will not be overwritten or merged'),
      findsOneWidget,
    );
    expect(picker.pickCalls, 0);
    expect(repository.value, same(original));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.busy, isFalse);
  });

  testWidgets(
    'empty wallet can select a backup without an existing-wallet warning',
    (tester) async {
      controller.dispose();
      repository = MemoryWalletRepository();
      controller = WalletController(
        repository,
        backupService: WalletBackupService(repository, null),
      );
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(home: WalletBackupScreen(controller: controller)),
      );
      await tester.ensureVisible(find.byKey(const Key('import-backup')));
      await tester.tap(find.byKey(const Key('import-backup')));
      await tester.pumpAndSettle();

      expect(picker.pickCalls, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(repository.value, isNull);
    },
  );

  testWidgets('eight-character export reaches save with a recoverable file', (
    tester,
  ) async {
    await enterPassword(tester, '12345678');
    expect(picker.name, endsWith('.sygnaturebkp'));
    expect(find.textContaining('Encrypted backup saved.'), findsOneWidget);
    await tester.runAsync(() async {
      final plaintext = await BackupEnvelope.decrypt(picker.saved!, '12345678');
      final backup = WalletBackupV1.decode(plaintext);
      expect(backup.wallet!.accounts, hasLength(1));
      backup.clearSecrets();
      plaintext.fillRange(0, plaintext.length, 0);
    });
  });

  testWidgets(
    'save failure identifies stage and type without exception contents',
    (tester) async {
      picker.failure = MissingPluginException('SECRET-MESSAGE-MUST-NOT-ESCAPE');
      await enterPassword(tester, '12345678');
      expect(
        find.textContaining(
          'Saving encrypted backup failed (MissingPluginException)',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('SECRET-MESSAGE-MUST-NOT-ESCAPE'),
        findsNothing,
      );
    },
  );
}
