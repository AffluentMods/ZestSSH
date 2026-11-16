import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// The one SFTP context-menu surface (chrome-exact §7). Both the rail pin menu
/// and the path-bar bookmark menu are built from this, so they can never drift
/// into two implementations again: same 224px surface, same border, same path
/// header, same item metrics, same hover and disabled tokens.
///
/// Geometry is fixed by composition (§8), never by hiding rows: an unavailable
/// item is passed disabled, not omitted, so a menu keeps the same height every
/// time it opens on the same list.

const double _kMenuWidth = 224;
const double _kItemHeight = 30;
const double _kHeaderHeight = 26;
const double _kSepRun = 11; // 1px rule + 5px margin top and bottom
const double _kPadding = 5;

/// A path header row. Carries the stored path, not a guess at its contents.
class SftpMenuHeader {
  const SftpMenuHeader({
    required this.icon,
    required this.path,
    this.stale = false,
    this.trailing,
  });

  final IconData icon;
  final String path;

  /// Warn-tinted glyph, for a pin whose path is gone.
  final bool stale;

  /// Optional right-aligned note, e.g. "Not found" on a stale pin.
  final String? trailing;
}

sealed class SftpMenuEntry {
  const SftpMenuEntry();
}

class SftpMenuSeparator extends SftpMenuEntry {
  const SftpMenuSeparator();
}

class SftpMenuItem extends SftpMenuEntry {
  const SftpMenuItem({
    required this.icon,
    required this.label,
    required this.value,
    this.shortcut,
    this.enabled = true,
    this.danger = false,
  });

  final IconData icon;
  final String label;

  /// Returned from [showSftpContextMenu] when this row is chosen.
  final String value;

  /// Right-aligned mono hint, never wrapped.
  final String? shortcut;
  final bool enabled;

  /// Crit-coloured. Reserved for operations that touch the remote filesystem -
  /// removing a pin is not one of them, so it is never danger.
  final bool danger;
}

/// Open the menu with its top-left corner at [globalPosition] + 2px, flipping on
/// whichever axis would run it off-screen. Returns the chosen item's value, or
/// null if dismissed.
Future<String?> showSftpContextMenu(
  BuildContext context, {
  required Offset globalPosition,
  required List<SftpMenuEntry> entries,
  SftpMenuHeader? header,
}) {
  return Navigator.of(context, rootNavigator: true).push<String>(
    _SftpMenuRoute(
      globalPosition: globalPosition,
      entries: entries,
      header: header,
      dismissLabel: AppLocalizations.of(context)!.desktopDismiss,
    ),
  );
}

/// Total surface height from the composition, so the anchor can flip precisely
/// instead of guessing (§8: "any pin menu that is not exactly 180px has hidden
/// a row instead of disabling it").
double _measure(List<SftpMenuEntry> entries, SftpMenuHeader? header) {
  var h = _kPadding * 2;
  if (header != null) h += _kHeaderHeight;
  for (final e in entries) {
    h += e is SftpMenuSeparator ? _kSepRun : _kItemHeight;
  }
  return h;
}

class _SftpMenuRoute extends PopupRoute<String> {
  _SftpMenuRoute({
    required this.globalPosition,
    required this.entries,
    required this.header,
    required this.dismissLabel,
  });

  final Offset globalPosition;
  final List<SftpMenuEntry> entries;
  final SftpMenuHeader? header;

  /// The barrier's semantics label, localized by the caller.
  final String dismissLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => dismissLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 90);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final size = media.size;
    const margin = 8.0;
    final menuH = _measure(entries, header);

    var x = globalPosition.dx + 2;
    var y = globalPosition.dy + 2;
    if (x + _kMenuWidth > size.width - margin) x = globalPosition.dx - _kMenuWidth;
    if (y + menuH > size.height - margin) y = globalPosition.dy - menuH;
    x = x.clamp(margin, size.width - _kMenuWidth - margin);
    y = y.clamp(margin, (size.height - menuH - margin).clamp(margin, double.infinity));

    return Stack(
      children: [
        Positioned(
          left: x,
          top: y,
          child: FadeTransition(
            opacity: animation,
            child: _SftpMenuSurface(entries: entries, header: header),
          ),
        ),
      ],
    );
  }
}

class _SftpMenuSurface extends StatelessWidget {
  const _SftpMenuSurface({required this.entries, required this.header});

