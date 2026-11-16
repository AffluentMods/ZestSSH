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
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The sessions the phone opens.
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

/// Selecting hosts on a phone (3.4):
/// a long press starts it with that host, a tap adds or takes out; the top
/// bar says how many and selects every host shown; a selected host the
/// search hides is said, with Show; the tab bar is Edit, Open, Tags, Move
/// and More; Edit opens the editor's sheet; back ends it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  late AppDatabase db;
  late ProviderContainer container;

  Future<_Sessions> pumpPhone(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      for (final label in ['legacy-db-01', 'legacy-db-02', 'legacy-db-03', 'legacy-web-01']) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: label,
              label: label,
              host: '$label.example.com',
              createdAt: DateTime(2026, 10, 28),
              updatedAt: DateTime(2026, 10, 28),
            ));
      }
    });
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => null),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      recordingModeProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 28, 12))),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
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

  Set<String> selected() => container.read(hostMultiSelectProvider).selected;
  bool selecting() => container.read(hostMultiSelectProvider).active;
  Finder action(int i) => find.descendant(
      of: find.byKey(const ValueKey('phone-selection-actions')), matching: find.byKey(ValueKey('phone-tab-$i')));

  testWidgets('a long press starts it with that host, taps add and take out; the bars are the selection\'s; X ends it',
      (tester) async {
    final sessions = await pumpPhone(tester);
    await tester.longPress(find.text('legacy-db-01'));
    await settle(tester);
    expect(selecting(), isTrue);
    expect(selected(), {'legacy-db-01'});
    expect(sessions.started, isEmpty, reason: 'a long press connects nothing');
    expect(find.text(l10n.hostBulkActionSelectedCount(1)), findsOneWidget);
    expect(find.text(l10n.bulkSelectAllShown), findsOneWidget);
    for (final label in [l10n.edit, l10n.hostsSelOpen, l10n.bulkTags, l10n.bulkMove, l10n.phoneTabMore]) {
      expect(find.descendant(of: find.byKey(const ValueKey('phone-selection-actions')), matching: find.text(label)),
          findsOneWidget, reason: label);
    }
    expect(find.byKey(const ValueKey('phone-host-box-legacy-db-01')), findsOneWidget);

    await tester.tap(find.text('legacy-db-02'));
    await settle(tester);
    expect(selected(), {'legacy-db-01', 'legacy-db-02'});
    expect(sessions.started, isEmpty, reason: 'a tap while selecting selects');
    expect(find.text(l10n.hostBulkActionSelectedCount(2)), findsOneWidget);
    await tester.tap(find.text('legacy-db-01'));
    await settle(tester);
    expect(selected(), {'legacy-db-02'});

    await tester.tap(find.byKey(const ValueKey('phone-selection-close')));
    await settle(tester);
    expect(selecting(), isFalse);
    expect(find.byKey(const ValueKey('phone-selection-actions')), findsNothing, reason: 'the tabs again');
    await finish(tester);
  });

  testWidgets('Select all shown takes what the search shows; one it hides is said, and Show shows it', (tester) async {
    await pumpPhone(tester);
    await tester.longPress(find.text('legacy-web-01'));
    await settle(tester);
    container.read(connectionSearchQueryProvider.notifier).state = 'db';
    await settle(tester);
    expect(find.text(l10n.bulkHiddenBySearch(1)), findsOneWidget, reason: 'the design\'s "1 selected host is hidden by search"');
    await tester.tap(find.byKey(const ValueKey('phone-selection-all')));
    await settle(tester);
    expect(selected(), {'legacy-web-01', 'legacy-db-01', 'legacy-db-02', 'legacy-db-03'},
        reason: 'the three shown, and the one selected before stays');
    await tester.tap(find.byKey(const ValueKey('phone-selection-show-hidden')));
    await settle(tester);
    expect(container.read(connectionSearchQueryProvider), isEmpty);
    expect(find.byKey(const ValueKey('phone-selection-hidden')), findsNothing);
    expect(find.text('legacy-web-01'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Edit opens the editor\'s sheet for the selected hosts; Apply writes, says so, and ends selecting',
      (tester) async {
    await pumpPhone(tester);
    await tester.longPress(find.text('legacy-db-01'));
    await settle(tester);
    await tester.tap(find.text('legacy-db-03'));
    await settle(tester);
    await tester.tap(action(0));
    await settle(tester);
    expect(find.text(l10n.bulkEditTitle(2)), findsOneWidget);
    expect(find.text(l10n.bulkEditSubtitleShort), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bulk-compat-switch')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-edit-apply')));
    await settle(tester);
    expect(find.text(l10n.bulkEditTitle(2)), findsNothing, reason: 'the sheet closed');
    expect(find.text(l10n.bulkAppliedChanged(2)), findsOneWidget);
    expect(selecting(), isFalse);
    final r = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
    expect([for (final c in r) if (c.compatibilityMode) c.id], ['legacy-db-01', 'legacy-db-03']);
    await tester.pump(const Duration(seconds: 12));
    await finish(tester);
  });

  testWidgets('Open starts a session to each selected host (a few: at once) and shows the sessions', (tester) async {
    final sessions = await pumpPhone(tester);
    await tester.longPress(find.text('legacy-db-01'));
    await settle(tester);
    await tester.tap(find.text('legacy-web-01'));
    await settle(tester);
    await tester.tap(action(1));
    await settle(tester);
    expect(sessions.started, ['legacy-db-01', 'legacy-web-01']);
    expect(selecting(), isFalse);
    expect(find.byKey(const ValueKey('phone-tab-bar')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('back ends selecting, and leaves the app\'s page where it is', (tester) async {
    await pumpPhone(tester);
    await tester.longPress(find.text('legacy-db-01'));
    await settle(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(selecting(), isFalse);
    expect(find.text('legacy-db-01'), findsOneWidget, reason: 'still on the hosts');
    await finish(tester);
  });
}
