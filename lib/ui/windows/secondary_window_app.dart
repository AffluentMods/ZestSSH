import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/theme_providers.dart' show kDefaultAppThemeId;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/ui/widgets/broken_widget_notice.dart';
import 'package:zestssh/providers/locale_providers.dart' show resolveAppLocale;

/// The theme the main window shows and its own accent, if one is chosen:
/// kept as they change (app.dart), for the windows it opens.
ZestTheme? mainWindowTheme;
Color? mainWindowAccent;

/// [mainWindowTheme] and [mainWindowAccent] as a new window's payload
/// carries them: a window has no settings of its own (as for its language).
Map<String, dynamic> windowThemePayload() => {
      if (mainWindowTheme != null) 'theme': mainWindowTheme!.colorScheme.toJson(),
      if (mainWindowAccent != null) 'accent': mainWindowAccent!.toARGB32(),
    };

/// The theme a window's payload names ([windowThemePayload]); the default
/// one where it names none or cannot be read.
ZestTheme windowThemeFrom(Object? scheme) {
  final read = scheme is Map<String, dynamic> ? ZestColorScheme.fromJson(scheme) : null;
  if (read == null) return BuiltInThemes.getById(kDefaultAppThemeId);
  return ZestTheme(
    id: read.id,
    name: read.name,
    brightness: read.isDark ? Brightness.dark : Brightness.light,
    colorScheme: read,
  );
}

/// The [MaterialApp] every secondary (popped-out) window runs in.
///
/// It carries the same localizations as the main app: a screen built with
/// `AppLocalizations.of(context)!` throws without them, and in a release
/// build an uncaught build error is nothing but Flutter's bare grey box,
/// which is exactly what the popped-out SFTP editor looked like. It also
/// applies the main window's locale (passed in the window payload, since a
/// secondary window has no settings of its own) and keeps `gl10n` current for
/// the contextless paths.
Widget secondaryWindowApp({
  required String title,
  required Widget home,
  String? localeName,
  Object? theme,
  int? accent,
  Widget Function(BuildContext context, Widget child)? over,
}) {
  // The main window's theme, drawn as it draws it: its colours for the
  // widgets that read them directly too (it was the old dark theme always).
  final shown = windowThemeFrom(theme);
  AppColors.applyTheme(shown.colorScheme);
  return MaterialApp(
    title: title,
    theme: shown.toThemeData(accentOverride: accent == null ? null : Color(accent)),
    debugShowCheckedModeBanner: false,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    localeListResolutionCallback: resolveAppLocale,
    locale: localeFromName(localeName),
    builder: (context, child) {
      L10nGlobal.update(AppLocalizations.of(context)!);
      final all = child ?? const SizedBox.shrink();
      // [over] wraps everything the window shows, the questions and panels
      // it opens over its home too (they are routes of the navigator that
      // [child] is): where the app lock's cover belongs for a window whose
      // open panel could otherwise still be used while the app is locked.
      return over == null ? all : over(context, all);
    },
    home: home,
  );
}

/// `en`, `pt_BR`, `zh_Hant_TW` back into a [Locale]; null or empty means
/// "follow the system", which is what [MaterialApp] does with a null locale.
Locale? localeFromName(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  final parts = name.trim().split(RegExp('[_-]'));
  return switch (parts.length) {
    1 => Locale(parts[0]),
    2 => parts[1].length == 4
        ? Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1])
        : Locale(parts[0], parts[1]),
    _ => Locale.fromSubtags(
        languageCode: parts[0], scriptCode: parts[1], countryCode: parts[2]),
  };
}

/// What a secondary window shows when a build throws, on the app's own
/// background: that something went wrong, in the app's language, with the
/// report of it to copy (BrokenWidgetNotice). Installed as
/// `ErrorWidget.builder` for the secondary windows, which have no console and
/// no other way to say what went wrong. (3.0: it showed the raw
/// error, which can name a path or a host, and nothing to copy.)
class SecondaryWindowError extends StatelessWidget {
  final FlutterErrorDetails details;

  const SecondaryWindowError(this.details, {super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.v3Background,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: BrokenWidgetNotice(details),
      ),
    );
  }
}
