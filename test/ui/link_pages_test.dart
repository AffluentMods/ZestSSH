// The pages a zestssh:// link names, opened where each device opens them,
// and a host by its address opening Quick connect (found
// while comparing the five versions). A computer went to a phone's page for
// each link's page (settings, snippets, identities, profile, a host's
// editor, the SSH config import, upgrade), which took the shell's place,
// its whole window; and zestssh://connect?host=&user=&port=, documented as
// Quick connect, was answered by nothing.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/connect_link.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/router/link_pages.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  tearDown(() {
    ConnectionEditScreen.debugDesktopShell = null;
    debugConnectLinkOnComputer = null;
    debugTopSnackBarOnPhone = null;
    quickConnectLinkText.value = null;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  group('a quick connect link', () {
    String? text(String link) => quickConnectLinkOf(Uri.parse(link)).text;

    test('names what Quick connect is opened with, as it would be typed', () {
      expect(text('zestssh://connect?host=web-01.example.com&user=deploy&port=2222'), 'deploy@web-01.example.com:2222');
      expect(text('zestssh://connect?host=web-01.example.com'), 'web-01.example.com');
      expect(text('zestssh://connect?host=web-01.example.com&port=22'), 'web-01.example.com:22',
          reason: 'a 22 given is kept, where Settings gives new connections another');
      expect(text('zestssh://connect?host=2001:db8::1&user=ops'), 'ops@[2001:db8::1]');
      expect(text('zestssh://connect?host=192.0.2.10&user=&port='), '192.0.2.10');
    });

    test('one that names no host Quick connect would read is said to be one, with nothing to open', () {
      for (final link in [
        'zestssh://connect?host=web%2001',
        'zestssh://connect?host=web-01%E2%80%AE.example.com',
        'zestssh://connect?host=web-01&user=ops%40root',
        'zestssh://connect?host=web-01&user=o%E2%80%8Bps',
        'zestssh://connect?host=web-01&user=o%C2%85ps',
        'zestssh://connect?host=web-01&user=${'o' * 65}',
        'zestssh://connect?host=web-01&port=0',
        'zestssh://connect?host=web-01&port=70000',
        'zestssh://connect?host=web-01&port=ssh',
        'zestssh://connect?host=${'a' * 254}',
      ]) {
        final read = quickConnectLinkOf(Uri.parse(link));
        expect((read.isLink, read.text), (true, null), reason: link);
      }
      // As long a user as may be is one.
      expect(text('zestssh://connect?host=web-01&user=${'o' * 64}'), '${'o' * 64}@web-01');
    });

    test('one that names a saved host, or that is no connect link, is not one', () {
      for (final link in [
        'zestssh://connect?id=h-web&host=web-01',
        'zestssh://connect?name=web-01',
        'zestssh://connect',
        'zestssh://connect?host=',
        'zestssh://settings?host=web-01',
        'https://connect/?host=web-01',
      ]) {
        expect(quickConnectLinkOf(Uri.parse(link)).isLink, isFalse, reason: link);
      }
    });
  });

  /// The app on a router at [start], with a page for every route, and the
  /// ref of its first page.
  Future<(ProviderContainer, GoRouter, WidgetRef)> app(WidgetTester tester, {double width = 1100}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    late WidgetRef ref;
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Consumer(builder: (_, r, _) {
          ref = r;
          return const Scaffold(body: Text('the shell'));
        }),
      ),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    return (container, router, ref);
  }

  String where(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

  testWidgets("a computer opens a link's page in its shell, which stays", (tester) async {
    ConnectionEditScreen.debugDesktopShell = true;
    final (c, router, ref) = await app(tester);

    // (A computer is what the app runs on here: as the app asks it.)
    await openLinkPage(ref, router, Routes.settings);
    await tester.pumpAndSettle();
    expect(c.read(settingsPopupOpenProvider), isTrue, reason: 'its pop-up');
    expect(where(router), '/');
    expect(find.text('the shell'), findsOneWidget);
    c.read(settingsPopupOpenProvider.notifier).state = false;

    await openLinkPage(ref, router, Routes.snippets, onComputer: true);
    expect(c.read(activeSidebarNavProvider), NavSection.snippets);
    await openLinkPage(ref, router, Routes.identityList, onComputer: true);
    expect(c.read(activeSidebarNavProvider), NavSection.keys);

    await openLinkPage(ref, router, Routes.profile, onComputer: true);
    expect((c.read(settingsJumpProvider), c.read(settingsPopupOpenProvider)), (SettingsJumpTarget.account, true),
        reason: 'the account, in Settings');
    c.read(settingsPopupOpenProvider.notifier).state = false;

    await openLinkPage(ref, router, Routes.connectionEdit, onComputer: true);
    final made = c.read(connectionEditorTargetProvider);
    expect((made != null, made?.connectionId), (true, null), reason: "a new host's editor, docked");
    c.read(connectionEditorTargetProvider.notifier).state = null;
    await openLinkPage(ref, router, '${Routes.connectionEdit}/h-web', onComputer: true);
    expect(c.read(connectionEditorTargetProvider)?.connectionId, 'h-web');
    expect(c.read(activeSidebarNavProvider), NavSection.hosts);

    // A link that is no page of the shell's leaves it as it is.
    await openLinkPage(ref, router, Routes.home, onComputer: true);
    await tester.pumpAndSettle();
    expect(where(router), '/');

    await openLinkPage(ref, router, Routes.upgrade, onComputer: true);
    await tester.pumpAndSettle();
    expect(find.text('route /upgrade'), findsOneWidget);
    expect(router.canPop(), isTrue, reason: 'over the shell, as its palette opens it');
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('the shell'), findsOneWidget);
  });

  test('the app answers a link through these: a quick connect link, and a page', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('if (answerQuickConnectLink(uri, ref.read(routerProvider))) return;'));
    expect(app, contains('await openLinkPage(ref, ref.read(routerProvider), route);'));
  });

  testWidgets("a phone goes to a link's page", (tester) async {
    final (c, router, ref) = await app(tester, width: 400);
    await openLinkPage(ref, router, Routes.settings, onComputer: false);
    await tester.pumpAndSettle();
    expect(find.text('route /settings'), findsOneWidget);
    expect(c.read(settingsPopupOpenProvider), isFalse);
  });

  /// A phone's home screen over one saved host.
  Future<GoRouter> pumpPhone(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(() async {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-web',
            label: 'web-01',
            host: 'web-01.example.com',
            createdAt: DateTime(2026, 10, 15),
            updatedAt: DateTime(2026, 10, 15),
          ));
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => null),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      recordingModeProvider.overrideWith((ref) => false),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 15, 12))),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    await settle(tester);
    return router;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  final bar = find.byKey(const ValueKey('quick-connect-bar-field'));
  TextField barField(WidgetTester tester) => tester.widget<TextField>(bar);

  testWidgets("a phone types a quick connect link's host into its quick connect bar, on its list of hosts, for the "
      'person to connect or not; nothing connects by itself', (tester) async {
    debugConnectLinkOnComputer = false;
    debugTopSnackBarOnPhone = true;
    final router = await pumpPhone(tester);
    // On another tab of the home screen.
    await tester.tap(find.text(l10n.homeSessionsTab));
    await settle(tester);
    expect(bar, findsNothing);
    expect(answerQuickConnectLink(Uri.parse('zestssh://connect?host=web-01.example.com&user=deploy&port=2222'), router),
        isTrue);
    await settle(tester);
    expect(barField(tester).controller!.text, 'deploy@web-01.example.com:2222');
    expect(barField(tester).focusNode!.hasFocus, isTrue);
    expect(quickConnectLinkText.value, isNull, reason: 'taken once');
    expect(find.textContaining('route /terminal'), findsNothing, reason: 'nothing connects by itself');

    // From another page, the home screen is gone to.
    router.go('/settings');
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
    answerQuickConnectLink(Uri.parse('zestssh://connect?host=192.0.2.10&user=ops'), router);
    await settle(tester);
    expect(barField(tester).controller!.text, 'ops@192.0.2.10');

    // One that names no host is said to, and changes nothing.
    expect(answerQuickConnectLink(Uri.parse('zestssh://connect?host=web%2001'), router), isTrue);
    await tester.pump();
    expect(find.text(l10n.connectLinkNotHost), findsOneWidget);
    expect(barField(tester).controller!.text, 'ops@192.0.2.10');
    expect(quickConnectLinkText.value, isNull);
    // And one that is none is left to the rest.
    expect(answerQuickConnectLink(Uri.parse('zestssh://connect?id=h-web'), router), isFalse);
    await tester.pump(const Duration(seconds: 10));
    await finish(tester);
  });
}
