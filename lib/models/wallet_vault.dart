import 'wallet_account.dart';

class WalletVault {
  const WalletVault({
    required this.accounts,
    required this.nextAccountIndex,
    this.mnemonic,
    this.languageId,
    this.mnemonicWordCount,
  });

  static const schemaVersion = 1;

  /// Reserved for coinlib-backed setup. Sensitive fields live in encrypted Hive.
  final String? mnemonic;
  final String? languageId;
  final int? mnemonicWordCount;
  final List<WalletAccount> accounts;
  final int nextAccountIndex;

  WalletVault copyWith({
    List<WalletAccount>? accounts,
    int? nextAccountIndex,
  }) => WalletVault(
    mnemonic: mnemonic,
    languageId: languageId,
    mnemonicWordCount: mnemonicWordCount,
    accounts: accounts ?? this.accounts,
    nextAccountIndex: nextAccountIndex ?? this.nextAccountIndex,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'mnemonic': mnemonic,
    'languageId': languageId,
    'mnemonicWordCount': mnemonicWordCount,
    'accounts': accounts.map((account) => account.toJson()).toList(),
    'nextAccountIndex': nextAccountIndex,
  };

  factory WalletVault.fromJson(Map<Object?, Object?> json) {
    final version = json['schemaVersion'] as int? ?? 0;
    if (version != schemaVersion) {
      throw StateError('Unsupported wallet vault schema: $version');
    }
    return WalletVault(
      mnemonic: json['mnemonic'] as String?,
      languageId: json['languageId'] as String?,
      mnemonicWordCount: json['mnemonicWordCount'] as int?,
      accounts: (json['accounts']! as List)
          .map((account) => WalletAccount.fromJson(account as Map))
          .toList(growable: false),
      nextAccountIndex: json['nextAccountIndex']! as int,
    );
  }
}
