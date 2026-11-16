import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart' show GuideHelpButton;
import 'package:zestssh/ui/widgets/zest_pressable.dart';

import '../state/hosts_page_prefs.dart';

/// The Hosts page's toolbar: one row
/// on a strip of its own colour, so the top of the page reads as its top.
/// At the left the ways to add and open ([lead]: New host, Local terminal)
/// and, set apart from them, the filter-or-connect field; at the right
/// [trailing] (Sort, Filter) and the view's [toggles]. How many hosts need
/// attention is not here (each host's card and
/// the Server monitor say it; Filter still shows only those). No title: the Hosts tab says where
/// one is. Where the window is too narrow for one row, the field gives way
/// first, then the last of [lead] gives way to [leadCompact] (Local terminal
/// by its icon), then the toggles go to a second row, at its end as they are
/// on one row, then the rest of the right side ([_ToolbarLayout]). A short
/// brand line fades along its foot.
class HostsBand extends StatelessWidget {
  const HostsBand({
    super.key,
    required this.lead,
    this.leadCompact,
    required this.field,
    required this.trailing,
    required this.toggles,
  });

  final List<Widget> lead;

  /// The last of [lead] as it is drawn where only that keeps the toolbar on
  /// one row (with a side panel open): its icon alone, its words in its
  /// tooltip (the views were left alone
  /// on a second row).
  final Widget? leadCompact;

  /// The filter-or-connect field: as wide as the row allows, up to 420.
  final Widget field;
  final List<Widget> trailing;
  final Widget toggles;

