import 'package:flutter/material.dart';

import '../controllers/theme_controller.dart';

class const AppColors(final Brightness brightness) {
  static AppColors of(BuildContext context) =>
      AppColors(Theme.of(context).brightness);

  bool get _dark => brightness == Brightness.dark;

  Color get ink => _dark ? const Color(0xffe5e7e1) : const Color(0xff20221f);
  Color get inkMuted =>
      _dark ? const Color(0xffaab0a7) : const Color(0xff666a64);
  Color get forest => _dark ? const Color(0xff91d5a9) : const Color(0xff24583b);
  Color get green => _dark ? const Color(0xff91d5a9) : const Color(0xff3a7d57);
  Color get greenDark =>
      _dark ? const Color(0xff91d5a9) : const Color(0xff24583b);
  Color get success =>
      _dark ? const Color(0xff7cdaa5) : const Color(0xff087a41);
  Color get successSurface =>
      _dark ? const Color(0xff153c29) : const Color(0xffe7f6ed);
  Color get danger => _dark ? const Color(0xffffb4ab) : const Color(0xffb42318);
  Color get dangerSurface =>
      _dark ? const Color(0xff4b2523) : const Color(0xffffecea);
  Color get warningDark =>
      _dark ? const Color(0xffedc66c) : const Color(0xff875900);
  Color get lime => _dark ? const Color(0xff284234) : const Color(0xffdce9df);
  Color get canvas => _dark ? const Color(0xff121612) : const Color(0xfff5f5f2);
  Color get surface =>
      _dark ? const Color(0xff1c211c) : const Color(0xffffffff);
  Color get line => _dark ? const Color(0xff414940) : const Color(0xffd7d9d4);
  Color get warning =>
      _dark ? const Color(0xff483b1d) : const Color(0xfff3dfad);
}

ThemeData buildAppTheme({Brightness brightness = Brightness.light}) {
  final colors = AppColors(brightness);
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff3a7d57),
    brightness: brightness,
    primary: colors.forest,
    secondary: colors.green,
    surface: colors.surface,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.canvas,
    fontFamily: 'sans-serif',
    textTheme: TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        color: colors.ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: colors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: colors.ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: colors.ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: colors.inkMuted),
      labelLarge: TextStyle(fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: colors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        side: BorderSide(color: colors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: colors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: colors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: colors.greenDark, width: 1.5),
      ),
    ),
    dividerColor: colors.line,
  );
}

class const AppThemeScope({
  super.key,
  required super.notifier,
  required super.child,
}) extends InheritedNotifier<ThemeController> {
  static ThemeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>()?.notifier;
}
