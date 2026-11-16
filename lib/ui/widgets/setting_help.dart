import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';

// Settings rows are one line, with the help behind a quiet More (on
// computers and on phones): the More
// beside a setting's name, and a phone's row title that folds its help.

/// The quiet More beside a setting's name, Less while its help is shown: a
/// button by click, tap, Enter or Space, said to a screen reader with the
/// setting's name and whether the help is shown. Its hit area is [minHit]
/// high around the small chip (48 on a phone or a tablet, as every touch
/// target there).
class SettingMoreButton extends StatefulWidget {
  const SettingMoreButton({
    super.key,
    required this.setting,
    required this.open,
    required this.onTap,
    this.minHit = 40,
    this.hitBeyond = false,
  });

  /// The setting's name, for a screen reader and for the button's key.
  final String setting;
  final bool open;
  final VoidCallback onTap;
  final double minHit;

  /// Laid out at its chip's height, [minHit] wide: the row it stands in makes
  /// its target [minHit] high, reaching into the row's padding
  /// ([FoldedHelpTitle]), so the name's line is no taller for it.
  final bool hitBeyond;

  /// The key of the More of [setting] (one key a setting, for tests).
  static ValueKey<String> keyOf(String setting) => ValueKey('settings-row-more-$setting');

  @override
  State<SettingMoreButton> createState() => _SettingMoreButtonState();
}

class _SettingMoreButtonState extends State<SettingMoreButton> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final open = widget.open;
    final ink = open || _hover ? AppColors.v3TextSecondary : ZestTokens.textMuted;
    final chip = Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: open || _hover ? ZestTokens.surfaceChip : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _focus ? ZestTokens.brand : Colors.transparent, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(open ? l10n.settingsRowLess : l10n.settingsRowMore, style: TextStyle(fontSize: 12.5, color: ink)),
          const SizedBox(width: 3),
          Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 14, color: ink),
        ],
      ),
    );
    return Semantics(
      button: true,
      expanded: open,
      label: open ? l10n.settingsRowLessAbout(widget.setting) : l10n.settingsRowMoreAbout(widget.setting),
      excludeSemantics: true,
      onTap: widget.onTap,
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
          key: SettingMoreButton.keyOf(widget.setting),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: widget.hitBeyond ? 0 : widget.minHit, minWidth: widget.minHit),
            child: Center(widthFactor: 1, heightFactor: 1, child: chip),
          ),
        ),
      ),
    );
  }
}

/// A phone's settings row title that folds its help: the setting's name (or
/// [title], a name with its own (?) after it) with a More beside it, and
/// [help] under them while it is open. It stands where a ListTile's title
/// stood, in place of a subtitle that held the help; the row's own tap (its
/// switch, its page) stays the row's, and More's tap is More's.
///
/// More stands after the name's last word, on its line (on a line of its own
/// only where that line has no room), and the line is no taller for it: its
/// 48 high target reaches into the row's padding (the device run of 13
/// November 2026 found a 48 high line, an empty strip under the name, and
/// More on a line of its own under a long name).
class FoldedHelpTitle extends StatefulWidget {
  const FoldedHelpTitle({super.key, required this.setting, required this.help, this.title});

  /// The setting's name.
  final String setting;

  /// What it does, behind More.
  final String help;

  /// Drawn in place of the name (a name with its (?) after it); [setting] is
  /// still the name a screen reader and the search use.
  final Widget? title;

  /// The setting's name of a row title: a [FoldedHelpTitle]'s or a [Text]'s.
  static String? nameOf(Widget? title) => switch (title) {
        FoldedHelpTitle(:final setting) => setting,
        Text(:final data) => data,
        _ => null,
      };

  @override
  State<FoldedHelpTitle> createState() => _FoldedHelpTitleState();
}

