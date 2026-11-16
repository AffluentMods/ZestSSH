import 'package:lucide_icons/lucide_icons.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Wraps a widget with a drop target that accepts file drops.
///
/// On desktop, users can drag files onto the terminal area to trigger
/// an SFTP upload or paste the file path into the terminal, and a key file
/// onto the Keys page to add it (4.0).
class DesktopDropTarget extends StatefulWidget {
  final Widget child;

  /// Called when files are dropped onto the target.
  final void Function(List<String> filePaths)? onFilesDropped;

  /// Called when a text string is dropped.
  final void Function(String text)? onTextDropped;

  /// What the highlight says while files are dragged over the target: the
  /// terminal's words (upload them, or type their paths) unless given.
  final String? hint;

  /// The highlight's glyph.
  final IconData icon;

  /// The glyph and [hint] on a card of their own in the middle (a page of
  /// cards and words under them, the Keys page); else straight on the tint,
  /// as over a terminal.
  final bool hintOnCard;

  /// False: nothing is taken, and nothing is highlighted (the Keys page of a
  /// team vault this account may not add to).
  final bool enabled;

  const DesktopDropTarget({
    super.key,
    required this.child,
    this.onFilesDropped,
    this.onTextDropped,
    this.hint,
    this.icon = LucideIcons.upload,
    this.hintOnCard = false,
    this.enabled = true,
  });

  @override
  State<DesktopDropTarget> createState() => _DesktopDropTargetState();
}

class _DesktopDropTargetState extends State<DesktopDropTarget> {
  bool _isDragging = false;

  /// Whether a drop at [position] falls on this target. The plugin goes by a
  /// target's bounds alone, so a drop is told to every target under it: one
  /// hidden in an IndexedStack, one under the Support Hub or a dialog. A path
  /// typed into those is typed into a live host nobody is looking at.
  bool _droppedHere(Offset position) {
    final target = context.findRenderObject();
    if (target == null) return false;
    final hits = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hits, position, View.of(context).viewId);
    return hits.path.any((entry) => identical(entry.target, target));
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) {
      return widget.child;
    }

    // Whatever is in front (a dialog, a sheet, another page) has the drop: a
    // file dropped there is never typed into a terminal behind it. A drag under
    // way when it opens is let go of here, in this build.
    final inFront = ModalRoute.of(context)?.isCurrent ?? true;
    final takes = inFront && widget.enabled;
    if (!takes) _isDragging = false;

    return DropTarget(
      enable: takes,
      onDragEntered: (_) {
        setState(() => _isDragging = true);
      },
      onDragExited: (_) {
        if (_isDragging) setState(() => _isDragging = false);
      },
      onDragDone: (details) {
        setState(() => _isDragging = false);

        final filePaths = details.files
            .map((item) => item.path)
            .where((p) => p.isNotEmpty)
            .toList();

        if (filePaths.isNotEmpty && _droppedHere(details.globalPosition)) {
          widget.onFilesDropped?.call(filePaths);
        }
      },
      child: Stack(
        children: [
          widget.child,

          // Drop overlay
          if (_isDragging)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  // A page under a card is dimmed, so the card stands out.
                  color: widget.hintOnCard
                      ? Color.alphaBlend(AppColors.brandOrange.withValues(alpha: 0.06), ZestTokens.surfaceBase.withValues(alpha: 0.72))
                      : AppColors.brandOrange.withValues(alpha: 0.1),
                  border: Border.all(
                    color: AppColors.brandOrange.withValues(alpha: 0.6),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: widget.hintOnCard
                      // Over a page of cards and words, on a card of its
                      // own so it is read, not lost among them.
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                          decoration: BoxDecoration(
                            color: ZestTokens.surfaceRaised,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: ZestTokens.brandBorder),
                            boxShadow: const [
                              BoxShadow(color: Color(0x66000000), blurRadius: 32, offset: Offset(0, 12)),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(widget.icon, size: 32, color: ZestTokens.brandInk),
                              const SizedBox(height: 10),
                              Text(
                                widget.hint ?? AppLocalizations.of(context)!.dropFilesHint,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: ZestTokens.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.icon,
                              size: 48,
                              color: AppColors.accentInk.withValues(alpha: 0.8),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              widget.hint ?? AppLocalizations.of(context)!.dropFilesHint,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: AppColors.accentInk.withValues(alpha: 0.9),
                              ),
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
