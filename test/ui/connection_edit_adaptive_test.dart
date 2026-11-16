import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

/// Where a host's editor opens (3.0, found while comparing
/// the five versions). It docked beside the hosts wherever the window was
/// wider than a phone's, but only a computer's shell has that dock: on a
/// tablet, or a phone held sideways, a host's row in Networks (the one place
/// a phone opens it this way) asked for the dock and nothing showed it. Now
/// it docks in a computer's shell, in a window wide enough, and is a page of
/// its own everywhere else.
void main() {
  tearDown(() => ConnectionEditScreen.debugDesktopShell = null);

  /// The app, as wide as [width], and a button that opens h-web's editor.
  Future<(ProviderContainer, GoRouter)> app(WidgetTester tester, {required double width}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => ConnectionEditScreen.showAdaptive(context, connectionId: 'h-web'),
            child: const Text('web-01'),
          ),
        ),
      ),
      GoRoute(path: Routes.connectionEditId, builder: (_, state) => Text('the editor of ${state.pathParameters['id']}')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.tap(find.text('web-01'));
    await tester.pumpAndSettle();
    return (container, router);
  }

  for (final width in [1100.0, 760.0]) {
    testWidgets('a tablet or a phone held sideways, $width wide: a page of its own', (tester) async {
      ConnectionEditScreen.debugDesktopShell = false;
      final (container, _) = await app(tester, width: width);
      expect(find.text('the editor of h-web'), findsOneWidget);
      expect(container.read(connectionEditorTargetProvider), isNull, reason: 'no dock asked for');
    });
  }

  testWidgets('a phone held upright: a page of its own, as before', (tester) async {
    ConnectionEditScreen.debugDesktopShell = false;
    final (container, _) = await app(tester, width: 400);
    expect(find.text('the editor of h-web'), findsOneWidget);
    expect(container.read(connectionEditorTargetProvider), isNull);
  });

  testWidgets("a computer's wide window: docked beside the hosts, as before", (tester) async {
    ConnectionEditScreen.debugDesktopShell = true;
    final (container, _) = await app(tester, width: 1100);
    expect(find.text('the editor of h-web'), findsNothing);
    expect(container.read(connectionEditorTargetProvider)?.connectionId, 'h-web');
    expect(container.read(activeSidebarNavProvider), NavSection.hosts);
  });

  testWidgets("a computer's narrow window: a page of its own, as before", (tester) async {
    ConnectionEditScreen.debugDesktopShell = true;
    final (container, _) = await app(tester, width: 600);
    expect(find.text('the editor of h-web'), findsOneWidget);
    expect(container.read(connectionEditorTargetProvider), isNull);
  });
}