  @override
  Widget build(BuildContext context) {
    Widget row(List<Widget> items) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              // The guide's "?" has a mouse's 32 square around its 16 px icon
              // (it was 24): half its gap before it is in that square, so
              // the icon stands where it stood.
              if (i > 0) SizedBox(width: items[i] is GuideHelpButton ? 4 : 8),
              items[i],
            ],
          ],
        );
    final head = lead.isEmpty ? const <Widget>[] : lead.sublist(0, lead.length - 1);
    return DecoratedBox(
      key: const ValueKey('hosts-toolbar'),
      decoration: BoxDecoration(
        // On a light page the band's own grey is a shade off the page's: the
        // strip is white there, as a card on it, so the top reads as the top
        // (a box of its own colour behind it).
        color: Theme.of(context).brightness == Brightness.light ? ZestTokens.surfaceElevated : ZestTokens.band,
        border: Border(bottom: BorderSide(color: ZestTokens.bandLine)),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            child: _ToolbarLayout(
              textDirection: Directionality.of(context),
              hasCompact: leadCompact != null,
              fieldBelow: touchSizedAt(context),
              children: [
                row(head),
                lead.isEmpty ? const SizedBox.shrink() : lead.last,
                leadCompact ?? const SizedBox.shrink(),
                field,
                row(trailing),
                toggles,
              ],
            ),
          ),
          // The brand line along the foot, fading out by the middle.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 1,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [ZestTokens.brand.withValues(alpha: 0.32), ZestTokens.brand.withValues(alpha: 0)],
                    stops: const [0, 0.55],
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

/// Lays out the toolbar's parts (the lead's first buttons, its last one and
/// that one's compact form, the field, trailing, toggles) at their own
/// widths, measured, so a longer language wraps as cleanly as English: one
/// row where all fit with the field at least [_RenderToolbar._fieldMin]
/// wide; else one row with the lead's last button compact; else the toggles
/// on a second row at its end; else the field after the lead on the first
/// row and the toggles and the rest on the second (each on a row of its own
/// where even that is too wide). Of the lead's last button and its compact
/// form only the one in use is drawn and answers the pointer.
class _ToolbarLayout extends MultiChildRenderObjectWidget {
  const _ToolbarLayout({
    required this.textDirection,
    required this.hasCompact,
    this.fieldBelow = false,
    required super.children,
  });

  final TextDirection textDirection;
  final bool hasCompact;

  /// Touch sized (a tablet, 4.0, portrait and
  /// landscape): the buttons on the first row (the lead at the left, the
  /// rest at the right) and the field the whole width of a second, where the
  /// buttons fit on one row.
  final bool fieldBelow;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderToolbar(textDirection, hasCompact, fieldBelow);

  @override
  void updateRenderObject(BuildContext context, _RenderToolbar renderObject) => renderObject
    ..textDirection = textDirection
    ..hasCompact = hasCompact
    ..fieldBelow = fieldBelow;
}

class _ToolbarSlot extends ContainerBoxParentData<RenderBox> {}

class _RenderToolbar extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ToolbarSlot>, RenderBoxContainerDefaultsMixin<RenderBox, _ToolbarSlot> {
  _RenderToolbar(this._textDirection, this._hasCompact, this._fieldBelow);

  static const _gap = 8.0;
  static const _apart = 16.0;

  /// Between the buttons at the left and the field: the field stands apart
  /// from them, not crowded against Local terminal.
  ///
  static const _fieldApart = 28.0;
  static const _runGap = 8.0;
  static const _fieldPref = 420.0;
  static const _fieldMin = 240.0;

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  bool _hasCompact;
  set hasCompact(bool v) {
    if (v == _hasCompact) return;
    _hasCompact = v;
    markNeedsLayout();
  }

  bool _fieldBelow;
  set fieldBelow(bool v) {
    if (v == _fieldBelow) return;
    _fieldBelow = v;
    markNeedsLayout();
  }

  /// The one of the lead's last button and its compact form not in use:
  /// laid out, never drawn, and deaf to the pointer.
  RenderBox? _hidden;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ToolbarSlot) child.parentData = _ToolbarSlot();
  }

  @override
  void performLayout() {
    final w = constraints.maxWidth;
    final kids = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      kids.add(c);
      c = childAfter(c);
    }
    assert(kids.length == 6);
    final head = kids[0], last = kids[1], compact = kids[2], field = kids[3], trailing = kids[4], toggles = kids[5];
    Size lay(RenderBox box, double maxW) {
      box.layout(BoxConstraints(maxWidth: math.max(0, maxW)), parentUsesSize: true);
      return box.size;
    }

    final headS = lay(head, w);
    final lastS = lay(last, w);
    final compactS = lay(compact, w);
    final trailS = lay(trailing, w);
    final togS = lay(toggles, w);
    void layField(double width) =>
        field.layout(BoxConstraints.tightFor(width: math.max(0, width)), parentUsesSize: true);

    // The lead with its last button whole, or compact.
    final tailAt = headS.width > 0 ? headS.width + _gap : 0.0;
    var tail = last;
    var leadW = tailAt + lastS.width;
    List<(RenderBox, double)> leadAt() => [(head, 0), (tail, tailAt)];

    // Each row: its boxes and where each starts along it.
    final rows = <List<(RenderBox, double)>>[];
    double oneRowWith(double lead) => w - lead - _fieldApart - _apart - trailS.width - _gap - togS.width;
    // (Touch sized, the field has a row of its own: the lead stays whole
    // where the buttons fit on theirs.)
    final buttonsFit = _fieldBelow && leadW + _apart + trailS.width + _gap + togS.width <= w;
    if (!buttonsFit && oneRowWith(leadW) < _fieldMin && _hasCompact && oneRowWith(tailAt + compactS.width) >= _fieldMin) {
      tail = compact;
      leadW = tailAt + compactS.width;
    }
    final hidden = tail == last ? compact : last;
    if (hidden != _hidden) {
      _hidden = hidden;
      markNeedsSemanticsUpdate();
    }
    final oneRow = oneRowWith(leadW);
    final twoRows = w - leadW - _fieldApart - _apart - trailS.width;
    if (buttonsFit) {
      // Touch sized: the buttons on one row, the field under them.
      layField(w);
      rows.add([
        ...leadAt(),
        (trailing, w - togS.width - _gap - trailS.width),
        (toggles, w - togS.width),
      ]);
      rows.add([(field, 0)]);
    } else if (oneRow >= _fieldMin) {
      layField(math.min(_fieldPref, oneRow));
      rows.add([
        ...leadAt(),
        (field, leadW + _fieldApart),
        (trailing, w - togS.width - _gap - trailS.width),
        (toggles, w - togS.width),
      ]);
    } else if (twoRows >= _fieldMin) {
      layField(math.min(_fieldPref, twoRows));
      rows.add([...leadAt(), (field, leadW + _fieldApart), (trailing, w - trailS.width)]);
      // At the end, where they are on one row.
      rows.add([(toggles, w - togS.width)]);
    } else {
      final beside = w - leadW - _fieldApart;
      if (beside >= 160) {
        layField(beside);
        rows.add([...leadAt(), (field, leadW + _fieldApart)]);
      } else {
        layField(w);
        rows.add(leadAt());
        rows.add([(field, 0)]);
      }
      if (togS.width + _apart + trailS.width <= w) {
        rows.add([(toggles, 0), (trailing, w - trailS.width)]);
      } else {
        rows.add([(toggles, 0)]);
        rows.add([(trailing, 0)]);
      }
    }
    var y = 0.0;
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) y += _runGap;
      final h = rows[i].fold<double>(0, (m, e) => math.max(m, e.$1.size.height));
      for (final (box, x) in rows[i]) {
        final dx = _textDirection == TextDirection.rtl ? w - x - box.size.width : x;
        (box.parentData! as _ToolbarSlot).offset = Offset(dx, y + (h - box.size.height) / 2);
      }
      y += h;
    }
    size = constraints.constrain(Size(w, y));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var child = firstChild;
    while (child != null) {
      final slot = child.parentData! as _ToolbarSlot;
      if (child != _hidden) context.paintChild(child, slot.offset + offset);
      child = slot.nextSibling;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    var child = lastChild;
    while (child != null) {
      final box = child;
      final slot = box.parentData! as _ToolbarSlot;
      if (box != _hidden &&
          result.addWithPaintOffset(
            offset: slot.offset,
            position: position,
            hitTest: (result, transformed) => box.hitTest(result, position: transformed),
          )) {
        return true;
      }
      child = slot.previousSibling;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitChildren((child) {
      if (child != _hidden) visitor(child);
    });
  }
}

