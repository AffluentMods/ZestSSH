import 'dart:async';
import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zestssh/features/hosts/host_share_file.dart' show addLinkedHost;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/connection/incoming_share_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';

/// Camera-based scanner that ingests a `zestssh://share?d=…` or
/// `zestssh://add-host?…` URL from another device and routes it
/// through the same [IncomingShareDialog] confirmation flow that
/// the deep-link handler uses.
///
/// Available on Android and iOS only - desktop builds have no
/// realistic camera surface and the deep-link / paste flow is
/// already sufficient there.
class QrScanScreen extends ConsumerStatefulWidget {
  const QrScanScreen({super.key, this.readCode, this.title, this.hint, this.notCode});

  /// Scanning for something else than a host (an invite code to a team):
  /// what a scanned text holds, or null when it is not one; the screen
  /// closes with it. A host's share link goes as before when this is null.
  final String? Function(String raw)? readCode;

  /// The title, the hint under the camera and what is said for a code that
  /// is not one, where [readCode] is given.
  final String? title;
  final String? hint;
  final String? notCode;

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  @override
  ConsumerState<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends ConsumerState<QrScanScreen> {
  late final MobileScannerController _controller;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .where((v) => v != null && v.isNotEmpty)
        .firstOrNull;
    if (raw == null) return;

    final read = widget.readCode;
    if (read != null) {
      final found = read(raw);
      if (found != null) {
        _processing = true;
        Navigator.of(context).pop(found);
      } else {
        showTopSnackBar(context, widget.notCode ?? AppLocalizations.of(context)!.qrScanNotShareCode, isError: true);
      }
      return;
    }

    setState(() => _processing = true);
    await _controller.stop();

    final l10n = AppLocalizations.of(context)!;
    try {
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.scheme != 'zestssh') {
        if (!mounted) return;
        showTopSnackBar(
          context,
          l10n.qrScanNotShareCode,
          isError: true,
        );
        await _controller.start();
        if (mounted) setState(() => _processing = false);
        return;
      }
      final parsed = ConnectionShareUrlService.tryParse(uri);
      if (parsed == null) {
        if (!mounted) return;
        showTopSnackBar(
          context,
          l10n.qrScanRejectedPayload,
          isError: true,
        );
        await _controller.start();
        if (mounted) setState(() => _processing = false);
        return;
      }

      if (!mounted) return;
      final approved = await IncomingShareDialog.show(
        context,
        payload: parsed,
        sourceUri: uri,
      );
      if (!approved) {
        // User backed out - resume scanning so they can try a
        // different code.
        if (mounted) {
          await _controller.start();
          if (!mounted) return;
          setState(() => _processing = false);
        }
        return;
      }

      await _saveShared(parsed);
      if (mounted) {
        Navigator.of(context).pop();
        showTopSnackBar(context, l10n.qrScanConnectionAdded,
            isSuccess: true);
      }
    } catch (e) {
      AppLogger.error('QR scan failed', e);
      if (mounted) {
        // What failed, in the app's words, with what was thrown to copy
        // (it was "Failed to add: " and the raw error).
        showTopSnackBar(context, l10n.sharedConnectionSaveFailed, isError: true, details: '$e');
        await _controller.start();
        if (!mounted) return;
        setState(() => _processing = false);
      }
    }
  }

  /// Into your Tree, as a share link's host goes (addLinkedHost): with its
  /// user, group and tags, its forwards not started.
  Future<void> _saveShared(ParsedConnectionShare share) =>
      addLinkedHost(ref.read(treeDatabaseProvider), ref.read(secureStorageProvider), share);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title ?? l10n.qrScanTitle),
        actions: [
          IconButton(
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (_, state, _) {
                return Icon(state.torchState == TorchState.on
                    ? LucideIcons.zap
                    : LucideIcons.zapOff);
              },
            ),
            tooltip: l10n.qrScanToggleTorch,
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(LucideIcons.switchCamera),
            tooltip: l10n.qrScanSwitchCamera,
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return _CameraError(error: error);
            },
          ),
          // Reticle overlay
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.v3AccentPrimary.withValues(alpha: 0.8),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          if (_processing)
            Container(
              color: Colors.black.withValues(alpha: 0.55),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    widget.hint ?? l10n.qrScanHint,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 12,
                      height: 1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;
  const _CameraError({required this.error});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.videoOff,
                size: 48, color: Colors.white),
            const SizedBox(height: 12),
            Text(
              l10n.qrScanCameraOpenError,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error.errorDetails?.message ?? error.errorCode.name,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
