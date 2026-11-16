// PuTTY's saved sessions are imported where they are kept, on Windows (found
// while comparing the five versions): a computer's command
// palette offered the import on a Mac and on Linux too, and its page said
// there that it was for Windows alone. Import hosts offered it on Windows
// alone already; both now ask the same question. So does the Import data
// sheet of Settings, which listed "PuTTY sessions (.reg)" on a phone too, and
// opened a page saying it was for Windows (found in a 3.0 docs
// check).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    debugPuttyImportHere = null;
    await db.close();
  });

  Future<void> openImport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Builder(
            builder: (c) => TextButton(onPressed: () => openImportHosts(c), child: const Text('go')),
          ),
        ),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets("Import hosts offers PuTTY's sessions where they can be read, and not elsewhere", (tester) async {
    debugPuttyImportHere = false;
    await openImport(tester);
    expect(find.byKey(const ValueKey('file-source-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('file-source-putty')), findsNothing);
    await tester.pumpWidget(const SizedBox());

    debugPuttyImportHere = true;
    await openImport(tester);
    expect(find.byKey(const ValueKey('file-source-putty')), findsOneWidget);
  });

  testWidgets('a saved session with a dash in front of its address is left out: it reads as an option wherever it is passed later',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: PuttyImportScreen(debugSessions: [
          ('evil-one', '-oProxyCommand=calc', 22, ''),
          ('old-web', '203.0.113.10', 22, 'deploy'),
          ('no-address', '', 22, ''),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('old-web'), findsOneWidget);
    expect(find.textContaining('evil-one'), findsNothing);
    expect(find.textContaining('oProxyCommand'), findsNothing);
    expect(find.textContaining('no-address'), findsNothing);
  });

  group('Compatibility mode for the sessions imported', () {
    Future<List<Connection>> importing(WidgetTester tester, {required bool ticked}) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
          databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
          orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(
                builder: (_) => const PuttyImportScreen(debugSessions: [
                  ('old-web', '203.0.113.10', 22, 'deploy'),
                  ('old-db', '203.0.113.11', 2222, ''),
                ]),
              )),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final l10n = lookupAppLocalizations(const Locale('en'));
      final box = find.byKey(const ValueKey('putty-compatibility'));
      expect(box, findsOneWidget);
      expect(find.descendant(of: box, matching: find.text(l10n.csvImpCompatibility)), findsOneWidget);
      if (ticked) {
        await tester.tap(box);
        await tester.pump();
      }
      await tester.tap(find.text(l10n.puttyImportSelectAll));
      await tester.pump();
      await tester.tap(find.text(l10n.puttyImportImportSessions(2)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      return (await tester.runAsync(db.connectionsDao.getAll))!;
    }

    testWidgets('ticked: every one has it on', (tester) async {
      final hosts = await importing(tester, ticked: true);
      expect({for (final h in hosts) h.host: h.compatibilityMode}, {'203.0.113.10': true, '203.0.113.11': true});
    });

    testWidgets('left as it starts, unticked: none has it', (tester) async {
      final hosts = await importing(tester, ticked: false);
      expect({for (final h in hosts) h.host: h.compatibilityMode}, {'203.0.113.10': false, '203.0.113.11': false});
    });
  });

  /// [page] alone, with the app's router, its Import data sheet open.
  Future<void> openImportData(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1400, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => Scaffold(body: page)),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.ensureVisible(find.text(l10n.settingsMobImportData));
    await tester.tap(find.text(l10n.settingsMobImportData));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-data-csv')), findsOneWidget);
  }

  for (final (name, page) in [
    ("a phone's Data settings", const DataSettingsScreen()),
    ('Settings', const SettingsScreen()),
  ]) {
    testWidgets("$name: the Import data sheet offers PuTTY's sessions on Windows alone", (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      debugPuttyImportHere = false;
      await openImportData(tester, page);
      expect(find.byKey(const ValueKey('import-data-putty')), findsNothing);
      expect(find.text(l10n.settingsMobPuttySessions), findsNothing);
      // A PuTTY key file (.ppk) is read on any system: still offered.
      expect(find.text(l10n.settingsMobPuttyPrivateKey), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      debugPuttyImportHere = true;
      await openImportData(tester, page);
      expect(find.byKey(const ValueKey('import-data-putty')), findsOneWidget);
    });
  }
}
