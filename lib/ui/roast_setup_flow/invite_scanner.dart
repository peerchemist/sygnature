part of '../roast_setup_flow.dart';

class const _RoastInviteScanner() extends StatefulWidget {
  @override
  State<_RoastInviteScanner> createState() => _RoastInviteScannerState();
}

class _RoastInviteScannerState extends State<_RoastInviteScanner> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (barcode.format != BarcodeFormat.qrCode ||
          value == null ||
          value.isEmpty) {
        continue;
      }
      _handled = true;
      Navigator.pop(context, value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan invitation')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: _onDetect,
          errorBuilder: (_, _) => const ColoredBox(
            color: Colors.black,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Camera access is unavailable. Go back and paste the '
                  'invitation from the clipboard instead.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
        Center(
          child: IgnorePointer(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 40,
          child: Text(
            'Point the camera at the invitation QR code.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(blurRadius: 8, color: Colors.black)],
            ),
          ),
        ),
      ],
    ),
  );
}
