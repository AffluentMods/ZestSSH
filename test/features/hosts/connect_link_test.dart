import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/connect_link.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/redactor.dart';

/// A saved host opened from outside the app (3.0): a home-screen widget's
/// host by its id, or a shortcut naming one (Siri on an iPhone: its name,
/// or its id). The iPhone's widget and Siri sent a link nothing answered;
/// the question asked first was in English, a host not found or the free
/// plan's limit said nothing, and the host was looked for in the space on
/// screen, where a widget's host (one of your Tree's) is not.

/// Sessions asked for, and the space on screen when each was.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(this._ref) : super(_ref);

  final Ref _ref;
  final asked = <(String, Space)>[];
  var full = false;

  @override
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) {
    if (full) return null;
    asked.add((connection.id, _ref.read(activeSpaceProvider)));
    return 'session-${asked.length}';
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 10, 16);

  group('the link', () {
    test('a host by its id, or by its name; nothing else is a connect link', () {
      expect(connectLinkOf(Uri.parse('zestssh://connect?id=h-1')), (id: 'h-1', name: null));
      expect(connectLinkOf(Uri.parse('zestssh://connect?name=Web%2001')), (id: null, name: 'Web 01'));
      expect(connectLinkOf(Uri.parse('zestssh://connect?id=h-1&name=web')), (id: 'h-1', name: null));
      for (final no in [
        'zestssh://connect',
        'zestssh://connect?id=',
        'zestssh://connect?name=%20',
        'zestssh://connect?host=web-01.example.com&port=22',
        'zestssh://snippets?id=h-1',
        'https://connect?id=h-1',
      ]) {
        expect(connectLinkOf(Uri.parse(no)), isNull, reason: no);
      }
    });

    test('the host it names: by its id; by its name in any case, else by its id; two of that name are said', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      for (final (id, label) in [('h-1', 'Web 01'), ('h-2', 'db'), ('h-3', 'DB')]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id, label: label, host: '$id.example.com', createdAt: at, updatedAt: at));
      }
      expect((await hostOfConnectLink(db, (id: 'h-1', name: null))).host?.id, 'h-1');
      expect((await hostOfConnectLink(db, (id: 'web 01', name: null))).host, isNull, reason: 'an id is an id');
      expect((await hostOfConnectLink(db, (id: null, name: 'web 01'))).host?.id, 'h-1');
      expect((await hostOfConnectLink(db, (id: null, name: 'h-2'))).host?.id, 'h-2', reason: 'by its id');
      final two = await hostOfConnectLink(db, (id: null, name: 'Db'));
      expect((two.host, two.twice), (null, true));
      final none = await hostOfConnectLink(db, (id: null, name: 'mail'));
      expect((none.host, none.twice), (null, false));
    });
  });

  group('opening it', () {
    late AppDatabase tree;
    late _Sessions sessions;
    late List<String?> opened;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web', label: 'Payroll web', host: 'payroll.example.com', port: const Value(2222), createdAt: at, updatedAt: at));
      opened = [];
      debugTopSnackBarOnPhone = true;
    });

    tearDown(() async {
      debugTopSnackBarOnPhone = null;
      Redactor.instance.enabled = false;
      await tree.close();
    });

    Future<void> pump(WidgetTester tester, ConnectLinkTarget link,
        {Space space = const TreeSpace(), bool locked = false, bool recording = false}) async {
      SharedPreferences.setMockInitialValues({if (recording) 'recording_mode_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseSessionProvider.overrideWith((ref) {
          final session = DatabaseSessionNotifier();
          if (!locked) session.seed(tree);
          return session;
        }),
        activeSpaceProvider.overrideWith((ref) => space),
        activeSessionsProvider.overrideWith(_Sessions.new),
      ]);
      addTearDown(c.dispose);
      sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async => opened.add(await openConnectLink(context, ref, link)),
                child: const Text('link'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('link'));
      await tester.pumpAndSettle();
    }

    testWidgets('it asks first, naming the host and where it goes; Cancel opens nothing, Connect opens it in your '
        'Tree', (tester) async {
      await pump(tester, (id: 'h-web', name: null));
      expect(find.text(l10n.connectLinkTitle('Payroll web')), findsOneWidget);
      expect(find.text(l10n.connectLinkBody('payroll.example.com:2222')), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(sessions.asked, isEmpty);
      expect(opened, [null]);

      await tester.tap(find.text('link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonConnect));
      await tester.pumpAndSettle();
      expect(sessions.asked, [('h-web', const TreeSpace())]);
      expect(opened.last, 'session-1');
    });

    testWidgets('named by a shortcut, in any case; and with a team space on screen, your Tree is shown first',
        (tester) async {
      await pump(tester, (id: null, name: 'PAYROLL WEB'), space: const OrchardSpace('o-1'));
      await tester.tap(find.text(l10n.commonConnect));
      await tester.pumpAndSettle();
      expect(sessions.asked, [('h-web', const TreeSpace())], reason: 'its keys are found in the Tree');
    });

    testWidgets('a host that is not there, or a name two hosts have, is said; nothing is opened', (tester) async {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-2', label: 'twin', host: 'a.example.com', createdAt: at, updatedAt: at));
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-3', label: 'Twin', host: 'b.example.com', createdAt: at, updatedAt: at));
      await pump(tester, (id: 'h-gone', name: null));
      expect(find.text(l10n.connectLinkNoHost('h-gone')), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      await pump(tester, (id: null, name: 'twin'));
      expect(find.text(l10n.connectLinkTwoHosts('twin')), findsOneWidget);
      expect(find.text(l10n.commonConnect), findsNothing);
      expect(sessions.asked, isEmpty);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    // Found while comparing the five platforms' versions: a link to a
    // host that speaks Telnet opened it with no word that nothing encrypts it.
    testWidgets('a host that speaks Telnet is opened only after the warning that nothing encrypts it', (tester) async {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-tel',
          label: 'router',
          host: '192.168.20.1',
          port: const Value(23),
          protocol: const Value('telnet'),
          createdAt: at,
          updatedAt: at));
      await pump(tester, (id: 'h-tel', name: null));
      await tester.tap(find.text(l10n.commonConnect));
      await tester.pumpAndSettle();
      expect(find.text(l10n.desktopShellTelnetWarning), findsOneWidget, reason: 'it was opened with no word of it');
      expect(sessions.asked, isEmpty);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(sessions.asked, isEmpty, reason: 'Cancel opens nothing');
      expect(opened, [null]);

      await tester.tap(find.text('link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonConnect));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.desktopShellConnectAnyway));
      await tester.pumpAndSettle();
      expect(sessions.asked, [('h-tel', const TreeSpace())]);
    });

    testWidgets("the free plan's limit is said", (tester) async {
      await pump(tester, (id: 'h-web', name: null));
      sessions.full = true;
      await tester.tap(find.text(l10n.commonConnect));
      await tester.pumpAndSettle();
      expect(find.text(l10n.hostsHomeFreeTierLimit), findsOneWidget);
      expect(opened, [null]);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('while the app is locked nothing is opened, nor asked', (tester) async {
      await pump(tester, (id: 'h-web', name: null), locked: true);
      expect(find.text(l10n.commonConnect), findsNothing);
      expect(opened, [null]);
    });

    testWidgets("as a phone answers a link: the session's terminal is shown once it is opened; any other link is "
        'left to the rest of the app', (tester) async {
      debugConnectLinkOnComputer = false;
      addTearDown(() => debugConnectLinkOnComputer = null);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final answered = <bool>[];
      late GoRouter router;
      router = GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(children: [
                TextButton(
                  onPressed: () async =>
                      answered.add(await answerConnectLink(Uri.parse('zestssh://connect?id=h-web'), ref, router)),
                  child: const Text('widget'),
                ),
                TextButton(
                  onPressed: () async =>
                      answered.add(await answerConnectLink(Uri.parse('zestssh://snippets'), ref, router)),
                  child: const Text('other'),
                ),
                TextButton(
                  onPressed: () async =>
                      answered.add(await answerConnectLink(Uri.parse('zestssh://connect?name=Nowhere'), ref, router)),
                  child: const Text('nowhere'),
                ),
              ]),
            ),
          ),
        ),
        GoRoute(path: '/terminal/:id', builder: (context, state) => Text('terminal ${state.pathParameters['id']}')),
      ]);
      addTearDown(router.dispose);
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(tree)),
        activeSessionsProvider.overrideWith(_Sessions.new),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      await tester.tap(find.text('other'));
      await tester.pumpAndSettle();
      expect(answered, [false]);
      // A host that is not there: said on the screen, though the app answers
      // a link with no screen of its own (it gives the notice its navigator's
      // context, where a phone drew nothing).
      await tester.tap(find.text('nowhere'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.connectLinkNoHost('Nowhere')), findsOneWidget);
      expect(answered, [false, true]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(l10n.connectLinkNoHost('Nowhere')), findsNothing, reason: 'gone in its time');
      await tester.tap(find.text('widget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonConnect));
      await tester.pumpAndSettle();
      expect(answered, [false, true, true]);
      expect(find.text('terminal session-1'), findsOneWidget);
    });

    // Found while comparing the five platforms' versions: a computer
    // went to a phone's terminal page, which took the shell's place.
    testWidgets("as a computer answers it: the session's tab in front, in its shell, from wherever it was",
        (tester) async {
      debugConnectLinkOnComputer = true;
      addTearDown(() => debugConnectLinkOnComputer = null);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      late GoRouter router;
      router = GoRouter(initialLocation: '/elsewhere', routes: [
        GoRoute(path: '/', builder: (context, state) => const Text('shell')),
        GoRoute(
          path: '/elsewhere',
          builder: (context, state) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => answerConnectLink(Uri.parse('zestssh://connect?id=h-web'), ref, router),
                child: const Text('widget'),
              ),
            ),
          ),
        ),
        GoRoute(path: '/terminal/:id', builder: (context, state) => Text('terminal ${state.pathParameters['id']}')),
      ]);
      addTearDown(router.dispose);
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(tree)),
        activeSessionsProvider.overrideWith(_Sessions.new),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      await tester.tap(find.text('widget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonConnect));
      await tester.pumpAndSettle();
      expect(find.text('terminal session-1'), findsNothing, reason: "a phone's page in the shell's place");
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
      expect(find.text('shell'), findsOneWidget);
      expect(c.read(v3ActiveSessionTabProvider), 'session-1');
      expect(c.read(workTabsProvider).activeTab?.sessionIds, contains('session-1'));
    });

    testWidgets('while the screen is recorded, recording is turned off first, or nothing is opened; turned off, the '
        'host is named as it is (it named a stand-in)', (tester) async {
      await pump(tester, (id: 'h-web', name: null), recording: true);
      expect(find.text(l10n.recModeRevealTitle), findsOneWidget);
      await tester.tap(find.text(l10n.recModeRevealCancel));
      await tester.pumpAndSettle();
      expect(find.text(l10n.commonConnect), findsNothing);
      expect(opened, [null]);

      await tester.tap(find.text('link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.recModeRevealDisable));
      await tester.pumpAndSettle();
      expect(find.textContaining('Payroll'), findsWidgets);
      expect(find.text(l10n.commonConnect), findsOneWidget);
    });
  });
}
