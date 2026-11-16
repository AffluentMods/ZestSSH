import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The host editor for an FTPS host (3.4): FTPS among the protocols, its
/// explicit or implicit TLS under it (the port following, 21 or 990), the
/// key's user name and password, and nothing of SSH's or a terminal's.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    // What the form says is shown on the page, as a phone shows it.
    debugTopSnackBarOnPhone = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 30);
    for (final (id, protocol, port) in [('h-ftps', 'ftps', 21), ('h-ssh', 'ssh', 22)]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id == 'h-ftps' ? 'nas-files' : 'db-primary',
            host: '192.0.2.${id.length}',
            port: Value(port),
            protocol: Value(protocol),
            startupCommand: const Value('tmux attach'),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() async {
    debugHostFormOnComputer = null;
    debugHostFormLocalShell = null;
    debugTopSnackBarOnPhone = null;
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, Widget home, {Size size = const Size(1300, 1000)}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder anywhere(String text) => find.text(text, skipOffstage: false);
  Finder keyed(String key) => find.byKey(ValueKey(key), skipOffstage: false);

  testWidgets("a computer's editor of an FTPS host: TLS mode, a password's sign-in, no SSH and no terminal",
      (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-ftps', inDialog: true, onClose: () {}));
    expect(find.text('FTPS'), findsWidgets);
    expect(keyed('host-edit-ftps-mode'), findsOneWidget);
    expect(anywhere(en.connectionEditFtpsExplicit), findsOneWidget);
    expect(anywhere(en.connectionEditFtpsImplicit), findsOneWidget);
    expect(keyed('host-edit-auth-ftps'), findsOneWidget);
    // Nothing of SSH's: no jump host, no Compatibility mode, no agent forwarding.
    expect(anywhere(en.connectionConnectVia), findsNothing);
    expect(anywhere(en.connectionEditCompatibilityModeLabel), findsNothing);
    expect(anywhere(en.connectionEditForwardAgent), findsNothing);
    // Nothing of a terminal's, and the line that says why.
    expect(anywhere(en.connectionStartupCommand), findsNothing);
    expect(anywhere(en.connectionEditEnvironment), findsNothing);
    expect(anywhere(en.hostFtpsNoTerminal), findsWidgets);
    await finish(tester);
  });

  testWidgets('implicit TLS moves the port from 21 to 990 and is saved as ftpsImplicit', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-ftps', inDialog: true, onClose: () {}));
    await tester.tap(keyed('host-edit-ftps-ftpsImplicit'));
    await settle(tester);
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '990'), findsOneWidget);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('h-ftps'))!;
    expect(saved.protocol, 'ftpsImplicit');
    expect(saved.port, 990);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('an FTPS host has no rules per network and never saves Compatibility mode, which it does not read',
      (tester) async {
    // On from before (the host was another kind, or came in so).
    await (db.update(db.connections)..where((c) => c.id.equals('h-ftps')))
        .write(const ConnectionsCompanion(compatibilityMode: Value(true)));
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-ftps', inDialog: true, onClose: () {}));
    expect(find.byType(HostNetworkOverridesSection, skipOffstage: false), findsNothing);
    await tester.tap(keyed('host-edit-ftps-ftpsImplicit'));
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('h-ftps'))!;
    expect(saved.protocol, 'ftpsImplicit');
    expect(saved.compatibilityMode, isFalse);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets("an SSH host's editor keeps its rules per network", (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-ssh', inDialog: true, onClose: () {}));
    expect(find.byType(HostNetworkOverridesSection, skipOffstage: false), findsOneWidget);
    await finish(tester);
  });

  testWidgets('picking FTPS for an SSH host sets port 21, explicit TLS, and saves it as ftps', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-ssh', inDialog: true, onClose: () {}));
    expect(keyed('host-edit-ftps-mode'), findsNothing);
    await tester.tap(find.text('FTPS'));
    await settle(tester);
    expect(keyed('host-edit-ftps-mode'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '21'), findsOneWidget);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    expect((await db.connectionsDao.getById('h-ssh'))!.protocol, 'ftps');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  group("a team's hosts (3.4)", () {
    late AppDatabase tree;

    /// The editor on a team's database: an FTPS host and an SSH host in its
    /// vault, where this account may do everything.
    Future<void> asTeam() async {
      tree = db;
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      const crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
      await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
        "VALUES (1, '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3', 'Acme', 'owner', 1, ?)",
        [crate],
      );
      await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Production', 'manage', ?, 1)",
        [crate, '["add","connect","delete","edit","forward","reveal","sftp"]'],
      );
      final at = DateTime(2026, 11, 6);
      for (final (id, protocol, port) in [('t-ftps', 'ftps', 21), ('t-ssh', 'ssh', 22)]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: id,
              host: '192.0.2.10',
              port: Value(port),
              protocol: Value(protocol),
              createdAt: at,
              updatedAt: at,
            ));
      }
    }

    tearDown(() => tree.close());

    testWidgets('a new host offers FTPS, as in a personal space', (tester) async {
      debugHostFormOnComputer = true;
      await asTeam();
      await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}));
      expect(find.text('FTPS'), findsOneWidget);
      expect(find.text('Telnet'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an SSH host saved in a team offers no FTPS: it keeps its kind', (tester) async {
      debugHostFormOnComputer = true;
      await asTeam();
      await pump(tester, ConnectionEditScreen(connectionId: 't-ssh', inDialog: true, onClose: () {}));
      expect(find.text('FTPS'), findsNothing);
      expect(find.text('Telnet'), findsOneWidget, reason: 'the other kinds are offered as before');
      await finish(tester);
    });

    testWidgets('an FTPS host saved in a team offers FTPS alone, and saves a change of its TLS', (tester) async {
      debugHostFormOnComputer = true;
      await asTeam();
      await pump(tester, ConnectionEditScreen(connectionId: 't-ftps', inDialog: true, onClose: () {}));
      expect(find.text('FTPS'), findsWidgets);
      expect(find.text('Telnet'), findsNothing);
      expect(find.text(en.connectionEditProtocolSftpShort), findsNothing);
      await tester.tap(keyed('host-edit-ftps-ftpsImplicit'));
      await settle(tester);
      await tester.tap(find.text(en.connectionSaveChanges));
      await settle(tester);
      expect((await db.connectionsDao.getById('t-ftps'))!.protocol, 'ftpsImplicit');
      await tester.pump(const Duration(seconds: 7));
      await finish(tester);
    });
  });
}
