import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// In-app image preview for an SFTP or local file. The bytes are already
/// fetched (from either pane, remote or local) and rendered by Flutter, so this
/// works identically on Windows, Linux and macOS - it does not depend on the
/// OS file explorer, and it previews remote files the OS could never reach.
///
/// Zoom/pan via [InteractiveViewer]; a decode failure falls back to a plain
/// "can't preview" message rather than a broken-image glyph.
class SftpImagePreviewDialog extends StatefulWidget {
  const SftpImagePreviewDialog({
    super.key,
    required this.name,
    required this.bytes,
    required this.sizeLabel,
  });

  final String name;
  final Uint8List bytes;
  final String sizeLabel;

  static Future<void> show(
    BuildContext context, {
    required String name,
    required Uint8List bytes,
    required String sizeLabel,
  }) {
    return showZestModal<void>(
      context: context,
      size: ZestModalSize.large,
      child: SftpImagePreviewDialog(
        name: name,
        bytes: bytes,
        sizeLabel: sizeLabel,
      ),
    );
  }

  @override
  State<SftpImagePreviewDialog> createState() => _SftpImagePreviewDialogState();
}

class _SftpImagePreviewDialogState extends State<SftpImagePreviewDialog> {
  /// Decoded pixel dimensions, once known. Used only to pick the scaling
  /// treatment - a tiny icon (favicon) is enlarged with crisp nearest-neighbour
  /// pixels, a normal photo is smoothed.
  int? _imgW;
  int? _imgH;

  @override
  void initState() {
    super.initState();
    ui.decodeImageFromList(widget.bytes, (img) {
      if (!mounted) return;
      setState(() {
        _imgW = img.width;
        _imgH = img.height;
      });
    });
  }

  /// A small image - a favicon / icon - that we should enlarge crisply rather
  /// than show at its lost-pixel native size or blur into mush.
  bool get _isTinyIcon =>
      _imgW != null && _imgH != null && _imgW! <= 128 && _imgH! <= 128;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final l10n = AppLocalizations.of(context)!;
    // The shell (the dialog rules of 3.4): the file's name, its size and
    // pixels under it, the image, and the X; no lines, and no colour of its
    // own.
    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.image,
      title: widget.name,
      subtitle: _imgW != null && _imgH != null
          ? '${widget.sizeLabel}  \u00b7  $_imgW\u00d7$_imgH'
          : widget.sizeLabel,
      bodyScrolls: false,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Image on a dark ground so transparency reads.
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: screen.height * 0.7),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.v3Background,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                // LayoutBuilder + a viewport-sized box is what fixes small
                // images: inside InteractiveViewer's unbounded constraints a
                // bare Image sizes to its NATIVE pixels, so a 16x16 favicon was
                // a single lost dot. Handing it the viewport as its box lets
                // BoxFit.contain scale it UP to fit (and large images DOWN).
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return InteractiveViewer(
                      maxScale: 16,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                        child: Image.memory(
                          widget.bytes,
                          fit: BoxFit.contain,
                          // Crisp square pixels for a tiny icon enlarged a lot;
                          // smooth for a normal photo.
                          filterQuality: _isTinyIcon
                              ? FilterQuality.none
                              : FilterQuality.medium,
                          // Downsample very large images at decode time so the
                          // decoded bitmap stays bounded; the caller already
                          // refuses a declared-oversize decompression bomb.
                          cacheWidth: 4096,
                          errorBuilder: (_, _, _) => _unpreviewable(l10n),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // That scroll zooms.
          Text(
            l10n.sftpImageZoomHint,
            style: TextStyle(fontSize: 11.5, color: AppColors.onSurfaceDim),
          ),
        ],
      ),
    );
  }

  Widget _unpreviewable(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, size: 32, color: AppColors.onSurfaceDim),
          const SizedBox(height: 10),
          Text(
            l10n.sftpImageCantPreview,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
