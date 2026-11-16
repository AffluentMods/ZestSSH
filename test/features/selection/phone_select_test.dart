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
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Selecting keys, snippets and port forwards on a phone (3.4), the hosts'
/// way: a long press starts it with that item, taps add and take out; the
/// top bar says how many and selects every item shown (what the search
/// shows); a selected item the search hides is said, with Show; the tab bar
/// is the selection's actions; back ends it.
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
  final at = DateTime(2026, 11, 1);

  Future<void> pumpPhone(WidgetTester tester, {Widget home = const HomeScreen()}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      for (final (id, label) in const [('k1', 'alpha key'), ('k2', 'beta key'), ('k3', 'gamma key')]) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: id, label: label, username: 'ops', authMethod: 'publicKey', createdAt: at));
      }
      for (final (id, label, category) in const [
        ('s1', 'disk use', 'System'),
        ('s2', 'uptime', 'System'),
        ('s3', 'restart nginx', 'Web'),
      ]) {
        await db.into(db.snippets).insert(SnippetsCompanion.insert(
            id: id, label: label, command: 'echo $id', category: Value(category), createdAt: at, updatedAt: at));
      }
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1', label: 'web-01', host: '10.50.0.21', createdAt: at, updatedAt: at));
      for (final (id, port) in const [('f1', 8080), ('f2', 8443)]) {
        await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: id,
            connectionId: 'h1',
            type: 'local',
            bindPort: port,
            remoteHost: 'localhost',
            remotePort: port,
            label: Value('app $port'),
            createdAt: at));
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
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 1, 12))),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => home),
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
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder bar() => find.byKey(const ValueKey('phone-selection-actions'));
  Finder action(String label) => find.descendant(of: bar(), matching: find.text(label));

  /// The Manage tab, on [section]'s part.
  Future<void> manage(WidgetTester tester, {bool forwards = false}) async {
    await tester.tap(find.byKey(const ValueKey('phone-tab-2')));
    await settle(tester);
    if (forwards) {
      await tester.tap(find.byKey(const ValueKey('manage-port-forwards')));
      await settle(tester);
    }
  }

  testWidgets('keys: a long press starts it, taps add and take out, the bars are the selection\'s, back ends it',
      (tester) async {
    await pumpPhone(tester);
    await manage(tester);
    await tester.longPress(find.text('alpha key'));
    await settle(tester);
    expect(container.read(keySelectionProvider).selected, {'k1'});
    expect(find.byKey(const ValueKey('phone-key-box-k1')), findsOneWidget);
    expect(find.text(l10n.hostBulkActionSelectedCount(1)), findsOneWidget);
    expect(action(l10n.delete), findsOneWidget);
    // With one key: More, that key's own sheet.
    expect(action(l10n.selectKeyActions), findsOneWidget);
    await tester.tap(find.text('beta key'));
    await settle(tester);
    expect(container.read(keySelectionProvider).selected, {'k1', 'k2'});
    expect(find.text('route /identity/edit/k2'), findsNothing, reason: 'a tap while selecting selects');
    expect(action(l10n.selectKeyActions), findsNothing);
    await tester.tap(find.text('alpha key'));
    await settle(tester);
    expect(container.read(keySelectionProvider).selected, {'k2'});
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(container.read(keySelectionProvider).active, isFalse);
    expect(bar(), findsNothing, reason: 'the tabs again');
    expect(find.text('alpha key'), findsOneWidget, reason: 'still on the keys');
    await finish(tester);
  });

  testWidgets('keys: Select all shown takes what the search shows, one it hides is said; Delete asks once',
      (tester) async {
    await pumpPhone(tester);
    await manage(tester);
    await tester.longPress(find.text('gamma key'));
    await settle(tester);
    container.read(identitySearchQueryProvider.notifier).state = 'alpha';
    await settle(tester);
    expect(find.text(l10n.selectHiddenBySearch(1)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-selection-all')));
    await settle(tester);
    expect(container.read(keySelectionProvider).selected, {'k1', 'k3'},
        reason: 'the one shown, and the one selected before stays');
    await tester.tap(find.byKey(const ValueKey('phone-selection-show-hidden')));
    await settle(tester);
    expect(container.read(identitySearchQueryProvider), isEmpty);
    await tester.tap(action(l10n.delete));
    await settle(tester);
    expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatKeys(2))), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
    await settle(tester);
    expect([for (final i in (await tester.runAsync(() => db.select(db.identities).get()))!) i.id], ['k2']);
    expect(container.read(keySelectionProvider).active, isFalse);
    await tester.pump(const Duration(seconds: 5));
    await finish(tester);
  });

  testWidgets('keys: More with one key opens its own sheet', (tester) async {
    await pumpPhone(tester);
    await manage(tester);
    await tester.longPress(find.text('beta key'));
    await settle(tester);
    await tester.tap(action(l10n.selectKeyActions));
    await settle(tester);
    expect(container.read(keySelectionProvider).active, isFalse);
    expect(find.text(l10n.homeSetAsDefaultAction), findsOneWidget);
    await finish(tester);
  });

  testWidgets('port forwards: a long press starts it on the Manage tab\'s other part, Delete asks once',
      (tester) async {
    await pumpPhone(tester);
    await manage(tester, forwards: true);
    await tester.longPress(find.text('app 8080'));
    await settle(tester);
    await tester.tap(find.text('app 8443'));
    await settle(tester);
    expect(container.read(forwardSelectionProvider).selected, {'f1', 'f2'});
    expect(find.byKey(const ValueKey('phone-forward-box-f1')), findsOneWidget);
    expect(action(l10n.zestPfStart), findsOneWidget);
    expect(action(l10n.zestPfStop), findsOneWidget);
    await tester.tap(action(l10n.delete));
    await settle(tester);
    expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatForwards(2))), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
    await settle(tester);
    expect(await tester.runAsync(() => db.select(db.portForwardRules).get()), isEmpty);
    await tester.pump(const Duration(seconds: 5));
    await finish(tester);
  });

  testWidgets('snippets: a long press starts it, Category moves the selected into another category',
      (tester) async {
    await pumpPhone(tester, home: const SnippetsPhoneScreen());
    await tester.longPress(find.text('disk use'));
    await settle(tester);
    await tester.tap(find.text('uptime'));
    await settle(tester);
    expect(container.read(snippetSelectionProvider).selected, {'s1', 's2'});
    expect(find.byKey(const ValueKey('phone-snippet-box-s1')), findsOneWidget);
    await tester.tap(action(l10n.selectCategoryShort));
    await settle(tester);
    expect(find.text(l10n.selectCategoryTitle(l10n.transferWhatSnippets(2))), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('select-category-Web')));
    await settle(tester);
    final rows = (await tester.runAsync(() => db.select(db.snippets).get()))!;
    expect({for (final s in rows) s.id: s.category}, {'s1': 'Web', 's2': 'Web', 's3': 'Web'});
    expect(container.read(snippetSelectionProvider).active, isFalse);
    expect(find.text(l10n.selectCategoryMoved(l10n.transferWhatSnippets(2), 'Web')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    // Back ends selecting there too.
    await tester.longPress(find.text('disk use'));
    await settle(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(container.read(snippetSelectionProvider).active, isFalse);
    await finish(tester);
  });
}
