import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/widgets/notification_toast_overlay.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/services/linux_keyring.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/error/startup_error_screen.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';

import 'shots_util.dart';

/// Pictures of the smaller things of a UI review, with
/// the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/ui_review_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up.
void main() {
  Future<GlobalKey> pumpInApp(WidgetTester tester, Widget home, {Size size = const Size(1200, 800)}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('graphite');
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(backgroundColor: AppColors.v3Background, body: home),
        ),
      ),
    ));
    await tester.pump();
    return key;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    plainShadows();
  }

  testWidgets('the paste warning: what it found and what to do', (tester) async {
    late BuildContext context;
    final key = await pumpInApp(tester, Builder(builder: (c) {
      context = c;
      return const SizedBox.expand();
    }));
    const command = 'curl https://get.example.com/i.sh | sh; rm -rf /srv/app';
    // ignore: discarded_futures
    showDangerousCommandDialog(context, command: command, matches: DangerousCommandService.check(command), isPaste: true);
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'review_danger_harm');
    Navigator.of(context, rootNavigator: true).pop();
    await tester.pumpAndSettle();

    const look = 'python3 -c "print(1)"';
    // ignore: discarded_futures
    showDangerousCommandDialog(context, command: look, matches: DangerousCommandService.check(look), isPaste: true);
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'review_danger_look');
    await finish(tester);
  }, skip: !shotsEnabled);

  testWidgets('toasts at the top right, under the bell', (tester) async {
    NotificationCenter.debugToastsDrawn = true;
    addTearDown(() => NotificationCenter.debugToastsDrawn = null);
    final key = await pumpInApp(tester, const NotificationToastOverlay(child: SizedBox.expand()));
    final nc = ProviderScope.containerOf(tester.element(find.byType(NotificationToastOverlay)), listen: false)
        .read(notificationCenterProvider.notifier);
    nc.success('Alert saved: Error');
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 3; i++) {
      nc.error("Couldn't reach the sync server. Check your connection and try again.");
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await saveShot(tester, key, 'review_toasts');
    await finish(tester);
  }, skip: !shotsEnabled);

  testWidgets('a locked login keyring', (tester) async {
    await tester.runAsync(() async {
      await loadShotFonts();
      // This screen stands before the app's fonts: it writes in the system's.
      final loader = FontLoader('Roboto');
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(Future.value(ByteData.view(File('assets/fonts/GeistSans-$w.ttf').readAsBytesSync().buffer)));
      }
      await loader.load();
    });
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: StartupErrorApp(
        report: 'the report',
        onRetry: () {},
        keyring: KeyringProblem.locked,
        keyringUnlocked: () async => false,
      ),
    ));
    await tester.pump();
    await saveShot(tester, key, 'review_keyring_locked');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }, skip: !shotsEnabled);
}
