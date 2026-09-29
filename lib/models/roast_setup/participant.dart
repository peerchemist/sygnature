class RoastParticipant({
  required final String cardId,
  required final String name,
  required final String identifierHex,
  required final String publicKeyHex,
}) {
  Map<String, Object?> toJson() => {
    'cardId': cardId,
    'name': name,
    'identifierHex': identifierHex,
    'publicKeyHex': publicKeyHex,
  };

  factory RoastParticipant.fromJson(Map<Object?, Object?> json) =>
      RoastParticipant(
        cardId: json['cardId']! as String,
        name: json['name']! as String,
        identifierHex: json['identifierHex']! as String,
        publicKeyHex: json['publicKeyHex']! as String,
      );
}
