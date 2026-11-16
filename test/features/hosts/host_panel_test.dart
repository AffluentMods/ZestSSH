
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// The desktop Hosts page (3.0): a click opens the host's read-only panel, a
/// double click or Enter connects, Escape closes the panel.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
  void set(Map<String, SessionState> s) => state = s;
}

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late List<String> connected;
  late List<String> sftp;
  late List<String> switched;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool knownKey = false,
  }) async {
    connected = [];
    sftp = [];
    switched = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/connectivity'),
            (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 9, 24);
    for (final (id, label, host) in [
      ('c0', 'db-primary', '10.50.0.21'),
      ('c1', 'web-01', '10.50.0.13'),
    ]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            port: const Value(22),
            createdAt: now,
            updatedAt: now,
          ));
    }
    if (knownKey) {
      await db.knownHostsDao.upsertHost(KnownHostsCompanion.insert(
        id: 'k0',
        host: '10.50.0.21',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abc',
        publicKeyBase64: 'AAAA',
        firstSeen: DateTime(2026, 3, 14),
        lastSeen: DateTime(2026, 9, 24),
      ));
    }
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HostsHomePage(
            onConnectTo: (ConnectionWithDetails i) =>
                connected.add(i.connection.id),
            onOpenSftp: (i) => sftp.add(i.connection.id),
            onSwitchToSession: switched.add,
          ),
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return c;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder panel() => find.byKey(const ValueKey('host-panel-c0'));

  // Connect was not centred,
  // and the page floated under a large empty band while a panel was open.
  testWidgets("with a host's panel open the page stays at the top, and SFTP and Connect fill the panel's foot, "
      'Connect twice as wide, each word in its middle', (tester) async {
    await pump(tester);
    final newHost = find.byKey(const ValueKey('hosts-new-host'));
    final before = tester.getTopLeft(newHost).dy;
    await tester.tap(find.text('db-primary'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(panel(), findsOneWidget);
    expect(tester.getTopLeft(newHost).dy, before, reason: 'the page where it was without the panel');
    expect(before, lessThan(80), reason: 'at the top');

    final foot = tester.getRect(find.ancestor(
        of: find.byKey(const ValueKey('host-panel-sftp')), matching: find.byType(Row)).first);
    final sftp = tester.getRect(find.byKey(const ValueKey('host-panel-sftp')));
    final connect = tester.getRect(find.byKey(const ValueKey('host-panel-primary')));
    expect(sftp.left, moreOrLessEquals(foot.left, epsilon: 0.5));
    expect(connect.right, moreOrLessEquals(foot.right, epsilon: 0.5));
    expect(connect.width, moreOrLessEquals(2 * sftp.width, epsilon: 1.5), reason: 'Connect twice as wide');
    for (final (button, word) in [(sftp, 'SFTP'), (connect, 'Connect')]) {
      final words = tester.getRect(find.descendant(of: panel(), matching: find.text(word)));
      expect(words.center.dx, moreOrLessEquals(button.center.dx, epsilon: 12), reason: '$word in the middle');
      expect(words.center.dy, moreOrLessEquals(button.center.dy, epsilon: 1), reason: word);
    }
    await finish(tester);
  });

  testWidgets('a click opens the panel and connects nothing', (tester) async {
    await pump(tester);
    expect(panel(), findsNothing);
    await tester.tap(find.text('db-primary'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    expect(panel(), findsOneWidget);
    expect(connected, isEmpty, reason: 'a single click only selects');
    expect(find.text('Not known yet'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a double click connects', (tester) async {
    await pump(tester);
    await tester.tap(find.text('web-01'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('web-01'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(connected, ['c1']);
    await finish(tester);
  });

  testWidgets('Enter connects the host in the panel; Escape closes it',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('db-primary'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(connected, ['c0']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(panel(), findsNothing);
    await finish(tester);
  });

  testWidgets('the panel connects, opens SFTP, and closes', (tester) async {
    await pump(tester, knownKey: true);
    await tester.tap(find.text('db-primary'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    expect(find.textContaining('Known since'), findsOneWidget);
    expect(find.textContaining('SHA256:abc'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-panel-sftp')));
    expect(sftp, ['c0']);
    await tester.tap(find.byKey(const ValueKey('host-panel-primary')));
    expect(connected, ['c0']);
    await tester.tap(find.byKey(const ValueKey('host-panel-close')));
    await tester.pump();
    expect(panel(), findsNothing);
    await finish(tester);
  });

  testWidgets('with a session open it switches to it instead', (tester) async {
    final c = await pump(tester);
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      's9': SessionState(
        status: SessionStatus.connected,
        connectionId: 'c0',
        connectionLabel: 'db-primary',
        host: '10.50.0.21',
        port: 22,
        session: TerminalSession(
          id: 's9',
          connectionId: 'c0',
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 9, 24),
        ),
      ),
    });
    await tester.pump();
    await tester.tap(find.text('db-primary'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Switch to session'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-panel-primary')));
    expect(switched, ['s9']);
    expect(connected, isEmpty);
    await finish(tester);
  });
}
