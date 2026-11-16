import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart' show resolveAppLocale;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';

/// The build the notice of macOS's questions was last shown for, on a Mac (3.3.2): a
/// key of the system's preferences, the computer's, read before anything reads the
/// keychain.
const kKeychainToldBuildKey = 'mac_keychain_told_build';

/// Whether the notice of macOS's questions is to be shown before anything reads the
/// keychain (3.3.2): on a Mac whose ZestSSH changed build since the last start, and
/// whose keychain holds something of ZestSSH's to be asked about. The Mac app is signed
/// ad-hoc, so each build is a new app to macOS, and a read of each item an older build
/// made brings up macOS's question. A first install has nothing to be asked about: its
/// build is noted, and nothing is shown. [names] lists the keychain's names, which asks
/// nothing of anyone; where it fails the notice is shown, as the questions may come.
Future<bool> keychainAsksAfterUpdate({
  required SharedPreferences prefs,
  required String build,
  required Future<List<String>> Function() names,
}) async {
  if (build.isEmpty || prefs.getString(kKeychainToldBuildKey) == build) return false;
  try {
    if ((await names()).isEmpty) {
      await prefs.setString(kKeychainToldBuildKey, build);
      return false;
    }
  } catch (_) {
    // Not known: said, as the questions may well come.
  }
  return true;
}

/// Says, before anything reads the keychain, that macOS will ask for the login password
/// for ZestSSH's saved keys after this update, and to choose Always Allow for each
/// ([keychainAsksAfterUpdate]); the start goes on with Continue. Once for each build:
/// the build is noted as Continue is chosen. [show] puts the screen up (runApp: not the
/// app's window yet, so a failure that follows still has its own screen to say it).
Future<void> sayKeychainAsksAfterUpdate({
  required SharedPreferences prefs,
  required String build,
  required Future<List<String>> Function() names,
  required void Function(Widget app) show,
}) async {
  if (!await keychainAsksAfterUpdate(prefs: prefs, build: build, names: names)) return;
  final going = Completer<void>();
  show(MacKeychainUpdateApp(
    language: prefs.getString('app_locale'),
    onContinue: () {
      if (!going.isCompleted) going.complete();
    },
  ));
  await going.future;
  await prefs.setString(kKeychainToldBuildKey, build);
}

/// The notice itself: it runs as its own MaterialApp, before anything of the app, as
/// the screen of a move to profiles does.
class MacKeychainUpdateApp extends StatelessWidget {
  const MacKeychainUpdateApp({super.key, this.language, required this.onContinue});

  /// The language the person chose, where they did: a language code.
  final String? language;

  final VoidCallback onContinue;

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
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.dark(primary: AppColors.brandOrange, surface: AppColors.surface),
      ),
      home: WindowBarOver(child: _MacKeychainUpdateScreen(onContinue: onContinue)),
    );
  }
}

class _MacKeychainUpdateScreen extends StatelessWidget {
  const _MacKeychainUpdateScreen({required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.divider),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 16)),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.brandOrange.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(LucideIcons.keyRound, size: 36, color: AppColors.accentInk),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      l10n.macKeychainUpdateTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: AppColors.onBackground,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      l10n.macKeychainUpdateBody,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14.5, color: AppColors.onBackground, height: 1.55),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const ValueKey('mac-keychain-update-continue'),
                      onPressed: onContinue,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandOrange,
                        foregroundColor: AppColors.onBrand(AppColors.brandOrange),
                        minimumSize: const Size.fromHeight(46),
                        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 15, fontWeight: FontWeight.w600),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                      ),
                      child: Text(l10n.macKeychainUpdateContinue),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
