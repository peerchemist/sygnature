import 'package:logger/logger.dart';

class AppLogger {
  const AppLogger._();

  static const _redacted = '<redacted>';

  static final RegExp _labelledSecret = RegExp(
    r'''\b(mnemonic|recovery[ _-]?phrase|seed|entropy|private[ _-]?key|secret[ _-]?share|passphrase|password|signing[ _-]?nonce)\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^,;\n}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _invite = RegExp(
    r'\b(?:sygnature-roast-v1:|https://noosphere\.network/roast#)[^\s<>()\[\]{}]+',
    caseSensitive: false,
  );
  static final RegExp _privateExtendedKey = RegExp(
    r'\b(?:xprv|tprv|yprv|zprv|uprv|vprv)[1-9A-HJ-NP-Za-km-z]{20,}\b',
  );
  static final RegExp _walletImportKey = RegExp(
    r'\b[5KLc9][1-9A-HJ-NP-Za-km-z]{50,51}\b',
  );
  static final RegExp _longHex = RegExp(r'\b(?:0x)?[0-9A-Fa-f]{64,}\b');
  static final RegExp _uriCredentials = RegExp(
    r'([a-z][a-z0-9+.-]*://)[^/@\s]+@',
    caseSensitive: false,
  );
  static final RegExp _sensitiveQueryValue = RegExp(
    r'([?&](?:mnemonic|seed|private_key|privateKey|secret_share|secretShare|passphrase|password|token|key)=)[^&#\s]*',
    caseSensitive: false,
  );

  static final Logger _logger = Logger(
    filter: DevelopmentFilter(),
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: false,
      printEmojis: false,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  static void trace(String message, {Object? error, StackTrace? stackTrace}) {
    _log(Level.trace, message, error: error);
  }

  static void debug(String message, {Object? error, StackTrace? stackTrace}) {
    _log(Level.debug, message, error: error);
  }

  static void info(String message, {Object? error, StackTrace? stackTrace}) {
    _log(Level.info, message, error: error);
  }

  static void warn(String message, {Object? error, StackTrace? stackTrace}) {
    _log(Level.warning, message, error: error);
  }

  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    _log(Level.error, message, error: error);
  }

  static void fatal(String message, {Object? error, StackTrace? stackTrace}) {
    _log(Level.fatal, message, error: error);
  }

  /// Removes known secret encodings from developer-authored diagnostic text.
  ///
  /// Exception objects and stack traces are never converted to strings: native
  /// and domain failures can contain decrypted payloads or user input. This
  /// method is a second line of defence for accidentally interpolated values in
  /// the diagnostic message itself.
  static String redact(String message) => message
      .replaceAllMapped(
        _labelledSecret,
        (match) => '${match.group(1)}=$_redacted',
      )
      .replaceAll(_invite, _redacted)
      .replaceAll(_privateExtendedKey, _redacted)
      .replaceAll(_walletImportKey, _redacted)
      .replaceAll(_longHex, _redacted)
      .replaceAllMapped(
        _uriCredentials,
        (match) => '${match.group(1)}$_redacted@',
      )
      .replaceAllMapped(
        _sensitiveQueryValue,
        (match) => '${match.group(1)}$_redacted',
      );

  static void _log(Level level, String message, {Object? error}) {
    final errorType = error?.runtimeType;
    final suffix = errorType == null ? '' : ' (failure: $errorType)';
    _logger.log(level, '${redact(message)}$suffix');
  }
}
