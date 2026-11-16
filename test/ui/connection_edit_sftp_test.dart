import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
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

/// The host editor for a host that is SFTP only:
/// everything SSH has stays (the address and port, the key, jump hosts,
/// Compatibility mode, both tests), and what is a terminal's is not offered
/// (agent forwarding, its theme, what runs as it starts, its variables, its
/// forwards), one line saying why where it would be.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    // What the form says is shown on the page, as a phone shows it.
    debugTopSnackBarOnPhone = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 30);
    for (final (id, protocol) in [('h-sftp', 'sftp'), ('h-ssh', 'ssh')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id == 'h-sftp' ? 'files-01' : 'db-primary',
            host: '192.0.2.${id.length}',
            port: const Value(2222),
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

  testWidgets("a computer's editor of a host that is SFTP only: SSH's sign-in and network, no terminal's settings",
      (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-sftp', inDialog: true, onClose: () {}));
    // Its badge says SFTP, by its short name.
    expect(find.text('SFTP'), findsWidgets);
    // Auth: Compatibility mode, and no agent forwarding, which is for a
    // terminal's next hop.
    expect(keyed('host-edit-compat-sftp'), findsOneWidget);
    expect(anywhere(en.connectionEditAuthSftpOnly), findsOneWidget);
    expect(anywhere(en.connectionEditForwardAgent), findsNothing);
    // Network: the jump host and the keep-alive, as for SSH.
    expect(anywhere(en.connectionConnectVia), findsWidgets);
    expect(anywhere(en.settingsKeepaliveInterval), findsOneWidget);
    // Terminal: why there is nothing there.
    expect(keyed('host-edit-sftp-no-terminal'), findsOneWidget);
    expect(anywhere(en.connectionEditTheme), findsNothing);
    // Advanced: no startup command, snippet on connect or variables.
    expect(anywhere(en.connectionStartupCommand), findsNothing);
    expect(anywhere(en.connectionRunSnippet), findsNothing);
    expect(anywhere(en.connectionEditEnvironment), findsNothing);
    expect(anywhere(en.hostSftpOnlyNoTerminal), findsWidgets);
    // Both tests stay.
    expect(find.text(en.zestHostTestReachability), findsOneWidget);
    expect(find.text(en.zestHostTestFull), findsOneWidget);
    await finish(tester);
  });

  testWidgets('an SSH host keeps all of it, as before', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-ssh', inDialog: true, onClose: () {}));
    expect(keyed('host-edit-compat-sftp'), findsNothing);
    expect(anywhere(en.connectionEditForwardAgent), findsOneWidget);
    expect(keyed('host-edit-sftp-no-terminal'), findsNothing);
    expect(anywhere(en.connectionStartupCommand), findsOneWidget);
    await finish(tester);
  });

  testWidgets('picking SFTP only for an SSH host keeps its port, says what it is, and is saved as sftp',
      (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'h-ssh', inDialog: true, onClose: () {}));
    await tester.tap(find.text('SFTP'));
    await settle(tester);
    expect(find.text(en.connectionEditSftpInfo), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '2222'), findsOneWidget,
        reason: 'SSH and SFTP only are reached on the same port');
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('h-ssh'))!;
    expect(saved.protocol, 'sftp');
    expect(saved.port, 2222);
    expect(saved.startupCommand, 'tmux attach', reason: 'kept, for a host made SSH again');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets("a phone's form of a host that is SFTP only: its advanced options have none of a terminal's",
      (tester) async {
    debugHostFormOnComputer = false;
    debugHostFormLocalShell = false;
    await pump(tester, const ConnectionEditScreen(connectionId: 'h-sftp'), size: const Size(390, 844));
    final advanced = find.byKey(const ValueKey('host-form-advanced'));
    await tester.scrollUntilVisible(advanced, 300, scrollable: find.byType(Scrollable).first);
    // Clear of the bar Test and Save stand in, at the foot of the page.
    await tester.ensureVisible(advanced);
    await tester.pump();
    await tester.tap(advanced);
    await settle(tester);
    expect(keyed('host-edit-compat-sftp'), findsOneWidget);
    expect(keyed('host-edit-sftp-no-terminal'), findsOneWidget);
    expect(anywhere(en.connectionStartupCommand), findsNothing);
    expect(anywhere(en.connectionEditEnvironment), findsNothing);
    expect(anywhere(en.connectionEditForwardAgent), findsNothing);
    await finish(tester);
  });
}
