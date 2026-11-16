import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// The one link at the end of a section's rule (Show all, Edit, All): its
/// words in the muted ink at 12 with a chevron, the text colour under the
/// pointer. (They were orange on one section, white on another, grey on a
/// third.)
class SectionLink extends StatefulWidget {
  const SectionLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<SectionLink> createState() => _SectionLinkState();
}

class _SectionLinkState extends State<SectionLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    final fg = !on
        ? ZestTokens.textPlaceholder
        : (_hover ? ZestTokens.textPrimary : ZestTokens.textMuted);
    // Reached with Tab and said as a button; a mouse's 32 high (a text
    // link at the end of a section's rule, it was 17).
    return ZestPressable(
      onTap: widget.onTap,
      onHover: (h) => setState(() => _hover = h),
      borderRadius: 4,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg),
            ),
          ),
          const SizedBox(width: 2),
          ExcludeSemantics(child: Icon(LucideIcons.chevronRight, size: 13, color: fg)),
        ],
      ),
    );
  }
}

/// A section of the Hosts page, headed as the Blueprint heads them: the
/// brand tick, the name in capitals, its count, a rule to the right edge and
/// an optional action at the end. Inset by the page's own 24px margin.
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.label, {
    super.key,
    this.count,
    this.trailingChild,
    this.actionLabel,
    this.onAction,
    this.padded = true,
    this.folded = false,
    this.onFold,
    this.foldKey,
  });

  /// The section is folded away: its chevron points right (else down).
  final bool folded;

  /// Folds the section away, or shows it again: a chevron before the head
  /// (none where null).
  final VoidCallback? onFold;

  /// The chevron's key, for tests.
  final Key? foldKey;

  /// The section's name (drawn in capitals).
  final String label;

  /// How many things it holds, beside the name.
  final int? count;

  /// A widget at the end of the rule (a sort button, a hint).
  final Widget? trailingChild;

  /// A plain text action at the very end.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Inset by the page's 24px margin (false where the caller already is).
  final bool padded;

  @override
  Widget build(BuildContext context) {
    Widget head = ZestSectionHeader(
      label: label,
      count: count,
      // Folded, the head stands alone: what its end offers is for the
      // section's content.
      trailing: folded ? null : trailingChild,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    if (onFold != null) {
      // The chevron's target is a mouse's 32 square or a finger's 48 (4.0,
      // the accessibility pass: it was its 16 by 12 drawing), its arrow where
      // it was: the head is centred on it, and the row starts that much
      // sooner.
      final target = minTapTarget(context);
      head = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FoldChevron(key: foldKey, folded: folded, onTap: onFold!, section: label, size: target),
          Expanded(
            child: ConstrainedBox(
              // The head's own 10 under it counted in.
              constraints: BoxConstraints(minHeight: target + 10),
              child: Align(alignment: AlignmentDirectional.centerStart, child: head),
            ),
          ),
        ],
      );
      final inset = 24 - (target - 16) / 2 - 1;
      return padded
          ? Padding(padding: EdgeInsetsDirectional.only(start: inset, end: 24), child: head)
          : head;
    }
    return padded ? Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: head) : head;
  }
}

/// The chevron before a section's head that folds it away (pointing down
/// while it is shown, right while it is folded), remembered by the page.
class _FoldChevron extends StatefulWidget {
  const _FoldChevron({super.key, required this.folded, required this.onTap, required this.section, required this.size});

  final bool folded;
  final VoidCallback onTap;

  /// The section's name, in what a screen reader says ("Hide Groups").
  final String section;

  /// Its target, square.
  final double size;

  @override
  State<_FoldChevron> createState() => _FoldChevronState();
}

class _FoldChevronState extends State<_FoldChevron> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tip = widget.folded ? l10n.hostsSectionUnfold : l10n.hostsSectionFold;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      excludeFromSemantics: true,
      child: ZestPressable(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        semanticLabel:
            widget.folded ? l10n.hostsSectionUnfoldNamed(widget.section) : l10n.hostsSectionFoldNamed(widget.section),
        expanded: !widget.folded,
        excludeChildSemantics: true,
        minSize: widget.size,
        borderRadius: 4,
        child: SizedBox(
          width: 16,
          height: 16,
          child: Icon(
            widget.folded ? LucideIcons.chevronRight : LucideIcons.chevronDown,
            size: 14,
            color: _hover ? ZestTokens.textPrimary : ZestTokens.textTertiary,
          ),
        ),
      ),
    );
  }
}