  final List<SftpMenuEntry> entries;
  final SftpMenuHeader? header;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: _kMenuWidth,
        padding: const EdgeInsets.all(_kPadding),
        decoration: BoxDecoration(
          color: AppColors.surface, // --raised
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.sftpBorderLift), // --border-lift
          boxShadow: const [
            BoxShadow(
              color: Color(0x99000000), // rgba(0,0,0,.6)
              blurRadius: 40,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) _MenuHeader(header: header!),
            for (final e in entries)
              if (e is SftpMenuSeparator)
                const _MenuSeparator()
              else if (e is SftpMenuItem)
                _MenuItemRow(item: e),
          ],
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.header});

  final SftpMenuHeader header;

  @override
  Widget build(BuildContext context) {
    final tint = header.stale ? AppColors.sftpWarn : AppColors.sftpMenuMuted;
    return SizedBox(
      height: _kHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        child: Row(
          children: [
            Icon(header.icon, size: 12, color: tint),
            const SizedBox(width: 7),
            Expanded(
              child: _MiddleEllipsisText(
                header.path,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10.5,
                  color: AppColors.sftpMenuMuted,
                  height: 1.0,
                ),
              ),
            ),
            if (header.trailing != null) ...[
              const SizedBox(width: 8),
              Text(
                header.trailing!,
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppColors.sftpWarn,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MenuSeparator extends StatelessWidget {
  const _MenuSeparator();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      color: AppColors.divider, // --border
    );
  }
}

class _MenuItemRow extends StatefulWidget {
  const _MenuItemRow({required this.item});

  final SftpMenuItem item;

  @override
  State<_MenuItemRow> createState() => _MenuItemRowState();
}

class _MenuItemRowState extends State<_MenuItemRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final disabled = !item.enabled;

    final Color fg;
    final Color glyph;
    final Color hint;
    if (disabled) {
      fg = glyph = hint = AppColors.sftpMenuDim;
    } else if (item.danger) {
      fg = glyph = AppColors.sftpCrit;
      hint = AppColors.sftpMenuMuted;
    } else {
      fg = _hover ? AppColors.onSurface : AppColors.sftpMenuText;
      glyph = AppColors.onSurfaceDim; // does not change on hover (§7)
      hint = AppColors.sftpMenuMuted;
    }

    return MouseRegion(
      cursor: disabled ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: disabled ? null : (_) => setState(() => _hover = true),
      onExit: disabled ? null : (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled
            ? null
            : () => Navigator.of(context).pop(item.value),
        child: Container(
          height: _kItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: (_hover && !disabled) ? AppColors.sftpRaised2 : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(item.icon, size: 14, color: glyph),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: fg),
                ),
              ),
              if (item.shortcut != null) ...[
                const SizedBox(width: 10),
                Text(
                  item.shortcut!,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10.5,
                    color: hint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Elides the middle of a path so both the root and the leaf stay visible - the
/// leaf is the part that identifies the folder, and an end-ellipsis would hide
/// it. Measures with a [TextPainter] and binary-searches the longest head+tail
/// that fits the available width.
class _MiddleEllipsisText extends StatelessWidget {
  const _MiddleEllipsisText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        if (_fits(text, style, maxW)) {
          return Text(text, style: style, maxLines: 1, softWrap: false);
        }
        const ell = '…';
        var lo = 0, hi = text.length;
        var best = ell;
        while (lo <= hi) {
          final keep = (lo + hi) ~/ 2;
          final head = keep - keep ~/ 2;
          final tail = keep ~/ 2;
          final candidate =
              '${text.substring(0, head)}$ell${text.substring(text.length - tail)}';
          if (_fits(candidate, style, maxW)) {
            best = candidate;
            lo = keep + 1;
          } else {
            hi = keep - 1;
          }
        }
        return Text(best, style: style, maxLines: 1, softWrap: false);
      },
    );
  }

  bool _fits(String s, TextStyle style, double maxW) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width <= maxW;
  }
}

/// Shared glyphs so the two menus name the same action with the same icon.
class SftpMenuIcons {
  static const IconData pin = LucideIcons.folder;
  static const IconData stale = LucideIcons.alertTriangle;
  static const IconData rename = LucideIcons.pencil;
  static const IconData moveUp = LucideIcons.arrowUp;
  static const IconData moveDown = LucideIcons.arrowDown;
  static const IconData removePin = LucideIcons.bookmarkMinus;
  static const IconData bookmark = LucideIcons.bookmark;
  static const IconData teamBookmark = LucideIcons.users;
  static const IconData restore = LucideIcons.rotateCcw;
}
