import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// 1.7 section header (`.section`).
///
/// A single UPPERCASE [label] in [ZestTokens.textMuted] (letter-spacing .08em),
/// followed by an optional count badge, an optional `?` help glyph, a 1px
/// [ZestTokens.borderSubtle] hairline filling the remaining width, and finally
/// a right-aligned [trailing] widget and/or a brand `action` text link.
/// Deliberately has **no** decorative colour dot - the label alone carries the
/// hierarchy. Carries its own 10px bottom gap so a header sits directly above
/// its content.
///
/// All caller-provided strings are assumed already-localized.
/// A field's label above its value: sentence case, in the app's sans, a
/// step quieter than the value (forms read as Linear's and Vercel's do; the
/// capitals stay with section headers).
class ZestFieldLabel extends StatelessWidget {
  const ZestFieldLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          height: 1.3,
          color: color ?? ZestTokens.textSecondary,
        ),
      );
}

class ZestSectionHeader extends StatelessWidget {
  const ZestSectionHeader({
    super.key,
    required this.label,
    this.count,
    this.infoTooltip,
    this.trailing,
    this.actionLabel,
    this.onAction,
    this.danger = false,
  })  : dot = null,
        labelColor = null,
        badge = null,
        _isCategory = false;

  /// List-pane category divider variant.
  ///
  /// Same grammar and machinery as [ZestSectionHeader.new] - UPPERCASE label,
  /// neutral count badge, `?` help glyph, the shared [ZestTokens.borderSubtle]
  /// hairline and a right-aligned [trailing] - but tuned for a list category
  /// divider: an optional leading colour [dot] (a category accent the caller
  /// already computes, e.g. `categoryAccent(...)`), an optional [labelColor] so
  /// the label can carry that same accent, a slightly heavier label weight, and
  /// an optional [badge] widget that fills the count slot in place of a numeric
  /// [count] (e.g. a "Coming soon" chip).
  const ZestSectionHeader.category({
    super.key,
    required this.label,
    this.dot,
    this.labelColor,
    this.count,
    this.badge,
    this.infoTooltip,
    this.trailing,
  })  : actionLabel = null,
        onAction = null,
        danger = false,
        _isCategory = true;

  /// Already-localized label. Rendered UPPERCASE.
  final String label;

  /// Optional item count → neutral badge after the label.
  final int? count;

  /// Already-localized help text surfaced by a tappable `?` glyph.
  final String? infoTooltip;

  /// Right-aligned widget, drawn past the hairline (before any [actionLabel]).
  final Widget? trailing;

  /// Already-localized brand text link drawn at the far right (e.g. "+ Add").
  final String? actionLabel;

  /// Tapped when [actionLabel] is pressed.
  final VoidCallback? onAction;

  /// Leading category-accent dot ([ZestSectionHeader.category] only). Null = no
  /// dot, matching the plain `.section` look.
  final Color? dot;

  /// Label colour override ([ZestSectionHeader.category] only). Null falls back
  /// to [ZestTokens.textMuted].
  final Color? labelColor;

  /// Widget shown in the count-badge slot instead of a numeric [count]
  /// ([ZestSectionHeader.category] only) - e.g. a "Coming soon" chip. Takes
  /// precedence over [count] when both are set.
  final Widget? badge;

  /// What follows cannot be taken back (a Danger zone): the same header, its
  /// tick and label in red. One look for every section; the red says
  /// "careful" and the red buttons under it do the rest (chosen
  /// over a red heading of its own).
  final bool danger;

  /// True for the [ZestSectionHeader.category] divider variant - carries the
  /// dot slot and a slightly heavier label weight.
  final bool _isCategory;