/// The band's quick-connect field: searches the hosts as typed, and connects
/// to user@host:port when that is what was typed (Enter, or its Connect).
class HostsQuickField extends StatelessWidget {
  const HostsQuickField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onConnect,
    this.width = 360,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  /// Its Connect: null while there is nothing to connect to.
  final VoidCallback? onConnect;
  final double width;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 34 tall as every desktop control, taller where the system's text
    // size needs it.
    return Container(
      width: width == double.infinity ? null : width,
      constraints: BoxConstraints(minHeight: touchSizedAt(context) ? 48 : 34),
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: ZestTokens.surfaceSunken,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: focusNode.hasFocus ? ZestTokens.brand : ZestTokens.border),
          ),
          child: Row(
            children: [
              const SizedBox(width: 10),
              Icon(LucideIcons.search, size: 14, color: ZestTokens.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('hosts-quick-field'),
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: onChanged,
                  onSubmitted: (_) => onSubmitted(),
                  textInputAction: TextInputAction.go,
                  style: TextStyle(color: ZestTokens.textPrimary, fontSize: 12.5),
                  cursorHeight: 14,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.hostsQuickHint,
                    hintStyle: TextStyle(color: ZestTokens.textTertiary, fontSize: 12.5),
                    // The box above is the field's one edge: none of the
                    // theme's inside it (it drew a second box).
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    // The field's own target as tall as the box around it
                    // (a mouse's 32, a finger's 48: it was 27).
                    contentPadding: EdgeInsets.symmetric(vertical: touchSizedAt(context) ? 19 : 11),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _QuickGo(onTap: onConnect),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickGo extends StatefulWidget {
  const _QuickGo({required this.onTap});
  final VoidCallback? onTap;

  @override
  State<_QuickGo> createState() => _QuickGoState();
}

class _QuickGoState extends State<_QuickGo> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    // Its target the field's height (a pill of 24 drawn in it).
    return ZestPressable(
      key: const ValueKey('hosts-quick-connect'),
      onTap: widget.onTap,
      onHover: (h) => setState(() => _hover = h),
      borderRadius: 6,
      child: Container(
          constraints: const BoxConstraints(minHeight: 24),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on && _hover ? ZestTokens.brand : ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            AppLocalizations.of(context)!.hostsQuickConnect,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: on
                  ? (_hover ? ZestTokens.onBrand : ZestTokens.textSecondary)
                  : ZestTokens.textPlaceholder,
            ),
          ),
        ),
    );
  }
}

