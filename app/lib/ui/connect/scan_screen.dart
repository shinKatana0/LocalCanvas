/// QR pairing (`docs/connection.md` §3). Entirely local: the camera, the
/// parser, and the handshake against the address the code carried. No external
/// QR service, no shortener, no hosted redirect, nothing leaves the device but
/// the request to the gateway itself.
///
/// The screen is deliberately thin. Reading the payload is
/// `parsePairingPayload`, verifying it is the connection controller, and both
/// are covered without a camera; what is left here is the viewfinder and the
/// way out of it.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../keys.dart';

/// What the scanner produced.
sealed class ScanResult {
  const ScanResult();
}

/// A code was read. The text is handed back unverified — verification is the
/// handshake, and it belongs to the controller.
final class ScannedPayload extends ScanResult {
  const ScannedPayload(this.payload);
  final String payload;
}

/// The user asked to type the address instead.
final class ScanDismissedForManualEntry extends ScanResult {
  const ScanDismissedForManualEntry();
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _scanner = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(ScannedPayload(value));
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(l.scanPairingCode),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          MobileScanner(
            controller: _scanner,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ScannerUnavailable(error: error),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(LcSpace.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      l.scanHint,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: LcSpace.sm),
                    TextButton(
                      key: LcKeys.scannerFallback,
                      onPressed: () => Navigator.of(context).pop(
                        const ScanDismissedForManualEntry(),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: palette.brightness == Brightness.dark
                            ? palette.accent
                            : Colors.white,
                      ),
                      child: Text(l.scanEnterAddressInstead),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// No camera, or permission refused. Still not a dead end.
class _ScannerUnavailable extends StatelessWidget {
  const _ScannerUnavailable({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied => l.scannerPermissionDenied,
      MobileScannerErrorCode.unsupported => l.scannerUnsupported,
      _ => l.scannerFailed,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LcSpace.xl),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}
