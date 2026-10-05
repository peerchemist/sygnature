enum WalletKeySource { personal, watchOnly, roast }

enum WalletDerivationState { pending, ready, watchOnly, locked, error }

class WalletAccount {
  const WalletAccount({
    required this.id,
    required this.name,
    required this.accountIndex,
    required this.blockchainId,
    required this.networkId,
    required this.derivationState,
    required this.createdAt,
    this.keySource = WalletKeySource.personal,
    this.sourceId,
    this.keyId,
    this.derivationPath,
    this.address,
    this.privateKeyHex,
    this.archivedAt,
  });

  final String id;
  final String name;
  final int accountIndex;
  final String blockchainId;
  final String networkId;
  final WalletDerivationState derivationState;
  final WalletKeySource keySource;
  final String? sourceId;
  final String? keyId;

  /// BIP-86 account metadata derived from the wallet mnemonic.
  final String? derivationPath;
  final String? address;

  /// Taproot-tweaked spend key. Kept only inside the encrypted Hive box and
  /// never shown in the UI.
  final String? privateKeyHex;
  final DateTime createdAt;
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  WalletAccount copyWith({
    String? name,
    WalletDerivationState? derivationState,
    String? derivationPath,
    String? address,
    String? keyId,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
  }) => WalletAccount(
    id: id,
    name: name ?? this.name,
    accountIndex: accountIndex,
    blockchainId: blockchainId,
    networkId: networkId,
    derivationState: derivationState ?? this.derivationState,
    keySource: keySource,
    sourceId: sourceId,
    keyId: keyId ?? this.keyId,
    derivationPath: derivationPath ?? this.derivationPath,
    address: address ?? this.address,
    privateKeyHex: privateKeyHex,
    createdAt: createdAt,
    archivedAt: clearArchivedAt ? null : archivedAt ?? this.archivedAt,
  );

  WalletAccount archive(DateTime at) => copyWith(archivedAt: at.toUtc());

  WalletAccount restore() => copyWith(clearArchivedAt: true);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'accountIndex': accountIndex,
    'blockchainId': blockchainId,
    'networkId': networkId,
    'derivationState': derivationState.name,
    'keySource': keySource.name,
    'sourceId': sourceId,
    'keyId': keyId,
    'derivationPath': derivationPath,
    'address': address,
    'privateKeyHex': privateKeyHex,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'archivedAt': archivedAt?.toUtc().toIso8601String(),
  };

  factory WalletAccount.fromJson(Map<Object?, Object?> json) {
    final keySource = WalletKeySource.values.byName(
      json['keySource'] as String? ?? WalletKeySource.personal.name,
    );
    final address = json['address'] as String?;
    final privateKeyHex = json['privateKeyHex'] as String?;
    final storedState = json['derivationState'] as String?;
    final derivationState = keySource == WalletKeySource.watchOnly
        ? WalletDerivationState.watchOnly
        : storedState == null
        ? _legacyDerivationState(
            keySource: keySource,
            address: address,
            privateKeyHex: privateKeyHex,
          )
        : WalletDerivationState.values.byName(storedState);
    final normalizedKeySource =
        derivationState == WalletDerivationState.watchOnly &&
            keySource == WalletKeySource.personal
        ? WalletKeySource.watchOnly
        : keySource;
    return WalletAccount(
      id: json['id']! as String,
      name: json['name']! as String,
      accountIndex: json['accountIndex']! as int,
      blockchainId: json['blockchainId']! as String,
      networkId: json['networkId']! as String,
      derivationState: derivationState,
      keySource: normalizedKeySource,
      sourceId: json['sourceId'] as String?,
      keyId: json['keyId'] as String?,
      derivationPath: json['derivationPath'] as String?,
      address: address,
      privateKeyHex: privateKeyHex,
      createdAt: DateTime.parse(json['createdAt']! as String),
      archivedAt: switch (json['archivedAt']) {
        final String value => DateTime.parse(value),
        _ => null,
      },
    );
  }

  static WalletDerivationState _legacyDerivationState({
    required WalletKeySource keySource,
    required String? address,
    required String? privateKeyHex,
  }) {
    if (keySource == WalletKeySource.watchOnly) {
      return WalletDerivationState.watchOnly;
    }
    if (address == null) return WalletDerivationState.pending;
    if (keySource == WalletKeySource.personal && privateKeyHex == null) {
      return WalletDerivationState.watchOnly;
    }
    return WalletDerivationState.ready;
  }
}
