import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/zest_tokens.dart';

// The parts of a phone's host form (4.0 UI):
// a field's name above its box, boxes 48 high,
// the protocols as a grid of tiles with their whole names, a choice of two as
// segments, the folded options as rows of one card, and the bar at the foot
// that Test and Save stand in. The form itself is the host editor's
// (connection_edit_screen.dart); these only draw.

/// How tall a box of the phone's form is where its words take a line: a
/// finger's target.
const double kPhoneFormBoxHeight = 48;

/// The corners of the form's boxes, tiles and buttons.
const double kPhoneFormRadius = 12;

/// The well a box of the form is drawn in: the theme's raised surface on a
/// light theme, a step above the page on a dark one (the mockup's surface).
Color get phoneFormWell =>
    ZestTokens.surfaceBase.computeLuminance() > 0.5 ? ZestTokens.surfaceRaised : ZestTokens.surfaceElevated;

/// A value typed in a box: the app's font, or its monospace one for an
/// address or a port.
TextStyle phoneFormValueStyle({bool mono = false}) => TextStyle(
      fontFamily: mono ? 'JetBrainsMono' : 'GeistSans',
      fontSize: mono ? 15 : 15.5,
      height: 1.3,
      color: ZestTokens.textPrimary,
    );

/// What an empty box says it is for.
TextStyle get phoneFormHintStyle =>
    TextStyle(fontFamily: 'GeistSans', fontSize: 15.5, height: 1.3, color: ZestTokens.textTertiary);

/// A field's name, above its box; [trailing] (Optional) at the end of its
/// line.
class PhoneFormLabel extends StatelessWidget {
  const PhoneFormLabel(this.label, {super.key, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    // Each at its own width where both hold on the line, the name at the
    // start and [trailing] at the end; sharing it where they do not (a word
    // of a fixed share, "Необязательно", was cut in two at 1.3 times).
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, color: ZestTokens.textSecondary),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                trailing!,
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 13, height: 1.3, color: ZestTokens.textTertiary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The box a value of the form is typed or chosen in: 48 high (taller where
/// its words or an error under them need it), its edge in the brand's colour
/// while what is inside it has the keyboard.
class PhoneFormBox extends StatefulWidget {
  const PhoneFormBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
    this.alignment = AlignmentDirectional.centerStart,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final AlignmentGeometry alignment;

  @override
  State<PhoneFormBox> createState() => _PhoneFormBoxState();
}

class _PhoneFormBoxState extends State<PhoneFormBox> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f != _focused) setState(() => _focused = f);
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: kPhoneFormBoxHeight),
        padding: widget.padding,
        alignment: widget.alignment,
        decoration: BoxDecoration(
          color: phoneFormWell,
          borderRadius: BorderRadius.circular(kPhoneFormRadius),
          border: Border.all(
            color: _focused ? ZestTokens.brand : ZestTokens.border,
            width: _focused ? 1.5 : 1,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// One choice of a [PhoneChoiceGrid] or of [PhoneSegments].
class PhoneChoice<T> {
  const PhoneChoice(this.value, this.label, {this.semanticsLabel, this.icon, this.key});

  final T value;

  /// What its tile or segment says.
  final String label;

  /// What a screen reader says of it, where that is more than [label] (a
  /// protocol's whole name: "SFTP only (files, no terminal)" for SFTP).
  final String? semanticsLabel;

  /// Before [label], on a segment.
  final IconData? icon;
  final Key? key;
}

/// The protocols, or any choice of several, as a grid of tiles of one size,
/// 48 high, each with its whole name: as many to a row as hold the longest
/// name with the check before it (five on most phones in English), and the
/// rows as even as they can be. The chosen one is filled, edged in the
/// brand's colour and checked: never told apart by colour alone. The grid is
/// drawn only; its keyboard (one Tab stop, the arrows moving the choice) is
/// its form's, which says through [groupFocused] that it holds the focus, and
/// the chosen tile is ringed.
class PhoneChoiceGrid<T> extends StatelessWidget {
  const PhoneChoiceGrid({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelected,
    this.groupFocused = false,
    this.maxColumns = 5,
  });

  final List<PhoneChoice<T>> choices;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool groupFocused;
  final int maxColumns;

  static const double _gap = 8;
  static const double _check = 15;
  static const double _checkGap = 4;
  static const double _padding = 6;

  TextStyle _style(bool chosen) => TextStyle(
        fontSize: 14.5,
        height: 1.2,
        fontWeight: chosen ? FontWeight.w600 : FontWeight.w500,
        color: chosen ? ZestTokens.brandInk : ZestTokens.textSecondary,
      );

  /// How many tiles go in a row [width] wide: as many as hold the widest
  /// name, checked, at the text size the app is drawn at; then as few as
  /// keep the same number of rows, so the last row is not left with one.
  int columnsFor(BuildContext context, double width) {
    final base = Theme.of(context).textTheme.bodyMedium ?? DefaultTextStyle.of(context).style;
    var widest = 0.0;
    for (final choice in choices) {
      final painter = TextPainter(
        text: TextSpan(text: choice.label, style: base.merge(_style(true))),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    final need = widest + _check + _checkGap + 2 * _padding + 4;
    final fit = ((width + _gap) / (need + _gap)).floor().clamp(1, math.max(1, maxColumns));
    final rows = (choices.length / fit).ceil();
    return rows == 0 ? 1 : (choices.length / rows).ceil();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final columns = columnsFor(context, box.maxWidth);
      final rows = <Widget>[];
      for (var start = 0; start < choices.length; start += columns) {
        final run = choices.sublist(start, math.min(start + columns, choices.length));
        rows.add(Row(
          children: [
            for (var i = 0; i < columns; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(child: i < run.length ? _tile(run[i]) : const SizedBox()),
            ],
          ],
        ));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: _gap),
            rows[i],
          ],
        ],
      );
    });
  }

