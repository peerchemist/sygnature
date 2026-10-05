import 'group_transition.dart';
import 'roast_setup.dart';
import 'wallet_account.dart';
import 'wallet_activity.dart';

class WalletVault {
  const WalletVault({
    required this.accounts,
    required this.nextAccountIndex,
    this.roastSetups = const [],
    this.groupTransitions = const [],
    this.activities = const [],
    this.mnemonic,
    this.languageId,
    this.mnemonicWordCount,
    this.selectedAccountId,
  });

  static const schemaVersion = 1;
  static const _developmentSchemaVersion = 5;

  /// Sensitive fields live in the encrypted Hive box.
  final String? mnemonic;
  final String? languageId;
  final int? mnemonicWordCount;
  final String? selectedAccountId;
  final List<WalletAccount> accounts;
  final int nextAccountIndex;
  final List<RoastSetup> roastSetups;
  final List<WalletGroupTransition> groupTransitions;
  final List<WalletActivity> activities;

  WalletVault copyWith({
    List<WalletAccount>? accounts,
    int? nextAccountIndex,
    List<RoastSetup>? roastSetups,
    List<WalletGroupTransition>? groupTransitions,
    List<WalletActivity>? activities,
    String? selectedAccountId,
    bool clearSelectedAccountId = false,
  }) => WalletVault(
    mnemonic: mnemonic,
    languageId: languageId,
    mnemonicWordCount: mnemonicWordCount,
    selectedAccountId: clearSelectedAccountId
        ? null
        : selectedAccountId ?? this.selectedAccountId,
    accounts: accounts ?? this.accounts,
    nextAccountIndex: nextAccountIndex ?? this.nextAccountIndex,
    roastSetups: roastSetups ?? this.roastSetups,
    groupTransitions: groupTransitions ?? this.groupTransitions,
    activities: activities ?? this.activities,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'mnemonic': mnemonic,
    'languageId': languageId,
    'mnemonicWordCount': mnemonicWordCount,
    'selectedAccountId': selectedAccountId,
    'accounts': accounts.map((account) => account.toJson()).toList(),
    'nextAccountIndex': nextAccountIndex,
    'roastSetups': roastSetups.map((setup) => setup.toJson()).toList(),
    'groupTransitions': groupTransitions
        .map((transition) => transition.toJson())
        .toList(),
    'activities': activities.map((activity) => activity.toJson()).toList(),
  };

  factory WalletVault.fromJson(Map<Object?, Object?> json) {
    final version = json['schemaVersion'] as int? ?? 0;
    if (version != schemaVersion && version != _developmentSchemaVersion) {
      throw StateError('Unsupported wallet vault schema: $version');
    }
    return WalletVault(
      mnemonic: json['mnemonic'] as String?,
      languageId: json['languageId'] as String?,
      mnemonicWordCount: json['mnemonicWordCount'] as int?,
      selectedAccountId: json['selectedAccountId'] as String?,
      accounts: (json['accounts']! as List)
          .map((account) => WalletAccount.fromJson(account as Map))
          .toList(growable: false),
      nextAccountIndex: json['nextAccountIndex']! as int,
      roastSetups: ((json['roastSetups'] as List?) ?? const [])
          .map((setup) => RoastSetup.fromJson(setup as Map))
          .toList(growable: false),
      groupTransitions: ((json['groupTransitions'] as List?) ?? const [])
          .map((item) => WalletGroupTransition.fromJson(item as Map))
          .toList(growable: false),
      activities: ((json['activities'] as List?) ?? const [])
          .map((activity) => WalletActivity.fromJson(activity as Map))
          .toList(growable: false),
    );
  }
}
