import 'package:bip39_mnemonic/bip39_mnemonic.dart' as bip39;

class const MnemonicLanguage({
  required final bip39.Language bip39Language,
  required final String label,
}) {
  String get id => bip39Language.label;

  static const english = MnemonicLanguage(
    bip39Language: bip39.Language.english,
    label: 'English',
  );

  static const supported = <MnemonicLanguage>[
    english,
    MnemonicLanguage(bip39Language: bip39.Language.czech, label: 'Czech'),
    MnemonicLanguage(bip39Language: bip39.Language.french, label: 'French'),
    MnemonicLanguage(bip39Language: bip39.Language.italian, label: 'Italian'),
    MnemonicLanguage(bip39Language: bip39.Language.japanese, label: 'Japanese'),
    MnemonicLanguage(bip39Language: bip39.Language.korean, label: 'Korean'),
    MnemonicLanguage(
      bip39Language: bip39.Language.portuguese,
      label: 'Portuguese',
    ),
    MnemonicLanguage(bip39Language: bip39.Language.spanish, label: 'Spanish'),
    MnemonicLanguage(
      bip39Language: bip39.Language.simplifiedChinese,
      label: 'Chinese (simplified)',
    ),
    MnemonicLanguage(
      bip39Language: bip39.Language.traditionalChinese,
      label: 'Chinese (traditional)',
    ),
  ];

  static MnemonicLanguage byId(String id) =>
      supported.firstWhere((language) => language.id == id);
}

class MnemonicSession {
  const MnemonicSession({
    required this.words,
    required this.language,
    required this.createdInApp,
  });

  final List<String> words;
  final MnemonicLanguage language;
  final bool createdInApp;

  String get phrase => words.join(' ');
}

class MnemonicValidationResult {
  const MnemonicValidationResult.valid(this.words) : error = null;
  const MnemonicValidationResult.invalid(this.error) : words = const [];

  final List<String> words;
  final String? error;

  bool get isValid => error == null;
}
