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
    this.addressSchemeVersion = 1,
    this.addressPathPrefix,
    this.highestAllocatedAddressIndex = 0,
    this.archivedAt,
  }) : assert(highestAllocatedAddressIndex >= 0);

  final String id;
  final String name;
  final int accountIndex;
  final String blockchainId;
  final String networkId;
  final WalletDerivationState derivationState;
  final WalletKeySource keySource;
  final String? sourceId;
  final String? keyId;

  /// BIP-86 account metadata derived from the wallet's random root seed.
  final String? derivationPath;
  final String? address;

  /// Recovery metadata for the account's single receive/change sequence.
  /// Index zero is [address]; later indexes are retained change addresses.
  final int addressSchemeVersion;
  final String? addressPathPrefix;
  final int highestAllocatedAddressIndex;
  final DateTime createdAt;
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  WalletAccount copyWith({
    String? name,
    WalletDerivationState? derivationState,
    String? derivationPath,
    String? address,
    String? keyId,
    int? addressSchemeVersion,
    String? addressPathPrefix,
    int? highestAllocatedAddressIndex,
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
    addressSchemeVersion: addressSchemeVersion ?? this.addressSchemeVersion,
    addressPathPrefix: addressPathPrefix ?? this.addressPathPrefix,
    highestAllocatedAddressIndex:
        highestAllocatedAddressIndex ?? this.highestAllocatedAddressIndex,
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
    'addressSchemeVersion': addressSchemeVersion,
    'addressPathPrefix': addressPathPrefix,
    'highestAllocatedAddressIndex': highestAllocatedAddressIndex,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'archivedAt': archivedAt?.toUtc().toIso8601String(),
  };

  factory WalletAccount.fromJson(Map<Object?, Object?> json) {
    // Existing schema-3 records may contain privateKeyHex. Spend keys are now
    // derived on demand; ignore that redundant field without migrating the box.
    final keySource = WalletKeySource.values.byName(
      json['keySource']! as String,
    );
    final derivationState = WalletDerivationState.values.byName(
      json['derivationState']! as String,
    );
    if ((keySource == WalletKeySource.watchOnly) !=
        (derivationState == WalletDerivationState.watchOnly)) {
      throw StateError('Watch-only account metadata is inconsistent.');
    }
    return WalletAccount(
      id: json['id']! as String,
      name: json['name']! as String,
      accountIndex: json['accountIndex']! as int,
      blockchainId: json['blockchainId']! as String,
      networkId: json['networkId']! as String,
      derivationState: derivationState,
      keySource: keySource,
      sourceId: json['sourceId'] as String?,
      keyId: json['keyId'] as String?,
      derivationPath: json['derivationPath'] as String?,
      address: json['address'] as String?,
      addressSchemeVersion: json['addressSchemeVersion']! as int,
      addressPathPrefix: json['addressPathPrefix'] as String?,
      highestAllocatedAddressIndex:
          json['highestAllocatedAddressIndex']! as int,
      createdAt: DateTime.parse(json['createdAt']! as String),
      archivedAt: switch (json['archivedAt']) {
        final String value => DateTime.parse(value),
        _ => null,
      },
    );
  }
}
