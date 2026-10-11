import 'dart:convert';

abstract final class RoastExchangeCodec {
  static const version = 1;
  static const uriScheme = 'sygnature-roast-v1';
  static const _prefix = '$uriScheme:';
  static const maxEncodedLength = 16384;

  static String encodeParticipantCard({
    required String cardId,
    required String name,
    required String publicKeyHex,
  }) => _encode({
    'version': version,
    'type': 'participant-card',
    'cardId': cardId,
    'name': name,
    'publicKeyHex': publicKeyHex,
  });

  static ({String cardId, String name, String publicKeyHex})
  decodeParticipantCard(String encoded) {
    final json = _decode(encoded, expectedType: 'participant-card');
    return (
      cardId: _requiredString(json, 'cardId'),
      name: _requiredString(json, 'name'),
      publicKeyHex: _requiredString(json, 'publicKeyHex'),
    );
  }

  static String _encode(Map<String, Object?> value) => _checkEncodedLength(
    '$_prefix${base64Url.encode(utf8.encode(jsonEncode(value)))}',
  );

  static String _checkEncodedLength(String encoded) {
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('ROAST exchange payload is too large.');
    }
    return encoded;
  }

  static Map<String, Object?> _decode(
    String input, {
    required String expectedType,
  }) {
    final encoded = input.trim();
    if (!encoded.startsWith(_prefix) || encoded.length > maxEncodedLength) {
      throw const FormatException('Invalid ROAST exchange payload.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(base64Url.decode(encoded.substring(_prefix.length))),
      );
    } on Object {
      throw const FormatException('Invalid ROAST exchange payload.');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != version ||
        decoded['type'] != expectedType) {
      throw const FormatException('Unsupported ROAST exchange payload.');
    }
    return decoded.cast<String, Object?>();
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('ROAST payload is missing $key.');
    }
    return value;
  }
}
