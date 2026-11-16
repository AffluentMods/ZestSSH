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
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart';
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

/// A host's last use, on a phone (found while comparing the
/// five versions): a phone's host list and its quick connect bar stamped it
/// as a session was asked for, before anything connected, so a connection
/// that failed made the host "used now", and that went to every device with
/// sync. A computer leaves it to the session, which stamps it once it is
/// connected; so does a phone now.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
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

  late AppDatabase db;
  late GoRouter router;

  Future<_Sessions> pumpPhone(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
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

  Future<DateTime?> lastUsed(WidgetTester tester) async =>
      (await tester.runAsync(() => db.connectionsDao.getById('h-web')))!.lastConnected;

  testWidgets('a host tapped in the list, and the same host typed in the quick connect bar: a session is asked for, '
      'and the host is not "used" before it connects', (tester) async {
    final sessions = await pumpPhone(tester);
    await tester.tap(find.descendant(of: find.byType(PhoneHostRow), matching: find.text('web-01')));
    await settle(tester);
    expect(sessions.started, ['h-web']);
    expect(await lastUsed(tester), isNull, reason: 'stamped as the session was asked for');

    router.go('/');
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.descendant(of: find.byType(QuickConnectBar), matching: find.byType(TextField)),
        'web-01.example.com');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect(sessions.started, ['h-web', 'h-web']);
    expect(await lastUsed(tester), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });
}
