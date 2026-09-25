enum WalletKeySource { personal, roast }

class WalletAccount {
  const WalletAccount({
    required this.id,
    required this.name,
    required this.accountIndex,
    required this.blockchainId,
    required this.networkId,
    required this.createdAt,
    this.keySource = WalletKeySource.personal,
    this.sourceId,
    this.keyId,
    this.derivationPath,
    this.address,
    this.privateKeyHex,
  });

  final String id;
  final String name;
  final int accountIndex;
  final String blockchainId;
  final String networkId;
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

  WalletAccount copyWith({
    String? name,
    String? derivationPath,
    String? address,
    String? keyId,
  }) => WalletAccount(
    id: id,
    name: name ?? this.name,
    accountIndex: accountIndex,
    blockchainId: blockchainId,
    networkId: networkId,
    keySource: keySource,
    sourceId: sourceId,
    keyId: keyId ?? this.keyId,
    derivationPath: derivationPath ?? this.derivationPath,
    address: address ?? this.address,
    privateKeyHex: privateKeyHex,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'accountIndex': accountIndex,
    'blockchainId': blockchainId,
    'networkId': networkId,
    'keySource': keySource.name,
    'sourceId': sourceId,
    'keyId': keyId,
    'derivationPath': derivationPath,
    'address': address,
    'privateKeyHex': privateKeyHex,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory WalletAccount.fromJson(Map<Object?, Object?> json) => WalletAccount(
    id: json['id']! as String,
    name: json['name']! as String,
    accountIndex: json['accountIndex']! as int,
    blockchainId: json['blockchainId']! as String,
    networkId: json['networkId']! as String,
    keySource: WalletKeySource.values.byName(
      json['keySource'] as String? ?? WalletKeySource.personal.name,
    ),
    sourceId: json['sourceId'] as String?,
    keyId: json['keyId'] as String?,
    derivationPath: json['derivationPath'] as String?,
    address: json['address'] as String?,
    privateKeyHex: json['privateKeyHex'] as String?,
    createdAt: DateTime.parse(json['createdAt']! as String),
  );
}
