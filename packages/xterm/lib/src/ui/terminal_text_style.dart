import 'package:flutter/widgets.dart';

const _kDefaultFontSize = 13.0;

const _kDefaultHeight = 1.2;

const _kDefaultFontFamily = 'monospace';

const _kDefaultFontFamilyFallback = [
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
  // ZestSSH: the app's bundled Nerd Font symbols (Private Use Area only), so
  // a terminal drawn with the default style (the detached window, a session
  // replay) has the powerline separators and icons too. A family an app does
  // not have is skipped.
  'SymbolsNerdFontMono',
];

/// OpenType features that turn on programming ligatures (FiraCode / Cascadia
/// Code: `-> => != >= === |>`). `calt` (contextual alternates) is what those
/// fonts actually use; `liga` (standard ligatures) is enabled too for fonts
/// that classify their coding ligatures there.
const _kLigatureFeatures = [
  FontFeature.enable('calt'),
  FontFeature.enable('liga'),
];

class TerminalStyle {
  const TerminalStyle({
    this.fontSize = _kDefaultFontSize,
    this.height = _kDefaultHeight,
    this.fontFamily = _kDefaultFontFamily,
    this.fontFamilyFallback = _kDefaultFontFamilyFallback,
    this.enableLigatures = false,
  });

  factory TerminalStyle.fromTextStyle(
    TextStyle textStyle, {
    bool enableLigatures = false,
  }) {
    return TerminalStyle(
      fontSize: textStyle.fontSize ?? _kDefaultFontSize,
      height: textStyle.height ?? _kDefaultHeight,
      fontFamily: textStyle.fontFamily ??
          textStyle.fontFamilyFallback?.first ??
          _kDefaultFontFamily,
      fontFamilyFallback:
          textStyle.fontFamilyFallback ?? _kDefaultFontFamilyFallback,
      enableLigatures: enableLigatures,
    );
  }

  final double fontSize;

  final double height;

  final String fontFamily;

  final List<String> fontFamilyFallback;

  /// When true, [toTextStyle] requests `calt`/`liga`. This ALONE renders no
  /// ligatures: the painter must also shape contiguous same-style cells as one
  /// run (see RenderTerminal's ligature paint path) so the features have
  /// adjacent glyphs to combine. Default false = byte-identical legacy paint.
  final bool enableLigatures;

  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
  }) {
    return TextStyle(
      fontSize: fontSize,
      height: height,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: underline ? TextDecoration.underline : TextDecoration.none,
      fontFeatures: enableLigatures ? _kLigatureFeatures : null,
    );
  }

  TerminalStyle copyWith({
    double? fontSize,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    bool? enableLigatures,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
      enableLigatures: enableLigatures ?? this.enableLigatures,
    );
  }
}
