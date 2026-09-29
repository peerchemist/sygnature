import 'wallet_account.dart';
import 'wallet_activity.dart';
import 'roast_setup.dart';

class WalletVault {
  const WalletVault({
    required this.accounts,
    required this.nextAccountIndex,
    this.roastSetups = const [],
    this.activities = const [],
    this.mnemonic,
    this.languageId,
    this.mnemonicWordCount,
  });

  static const schemaVersion = 1;

  /// Sensitive fields live in the encrypted Hive box.
  final String? mnemonic;
  final String? languageId;
  final int? mnemonicWordCount;
  final List<WalletAccount> accounts;
  final int nextAccountIndex;
  final List<RoastSetup> roastSetups;
  final List<WalletActivity> activities;

  WalletVault copyWith({
    List<WalletAccount>? accounts,
    int? nextAccountIndex,
    List<RoastSetup>? roastSetups,
    List<WalletActivity>? activities,
  }) => WalletVault(
    mnemonic: mnemonic,
    languageId: languageId,
    mnemonicWordCount: mnemonicWordCount,
    accounts: accounts ?? this.accounts,
    nextAccountIndex: nextAccountIndex ?? this.nextAccountIndex,
    roastSetups: roastSetups ?? this.roastSetups,
    activities: activities ?? this.activities,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'mnemonic': mnemonic,
    'languageId': languageId,
    'mnemonicWordCount': mnemonicWordCount,
    'accounts': accounts.map((account) => account.toJson()).toList(),
    'nextAccountIndex': nextAccountIndex,
    'roastSetups': roastSetups.map((setup) => setup.toJson()).toList(),
    'activities': activities.map((activity) => activity.toJson()).toList(),
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
      roastSetups: (json['roastSetups']! as List)
          .map((setup) => RoastSetup.fromJson(setup as Map))
          .toList(growable: false),
      activities: (json['activities']! as List)
          .map((activity) => WalletActivity.fromJson(activity as Map))
          .toList(growable: false),
    );
  }
}
