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
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/shortcut_service.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;

/// Sessions asked for, none of which ever connects.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final started = <String>[];

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
    started.add(connection.id);
    state = {...state, id: SessionState.connecting(connection.id, connectionLabel: connection.label)};
    return id;
  }
}

/// The app's lock, as the test sets it.
class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock(super.locked);

  void set(bool locked) => state = locked;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A host picked from the app icon's shortcuts, on a phone (Android's app
/// shortcuts, an iPhone's quick actions; found while
/// comparing the five versions): it was read once, as the home screen
/// started, so one picked while the app ran did nothing, and one the app was
/// started with was lost where the hosts had not loaded yet. Now it is
/// connected to whenever it is picked, as a tap in the list does, once the
/// hosts are loaded and the app is open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  tearDown(() => ShortcutService.pendingConnection.value = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  late GoRouter router;
  late _Lock lock;

  Future<_Sessions> pumpPhone(WidgetTester tester, {bool locked = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
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
      activeSessionsProvider.overrideWith(_Sessions.new),
      isAppLockedProvider.overrideWith((ref) => _Lock(locked)),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 15, 12))),
    ]);
    addTearDown(container.dispose);
    router = GoRouter(routes: [
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
    lock = container.read(isAppLockedProvider.notifier) as _Lock;
    await settle(tester);
    return container.read(activeSessionsProvider.notifier) as _Sessions;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  testWidgets('one picked while the app runs is connected to, as a tap in the list, its terminal shown',
      (tester) async {
    final sessions = await pumpPhone(tester);
    expect(sessions.started, isEmpty);
    ShortcutService.picked('connect_h-web');
    await settle(tester);
    expect(sessions.started, ['h-web']);
    expect(find.text('route /terminal/s1'), findsOneWidget);
    expect(ShortcutService.pendingConnection.value, isNull, reason: 'taken once');
    await finish(tester);
  });

  testWidgets('one the app was started with is connected to once the hosts are loaded', (tester) async {
    ShortcutService.picked('connect_h-web');
    final sessions = await pumpPhone(tester);
    expect(sessions.started, ['h-web']);
    expect(find.text('route /terminal/s1'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('while the app is locked nothing is connected to; once it is open, it is', (tester) async {
    final sessions = await pumpPhone(tester, locked: true);
    ShortcutService.picked('connect_h-web');
    await settle(tester);
    expect(sessions.started, isEmpty);
    expect(ShortcutService.pendingConnection.value, 'h-web', reason: 'it waits');
    lock.set(false);
    await settle(tester);
    expect(sessions.started, ['h-web']);
    await finish(tester);
  });

  testWidgets('one picked while the list of hosts is not there (another page in its place) is connected to once it '
      'is back', (tester) async {
    final sessions = await pumpPhone(tester);
    router.go('/locked');
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('route /locked'), findsOneWidget);
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
    ShortcutService.picked('connect_h-web');
    await settle(tester);
    expect(sessions.started, isEmpty);
    router.go('/');
    await settle(tester);
    expect(sessions.started, ['h-web']);
    await finish(tester);
  });

  testWidgets('a host that is not there any more: nothing is connected to, and the pick is not kept', (tester) async {
    final sessions = await pumpPhone(tester);
    ShortcutService.picked('connect_h-gone');
    await settle(tester);
    expect(sessions.started, isEmpty);
    expect(ShortcutService.pendingConnection.value, isNull);
    // A shortcut that is not one of a host's, though its name is a host's id.
    ShortcutService.picked('h-web');
    await settle(tester);
    expect(sessions.started, isEmpty, reason: 'a shortcut that names no host');
    expect(ShortcutService.pendingConnection.value, isNull);
    await finish(tester);
  });
}
