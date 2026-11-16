import 'package:zestssh/models/enums.dart';

/// Settings for the terminal emulator.
///
/// Terminal theme and app theme are independent systems.
class TerminalSettings {
  final String terminalThemeId;
  final TerminalFontFamily fontFamily;
  final double fontSize;
  final int scrollbackLines;
  final bool bellEnabled;
  final bool hapticFeedback;
  final bool keepScreenAwake;

  const TerminalSettings({
    this.terminalThemeId = 'dark',
    this.fontFamily = TerminalFontFamily.jetBrainsMono,
    this.fontSize = 14.0,
    this.scrollbackLines = 5000,
    this.bellEnabled = true,
    this.hapticFeedback = true,
    this.keepScreenAwake = true,
  });

  TerminalSettings copyWith({
    String? terminalThemeId,
    TerminalFontFamily? fontFamily,
    double? fontSize,
    int? scrollbackLines,
    bool? bellEnabled,
    bool? hapticFeedback,
    bool? keepScreenAwake,
  }) {
    return TerminalSettings(
      terminalThemeId: terminalThemeId ?? this.terminalThemeId,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      scrollbackLines: scrollbackLines ?? this.scrollbackLines,
      bellEnabled: bellEnabled ?? this.bellEnabled,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
    );
  }
}
