import 'package:material_ui/material_ui.dart';

final _dkgAbbreviation = RegExp(r'\bDKG\b');
const _initial = TextStyle(fontWeight: FontWeight.bold);
const _distributedKeyGeneration = TextSpan(
  children: [
    TextSpan(text: 'D', style: _initial),
    TextSpan(text: 'istributed '),
    TextSpan(text: 'K', style: _initial),
    TextSpan(text: 'ey '),
    TextSpan(text: 'G', style: _initial),
    TextSpan(text: 'eneration'),
  ],
);

TextSpan spellOutDkg(String text) {
  final parts = text.split(_dkgAbbreviation);
  return TextSpan(
    text: parts.first,
    children: [
      for (final part in parts.skip(1)) ...[
        _distributedKeyGeneration,
        TextSpan(text: part),
      ],
    ],
  );
}
