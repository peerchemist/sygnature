import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// The restricted RFC 8949 core deterministic profile used by ROASTBAK.
abstract final class BackupCbor {
  static const maxBytes = 16 * 1024 * 1024 - 76;

  static Uint8List encode(Object? value) =>
      Uint8List.fromList(cbor.encode(_value(value)));

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
    CborString() => value.toString(),
    CborBytes() => Uint8List.fromList(value.bytes),
    CborList() => value.map(_object).toList(),
    CborMap() => <String, Object?>{
      for (final e in value.entries)
        (e.key as CborString).toString(): _object(e.value),
    },
    _ => throw const FormatException('Unsupported backup CBOR type.'),
  };

  static int compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final result = a[i].compareTo(b[i]);
      if (result != 0) return result;
    }
    return a.length.compareTo(b.length);
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
    if (depth > 24 || ++items > 100000) _invalid();
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
        if (length > 10000 || length > bytes.length - offset) _invalid();
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
