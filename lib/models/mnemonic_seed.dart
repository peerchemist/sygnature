class MnemonicLanguage {
  const MnemonicLanguage({
    required this.id,
    required this.label,
    required this.assetPath,
  });

  final String id;
  final String label;
  final String assetPath;

  static const supported = <MnemonicLanguage>[
    MnemonicLanguage(
      id: 'english',
      label: 'English',
      assetPath: 'assets/wordlists/english.txt',
    ),
    MnemonicLanguage(
      id: 'czech',
      label: 'Czech',
      assetPath: 'assets/wordlists/czech.txt',
    ),
    MnemonicLanguage(
      id: 'french',
      label: 'French',
      assetPath: 'assets/wordlists/french.txt',
    ),
    MnemonicLanguage(
      id: 'italian',
      label: 'Italian',
      assetPath: 'assets/wordlists/italian.txt',
    ),
    MnemonicLanguage(
      id: 'japanese',
      label: 'Japanese',
      assetPath: 'assets/wordlists/japanese.txt',
    ),
    MnemonicLanguage(
      id: 'korean',
      label: 'Korean',
      assetPath: 'assets/wordlists/korean.txt',
    ),
    MnemonicLanguage(
      id: 'portuguese',
      label: 'Portuguese',
      assetPath: 'assets/wordlists/portuguese.txt',
    ),
    MnemonicLanguage(
      id: 'russian',
      label: 'Russian',
      assetPath: 'assets/wordlists/russian.txt',
    ),
    MnemonicLanguage(
      id: 'spanish',
      label: 'Spanish',
      assetPath: 'assets/wordlists/spanish.txt',
    ),
    MnemonicLanguage(
      id: 'turkish',
      label: 'Turkish',
      assetPath: 'assets/wordlists/turkish.txt',
    ),
  ];

  static MnemonicLanguage byId(String id) => supported.firstWhere(
    (language) => language.id == id,
    orElse: () => supported.first,
  );
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
