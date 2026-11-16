import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;
import 'package:zestssh/theme/app_colors.dart';

/// How the code looks in the file editor (3.4): by default the terminal's
/// theme and font, so code reads as it does in a session; with that option
/// off, the app's own theme and JetBrains Mono. With a dark terminal theme
/// in a light app the code stays dark: it is what the person chose for
/// code.
class EditorLook {
  const EditorLook({
    required this.background,
    required this.foreground,
    required this.gutterText,
    required this.gutterActiveText,
    required this.currentLine,
    required this.selection,
    required this.cursor,
    required this.match,
    required this.currentMatch,
    required this.changedBar,
    required this.syntax,
    required this.fontFamily,
    required this.fontSize,
    required this.dark,
  });

  final Color background;
  final Color foreground;
  final Color gutterText;
  final Color gutterActiveText;
  final Color currentLine;
  final Color selection;
  final Color cursor;
  final Color match;
  final Color currentMatch;

  /// The bar beside a line changed since the last save.
  final Color changedBar;

  /// The highlighter's styles, by its class names ('keyword', 'string', ...).
  final Map<String, TextStyle> syntax;
  final String fontFamily;
  final double fontSize;
  final bool dark;

  /// The terminal's [theme] and font ([fontFamily] at [fontSize]).
  factory EditorLook.terminal(TerminalTheme theme, {required String fontFamily, required double fontSize}) {
    final dark = theme.background.computeLuminance() < 0.4;
    final fg = theme.foreground;
    Color mix(Color a, double t) => Color.lerp(theme.background, a, t)!;
    return EditorLook(
      background: theme.background,
      foreground: fg,
      gutterText: mix(fg, 0.42),
      gutterActiveText: fg,
      currentLine: mix(fg, 0.06),
      selection: theme.selection,
      cursor: theme.cursor,
      match: theme.searchHitBackground.withValues(alpha: 0.35),
      currentMatch: theme.searchHitBackgroundCurrent.withValues(alpha: 0.75),
      changedBar: AppColors.v3AccentPrimary,
      syntax: _syntax(
        fg: fg,
        background: theme.background,
        comment: dark ? theme.brightBlack : Color.lerp(theme.brightBlack, fg, 0.25)!,
        keyword: theme.magenta,
        string: theme.green,
        number: dark ? theme.brightYellow : theme.yellow,
        type: theme.yellow,
        attribute: theme.blue,
        title: theme.cyan,
        variable: theme.red,
        meta: theme.brightBlue,
        addition: theme.green,
        deletion: theme.red,
      ),
      fontFamily: fontFamily,
      fontSize: fontSize,
      dark: dark,
    );
  }

  /// The app's own theme, in JetBrains Mono at [fontSize].
  factory EditorLook.app({required double fontSize}) {
    final bg = AppColors.v3Background;
    final dark = bg.computeLuminance() < 0.4;
    final fg = AppColors.v3TextPrimary;
    return EditorLook(
      background: bg,
      foreground: fg,
      gutterText: AppColors.v3TextTertiary,
      gutterActiveText: fg,
      currentLine: AppColors.v3Hover.withValues(alpha: 0.5),
      selection: AppColors.v3AccentPrimary.withValues(alpha: 0.28),
      cursor: AppColors.v3AccentPrimary,
      match: AppColors.v3Warning.withValues(alpha: 0.28),
      currentMatch: AppColors.v3AccentPrimary.withValues(alpha: 0.55),
      changedBar: AppColors.v3AccentPrimary,
      syntax: _syntax(
        fg: fg,
        background: bg,
        comment: AppColors.v3TextTertiary,
        keyword: AppColors.v3AccentInk,
        string: AppColors.v3Success,
        number: AppColors.v3Warning,
        type: AppColors.v3Info,
        attribute: AppColors.v3Info,
        title: AppColors.v3TextPrimary,
        variable: AppColors.v3Error,
        meta: AppColors.v3TextSecondary,
        addition: AppColors.v3Success,
        deletion: AppColors.v3Error,
      ),
      fontFamily: 'JetBrainsMono',
      fontSize: fontSize,
      dark: dark,
    );
  }

  static Map<String, TextStyle> _syntax({
    required Color fg,
    required Color background,
    required Color comment,
    required Color keyword,
    required Color string,
    required Color number,
    required Color type,
    required Color attribute,
    required Color title,
    required Color variable,
    required Color meta,
    required Color addition,
    required Color deletion,
  }) {
    TextStyle c(Color color) => TextStyle(color: color);
    return {
      'root': TextStyle(color: fg, backgroundColor: background),
      'comment': TextStyle(color: comment, fontStyle: FontStyle.italic),
      'quote': TextStyle(color: comment, fontStyle: FontStyle.italic),
      'doctag': c(keyword),
      'keyword': c(keyword),
      'selector-tag': c(keyword),
      'formula': c(keyword),
      'section': c(title),
      'name': c(title),
      'title': c(title),
      'title.class_': c(type),
      'class-title': c(type),
      'built_in': c(type),
      'type': c(type),
      'selector-class': c(type),
      'literal': c(number),
      'number': c(number),
      'symbol': c(number),
      'bullet': c(number),
      'string': c(string),
      'meta-string': c(string),
      'regexp': c(string),
      'link': TextStyle(color: string, decoration: TextDecoration.underline),
      'attribute': c(attribute),
      'attr': c(attribute),
      'selector-attr': c(attribute),
      'selector-pseudo': c(attribute),
      'selector-id': c(attribute),
      'property': c(attribute),
      'variable': c(variable),
      'template-variable': c(variable),
      'subst': c(variable),
      'meta': c(meta),
      'addition': c(addition),
      'deletion': c(deletion),
      'emphasis': const TextStyle(fontStyle: FontStyle.italic),
      'strong': const TextStyle(fontWeight: FontWeight.w700),
    };
  }
}
