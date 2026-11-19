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
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';

/// The sessions the phone home opens, noted.
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

/// A host's own screens on a phone (4.0): the row of an SSH host with a
/// screen has a monitor that opens it (a tap on the row still opens SSH),
/// its sheet has Screen beside Connect and Add a screen in its tools, and
/// the screen's own row says the host it is reached through.
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
      final at = DateTime(2026, 10, 15);
      for (final (id, label, protocol, host, port, via) in [
        ('h-web', 'web-01', 'ssh', 'web-01.example.com', 22, null),
        ('h-db', 'db-primary', 'ssh', 'db-primary.example.com', 22, null),
        ('s-web', 'web-01 desktop', 'vnc', 'localhost', 5900, 'h-web'),
      ]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: host,
              port: Value(port),
              protocol: Value(protocol),
              connectViaId: Value(via),
              createdAt: at,
              updatedAt: at,
            ));
      }
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

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder card(String label) => find.descendant(of: find.byType(PhoneHostRow), matching: find.text(label));
  Finder key(String k) => find.byKey(ValueKey(k));

  testWidgets("the row of a host with a screen has a monitor that opens it; a tap on the row still opens SSH; "
      'a host without one has none', (tester) async {
    final sessions = await pumpPhone(tester);
    expect(key('host-screen-button-h-web'), findsOneWidget);
    expect(key('host-screen-button-h-db'), findsNothing);
    expect(key('host-screen-button-s-web'), findsNothing);
    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(key('host-screen-button-h-web')),
        matchesSemantics(label: l10n.hostScreenOpenNamed('web-01 desktop'), isButton: true, hasTapAction: true,
            isFocusable: true, hasFocusAction: true, hasEnabledState: true, isEnabled: true));
    handle.dispose();
    await tester.tap(key('host-screen-button-h-web'));
    await settle(tester);
    expect(sessions.started, ['s-web']);
    router.go('/');
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(card('web-01'));
    await settle(tester);
    expect(sessions.started, ['s-web', 'h-web']);
    await finish(tester);
  });

  testWidgets("the screen's own row says the host it is reached through", (tester) async {
    await pumpPhone(tester);
    expect(find.descendant(of: find.byType(PhoneHostRow), matching: find.text('localhost:5900 ${l10n.pfPageVia('web-01')}')),
        findsOneWidget);
    await finish(tester);
  });

  testWidgets("the host's sheet: Screen beside Connect opens it; Add a screen asks VNC or RDP, then opens the "
      'editor of the new screen', (tester) async {
    final sessions = await pumpPhone(tester);
    await tester.tap(card('web-01'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(key('phone-sheet-screen'), findsOneWidget);
    expect(find.text(l10n.phoneHostsScreen), findsOneWidget);
    await tester.tap(key('phone-sheet-screen'));
    await settle(tester);
    expect(sessions.started, ['s-web']);
    router.go('/');
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(card('db-primary'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(key('phone-sheet-screen'), findsNothing);
    final add = key('phone-sheet-add-screen');
    await tester.ensureVisible(add);
    await tester.pump();
    await tester.tap(add);
    await settle(tester);
    expect(find.text(l10n.hostScreenAddTitle('db-primary')), findsOneWidget);
    await tester.tap(key('host-screen-kind-rdp'));
    await settle(tester);
    expect(find.text('route ${Routes.connectionEdit}'), findsOneWidget);
    await finish(tester);
  });
}