/// A button of the band: 32px, a hairline border on the card surface (or
/// none, [ghost]), an icon and words, and an optional count badge.
class BandButton extends StatefulWidget {
  const BandButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.ghost = false,
    this.badge,
    this.trailingIcon,
    this.tooltip,
    this.iconOnly = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool ghost;

  /// Its [icon] alone, as square as it is tall: [label] is said by its
  /// tooltip (unless [tooltip] says more) and to a screen reader.
  final bool iconOnly;

  /// A number in a brand badge after the words (the filters on).
  final int? badge;
  final IconData? trailingIcon;
  final String? tooltip;

  @override
  State<BandButton> createState() => _BandButtonState();
}

class _BandButtonState extends State<BandButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.ghost ? ZestTokens.textSecondary : ZestTokens.textPrimary;
    // Reached with Tab, pressed with Enter or Space, said as a button (it
    // was a bare tap: 4.0, the accessibility pass).
    Widget button = ZestPressable(
      onTap: widget.onPressed,
      onHover: (h) => setState(() => _hover = h),
      semanticLabel: widget.iconOnly ? widget.label : null,
      excludeChildSemantics: widget.iconOnly,
      minSize: 0,
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          constraints: BoxConstraints(
              minHeight: touchSizedAt(context) ? 48 : 34, minWidth: widget.iconOnly ? (touchSizedAt(context) ? 48 : 34) : 0),
          padding: EdgeInsets.symmetric(horizontal: widget.iconOnly ? 9 : 12, vertical: 4),
          decoration: BoxDecoration(
            color: widget.ghost
                ? (_hover ? ZestTokens.surfaceHover : Colors.transparent)
                : (_hover ? ZestTokens.surfaceRaisedAlt : ZestTokens.surfaceElevated),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.ghost
                  ? Colors.transparent
                  : (_hover ? ZestTokens.borderStrong : ZestTokens.border),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: fg),
                if (!widget.iconOnly) const SizedBox(width: 7),
              ],
              if (!widget.iconOnly)
                Text(
                  widget.label,
                  style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w500),
                ),
              if (widget.badge != null && widget.badge! > 0) ...[
                const SizedBox(width: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(color: ZestTokens.brand, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    '${widget.badge}',
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: ZestTokens.onBrand,
                    ),
                  ),
                ),
              ],
              if (widget.trailingIcon != null) ...[
                const SizedBox(width: 5),
                Icon(widget.trailingIcon, size: 12, color: ZestTokens.textTertiary),
              ],
            ],
          ),
        ),
    );
    final tip = widget.tooltip ?? (widget.iconOnly ? widget.label : null);
    if (tip != null) {
      button = Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 500),
        // Its label already says it (the reader said it twice).
        excludeFromSemantics: tip == widget.label,
        child: button,
      );
    }
    return Opacity(opacity: widget.onPressed == null ? 0.4 : 1, child: button);
  }
}

/// The page's brand button with a menu beside it: [label] does the main
/// thing, the caret opens [onMenu] (given where to open it).
class BandSplitButton extends StatefulWidget {
  const BandSplitButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.onMenu,
    required this.menuTooltip,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  /// Opens the menu under the button: [anchor] is the button's rectangle in
  /// global coordinates.
  final void Function(Rect anchor) onMenu;
  final String menuTooltip;

  @override
  State<BandSplitButton> createState() => _BandSplitButtonState();
}

class _BandSplitButtonState extends State<BandSplitButton> {
  bool _hoverMain = false;
  bool _hoverCaret = false;

