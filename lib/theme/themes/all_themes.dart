import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/theme/themes/default_dark.dart';
import 'package:zestssh/theme/themes/default_light.dart';
import 'package:zestssh/theme/themes/graphite.dart';
import 'package:zestssh/theme/themes/midnight.dart';
import 'package:zestssh/theme/themes/dracula.dart';
import 'package:zestssh/theme/themes/nord.dart';
import 'package:zestssh/theme/themes/monokai.dart';
import 'package:zestssh/theme/themes/solarized_dark.dart';
import 'package:zestssh/theme/themes/catppuccin_mocha.dart';
import 'package:zestssh/theme/themes/tokyo_night.dart';
import 'package:zestssh/theme/themes/gruvbox_dark.dart';
import 'package:zestssh/theme/themes/amoled.dart';
import 'package:zestssh/theme/themes/darcula.dart';
import 'package:zestssh/theme/themes/intellij_dark.dart';
import 'package:zestssh/theme/themes/intellij_light.dart';
import 'package:zestssh/theme/themes/one_dark.dart';
import 'package:zestssh/theme/themes/one_light.dart';

/// Registry of all built-in ZestSSH app themes.
///
/// Themes are listed in display order. The first theme is the default.
/// Use [getById] to resolve a persisted theme ID back to a [ZestTheme].
class BuiltInThemes {
  BuiltInThemes._();

  /// All built-in themes in display order.
  static const List<ZestTheme> all = [
    defaultDarkTheme,
    graphiteTheme,
    defaultLightTheme,
    amoledTheme,
    midnightTheme,
    draculaTheme,
    nordTheme,
    monokaiTheme,
    solarizedDarkTheme,
    catppuccinMochaTheme,
    tokyoNightTheme,
    gruvboxDarkTheme,
    // The looks of the editors people come from (3.0): Atom's One Dark and
    // One Light, and the JetBrains IDEs' Darcula, Light and Dark.
    oneDarkTheme,
    oneLightTheme,
    darculaTheme,
    intellijDarkTheme,
    intellijLightTheme,
  ];

  /// The default theme (used when no preference is stored or the stored
  /// ID can't be resolved).
  static const ZestTheme defaultTheme = defaultDarkTheme;

  /// Look up a theme by its [ZestTheme.id].
  ///
  /// Returns [defaultTheme] if [id] doesn't match any built-in theme.
  static ZestTheme getById(String id) {
    for (final theme in all) {
      if (theme.id == id) return theme;
    }
    return defaultTheme;
  }

  /// All theme IDs, in display order.
  static List<String> get ids => all.map((t) => t.id).toList();

  /// Human-readable names keyed by ID, for use in settings UI.
  static Map<String, String> get names =>
      {for (final t in all) t.id: t.name};

  /// Whether a given ID corresponds to a built-in theme.
  static bool contains(String id) => all.any((t) => t.id == id);
}