  /// The mark, the label and its count (and the `?`), in [rowWidth]'s row.
  List<Widget> _lead(double rowWidth) => [
        // The Blueprint's section mark: a short brand tick before the label
        // (a category divider carries its own dot instead).
        if (!_isCategory) ...[
          Container(
            key: const ValueKey('section-tick'),
            width: 3,
            height: 11,
            decoration: BoxDecoration(
              color: danger ? ZestTokens.statusCritical : ZestTokens.brand,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
        ],
        if (dot != null) ...[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
        ],
        // Intrinsic-width label so the single Expanded hairline always
        // terminates at the same x regardless of label length; at most
        // part of its own row (half where something stands at its end),
        // cut with an ellipsis past that (at twice the text size on a
        // phone, a long one ran off the row; in Settings' column at 1.25
        // times, a label and its control ran over), and never wider than
        // the room the mark and the count leave it.
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: rowWidth * (trailing != null || actionLabel != null ? 0.5 : 0.8)),
            // A heading to a screen reader, in the label's own case (the
            // capitals are drawn: a reader spelt some of them out) and with
            // its count, one thing to hear ("Hosts, 9"), not three.
            child: Semantics(
              header: true,
              child: Text(
              label.toUpperCase(),
              semanticsLabel: count != null && badge == null ? '$label, $count' : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _isCategory ? 11 : 10.5,
                // Monospace is for values (a phone's and a tablet's rule, the
                // 3.0 quick wins): a label is in the app's own type there.
                fontFamily: _isCategory || isTouchLayout ? null : 'JetBrainsMono',
                fontWeight: FontWeight.w600,
                color: labelColor ?? (danger ? ZestTokens.statusCritical : ZestTokens.textMuted),
                letterSpacing: _isCategory ? 0.88 : 1.05, // ~0.1em
                height: 1.0,
              ),
            ),
            ),
          ),
        ),
        if (badge != null) ...[
          const SizedBox(width: 9),
          badge!,
        ] else if (count != null) ...[
          const SizedBox(width: 9),
          // A count that filters nothing is plain text on a phone and a
          // tablet (chips are for filters and what needs someone).
          // Said with the label above.
          ExcludeSemantics(
            child: isTouchLayout
                ? Text('$count',
                    key: const ValueKey('section-count-text'),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: ZestTokens.textTertiary, height: 1.0))
                : _CountBadge(count: count!),
          ),
        ],
        if (infoTooltip != null) ...[
          const SizedBox(width: 6),
          _InfoGlyph(message: infoTooltip!),
        ],
      ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(builder: (context, box) => Row(
        children: [
          // What stands at the end (trailing, the action) takes its room
          // first; the mark, the label, its count and the rule share what is
          // left, the label cut before anything runs off the row (the
          // label's cap alone took no account of the tick and the count: in
          // a narrow list beside the host editor HOSTS and its count ran
          // over by 1.8 px).
          Expanded(
            child: LayoutBuilder(
              builder: (context, room) => Row(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: (room.maxWidth - 9).clamp(0.0, double.infinity)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: _lead(box.maxWidth)),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: SizedBox(
                      height: 1,
                      child: ColoredBox(color: ZestTokens.borderSubtle),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 9),
            // As wide as it is, up to under half the row (a hint in a long
            // language, cut with its own ellipsis); the rule runs up to it.
            ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * 0.45), child: trailing!),
          ],
          if (actionLabel != null) ...[
            const SizedBox(width: 9),
            // Reached with Tab and said as a button (a text link: its row
            // keeps its height).
            ZestPressable(
              onTap: onAction,
              minSize: 0,
              borderRadius: 4,
              child: Text(
                actionLabel!,
                style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary),
              ),
            ),
          ],
        ],
      )),
    );
  }
}

/// Small neutral count badge - `.chip2` fill, radius 4, no border.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 10.5,
          fontFamily: 'JetBrainsMono',
          color: ZestTokens.textTertiary,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Tappable / keyboard-focusable `?` glyph. Its tooltip carries [message].
/// Not a circle (no dot) - a subtle rounded hover/focus chip.
class _InfoGlyph extends StatefulWidget {
  const _InfoGlyph({required this.message});

  final String message;

  @override
  State<_InfoGlyph> createState() => _InfoGlyphState();
}

class _InfoGlyphState extends State<_InfoGlyph> {
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey<TooltipState>();
  bool _hovering = false;
  bool _focusRing = false; // keyboard focus only

  void _show() => _tooltipKey.currentState?.ensureTooltipVisible();

  @override
  Widget build(BuildContext context) {
    final glyph = Tooltip(
      key: _tooltipKey,
      message: widget.message,
      child: Container(
        width: 16,
        height: 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _hovering ? ZestTokens.surfaceHover : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '?',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: ZestTokens.textMuted,
            height: 1.0,
          ),
        ),
      ),
    );

    final interactive = FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (h) => setState(() => _hovering = h),
      onShowFocusHighlight: (f) => setState(() => _focusRing = f),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _show();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _show,
        child: glyph,
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        interactive,
        if (_focusRing)
          Positioned(
            left: -3,
            top: -3,
            right: -3,
            bottom: -3,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: ZestTokens.brand, width: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
