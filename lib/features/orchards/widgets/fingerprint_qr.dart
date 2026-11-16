import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

// Comparing keys by QR code (3.0): one phone scans the code the
// other person's screen shows, instead of both reading eight words aloud. The
// code carries only a fingerprint of public keys, the same thing the words
// spell, so showing it gives nothing away. A match counts exactly like "They
// match".

const _prefix = 'zestssh-fp:1:';

/// What a key fingerprint's QR code holds.
String fingerprintQrPayload(Uint8List fingerprint) =>
    '$_prefix${base64Url.encode(fingerprint).replaceAll('=', '')}';

/// The fingerprint in a scanned code, or null when it is not one of ours.
Uint8List? fingerprintFromQr(String raw) {
  final text = raw.trim();
  if (!text.startsWith(_prefix)) return null;
  final body = text.substring(_prefix.length);
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(body)) return null;
  try {
    final bytes = base64Url.decode('$body=');
    return bytes.length == 32 ? Uint8List.fromList(bytes) : null;
  } on FormatException {
    return null;
  }
}

/// Whether a scanned fingerprint is the one expected.
bool sameFingerprint(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Whether this device can scan (phones and tablets with a camera).
bool get canScanFingerprints => Platform.isAndroid || Platform.isIOS;

/// This account's own fingerprint as a QR code, dark on white so any camera
/// reads it in any theme.
class FingerprintQr extends StatelessWidget {
  const FingerprintQr({super.key, required this.fingerprint, this.size = 200});

  final Uint8List fingerprint;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        key: const ValueKey('fingerprint-qr'),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
        child: QrImageView(
          data: fingerprintQrPayload(fingerprint),
          version: QrVersions.auto,
          size: size,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          gapless: true,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0A0A0A)),
          dataModuleStyle:
              const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0A0A0A)),
        ),
      ),
    );
  }
}

/// Scans the key code on [name]'s screen and returns its fingerprint, or
/// null when the person backs out.
Future<Uint8List?> scanFingerprint(BuildContext context, {required String name}) {
  return Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(builder: (_) => _FingerprintScanScreen(name: name), fullscreenDialog: true),
  );
}

class _FingerprintScanScreen extends StatefulWidget {
  const _FingerprintScanScreen({required this.name});

  final String name;

  @override
  State<_FingerprintScanScreen> createState() => _FingerprintScanScreenState();
}

class _FingerprintScanScreenState extends State<_FingerprintScanScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _wrongCode = false;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      final fingerprint = fingerprintFromQr(raw);
      if (fingerprint != null) {
        _done = true;
        Navigator.of(context).pop(fingerprint);
        return;
      }
    }
    if (!_wrongCode) setState(() => _wrongCode = true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(l10n.fpScanTitle(widget.name))),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _wrongCode ? l10n.fpScanNotCode : l10n.fpScanHint(widget.name),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