  Widget _tile(PhoneChoice<T> choice) {
    final chosen = choice.value == selected;
    final ringed = chosen && groupFocused;
    return Semantics(
      button: true,
      selected: chosen,
      inMutuallyExclusiveGroup: true,
      label: choice.semanticsLabel ?? choice.label,
      excludeSemantics: true,
      onTap: () => onSelected(choice.value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: choice.key,
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelected(choice.value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minHeight: kPhoneFormBoxHeight),
            padding: const EdgeInsets.symmetric(horizontal: _padding),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: chosen ? ZestTokens.brandFill : phoneFormWell,
              borderRadius: BorderRadius.circular(kPhoneFormRadius),
              border: Border.all(
                color: chosen ? ZestTokens.brand : ZestTokens.border,
                width: chosen ? 2 : 1,
              ),
              boxShadow: ringed
                  ? [BoxShadow(color: ZestTokens.brand.withValues(alpha: 0.45), blurRadius: 6, spreadRadius: 1.5)]
                  : null,
            ),
            // Never cut: a grid narrower than its names (a very large text
            // size) draws them a little smaller rather than with an ellipsis.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (chosen) ...[
                    Icon(LucideIcons.check, size: _check, color: ZestTokens.brandInk),
                    const SizedBox(width: _checkGap),
                  ],
                  Text(choice.label, maxLines: 1, softWrap: false, style: _style(chosen)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A choice of two or three, side by side in one sunken box 48 high: the
/// chosen one raised, in the text's own colour, and each a button of its own
/// for the keyboard and a screen reader.
class PhoneSegments<T> extends StatelessWidget {
  const PhoneSegments({super.key, required this.choices, required this.selected, required this.onSelected});

  final List<PhoneChoice<T>> choices;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final light = ZestTokens.surfaceBase.computeLuminance() > 0.5;
    return Container(
      constraints: const BoxConstraints(minHeight: kPhoneFormBoxHeight),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(kPhoneFormRadius),
        border: Border.all(color: ZestTokens.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < choices.length; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(child: _segment(choices[i], light)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _segment(PhoneChoice<T> choice, bool light) {
    final chosen = choice.value == selected;
    final ink = chosen ? ZestTokens.textPrimary : ZestTokens.textFaint;
    return Semantics(
      button: true,
      selected: chosen,
      inMutuallyExclusiveGroup: true,
      label: choice.semanticsLabel ?? choice.label,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: choice.key,
          onTap: chosen ? () {} : () => onSelected(choice.value),
          borderRadius: BorderRadius.circular(9),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minHeight: kPhoneFormBoxHeight - 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: chosen ? ZestTokens.surfaceRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: chosen
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: light ? 0.12 : 0.35),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (choice.icon != null) ...[
                  Icon(choice.icon, size: 17, color: ink),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    choice.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.25,
                      fontWeight: chosen ? FontWeight.w600 : FontWeight.w500,
                      color: ink,
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

/// A folded part of the form: its row (an icon, its name, what is in it, and
/// the chevron that turns as it opens) and, while [open], what it holds.
class PhoneFold {
  const PhoneFold({
    required this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.open,
    required this.onToggle,
    required this.content,
  });

  final Key key;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool open;
  final VoidCallback onToggle;

  /// What it holds, built only while it is open.
  final WidgetBuilder content;
}

/// The form's folded parts, as rows of one card; what an open one holds is
/// under its row, the page's width (inside the card its long words had less
/// room than the form had given them, "Basiskonfiguration" among them), and
/// the rows after it a card of their own.
class PhoneFoldCard extends StatelessWidget {
  const PhoneFoldCard({super.key, required this.folds});

  final List<PhoneFold> folds;

  Widget _card(List<Widget> rows) => Container(
        decoration: BoxDecoration(
          color: phoneFormWell,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ZestTokens.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    var rows = <Widget>[];
    void endCard() {
      if (rows.isEmpty) return;
      children.add(_card(rows));
      rows = <Widget>[];
    }

    for (final fold in folds) {
      if (rows.isNotEmpty) rows.add(Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle));
      rows.add(_row(fold));
      if (fold.open) {
        endCard();
        children.add(Padding(
          key: ValueKey('${(fold.key as ValueKey).value}-open'),
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 20),
          child: Builder(builder: fold.content),
        ));
      }
    }
    endCard();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _row(PhoneFold fold) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        expanded: fold.open,
        child: InkWell(
          key: fold.key,
          onTap: fold.onToggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ZestTokens.surfaceChip,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(fold.icon, size: 17, color: ZestTokens.textSecondary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          fold.title,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: ZestTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          fold.subtitle,
                          style: TextStyle(fontSize: 13, height: 1.3, color: ZestTokens.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: fold.open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(LucideIcons.chevronDown, size: 18, color: ZestTokens.textFaint),
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

/// The bar at the foot of a phone's form, over the page's own system bar:
/// what a test said ([notice]), why Save is off where it is ([reason]), and
/// the buttons, [test] (where the host has one) beside [save] where the row
/// holds both with their words ([testWidth] and [saveWidth], what each
/// needs), else [test] over [save] (in Russian at 1.3 times the text size,
/// "Проверить" was cut in two beside it).
class PhoneFormBar extends StatelessWidget {
  const PhoneFormBar({
    super.key,
    this.notice,
    this.reason,
    this.test,
    this.testWidth = 0,
    required this.save,
    this.saveWidth = 0,
  });

  final Widget? notice;
  final String? reason;
  final Widget? test;
  final double testWidth;
  final Widget save;
  final double saveWidth;

  /// What a bar button with [words] needs, at the text size the app is drawn
  /// at: the words, its icon and the room around them.
  static double buttonWidth(BuildContext context, String words) {
    final base = Theme.of(context).textTheme.labelLarge ?? DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      text: TextSpan(text: words, style: base.merge(phoneBarButtonTextStyle)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    // Its icon (18), the room between (8), its padding (2 x 14) and edge.
    return width + 18 + 8 + 28 + 4;
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const ValueKey('host-form-bar'),
      decoration: BoxDecoration(
        color: ZestTokens.band,
        border: Border(top: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 9, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (notice != null) ...[
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
                  child: SingleChildScrollView(child: notice),
                ),
                const SizedBox(height: 9),
              ],
              if (reason != null)
                Padding(
                  key: const ValueKey('host-form-save-reason'),
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(LucideIcons.info, size: 16, color: ZestTokens.statusPending),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          reason!,
                          style: TextStyle(fontSize: 13.5, height: 1.35, color: ZestTokens.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              LayoutBuilder(builder: (context, box) {
                if (test == null) return save;
                // The mockup's Test is 118 wide, Save the rest of the row.
                final testBox = math.max(118.0, testWidth);
                if (testBox + 10 + saveWidth > box.maxWidth) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [test!, const SizedBox(height: 10), save],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: testBox, child: test),
                    const SizedBox(width: 10),
                    Expanded(child: save),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

/// The words of the bar's buttons. The app's font is named: a button's own
/// text style takes the place of the theme's, family and all.
const TextStyle phoneBarButtonTextStyle =
    TextStyle(fontFamily: 'GeistSans', fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.2);

/// The bar's buttons: 48 high where their words take a line, the form's
/// corners, the words a size up from a computer's.
ButtonStyle phoneBarButtonStyle({bool primary = false}) {
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(kPhoneFormRadius));
  const text = phoneBarButtonTextStyle;
  return primary
      ? FilledButton.styleFrom(
          minimumSize: const Size(0, kPhoneFormBoxHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: shape,
          textStyle: text,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        )
      : OutlinedButton.styleFrom(
          minimumSize: const Size(0, kPhoneFormBoxHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: shape,
          textStyle: text,
          backgroundColor: phoneFormWell,
          foregroundColor: ZestTokens.textPrimary,
          side: BorderSide(color: ZestTokens.border),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
}
