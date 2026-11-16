import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A notice the app gives from outside any screen, on a phone (3.0, found
/// while comparing the five versions): a listener of the app (a
/// refusal of automation, sessions dropped while the app was away, a host
/// added from a QR code) or a link has no screen of its own, and gives the
/// notice the context of the app's navigator, which sits above the
/// navigator's overlay. A phone draws the notice in the topmost overlay above
/// the context it is given, found none there, and drew nothing.
void main() {
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  Future<GoRouter> app(WidgetTester tester) async {
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('the list of hosts'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pump();
    return router;
  }

  testWidgets("given the context of the app's navigator, the notice is drawn, and its action works", (tester) async {
    final router = await app(tester);
    var pressed = 0;
    showTopSnackBar(
      router.routerDelegate.navigatorKey.currentContext!,
      'Automation is off, so the command was not run.',
      isWarning: true,
      actionLabel: 'Settings',
      onAction: () => pressed++,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Automation is off, so the command was not run.'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(pressed, 1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("given a screen's context, as before", (tester) async {
    await app(tester);
    showTopSnackBar(tester.element(find.text('the list of hosts')), 'Saved the layout');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Saved the layout'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
