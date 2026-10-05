import 'dart:convert';

import 'setup.dart';

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

  static String encodeInvitation(
    RoastSetup setup, {
    required String roomInvite,
    required String participantPublicKeyHex,
    required DateTime expiresAt,
    String? transitionSourceGroupId,
  }) {
    if (!setup.isFinalized ||
        setup.coordinatorId == null ||
        setup.hostParticipantId == null) {
      throw StateError('The ROAST setup is not ready for an invitation.');
    }
    return _encode({
      'version': version,
      'type': 'room-invitation',
      'groupId': setup.groupId,
      'setupName': setup.name,
      'threshold': setup.threshold,
      'participantCount': setup.participantCount,
      'blockchainId': setup.blockchainId,
      'networkId': setup.networkId,
      'keyName': setup.keyName,
      'hostParticipantId': setup.hostParticipantId,
      'coordinatorId': setup.coordinatorId,
      'coordinatorRelayUrls': setup.coordinatorRelayUrls,
      'coordinatorIpAddrs': setup.coordinatorIpAddrs,
      'groupFingerprintHex': setup.groupFingerprintHex,
      'participantPublicKeyHex': participantPublicKeyHex,
      'roomInvite': roomInvite,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'transitionSourceGroupId': ?transitionSourceGroupId,
      'participants': setup.participants.map((item) => item.toJson()).toList(),
    });
  }

  static Map<String, Object?> decodeInvitation(String encoded) =>
      _decode(encoded, expectedType: 'room-invitation');

  static String _encode(Map<String, Object?> value) {
    final encoded =
        '$_prefix${base64Url.encode(utf8.encode(jsonEncode(value)))}';
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
