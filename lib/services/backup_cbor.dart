import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// The restricted RFC 8949 core deterministic profile used by ROASTBAK.
abstract final class BackupCbor {
  static const maxBytes = 16 * 1024 * 1024 - 76;
  static const _maxDepth = 24;
  static const _maxItems = 100000;
  static const _maxEntries = 10000;

  static Uint8List encode(Object? value) {
    _EncodingValidator().validate(value);
    return Uint8List.fromList(cbor.encode(_value(value)));
  }

  static Object? decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Invalid backup payload length.');
    }
    // Inspect before the package allocates collections. This also detects
    // duplicate keys before a decoder could collapse them into a Dart map.
    _CanonicalReader(bytes).validate();
    return _object(cbor.decode(bytes));
  }

  static CborValue _value(Object? value) => switch (value) {
    null => const CborNull(),
    bool v => CborBool(v),
    int v when v >= 0 && v <= 0x1fffffffffffff => CborSmallInt(v),
    String v => CborString(v),
    Uint8List v => CborBytes(v),
    List v => CborList(v.map(_value).toList(), type: CborLengthType.definite),
    Map<String, Object?> v => _map(v),
    _ => throw const FormatException('Unsupported backup CBOR type.'),
  };

  static CborMap _map(Map<String, Object?> map) {
    final entries =
        map.entries
            .map(
              (e) => (
                key: CborString(e.key),
                bytes: cbor.encode(CborString(e.key)),
                value: e.value,
              ),
            )
            .toList()
          ..sort((a, b) => compareBytes(a.bytes, b.bytes));
    return CborMap({
      for (final e in entries) e.key: _value(e.value),
    }, type: CborLengthType.definite);
  }

  static Object? _object(CborValue value) => switch (value) {
    CborNull() => null,
    CborBool() => value.toObject(),
    CborInt() => value.toInt(),
    CborString() => _text(value),
    CborBytes() => Uint8List.fromList(value.bytes),
    CborList() => value.map(_object).toList(),
    CborMap() => <String, Object?>{
      for (final e in value.entries)
        _text(e.key as CborString): _object(e.value),
    },
    _ => throw const FormatException('Unsupported backup CBOR type.'),
  };

  static String _text(CborString value) {
    final bytes = value.utf8Bytes;
    final text = utf8.decode(bytes);
    // Dart strips one leading BOM; in CBOR it is part of the string.
    return bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? '\ufeff$text'
        : text;
  }

  static int compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final result = a[i].compareTo(b[i]);
      if (result != 0) return result;
    }
    return a.length.compareTo(b.length);
  }
}

/// Check the source before constructing CBOR collections or replacing invalid
/// UTF-16. Count the exact encoded size, including all headers and map keys.
final class _EncodingValidator {
  int items = 0;
  int bytes = 0;

  Never _invalid() =>
      throw const FormatException('Invalid or oversized backup CBOR value.');

  void _argument(int value) {
    bytes += value < 24
        ? 1
        : value <= 0xff
        ? 2
        : value <= 0xffff
        ? 3
        : value <= 0xffffffff
        ? 5
        : 9;
  }

  void validate(Object? value, [int depth = 0]) {
    if (depth > BackupCbor._maxDepth || ++items > BackupCbor._maxItems) {
      _invalid();
    }
    switch (value) {
      case null || bool():
        bytes++;
      case int v when v >= 0 && v <= 0x1fffffffffffff:
        _argument(v);
      case String v:
        if (v.length > BackupCbor.maxBytes - bytes) _invalid();
        var length = 0;
        for (final rune in v.runes) {
          if (rune >= 0xd800 && rune <= 0xdfff) _invalid();
          length += rune <= 0x7f
              ? 1
              : rune <= 0x7ff
              ? 2
              : rune <= 0xffff
              ? 3
              : 4;
        }
        _argument(length);
        bytes += length;
      case Uint8List v:
        _argument(v.length);
        bytes += v.length;
      case List v:
        if (v.length > BackupCbor._maxEntries) _invalid();
        _argument(v.length);
        for (final item in v) {
          validate(item, depth + 1);
        }
      case Map<String, Object?> v:
        if (v.length > BackupCbor._maxEntries) _invalid();
        _argument(v.length);
        for (final entry in v.entries) {
          validate(entry.key, depth + 1);
          validate(entry.value, depth + 1);
        }
      default:
        _invalid();
    }
    if (bytes > BackupCbor.maxBytes) _invalid();
  }
}

final class _CanonicalReader(final Uint8List bytes) {
  int offset = 0;
  int items = 0;

  Never _invalid() =>
      throw const FormatException('Malformed or noncanonical backup CBOR.');

  int _byte() {
    if (offset >= bytes.length) _invalid();
    return bytes[offset++];
  }

  void validate() {
    _item(0);
    if (offset != bytes.length) _invalid();
  }

  void _item(int depth, {bool key = false}) {
    if (depth > BackupCbor._maxDepth || ++items > BackupCbor._maxItems) {
      _invalid();
    }
    final first = _byte();
    final major = first >> 5;
    final info = first & 31;
    if (key && major != 3) _invalid();
    if (major == 7) {
      if (info != 20 && info != 21 && info != 22) _invalid();
      return;
    }
    if (major == 1 || major == 6 || info > 27) _invalid();
    var length = info;
    if (info >= 24) {
      final count = 1 << (info - 24);
      length = 0;
      for (var i = 0; i < count; i++) {
        length = length * 256 + _byte();
        if (length > 0x1fffffffffffff) _invalid();
      }
      final minimum = switch (count) {
        1 => 24,
        2 => 256,
        4 => 65536,
        _ => 4294967296,
      };
      if (length < minimum) _invalid();
    }
    switch (major) {
      case 0:
        return;
      case 2:
      case 3:
        if (length > bytes.length - offset) _invalid();
        if (major == 3) {
          utf8.decode(Uint8List.sublistView(bytes, offset, offset + length));
        }
        offset += length;
      case 4:
      case 5:
        if (length > BackupCbor._maxEntries || length > bytes.length - offset) {
          _invalid();
        }
        List<int>? previous;
        for (var i = 0; i < length; i++) {
          if (major == 5) {
            final start = offset;
            _item(depth + 1, key: true);
            final current = Uint8List.sublistView(bytes, start, offset);
            if (previous != null &&
                BackupCbor.compareBytes(previous, current) >= 0) {
              _invalid();
            }
            previous = current;
          }
          _item(depth + 1);
        }
      default:
        _invalid();
    }
  }
}