class _FoldedHelpTitleState extends State<FoldedHelpTitle> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return _NameMoreHelp(
      hitHeight: 48,
      textDirection: Directionality.of(context),
      children: [
        // A phone's row is one node to a screen reader (its switch, its
        // page): the help is said with the name, as a hint, folded or
        // not, and More, a thing to see, is not a second stop in it.
        Semantics(hint: _open ? null : widget.help, child: widget.title ?? Text(widget.setting)),
        ExcludeSemantics(
          child: SettingMoreButton(
            setting: widget.setting,
            open: _open,
            minHit: 48,
            hitBeyond: true,
            onTap: () => setState(() => _open = !_open),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.help,
              key: const ValueKey('settings-row-help'),
              style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// Lays out a row title's name, its More and, while open, its help: More after
/// the name's last word, centred on that line, where the line has room (else
/// at the start of a line under the name), the help under both. A tap up to
/// [hitHeight] high around More (into the row's padding above or below the
/// name) is More's.
class _NameMoreHelp extends MultiChildRenderObjectWidget {
  const _NameMoreHelp({required this.hitHeight, required this.textDirection, required super.children});

  final double hitHeight;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderNameMoreHelp(hitHeight, textDirection);

  @override
  void updateRenderObject(BuildContext context, _RenderNameMoreHelp renderObject) => renderObject
    ..hitHeight = hitHeight
    ..textDirection = textDirection;
}

class _NameMoreHelpSlot extends ContainerBoxParentData<RenderBox> {}

class _RenderNameMoreHelp extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _NameMoreHelpSlot>, RenderBoxContainerDefaultsMixin<RenderBox, _NameMoreHelpSlot> {
  _RenderNameMoreHelp(this._hitHeight, this._textDirection);

  /// Between the name's last word and More (its chip has room of its own
  /// round its word).
  static const _gap = 4.0;

  double _hitHeight;
  set hitHeight(double v) {
    if (v == _hitHeight) return;
    _hitHeight = v;
  }

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  RenderBox get _name => firstChild!;
  RenderBox get _more => childAfter(firstChild!)!;
  RenderBox? get _help => childAfter(_more);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _NameMoreHelpSlot) child.parentData = _NameMoreHelpSlot();
  }

  /// The name's last line, in the name's own space: where it ends (its right
  /// end, or its left one right to left), its top and its bottom. The whole
  /// name where it holds no paragraph to measure (a name drawn another way).
  (double end, double top, double bottom) _lastLine() {
    final name = _name;
    RenderParagraph? paragraph;
    void find(RenderObject o) {
      if (paragraph != null) return;
      if (o is RenderParagraph) {
        paragraph = o;
        return;
      }
      o.visitChildren(find);
    }

    find(name);
    final rtl = _textDirection == TextDirection.rtl;
    final whole = (rtl ? 0.0 : name.size.width, 0.0, name.size.height);
    final p = paragraph;
    if (p == null) return whole;
    final length = p.text.toPlainText(includeSemanticsLabels: false).length;
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length));
    if (boxes.isEmpty) return whole;
    final bottom = boxes.map((b) => b.bottom).reduce(math.max);
    final last = boxes.where((b) => b.bottom >= bottom - 0.5);
    final top = last.map((b) => b.top).reduce(math.min);
    final end = rtl ? last.map((b) => b.left).reduce(math.min) : last.map((b) => b.right).reduce(math.max);
    final shift = MatrixUtils.transformPoint(p.getTransformTo(name), Offset.zero);
    return (end + shift.dx, top + shift.dy, bottom + shift.dy);
  }

  /// Where each part goes for [width], and the height they take.
  ({Offset name, Offset more, Offset help, double height}) _place(
      double width, Size name, Size more, Size? help, (double, double, double) line) {
    final rtl = _textDirection == TextDirection.rtl;
    final nameX = rtl ? width - name.width : 0.0;
    final (end, top, bottom) = line;
    final room = rtl ? nameX + end : width - (nameX + end);
    var nameY = 0.0;
    double moreX, moreY;
    if (room >= _gap + more.width) {
      moreX = rtl ? nameX + end - _gap - more.width : nameX + end + _gap;
      moreY = (top + bottom) / 2 - more.height / 2;
      if (moreY < 0) {
        nameY = -moreY;
        moreY = 0;
      } else {
        moreY += nameY;
      }
    } else {
      moreX = rtl ? width - more.width : 0.0;
      moreY = name.height;
    }
    final rows = math.max(nameY + name.height, moreY + more.height);
    final helpX = help == null || !rtl ? 0.0 : width - help.width;
    return (
      name: Offset(nameX, nameY),
      more: Offset(moreX, moreY),
      help: Offset(helpX, rows),
      height: rows + (help?.height ?? 0),
    );
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : _name.getMaxIntrinsicWidth(double.infinity);
    final loose = BoxConstraints(maxWidth: width);
    _name.layout(loose, parentUsesSize: true);
    _more.layout(loose, parentUsesSize: true);
    _help?.layout(loose, parentUsesSize: true);
    final at = _place(width, _name.size, _more.size, _help?.size, _lastLine());
    (_name.parentData! as _NameMoreHelpSlot).offset = at.name;
    (_more.parentData! as _NameMoreHelpSlot).offset = at.more;
    if (_help != null) (_help!.parentData! as _NameMoreHelpSlot).offset = at.help;
    size = constraints.constrain(Size(width, at.height));
  }

  /// Without laying out: More after the name where the name is one line with
  /// room after it, else under it.
  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : _name.getMaxIntrinsicWidth(double.infinity);
    final loose = BoxConstraints(maxWidth: width);
    final name = _name.getDryLayout(loose);
    final more = _more.getDryLayout(loose);
    final help = _help?.getDryLayout(loose);
    final rtl = _textDirection == TextDirection.rtl;
    final at = _place(width, name, more, help, (rtl ? 0.0 : name.width, 0.0, name.height));
    return constraints.constrain(Size(width, at.height));
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final name = _name;
    final b = name.getDistanceToActualBaseline(baseline);
    return b == null ? null : b + (name.parentData! as _NameMoreHelpSlot).offset.dy;
  }

  @override
  double? computeDryBaseline(covariant BoxConstraints constraints, TextBaseline baseline) =>
      _name.getDryBaseline(BoxConstraints(maxWidth: constraints.maxWidth), baseline);

  @override
  double computeMinIntrinsicWidth(double height) => [
        _name.getMinIntrinsicWidth(double.infinity),
        _more.getMinIntrinsicWidth(double.infinity),
        _help?.getMinIntrinsicWidth(double.infinity) ?? 0,
      ].reduce(math.max);

  @override
  double computeMaxIntrinsicWidth(double height) => math.max(
        _name.getMaxIntrinsicWidth(double.infinity) + _gap + _more.getMaxIntrinsicWidth(double.infinity),
        _help?.getMaxIntrinsicWidth(double.infinity) ?? 0,
      );

  @override
  double computeMinIntrinsicHeight(double width) => getDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // More's target first, [hitHeight] high around it: above and below it, the
    // row's padding (outside this box), the name's other line or the help's
    // first (inside it), none of which takes a tap of its own.
    final more = _more;
    final at = (more.parentData! as _NameMoreHelpSlot).offset;
    final local = position - at;
    final extra = math.max(0.0, (_hitHeight - more.size.height) / 2);
    if (local.dx < 0 || local.dx >= more.size.width || local.dy < -extra || local.dy >= more.size.height + extra) {
      if (size.contains(position) && hitTestChildren(result, position: position)) {
        result.add(BoxHitTestEntry(this, position));
        return true;
      }
      return false;
    }
    final inside = Offset(local.dx, local.dy.clamp(0.0, more.size.height - 1).toDouble());
    final hit = result.addWithPaintOffset(
      offset: at,
      position: at + inside,
      hitTest: (result, transformed) => more.hitTest(result, position: transformed),
    );
    if (hit) result.add(BoxHitTestEntry(this, position));
    return hit;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}