  Rect _anchor() {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final brand = ZestTokens.brand;
    final hover = Color.lerp(brand, Colors.white, 0.12)!;
    final ink = ZestTokens.onBrand;
    return Opacity(
      opacity: widget.onPressed == null ? 0.4 : 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: touchSizedAt(context) ? 48 : 34),
        child: IntrinsicHeight(
          child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Each half reached with Tab and said as a button (4.0, the
            // accessibility pass).
            ZestPressable(
              key: const ValueKey('hosts-new-host'),
              onTap: widget.onPressed,
              onHover: (h) => setState(() => _hoverMain = h),
              minSize: 0,
              child: Container(
                  padding: const EdgeInsets.only(left: 12, right: 10),
                  decoration: BoxDecoration(
                    color: _hoverMain ? hover : brand,
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                  ),
                  child: Row(
                    children: [
                      Icon(widget.icon, size: 14, color: ink),
                      const SizedBox(width: 7),
                      Text(widget.label, style: TextStyle(color: ink, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ),
            Tooltip(
              message: widget.menuTooltip,
              waitDuration: const Duration(milliseconds: 500),
              excludeFromSemantics: true,
              child: ZestPressable(
                  key: const ValueKey('hosts-new-menu'),
                  onTap: () => widget.onMenu(_anchor()),
                  onHover: (h) => setState(() => _hoverCaret = h),
                  semanticLabel: widget.menuTooltip,
                  excludeChildSemantics: true,
                  minSize: 0,
                  child: Container(
                    // A mouse's 32 wide (it was 26), a finger's 48.
                    width: touchSizedAt(context) ? 48 : 32,
                    decoration: BoxDecoration(
                      color: _hoverCaret ? hover : brand,
                      borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                      border: Border(left: BorderSide(color: ink.withValues(alpha: 0.25))),
                    ),
                    child: Icon(LucideIcons.chevronDown, size: 13, color: ink),
                  ),
                ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// The views of the hosts: the list, the compact grid and the grid of cards,
/// side by side, the one shown lit.
class HostsViewToggle extends StatelessWidget {
  const HostsViewToggle({super.key, required this.mode, required this.onChanged});

  final HostsViewMode mode;
  final ValueChanged<HostsViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget seg(HostsViewMode m, IconData icon, String tip, String key) {
      final on = mode == m;
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 500),
        excludeFromSemantics: true,
        child: ZestPressable(
              key: ValueKey(key),
              onTap: () => onChanged(m),
              semanticLabel: tip,
              selected: on,
              excludeChildSemantics: true,
              minSize: 0,
              borderRadius: 6,
              // Pressed in a mouse's 32 square, a finger's 48 (they were 30
              // by 28, and 44 by 42): the segments touch, each drawn as it
              // was inside its target, the 2 px between them its margin, so
              // the toggle is no wider than it was.
              child: SizedBox(
                width: touchSizedAt(context) ? 48 : 32,
                height: touchSizedAt(context) ? 48 : 32,
                child: Container(
                  margin: touchSizedAt(context) ? const EdgeInsets.symmetric(horizontal: 2, vertical: 3) : const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
                  decoration: BoxDecoration(
                    color: on ? ZestTokens.surfaceRaised : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(icon, size: touchSizedAt(context) ? 18 : 15, color: on ? ZestTokens.textPrimary : ZestTokens.textTertiary),
                ),
              ),
        ),
      );
    }

    return Container(
      // As tall as the band's other buttons around its 32 high segments.
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(HostsViewMode.list, LucideIcons.list, l10n.hostsViewList, 'hosts-view-list'),
          seg(HostsViewMode.compact, LucideIcons.grid, l10n.hostsViewCompact, 'hosts-view-compact'),
          seg(HostsViewMode.grid, LucideIcons.layoutGrid, l10n.hostsViewCards, 'hosts-view-cards'),
        ],
      ),
    );
  }
}

/// A row of a band menu: an icon, words (with a line under them), and a key.
class BandMenuRow extends StatelessWidget {
  const BandMenuRow({super.key, required this.icon, required this.label, this.sub, this.keys, this.checked});

  final IconData icon;
  final String label;
  final String? sub;
  final String? keys;

  /// A tick at the start where it is a choice that is on (null: no tick slot).
  final bool? checked;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (checked != null)
          SizedBox(
            width: 22,
            child: checked! ? Icon(LucideIcons.check, size: 14, color: ZestTokens.brandInk) : null,
          ),
        Icon(icon, size: 15, color: ZestTokens.textTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: ZestTokens.textPrimary, fontSize: 12.5)),
              if (sub != null)
                Text(sub!, style: TextStyle(color: ZestTokens.textTertiary, fontSize: 11)),
            ],
          ),
        ),
        if (keys != null)
          Container(
            margin: const EdgeInsets.only(left: 10),
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceSunken,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: ZestTokens.borderStrong),
            ),
            child: Text(
              keys!,
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, height: 1.6, color: ZestTokens.textTertiary),
            ),
          ),
      ],
    );
  }
}
