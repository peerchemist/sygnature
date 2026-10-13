import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/theme_controller.dart';
import 'package:sygnature_ng/ui/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to system and restores the saved choice', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = ThemeController();
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.value, ThemeMode.system);
    expect(await controller.setMode(ThemeMode.dark), isTrue);
    final restored = ThemeController();
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.value, ThemeMode.dark);
  });

  test('unknown preferences fall back to system', () async {
    FlutterSecureStorage.setMockInitialValues({
      ThemeController.storageKey: 'unknown',
    });
    final controller = ThemeController();
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.value, ThemeMode.system);
  });

  test('both palettes keep text and status colors readable', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance();
      final y = b.computeLuminance();
      return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
    }

    for (final brightness in Brightness.values) {
      final colors = AppColors(brightness);
      final theme = buildAppTheme(brightness: brightness);
      expect(theme.brightness, brightness);
      for (final background in [colors.canvas, colors.surface]) {
        expect(contrast(colors.ink, background), greaterThanOrEqualTo(4.5));
        expect(
          contrast(colors.inkMuted, background),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(
        contrast(colors.success, colors.successSurface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.danger, colors.dangerSurface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.warningDark, colors.warning),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(theme.colorScheme.onPrimary, theme.colorScheme.primary),
        greaterThanOrEqualTo(4.5),
      );
    }
  });
}
