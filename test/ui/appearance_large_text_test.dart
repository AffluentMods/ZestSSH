import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';

import '../visual/shots_util.dart';

/// A phone's Appearance page at the large text a phone can be set to (3.0),
/// as appearance_fits_phone_test.dart holds it at the text
/// size the app is drawn at: at 1.3 times a section's title ran off the
/// page's edge in French (its row did not let it wrap), and at 1.5 times the
/// sample lines of each terminal theme's picture ran out of its card, in
/// every language. Now a title wraps where it does not fit, and the picture
/// of a terminal keeps its size, as a picture does.
void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('at 1.5 times the text size it fits, from its top to its end ($locale)', (tester) async {
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
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)), child: child!),
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
