class WalletAccount {
  const WalletAccount({
    required this.id,
    required this.name,
    required this.accountIndex,
    required this.createdAt,
    this.derivationPath,
    this.address,
    this.privateKeyHex,
  });

  final String id;
  final String name;
  final int accountIndex;

  /// Populated by coinlib once key derivation is introduced.
  final String? derivationPath;
  final String? address;

  /// Kept only inside the encrypted Hive box. Never show this in the UI.
  final String? privateKeyHex;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'accountIndex': accountIndex,
    'derivationPath': derivationPath,
    'address': address,
    'privateKeyHex': privateKeyHex,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory WalletAccount.fromJson(Map<Object?, Object?> json) => WalletAccount(
    id: json['id']! as String,
    name: json['name']! as String,
    accountIndex: json['accountIndex']! as int,
    derivationPath: json['derivationPath'] as String?,
    address: json['address'] as String?,
    privateKeyHex: json['privateKeyHex'] as String?,
    createdAt: DateTime.parse(json['createdAt']! as String),
  );
}
