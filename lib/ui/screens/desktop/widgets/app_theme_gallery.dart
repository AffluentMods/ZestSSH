import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/theme_sync_provider.dart' show kAppToTerminalThemeId;
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/theme/zest_tokens.dart';

// The app theme picker on a computer (4.0).
// It was a dropdown of 18 names with three
// tiny swatches each, open over half the page, so a theme could not be seen
// before it was chosen; the phone already showed its themes as a gallery.
// Now each theme is a card that draws it in its own colours: its sidebar, a
// card with its accent and a terminal line in the terminal colours paired
// with it. The theme in use has the accent's border and a check (not colour
// alone); three rows show, and Show all N the rest.

/// One theme to choose: the theme, its name as shown, and whether it is one
/// of the person's own (made in the theme designer or imported).
class AppThemeChoice {
  const AppThemeChoice({required this.theme, required this.name, this.custom = false, this.enabled = true});

  final ZestTheme theme;
  final String name;
  final bool custom;

  /// False: shown, but not to be picked on this plan.
  final bool enabled;
}

/// The cards, as many to a row as keep each [_minCardWidth] wide (two to
/// five), three rows of them until Show all; [header] is the row over them,
/// given Show all N (or Show fewer) to stand at its end, or null where every
/// theme shows.
class AppThemeGallery extends StatefulWidget {
  const AppThemeGallery({
    super.key,
    required this.header,
    required this.choices,
    required this.selectedId,
    required this.onPick,
  });

  final Widget Function(Widget? showAll) header;
  final List<AppThemeChoice> choices;
  final String selectedId;
  final ValueChanged<String> onPick;

  /// Rows shown before Show all.
  static const int foldedRows = 3;

  @override
  State<AppThemeGallery> createState() => _AppThemeGalleryState();
}

const double _gap = 12;
const double _minCardWidth = 168;

class _AppThemeGalleryState extends State<AppThemeGallery> {
  /// Null until Show all or Show fewer: open from the start where the theme
  /// in use is among the ones folded away, so it is always in sight.
  bool? _all;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, box) {
      final columns = ((box.maxWidth + _gap) / (_minCardWidth + _gap)).floor().clamp(2, 5);
      final folded = columns * AppThemeGallery.foldedRows;
      final choices = widget.choices;
      final fits = choices.length <= folded;
      final selectedAt = choices.indexWhere((c) => c.theme.id == widget.selectedId);
      final all = fits || (_all ?? selectedAt >= folded);
      final shown = all ? choices : choices.take(folded).toList();
      final rows = <Widget>[
        for (var i = 0; i < shown.length; i += columns) ...[
          if (i > 0) const SizedBox(height: _gap),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = i; j < i + columns; j++) ...[
                  if (j > i) const SizedBox(width: _gap),
                  Expanded(
                    child: j < shown.length
                        ? _ThemeCard(
                            key: ValueKey('app-theme-${shown[j].theme.id}'),
                            choice: shown[j],
                            selected: shown[j].theme.id == widget.selectedId,
                            onPick: () => widget.onPick(shown[j].theme.id),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.header(fits
              ? null
              : _ShowAll(
                  label: all ? l10n.settingsInlineThemesShowFewer : l10n.settingsInlineThemesShowAll(choices.length),
                  open: all,
                  onTap: () => setState(() => _all = !all),
                )),
          const SizedBox(height: 6),
          // In the order they are read; the arrow keys move between cards.
          FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ],
      );
    });
  }
}

/// Show all N, or Show fewer: a link-like button at the end of the header.
class _ShowAll extends StatefulWidget {
  const _ShowAll({required this.label, required this.open, required this.onTap});

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_ShowAll> createState() => _ShowAllState();
}

