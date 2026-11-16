// "Broadcast to hosts" (3.0): pick the hosts, and they open together in one
// tab, in its grid, typing to all of them.
//
// In 2.2.1, broadcasting meant opening every session by hand, dragging
// each to the same group, where they were laid out hard to read, and only
// then broadcasting a command: much extra work compared with a dedicated
// wizard.


import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/providers/broadcast_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;

/// Sessions without hosts behind them: opening one is a session that says
/// it is connecting; one to a host already open is that one (as the app
/// does it); past [limit] new ones nothing opens.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  int? limit;
  final opened = <String>[];

  void set(Map<String, SessionState> s) => state = s;

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false, String? usernameOverride, String? initialCommand, String? asAccount, bool unattended = false, Space? space}) {
    for (final e in state.entries) {
      if (e.value.connectionId == connection.id) return e.key;
    }
    if (limit != null && opened.length >= limit!) return null;
    final id = 'x-${connection.id}';
    opened.add(id);
    state = {...state, id: _state(id, connection.id, connection.label, connection.host)};
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
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionState _state(String id, String connectionId, String label, String host,
        {SessionStatus status = SessionStatus.connected}) =>
    SessionState(
      status: status,
      connectionId: connectionId,
      connectionLabel: label,
      host: host,
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: connectionId,
        terminal: Terminal(),
        shell: _Shell(),
        startedAt: DateTime(2026, 10, 3, 9),
      ),
    );

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 3);
    for (final (id, name) in [('g-web', 'Web'), ('g-db', 'Databases')]) {
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: id, name: name, createdAt: at));
    }
    final hosts = [
      ('h1', 'web-01', '10.50.0.11', 'g-web'),
      ('h2', 'web-02', '10.50.0.12', 'g-web'),
      ('h3', 'web-03', '10.50.0.13', 'g-web'),
      ('h4', 'db-primary', '10.50.0.21', 'g-db'),
      ('h5', 'build-runner', '10.50.0.31', null),
    ];
    for (var i = 0; i < hosts.length; i++) {
      final (id, label, host, group) = hosts[i];
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            groupId: Value(group),
            sortOrder: Value(i),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pump(WidgetTester tester, Widget child, {bool pro = true}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      activeSessionsProvider.overrideWith(_Sessions.new),
      isProProvider.overrideWith((ref) => _Pro(pro)),
    ]);
    addTearDown(container.dispose);
    container.read(workTabsProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child),
      ),
    ));
    await settle(tester);
    return container;
  }

  /// Opens the dialog from a button, and returns what it gave back.
  Future<(ProviderContainer, List<Connection>? Function())> openDialog(WidgetTester tester, {bool pro = true}) async {
    List<Connection>? picked;
    final c = await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            picked = await showDialog<List<Connection>>(
              context: context,
              builder: (_) => const Dialog(child: BroadcastToHostsDialog()),
            );
          },
          child: const Text('Pick'),
        ),
      ),
      pro: pro,
    );
    await tester.tap(find.text('Pick'));
    await settle(tester);
    return (c, () => picked);
  }

  Finder openButton(int count) => find.text(l10n.broadcastToHostsOpen(count));

  /// Presses "Open and broadcast" with [count] picked: whether the dialog
  /// closed on it.
  Future<bool> pressOpen(WidgetTester tester, int count) async {
    await tester.tap(openButton(count));
    await settle(tester);
    return find.text(l10n.broadcastToHostsTitle).evaluate().isEmpty;
  }

  group('Picking the hosts', () {
    testWidgets('every host is listed under its group, and those with none last', (tester) async {
      await openDialog(tester);
      expect(find.text(l10n.broadcastToHostsTitle), findsOneWidget);
      for (final name in ['web-01', 'web-02', 'web-03', 'db-primary', 'build-runner']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      final web = tester.getTopLeft(find.text('Web')).dy;
      final dbs = tester.getTopLeft(find.text('Databases')).dy;
      final none = tester.getTopLeft(find.text(l10n.hostPanelUngrouped)).dy;
      expect(web < tester.getTopLeft(find.text('web-01')).dy, isTrue);
      expect(dbs < tester.getTopLeft(find.text('db-primary')).dy, isTrue);
      expect(none > dbs && none > web, isTrue, reason: 'hosts in no group come last');
    });

    testWidgets('one host is not enough, two are', (tester) async {
      final (_, picked) = await openDialog(tester);
      expect(find.text(l10n.broadcastToHostsPickTwo), findsOneWidget);
      expect(await pressOpen(tester, 0), isFalse);
      await tester.tap(find.text('web-01'));
      await settle(tester);
      expect(await pressOpen(tester, 1), isFalse);
      await tester.tap(find.text('db-primary'));
      await settle(tester);
      expect(find.text(l10n.broadcastToHostsPickTwo), findsNothing);
      expect(await pressOpen(tester, 2), isTrue);
      expect(picked()!.map((c) => c.id), ['h1', 'h4']);
    });

    testWidgets('the hosts open in the order of the list, not in the order they were ticked', (tester) async {
      final (_, picked) = await openDialog(tester);
      for (final name in ['db-primary', 'web-02', 'web-01']) {
        await tester.tap(find.text(name));
        await settle(tester);
      }
      expect(await pressOpen(tester, 3), isTrue);
      expect(picked()!.map((c) => c.id), ['h1', 'h2', 'h4']);
    });

    testWidgets("a group's box picks all of it, then none of it", (tester) async {
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('broadcast-group-g-web')));
      await settle(tester);
      expect(openButton(3), findsOneWidget);
      // One of them taken out: the group's box is neither.
      await tester.tap(find.text('web-02'));
      await settle(tester);
      expect(tester.widget<Checkbox>(find.byKey(const ValueKey('broadcast-group-g-web'))).value, isNull);
      await tester.tap(find.byKey(const ValueKey('broadcast-group-g-web')));
      await settle(tester);
      expect(openButton(3), findsOneWidget, reason: 'neither is filled up');
      await tester.tap(find.byKey(const ValueKey('broadcast-group-g-web')));
      await settle(tester);
      expect(openButton(0), findsOneWidget);
    });

    testWidgets('the search finds by name, address and group, and says when nothing matches', (tester) async {
      await openDialog(tester);
      await tester.enterText(find.byKey(const ValueKey('broadcast-hosts-search')), 'web-0');
      await settle(tester);
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text('db-primary'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('broadcast-hosts-search')), '10.50.0.21');
      await settle(tester);
      expect(find.text('db-primary'), findsOneWidget);
      expect(find.text('web-01'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('broadcast-hosts-search')), 'databases');
      await settle(tester);
      expect(find.text('db-primary'), findsOneWidget);
      // In any case of letters.
      await tester.enterText(find.byKey(const ValueKey('broadcast-hosts-search')), 'WEB-02');
      await settle(tester);
      expect(find.text('web-02'), findsOneWidget);
      expect(find.text('web-01'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('broadcast-hosts-search')), 'nothing-here');
      await settle(tester);
      expect(find.text(l10n.broadcastToHostsNoMatch('nothing-here')), findsOneWidget);
    });

    testWidgets('with no saved hosts it says so', (tester) async {
      await db.delete(db.connections).go();
      await openDialog(tester);
      expect(find.text(l10n.hostPanelEmpty), findsOneWidget);
      expect(find.text(l10n.broadcastToHostsNoMatch('')), findsNothing);
    });

    testWidgets('a host that is open already says so', (tester) async {
      final (c, _) = await openDialog(tester);
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s4': _state('s4', 'h4', 'db-primary', '10.50.0.21')});
      await settle(tester);
      final row = find.byKey(const ValueKey('broadcast-host-h4'));
      expect(find.descendant(of: row, matching: find.text(l10n.broadcastToHostsIsOpen)), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('broadcast-host-h1')), matching: find.text(l10n.broadcastToHostsIsOpen)),
        findsNothing,
      );
    });

    testWidgets('a host on its way to open is open already', (tester) async {
      final (c, _) = await openDialog(tester);
      (c.read(activeSessionsProvider.notifier) as _Sessions)
          .set({'s4': _state('s4', 'h4', 'db-primary', '10.50.0.21', status: SessionStatus.connecting)});
      await settle(tester);
      expect(
        find.descendant(of: find.byKey(const ValueKey('broadcast-host-h4')), matching: find.text(l10n.broadcastToHostsIsOpen)),
        findsOneWidget,
      );
    });

    testWidgets('a paid plan picks as many as there are', (tester) async {
      await openDialog(tester);
      for (final name in ['web-01', 'web-02', 'web-03', 'db-primary', 'build-runner']) {
        await tester.tap(find.text(name));
        await settle(tester);
      }
      expect(find.byKey(const ValueKey('broadcast-hosts-limit')), findsNothing);
      expect(await pressOpen(tester, 5), isTrue);
    });

    testWidgets('a free plan picks no more than it opens at once; a host open already takes no place', (tester) async {
      final (c, _) = await openDialog(tester, pro: false);
      // db-primary open in all but three of the plan's places (two sessions
      // on a computer, where it opens five): three places left.
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({
        for (var i = 0; i < freeSessionLimit - 3; i++) 's4-$i': _state('s4-$i', 'h4', 'db-primary', '10.50.0.21'),
      });
      await settle(tester);
      for (final name in ['web-01', 'web-02', 'web-03', 'db-primary']) {
        await tester.tap(find.text(name));
        await settle(tester);
      }
      expect(find.byKey(const ValueKey('broadcast-hosts-limit')), findsNothing, reason: 'db-primary is open already');
      await tester.tap(find.text('build-runner'));
      await settle(tester);
      expect(find.text(l10n.broadcastToHostsLimit(freeSessionLimit)), findsOneWidget);
      expect(await pressOpen(tester, 5), isFalse);
      // One less, and it opens.
      await tester.tap(find.text('build-runner'));
      await settle(tester);
      expect(find.byKey(const ValueKey('broadcast-hosts-limit')), findsNothing);
      expect(await pressOpen(tester, 4), isTrue);
    });

    testWidgets('Cancel gives nothing back', (tester) async {
      final (_, picked) = await openDialog(tester);
      await tester.tap(find.text('web-01'));
      await tester.tap(find.text('web-02'));
      await settle(tester);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(picked(), isNull);
    });
  });

  group('Opening them', () {
    Future<(ProviderContainer, BroadcastOpened Function())> open(WidgetTester tester, List<String> ids,
        {int? limit, Map<String, SessionState> before = const {}}) async {
      BroadcastOpened? result;
      final c = await pump(
        tester,
        Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () async {
              final all = await db.select(db.connections).get();
              result = openForBroadcast(ref, [for (final id in ids) all.firstWhere((c) => c.id == id)]);
            },
            child: const Text('Open'),
          ),
        ),
      );
      final sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
      sessions.limit = limit;
      if (before.isNotEmpty) sessions.set(before);
      await settle(tester);
      await tester.tap(find.text('Open'));
      await settle(tester);
      return (c, () => result!);
    }

    testWidgets('together in one tab, in its grid, in front, typing to all', (tester) async {
      final (c, result) = await open(tester, ['h1', 'h2', 'h3', 'h4', 'h5']);
      final tab = result().tabId!;
      expect(result().opened, 5);
      expect(result().limited, isFalse);
      final tabs = c.read(workTabsProvider);
      expect(tabs.activeTabId, tab);
      final it = tabs.tabs.firstWhere((t) => t.id == tab);
      expect(it.paneTree.allLeaves.map((l) => l.sessionId), ['x-h1', 'x-h2', 'x-h3', 'x-h4', 'x-h5']);
      expect(isTiled(it.paneTree), isTrue);
      expect(c.read(broadcastModeProvider).broadcasts(tab), isTrue);
      expect(c.read(activeTabBroadcastProvider), ['x-h1', 'x-h2', 'x-h3', 'x-h4', 'x-h5']);
    });

    testWidgets('a host that is open already is gathered, not opened twice', (tester) async {
      final (c, result) = await open(
        tester,
        ['h1', 'h4'],
        before: {'s4': _state('s4', 'h4', 'db-primary', '10.50.0.21')},
      );
      final sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
      expect(sessions.opened, ['x-h1'], reason: 'only the host that was not open');
      final tab = c.read(workTabsProvider).tabs.firstWhere((t) => t.id == result().tabId);
      expect(tab.paneTree.allLeaves.map((l) => l.sessionId), ['x-h1', 's4']);
      expect(c.read(workTabsProvider).tabs, hasLength(1));
    });

    testWidgets('past the limit, a host that is open already is gathered all the same', (tester) async {
      final (c, result) = await open(
        tester,
        ['h1', 'h2', 'h4'],
        limit: 1,
        before: {'s4': _state('s4', 'h4', 'db-primary', '10.50.0.21')},
      );
      expect(result().limited, isTrue, reason: 'web-02 did not open');
      final tab = c.read(workTabsProvider).tabs.firstWhere((t) => t.id == result().tabId);
      expect(tab.paneTree.allLeaves.map((l) => l.sessionId), ['x-h1', 's4']);
      expect(c.read(broadcastModeProvider).broadcasts(tab.id), isTrue);
    });

    testWidgets('a plan that opens fewer opens what it can, and says the rest were kept back', (tester) async {
      final (c, result) = await open(tester, ['h1', 'h2', 'h3'], limit: 2);
      expect(result().opened, 2);
      expect(result().limited, isTrue);
      expect(c.read(broadcastModeProvider).broadcasts(result().tabId!), isTrue);
    });

    testWidgets('one that could open alone does not broadcast to nobody', (tester) async {
      final (c, result) = await open(tester, ['h1', 'h2'], limit: 1);
      expect(result().opened, 1);
      expect(result().limited, isTrue);
      expect(c.read(broadcastModeProvider).any, isFalse);
    });

    testWidgets('none that could open is nothing', (tester) async {
      final (c, result) = await open(tester, ['h1', 'h2'], limit: 0);
      expect(result().tabId, isNull);
      expect(result().opened, 0);
      expect(c.read(workTabsProvider).tabs, isEmpty);
    });
  });

  // What is typed to all of them crosses the network to a Telnet host as it
  // is, a password among it: the question every other way of opening one asks
  // is asked here too, once for the lot. (They opened with no question: a
  // security review found it.)
  group('A Telnet host among them', () {
    Future<(_Sessions, BroadcastOpened? Function())> pick(WidgetTester tester) async {
      final at = DateTime(2026, 10, 3);
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h6',
            label: 'switch-01',
            host: '10.50.0.41',
            protocol: const Value('telnet'),
            sortOrder: const Value(9),
            createdAt: at,
            updatedAt: at,
          ));
      BroadcastOpened? result;
      final c = await pump(
        tester,
        Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () async => result = await showBroadcastToHosts(context, ref),
            child: const Text('Broadcast'),
          ),
        ),
      );
      await tester.tap(find.text('Broadcast'));
      await settle(tester);
      for (final name in ['web-01', 'web-02', 'switch-01']) {
        await tester.tap(find.text(name));
        await settle(tester);
      }
      expect(await pressOpen(tester, 3), isTrue);
      return (c.read(activeSessionsProvider.notifier) as _Sessions, () => result);
    }

    testWidgets('it is asked about before anything opens, and "Connect anyway" opens them all', (tester) async {
      final (sessions, result) = await pick(tester);
      expect(find.text(l10n.desktopShellUnencryptedConnection), findsOneWidget);
      expect(find.text(l10n.desktopShellTelnetWarning), findsOneWidget);
      expect(sessions.opened, isEmpty, reason: 'nothing opens before the answer');
      await tester.tap(find.text(l10n.desktopShellConnectAnyway));
      await settle(tester);
      expect(sessions.opened, ['x-h1', 'x-h2', 'x-h6']);
      expect(result()!.opened, 3);
    });

    testWidgets('declined, the Telnet host is left out and the others open', (tester) async {
      final (sessions, result) = await pick(tester);
      expect(find.text(l10n.desktopShellUnencryptedConnection), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(sessions.opened, ['x-h1', 'x-h2']);
      expect(result()!.opened, 2);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
