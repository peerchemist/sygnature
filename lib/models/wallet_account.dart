class WalletAccount {
  const WalletAccount({
    required this.id,
    required this.name,
    required this.accountIndex,
    required this.blockchainId,
    required this.networkId,
    required this.createdAt,
    this.derivationPath,
    this.address,
    this.privateKeyHex,
  });

  final String id;
  final String name;
  final int accountIndex;
  final String blockchainId;
  final String networkId;

  /// BIP-86 account metadata derived from the wallet mnemonic.
  final String? derivationPath;
  final String? address;

  /// Taproot-tweaked spend key. Kept only inside the encrypted Hive box and
  /// never shown in the UI.
  final String? privateKeyHex;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'accountIndex': accountIndex,
    'blockchainId': blockchainId,
    'networkId': networkId,
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
    derivationPath: json['derivationPath'] as String?,
    address: json['address'] as String?,
    privateKeyHex: json['privateKeyHex'] as String?,
    createdAt: DateTime.parse(json['createdAt']! as String),
  );
}
