import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart' show resolveAppLocale;
import 'package:zestssh/theme/app_colors.dart';

/// What is on the screen while the device moves to profiles, at the first start
/// of the version that has them. It runs before anything else, and on Windows the
/// window shows at the first frame: with nothing to show, a person sees nothing
/// happen, and may end it. Like the error screens it runs as its own MaterialApp,
/// with nothing of the app behind it.
class MovingDataApp extends StatelessWidget {
  const MovingDataApp({super.key, this.language});

  /// The language the person chose, where they did: a language code.
  final String? language;

  @override
  Widget build(BuildContext context) {
    final code = language;
    return MaterialApp(
      title: 'ZestSSH',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      localeListResolutionCallback: resolveAppLocale,
      locale: code == null || code.isEmpty ? null : Locale(code),
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: AppColors.background),
      home: const _MovingDataScreen(),
    );
  }
}

class _MovingDataScreen extends StatelessWidget {
  const _MovingDataScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
              const SizedBox(height: 20),
              Text(
                AppLocalizations.of(context)!.movingDataMessage,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: AppColors.onBackground, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
