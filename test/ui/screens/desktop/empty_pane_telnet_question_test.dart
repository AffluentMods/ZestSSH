import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';

/// The empty pane of a split asks before it opens a Telnet host, as every
/// other way of opening one asks: what is typed there, a password among it,
/// crosses the network as it is. (A host picked there opened with no
/// question, as a security review found.)

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final opened = <String>[];

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false, String? usernameOverride, String? initialCommand, String? asAccount, bool unattended = false, Space? space}) {
    final id = 'x-${connection.id}';
    opened.add(id);
    state = {
      ...state,
      id: SessionState(
        status: SessionStatus.connecting,
        connectionId: connection.id,
        connectionLabel: connection.label,
        host: connection.host,
        port: connection.port,
        username: 'admin',
        session: TerminalSession(
          id: id,
          connectionId: connection.id,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 11, 9),
        ),
      ),
    };
    return id;
  }
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
  bool get isConnected => false;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => false;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  Future<_Sessions> pickInEmptyPane(WidgetTester tester, String name) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 11, 9);
    for (final (id, label, host, protocol) in [
      ('h1', 'web-01', 'web-01.example.com', 'ssh'),
      ('h2', 'switch-01', 'switch-01.example.com', 'telnet'),
    ]) {
      await tester.runAsync(() => db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            protocol: Value(protocol),
            createdAt: at,
            updatedAt: at,
          )));
    }
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: emptyPaneForTesting('leaf-1')),
      ),
    ));
    await settle(tester);
    // The pane itself is the button: its picker opens.
    await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
    await settle(tester);
    expect(find.text(l10n.desktopTerminalAreaConnectToTitle), findsOneWidget);
    await tester.tap(find.text(name));
    await settle(tester);
    return container.read(activeSessionsProvider.notifier) as _Sessions;
  }

  testWidgets('a Telnet host picked there is asked about, and opens only on "Connect anyway"', (tester) async {
    final sessions = await pickInEmptyPane(tester, 'switch-01');
    expect(find.text(l10n.desktopShellUnencryptedConnection), findsOneWidget);
    expect(sessions.opened, isEmpty, reason: 'nothing opens before the answer');
    await tester.tap(find.text(l10n.desktopShellConnectAnyway));
    await settle(tester);
    expect(sessions.opened, ['x-h2']);
  });

  testWidgets('declined, it does not open', (tester) async {
    final sessions = await pickInEmptyPane(tester, 'switch-01');
    await tester.tap(find.text(l10n.cancel));
    await settle(tester);
    expect(find.text(l10n.desktopShellUnencryptedConnection), findsNothing);
    expect(sessions.opened, isEmpty);
  });

  testWidgets('an SSH host picked there opens with no question', (tester) async {
    final sessions = await pickInEmptyPane(tester, 'web-01');
    expect(find.text(l10n.desktopShellUnencryptedConnection), findsNothing);
    expect(sessions.opened, ['x-h1']);
  });
}
