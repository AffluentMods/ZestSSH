import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;

/// The sessions the phone home opens, with the account each was asked for.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final started = <(String, String?)>[];
  final _accounts = <String, String>{};

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
    final id = 's${started.length + 1}';
    started.add((connection.id, asAccount));
    if (asAccount != null) _accounts[id] = asAccount;
    state = {...state, id: SessionState.connecting(connection.id, connectionLabel: connection.label)};
    return id;
  }

  @override
  String? accountOf(String sessionId) => _accounts[sessionId];
}

/// "Connect as" on a phone (3.0, accounts per host): a host card's long press
/// offers each of the host's other accounts first in its sheet; a pick opens
/// a session signed in with it, and opens it again where one of that account
/// is open, while a plain tap is the host's default, a session of its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  late GoRouter router;

  Future<_Sessions> pumpPhone(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      for (final (id, user) in [('i-root', 'root'), ('i-deploy', 'deploy')]) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: id,
              label: '$user key',
              username: user,
              authMethod: 'publicKey',
              createdAt: DateTime(2026, 10, 15),
            ));
      }
      for (final (id, label) in [('h-web', 'web-01'), ('h-db', 'db-primary')]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: '$label.example.com',
              identityId: const Value('i-root'),
              createdAt: DateTime(2026, 10, 15),
              updatedAt: DateTime(2026, 10, 15),
            ));
      }
      await db.hostAccountsDao.setOtherAccounts('h-web', ['i-deploy']);
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
      activeSessionsProvider.overrideWith(_Sessions.new),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 15, 12))),
    ]);
    addTearDown(container.dispose);
    router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
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
    return container.read(activeSessionsProvider.notifier) as _Sessions;
  }

  /// Back to the home, once the page that leaves has finished leaving (it
  /// covers the home while it does).
  Future<void> home(WidgetTester tester) async {
    router.go('/');
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  /// The host [label]'s card (a session open to it may show its label elsewhere too).
  Finder card(String label) => find.descendant(of: find.byType(PhoneHostRow), matching: find.text(label));

  /// The host's own sheet on a phone (3.4): a long press selects it, and the
  /// selection's More offers its Host actions.
  Future<void> hostSheet(WidgetTester tester, Finder row) async {
    await tester.longPress(row);
    await settle(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('phone-selection-actions')), matching: find.byKey(const ValueKey('phone-tab-4'))));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('phone-selection-host-actions')));
    await settle(tester);
  }

  final anyConnectAs = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('connect-as-'));

  testWidgets('the host\'s sheet (a long press, then More, Host actions) offers the other accounts; a pick connects with it, and opens it again', (tester) async {
    final sessions = await pumpPhone(tester);
    await hostSheet(tester, card('web-01'));
    // The sheet's Connect as lists them.
    await tester.tap(find.byKey(const ValueKey('phone-sheet-connect-as')));
    await settle(tester);
    expect(find.text(l10n.hostConnectAs('deploy')), findsOneWidget);
    await tester.tap(find.text(l10n.hostConnectAs('deploy')));
    await settle(tester);
    expect(sessions.started, [('h-web', 'i-deploy')]);
    expect(find.text('route /terminal/s1'), findsOneWidget);

    // Again: the session of that account is opened again, nothing new.
    await home(tester);
    await hostSheet(tester, card('web-01'));
    await tester.tap(find.byKey(const ValueKey('phone-sheet-connect-as')));
    await settle(tester);
    await tester.tap(find.text(l10n.hostConnectAs('deploy')));
    await settle(tester);
    expect(sessions.started, hasLength(1));
    expect(find.text('route /terminal/s1'), findsOneWidget);

    // A tap is the host's default: another session.
    await home(tester);
    await tester.tap(card('web-01'));
    await settle(tester);
    expect(sessions.started, [('h-web', 'i-deploy'), ('h-web', null)]);
    expect(find.text('route /terminal/s2'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a host without other accounts offers none', (tester) async {
    await pumpPhone(tester);
    await hostSheet(tester, card('db-primary'));
    expect(find.text(l10n.phoneHostsEditHost), findsOneWidget, reason: 'its sheet is open');
    expect(anyConnectAs, findsNothing);
    expect(find.byKey(const ValueKey('phone-sheet-connect-as')), findsNothing);
    await finish(tester);
  });

  // Found in a code review: the sheet's Delete closed the sheet, then
  // asked its question with the sheet's context, gone by then: nothing was
  // asked and nothing deleted.
  testWidgets("the sheet's Delete asks on the page once the sheet has closed, and deletes the host", (tester) async {
    await pumpPhone(tester);
    await hostSheet(tester, card('db-primary'));
    final delete = find.byKey(const ValueKey('phone-sheet-delete'));
    await tester.ensureVisible(delete);
    await tester.pump();
    await tester.tap(delete);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(l10n.connectionCardDeleteConnectionTitle), findsOneWidget, reason: 'the question is asked');
    expect(find.byKey(const ValueKey('phone-sheet-delete')), findsNothing, reason: 'the sheet has closed');
    final confirm = find.descendant(
        of: find.ancestor(of: find.text(l10n.connectionCardDeleteConnectionTitle), matching: find.byType(Material)).first,
        matching: find.text(l10n.delete));
    await tester.tap(confirm.last);
    await settle(tester);
    expect(card('db-primary'), findsNothing, reason: 'the host is gone from the list');
    expect(card('web-01'), findsOneWidget);
    await finish(tester);
  });

  // A tablet with a mouse: a right click on a host is its
  // long press, the same sheet.
  testWidgets('a right click on a host opens its sheet at once', (tester) async {
    final sessions = await pumpPhone(tester);
    await tester.tap(card('web-01'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-sheet-connect-as')), findsOneWidget);
    expect(sessions.started, isEmpty, reason: 'a right click does not connect');
    await finish(tester);
  });
}
