import 'group_transition.dart';
import 'roast_setup.dart';
import 'wallet_account.dart';
import 'wallet_activity.dart';

class WalletVault {
  const WalletVault({
    required this.rootSeedHex,
    required this.accounts,
    required this.nextAccountIndex,
    this.roastSetups = const [],
    this.groupTransitions = const [],
    this.activities = const [],
    this.announcedRoastActionIds = const [],
    this.changeAllocationOperationIds = const [],
    this.selectedAccountId,
    this.backupRestoreId,
  });

  static const schemaVersion = 3;

  /// Sensitive fields live in the encrypted Hive box.
  final String rootSeedHex;
  final String? selectedAccountId;

  /// Atomic commit marker for cross-box backup recovery. Never exported.
  final String? backupRestoreId;
  final List<WalletAccount> accounts;
  final int nextAccountIndex;
  final List<RoastSetup> roastSetups;
  final List<WalletGroupTransition> groupTransitions;
  final List<WalletActivity> activities;
  final List<String> announcedRoastActionIds;
  final List<String> changeAllocationOperationIds;

  WalletVault copyWith({
    List<WalletAccount>? accounts,
    int? nextAccountIndex,
    List<RoastSetup>? roastSetups,
    List<WalletGroupTransition>? groupTransitions,
    List<WalletActivity>? activities,
    List<String>? announcedRoastActionIds,
    List<String>? changeAllocationOperationIds,
    String? selectedAccountId,
    bool clearSelectedAccountId = false,
  }) => WalletVault(
    backupRestoreId: backupRestoreId,
    rootSeedHex: rootSeedHex,
    selectedAccountId: clearSelectedAccountId
        ? null
        : selectedAccountId ?? this.selectedAccountId,
    accounts: accounts ?? this.accounts,
    nextAccountIndex: nextAccountIndex ?? this.nextAccountIndex,
    roastSetups: roastSetups ?? this.roastSetups,
    groupTransitions: groupTransitions ?? this.groupTransitions,
    activities: activities ?? this.activities,
    announcedRoastActionIds:
        announcedRoastActionIds ?? this.announcedRoastActionIds,
    changeAllocationOperationIds:
        changeAllocationOperationIds ?? this.changeAllocationOperationIds,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'backupRestoreId': backupRestoreId,
    'rootSeedHex': rootSeedHex,
    'selectedAccountId': selectedAccountId,
    'accounts': accounts.map((account) => account.toJson()).toList(),
    'nextAccountIndex': nextAccountIndex,
    'roastSetups': roastSetups.map((setup) => setup.toJson()).toList(),
    'groupTransitions': groupTransitions
        .map((transition) => transition.toJson())
        .toList(),
    'activities': activities.map((activity) => activity.toJson()).toList(),
    'announcedRoastActionIds': announcedRoastActionIds,
    'changeAllocationOperationIds': changeAllocationOperationIds,
  };

  factory WalletVault.fromJson(Map<Object?, Object?> json) {
    final version = json['schemaVersion'] as int? ?? 0;
    if (version != schemaVersion) {
      throw StateError('Unsupported wallet vault schema: $version');
    }
    final rootSeedHex = json['rootSeedHex']! as String;
    if (rootSeedHex.length != 128 ||
        !RegExp(r'^[0-9a-f]+$').hasMatch(rootSeedHex)) {
      throw StateError('Invalid wallet root seed.');
    }
    return WalletVault(
      backupRestoreId: json['backupRestoreId'] as String?,
      rootSeedHex: rootSeedHex,
      selectedAccountId: json['selectedAccountId'] as String?,
      accounts: (json['accounts']! as List)
          .map((account) => WalletAccount.fromJson(account as Map))
          .toList(growable: false),
      nextAccountIndex: json['nextAccountIndex']! as int,
      roastSetups: (json['roastSetups']! as List)
          .map((setup) => RoastSetup.fromJson(setup as Map))
          .toList(growable: false),
      groupTransitions: (json['groupTransitions']! as List)
          .map((item) => WalletGroupTransition.fromJson(item as Map))
          .toList(growable: false),
      activities: (json['activities']! as List)
          .map((activity) => WalletActivity.fromJson(activity as Map))
          .toList(growable: false),
      announcedRoastActionIds: (json['announcedRoastActionIds']! as List)
          .cast<String>()
          .toList(growable: false),
      changeAllocationOperationIds:
          (json['changeAllocationOperationIds']! as List).cast<String>().toList(
            growable: false,
          ),
    );
  }
}
