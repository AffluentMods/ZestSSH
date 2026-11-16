// A phone's Appearance page, on the free plan (found while
// comparing the five versions): Import theme says custom themes are paid,
// with an Upgrade button that did nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import '../visual/shots_util.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  testWidgets('Import theme on the free plan says custom themes are paid, and its Upgrade opens the way to them',
      (tester) async {
    // The fonts the app ships, so the page is as wide as on a phone.
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pages = <String>[];
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => const AppearanceScreen()),
      GoRoute(
          path: Routes.upgrade,
          builder: (context, state) {
            pages.add(state.uri.toString());
            return const Scaffold(body: Text('upgrade'));
          }),
    ]);
    addTearDown(router.dispose);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(false)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: ThemeData(fontFamily: 'GeistSans'),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();

    final import = find.text(l10n.appearanceImportTheme);
    await tester.scrollUntilVisible(import, 300, scrollable: find.byType(Scrollable).first);
    // Built is not on screen: the button can sit just under the edge.
    await tester.ensureVisible(import);
    await tester.pumpAndSettle();
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(find.text(l10n.appearanceCustomThemesRequirePro), findsOneWidget);
    await tester.tap(find.text(l10n.appearanceUpgrade));
    await tester.pumpAndSettle();
    expect(pages, [Routes.upgrade]);
    expect(find.text('upgrade'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
