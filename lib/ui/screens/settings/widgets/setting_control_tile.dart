import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// A setting with a control of its own (a choice, a slider, a few segments),
/// as a phone's settings pages show one: its icon, its name and what it
/// does, and the control. The control stands beside the words where they
/// keep room to be read, and under them, as wide as they are, where they
/// would not: on a phone's narrow page, with a long choice, at a large text
/// size. Beside them there, it left the words a few letters a line (found
/// 17 October 2026).
class SettingControlTile extends StatelessWidget {
  const SettingControlTile({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    required this.controlWidth,
    required this.control,
    this.contentPadding,
  });

  final Widget leading;
  final Widget title;
  final Widget? subtitle;

  /// How wide the control stands beside the words.
  final double controlWidth;

  /// The control, told whether it stands beside the words (at
  /// [controlWidth]) or under them (as wide as they are).
  final Widget Function(BuildContext context, bool beside) control;

  final EdgeInsetsGeometry? contentPadding;

  /// The least room the words keep beside the control, at the text size the
  /// app is drawn at. It grows with the text.
  static const minWordsWidth = 200.0;

  /// Whether the control stands beside the words in a row [width] wide.
  bool controlBeside(BuildContext context, double width) {
    final theme = ListTileTheme.of(context);
    final padding = (contentPadding ?? theme.contentPadding ?? const EdgeInsets.symmetric(horizontal: 16)).horizontal;
    final gap = theme.horizontalTitleGap ?? 16;
    final leadingWidth = math.max(theme.minLeadingWidth ?? 24, 24);
    final words = width - padding - leadingWidth - gap - gap - controlWidth;
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return words >= minWordsWidth * scale;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final beside = controlBeside(context, constraints.maxWidth);
      if (beside) {
        return ListTile(
          contentPadding: contentPadding,
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: SizedBox(width: controlWidth, child: control(context, true)),
        );
      }
      return ListTile(
        contentPadding: contentPadding,
        leading: leading,
        title: title,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?subtitle,
            const SizedBox(height: 4),
            control(context, false),
          ],
        ),
      );
    });
  }
}

/// A [SettingControlTile] whose control is a choice from a few: the one picked
/// in a field (beside the words as wide as the longest choice, under them as
/// wide as they are, a long choice wrapping there) that opens every choice in
/// a sheet, the one picked marked (3.0 UI; it was a dropdown).
class SettingChoiceTile<T> extends StatelessWidget {
  const SettingChoiceTile({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.contentPadding,
  });

  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final T value;

  /// Each choice and its words.
  final List<(T, String)> choices;
  final ValueChanged<T> onChanged;
  final EdgeInsetsGeometry? contentPadding;

  static const _choiceStyle = TextStyle(fontSize: 14);

  /// The width of the dropdown beside the words: its longest choice at the
  /// text size it is drawn at, and its arrow.
  double _width(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(Theme.of(context).textTheme.titleMedium).merge(_choiceStyle);
    var widest = 0.0;
    for (final (_, words) in choices) {
      final painter = TextPainter(
        text: TextSpan(text: words, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    // The field's padding, its arrows, and room before them.
    return (widest + 24 + 22 + 8).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    return SettingControlTile(
      contentPadding: contentPadding,
      leading: leading,
      title: title,
      subtitle: subtitle,
      controlWidth: _width(context),
      control: (context, beside) => _ChoiceField<T>(
        key: const ValueKey('setting-choice-field'),
        title: title,
        value: value,
        choices: choices,
        onChanged: onChanged,
      ),
    );
  }
}

/// The choice picked, in a field that opens every choice in a sheet.
class _ChoiceField<T> extends StatelessWidget {
  const _ChoiceField({super.key, required this.title, required this.value, required this.choices, required this.onChanged});

  final Widget title;
  final T value;
  final List<(T, String)> choices;
  final ValueChanged<T> onChanged;

  Future<void> _pick(BuildContext context) async {
    // The app's sheet of choices on a phone, its dialog on a computer, the
    // one picked checked (settings/widgets/choice_sheet.dart).
    // The name, also where the title folds its help behind More (4.0).
    final name = FoldedHelpTitle.nameOf(title);
    final picked = await showSettingsChoice<T>(
      context,
      title: name ?? '',
      choices: choices,
      current: value,
    );
    if (picked != null && picked.$1 != value) onChanged(picked.$1);
  }

  @override
  Widget build(BuildContext context) {
    var words = '';
    for (final (choice, w) in choices) {
      if (choice == value) words = w;
    }
    // Drawn as the app's select is (ui/widgets/zest_select.dart): the
    // inputs' fill, hairline and radius, and its chevron. It was a chip of
    // its own with up and down arrows (found in a design
    // audit). It opens its choices in a sheet, as a phone does.
    final deco = Theme.of(context).inputDecorationTheme;
    final border = deco.enabledBorder as OutlineInputBorder?;
    final radius = border?.borderRadius ?? BorderRadius.circular(8);
    return Material(
      color: deco.fillColor ?? ZestTokens.surfaceChip,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => _pick(context),
        child: Container(
          padding: const EdgeInsets.only(left: 12, right: 10, top: 9, bottom: 9),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.fromBorderSide(border?.borderSide ?? BorderSide(color: ZestTokens.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  words,
                  style: SettingChoiceTile._choiceStyle.copyWith(color: ZestColors.textPrimary, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronDown, size: 14, color: ZestTokens.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
