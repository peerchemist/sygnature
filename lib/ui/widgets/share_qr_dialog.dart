import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

Future<void> showShareQrDialog(
  BuildContext context, {
  required String title,
  required String data,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Container(
      key: const Key('share-qr-code'),
      width: 264,
      height: 264,
      padding: const EdgeInsets.all(12),
      color: Colors.white,
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.L,
        errorStateBuilder: (_, _) => const SizedBox(
          width: 240,
          child: Text(
            'This value is too large to display as a QR code.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
