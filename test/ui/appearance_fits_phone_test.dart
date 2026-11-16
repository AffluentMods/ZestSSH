// A phone's Appearance page on a phone 360 wide, in every language, from
// its top to its end (found while comparing the five
// versions): Import theme and Export current side by side ran off its
// edge in nine languages of twelve, English too. Nothing may: a row that
// runs over is an error here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';

import '../visual/shots_util.dart';

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('it fits, from its top to its end ($locale)', (tester) async {
      await tester.runAsync(loadShotFonts);
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => const AppearanceScreen())]);
      addTearDown(router.dispose);
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: ThemeData(fontFamily: 'GeistSans'),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
        ),
      ));
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 12; i++) {
        await tester.drag(scrollable, const Offset(0, -500));
        await tester.pumpAndSettle();
      }
    });
  }
}