class _ShowAllState extends State<_ShowAll> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final ink = _hover || _focus ? ZestTokens.textPrimary : ZestTokens.textSecondary;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      button: true,
      expanded: widget.open,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap();
            return null;
          }),
        },
        child: GestureDetector(
          key: const ValueKey('app-theme-show-all'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _focus ? ZestTokens.brand : Colors.transparent, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.label,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  widget.open ? LucideIcons.chevronUp : (rtl ? LucideIcons.chevronLeft : LucideIcons.chevronRight),
                  size: 14,
                  color: ink,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A theme's card: the theme drawn in its own colours, its name, and on the
/// one in use the accent's border and a check. The card is one button, by
/// click, Enter or Space; a screen reader hears its name and that it is
/// the one chosen.
class _ThemeCard extends StatefulWidget {
  const _ThemeCard({super.key, required this.choice, required this.selected, required this.onPick});

  final AppThemeChoice choice;
  final bool selected;
  final VoidCallback onPick;

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final choice = widget.choice;
    final selected = widget.selected;
    final enabled = choice.enabled;
    final border = selected
        ? ZestTokens.brand
        : (_hover && enabled ? ZestTokens.borderStrong : ZestTokens.border);
    final card = Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
        // The one in use: a second line of the accent outside the first, so
        // it shows nothing moved.
        boxShadow: selected ? [BoxShadow(color: ZestTokens.brand, spreadRadius: 1)] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 82, child: AppThemePreview(theme: choice.theme)),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(6, 7, 4, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      choice.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.3,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected ? ZestTokens.brandInk : ZestTokens.textPrimary,
                      ),
                    ),
                  ),
                  if (choice.custom && !selected) ...[
                    const SizedBox(width: 6),
                    Text(
                      l10n.settingsInlineCustomBadge,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: ZestTokens.textTertiary),
                    ),
                  ],
                  if (selected) ...[
                    const SizedBox(width: 6),
                    Container(
                      key: const ValueKey('app-theme-check'),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(color: ZestTokens.brand, shape: BoxShape.circle),
                      child: Icon(LucideIcons.check, size: 12, color: ZestTokens.onBrand),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      enabled: enabled,
      label: choice.name,
      value: choice.custom ? l10n.settingsInlineCustomBadge : null,
      excludeSemantics: true,
      onTap: enabled ? widget.onPick : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (v) => setState(() => _hover = v),
          onShowFocusHighlight: (v) => setState(() => _focus = v),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
              if (enabled) widget.onPick();
              return null;
            }),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? widget.onPick : null,
            // The focus ring outside the card, as a button's is.
            child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.passthrough,
              children: [
                card,
                if (_focus)
                  Positioned(
                    left: -5,
                    top: -5,
                    right: -5,
                    bottom: -5,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: ZestTokens.brand.withValues(alpha: 0.7), width: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [theme] drawn small in its own colours: its sidebar with the accent on the
/// page in use, a card with a title, a line and the accent, and at the foot a
/// terminal line ("$", a command, the cursor) in the terminal colours paired
/// with it (a theme of the person's own has none: its own colours).
class AppThemePreview extends StatelessWidget {
  const AppThemePreview({super.key, required this.theme});

  final ZestTheme theme;

  /// The terminal colours [theme] is paired with, or none.
  static TerminalTheme? pairedTerminal(ZestTheme theme) {
    final id = kAppToTerminalThemeId[theme.id];
    return id == null ? null : TerminalThemes.all[id];
  }

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final s = cs.effectiveSurfaces;
    final terminal = pairedTerminal(theme);
    final termBg = terminal?.background ?? cs.background;
    final termFg = terminal?.foreground ?? s.text;
    final termPrompt = terminal?.green ?? cs.success;
    final cursor = terminal?.cursor ?? cs.primary;
    Widget bar(double width, double height, Color color) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        );
    return ExcludeSemantics(
      child: MediaQuery.withNoTextScaling(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: BoxDecoration(color: s.panel),
            position: DecorationPosition.background,
            child: Container(
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: s.line),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The sidebar, the page in use in the accent.
                  Container(
                    width: 30,
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
                    decoration: BoxDecoration(
                      color: cs.background,
                      border: BorderDirectional(end: BorderSide(color: s.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        bar(double.infinity, 4, cs.primary),
                        const SizedBox(height: 6),
                        bar(double.infinity, 4, s.muted.withValues(alpha: 0.6)),
                        const SizedBox(height: 6),
                        bar(double.infinity, 4, s.muted.withValues(alpha: 0.6)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // A card: a title, a line, and the accent.
                        Container(
                          height: 31,
                          margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                          padding: const EdgeInsets.fromLTRB(8, 7, 7, 0),
                          decoration: BoxDecoration(
                            color: s.raised,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: s.border),
                          ),
                          child: LayoutBuilder(builder: (context, box) {
                            final room = box.maxWidth;
                            return Stack(
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    bar(room * 0.5, 4, s.text),
                                    const SizedBox(height: 5),
                                    bar(room * 0.32, 3, s.muted),
                                  ],
                                ),
                                PositionedDirectional(
                                  end: 0,
                                  top: 2,
                                  child: Container(
                                    width: 16,
                                    height: 9,
                                    decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(3)),
                                  ),
                                ),
                              ],
                            );
                          }),
                        ),
                        const Spacer(),
                        // A terminal line in the terminal colours paired with it.
                        Container(
                          height: 26,
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          decoration: BoxDecoration(
                            color: termBg,
                            border: Border(top: BorderSide(color: s.line)),
                          ),
                          child: Row(
                            children: [
                              Text(
                                r'$',
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 10,
                                  height: 1,
                                  fontWeight: FontWeight.w700,
                                  color: termPrompt,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Flexible(child: bar(44, 4, termFg)),
                              const SizedBox(width: 5),
                              Container(width: 5, height: 10, color: cursor),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The custom theme card's tile: the palette, in grey.
class AppThemeCustomTile extends StatelessWidget {
  const AppThemeCustomTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: ZestTokens.surfaceChip, borderRadius: BorderRadius.circular(10)),
      child: Icon(LucideIcons.palette, size: 20, color: ZestTokens.textSecondary),
    );
  }
}
