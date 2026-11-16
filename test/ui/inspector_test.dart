import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes show TerminalThemes;
import 'package:zestssh/ui/screens/desktop/widgets/inspector_panel.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

/// The Inspector (3.0): Tools runs snippets by the one shared path (variables,
/// the risky-command check, "confirm before running") and lists only this
/// host's history; Session shows real load or says it has none.

class _Shell extends ShellService {
  _Shell({this.ssh = true});
  final bool ssh;
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
  bool get isEncryptedSsh => ssh;
}

/// An SSH session's shell that reads a host's list of containers: web and
/// db.
class _ListShell extends _Shell implements ShellOneOff {
  final asked = <String>[];

  @override
  Future<String?> runOnce(String command, {Duration timeout = const Duration(seconds: 10)}) async {
    asked.add(command);
    return command.startsWith('docker ps') ? 'web\ndb\n' : null;
  }
}

class _Health extends ConnectionHealthNotifier {}

/// The sessions, with the forwards started and stopped from here noted
/// instead of opened.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final started = <String>[];
  final stopped = <String>[];

  @override
  Future<void> connectThenStartForward(PortForwardRule rule) async => started.add(rule.id);

  @override
  Future<void> stopSavedForward(String ruleId) async => stopped.add(ruleId);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Terminal terminal;
  late StringBuffer typed;

  SessionState state({bool ssh = true, ShellService? shell, SessionStatus status = SessionStatus.connected}) =>
      SessionState(
        status: status,
        connectionId: 'c1',
        connectionLabel: 'db-primary',
        host: '10.50.0.21',
        port: 22,
        username: 'deploy',
        session: TerminalSession(
          id: 's1',
          connectionId: 'c1',
          terminal: terminal,
          shell: shell ?? _Shell(ssh: ssh),
          startedAt: DateTime(2026, 9, 24),
        ),
      );

  setUp(() {
    terminal = Terminal();
    typed = StringBuffer();
    terminal.onOutput = typed.write;
  });

  Future<(ProviderContainer, AppDatabase)> pump(
    WidgetTester tester, {
    InspectorTab tab = InspectorTab.tools,
    bool historyOn = true,
    bool guard = true,
    List<Snippet> snippets = const [],
    List<(String, String)> history = const [],
    Map<String, Object> prefsExtra = const {},
    bool ssh = true,
    ShellService? shell,
    SessionStatus status = SessionStatus.connected,
    Map<String, int> runs = const {},
    List<(String, int)> forwards = const [],
    Map<String, int?> exitCodes = const {},
    bool seedHosts = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'command_history_enabled': historyOn,
      // How often each snippet was run on this device.
      if (runs.isNotEmpty)
        'snippet_usage_v1': jsonEncode({
          for (final e in runs.entries)
            e.key: {'runCount': e.value, 'lastRunAt': DateTime(2026, 9, 24).millisecondsSinceEpoch},
        }),
      ...prefsExtra,
    });
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // c1 (this session's host) and c2 share the folder Web; c3 has none.
    final made = DateTime(2026, 9, 1);
    // (Only for Tools: the Session tab watches a saved host's route and
    // system, which keep timers this rig does not run out.)
    if (seedHosts && tab == InspectorTab.tools) await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: made));
    for (final (id, group) in seedHosts && tab == InspectorTab.tools ? [('c1', 'g1'), ('c2', 'g1'), ('c3', null)] : const <(String, String?)>[]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id,
            host: '10.50.0.2${id.substring(1)}',
            groupId: Value(group),
            createdAt: made,
            updatedAt: made,
          ));
    }
    for (final (conn, port) in forwards) {
      await db.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
            id: 'pf$port',
            connectionId: conn,
            type: 'local',
            bindPort: port,
            remoteHost: '127.0.0.1',
            remotePort: port,
            label: const Value('Grafana'),
            createdAt: made,
          ));
    }
    var at = DateTime(2026, 9, 24, 21);
    for (final (conn, cmd) in history) {
      await db.commandHistoryDao
          .record(command: cmd, connectionId: conn, hostLabel: conn, at: at);
      at = at.subtract(const Duration(minutes: 5));
    }
    for (final e in exitCodes.entries) {
      await (db.update(db.commandHistory)..where((t) => t.command.equals(e.key)))
          .write(CommandHistoryCompanion(exitCode: Value(e.value)));
    }
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      snippetsProvider.overrideWith((ref) => Stream.value(snippets)),
      dangerousCommandProtectionProvider.overrideWith((ref) => guard),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(c.dispose);
    c.read(inspectorTabProvider.notifier).state = tab;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(children: [
            const Spacer(),
            InspectorPanel(
              sessionId: 's1',
              sessionState: state(ssh: ssh, shell: shell, status: status),
              onClose: () {},
            ),
          ]),
        ),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump();
    return (c, db);
  }

  /// A snippet whose default host is [host] (this session's, c1, unless
  /// said; null for none).
  Snippet snip(String id, String label, String command, {bool confirm = false, String? host = 'c1'}) =>
      Snippet(
        id: id,
        label: label,
        command: command,
        metadata: host == null ? null : encodeSnippetMetadata(SnippetMetadata(defaultConnectionId: host)),
        confirmBeforeRun: confirm,
        isDefault: false,
        sortOrder: 0,
        createdAt: DateTime(2026, 9, 24),
        updatedAt: DateTime(2026, 9, 24),
      );

  group('Tools', () {
    testWidgets('search narrows the snippets', (tester) async {
      await pump(tester, snippets: [
        snip('a', 'Running containers', 'docker ps'),
        snip('b', 'Disk usage', 'df -h /'),
      ]);
      expect(find.text('Running containers'), findsOneWidget);
      expect(find.text('Disk usage'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('inspector-snippet-search')), 'disk');
      await tester.pump();
      expect(find.text('Running containers'), findsNothing);
      expect(find.text('Disk usage'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('inspector-snippet-search')), 'nothing');
      await tester.pump();
      expect(find.text('No snippet matches'), findsOneWidget);
    });

    testWidgets('Run types the command at the prompt, without Enter',
        (tester) async {
      await pump(tester, snippets: [snip('a', 'Running containers', 'docker ps')]);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      expect(typed.toString(), 'docker ps');
    });

    testWidgets('a snippet written on Windows is typed with one Enter per line',
        (tester) async {
      // A bug in 2.2.1: a snippet of several lines ran with blank lines
      // between: its lines end in a carriage return and a line feed, and
      // a shell takes each of the two for Enter.
      await pump(tester, snippets: [
        snip('a', 'Deploy', '(\r\nset -e\r\ncd /srv/app\r\nnpm ci\r\n)'),
      ]);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      expect(typed.toString(), '(\rset -e\rcd /srv/app\rnpm ci\r)',
          reason: 'each line once, and the last waits for Enter');
    });

    testWidgets('a snippet written anywhere else gets one Enter per line too',
        (tester) async {
      await pump(tester, snippets: [snip('a', 'Two', 'cd /srv\nls -la')]);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      expect(typed.toString(), 'cd /srv\rls -la');
    });

    testWidgets('"confirm before running" asks, and a cancel types nothing',
        (tester) async {
      await pump(tester,
          snippets: [snip('a', 'Restart web', 'systemctl restart nginx', confirm: true)]);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      expect(find.text('Run this snippet?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(typed.toString(), isEmpty);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run').last);
      await tester.pumpAndSettle();
      expect(typed.toString(), 'systemctl restart nginx');
    });

    testWidgets('a risky command goes through the risky-command check',
        (tester) async {
      await pump(tester, snippets: [snip('a', 'Wipe', 'rm -rf /')]);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      expect(typed.toString(), isEmpty, reason: 'nothing typed before the answer');
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('a variable without a default is asked for first',
        (tester) async {
      await pump(tester,
          snippets: [snip('a', 'Logs', r'docker logs ${CONTAINER} --tail 50')]);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      expect(typed.toString(), isEmpty);
      await tester.enterText(find.byType(TextField).last, 'api-1');
      await tester.pump();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      // Quoted for the shell, so a value can never inject a command.
      expect(typed.toString(), "docker logs 'api-1' --tail 50");
    });

    // Found while comparing the five versions: a list of
    // the host's own ($[DOCKER]) said there was no session here.
    testWidgets("a list of the host's own is read on its session, and what is picked is typed", (tester) async {
      final shell = _ListShell();
      await pump(tester, snippets: [snip('a', 'Logs', r'docker logs $[DOCKER] --tail 50')], shell: shell);
      await tester.tap(find.byTooltip('Run'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(shell.asked, ["docker ps --format '{{.Names}}'"]);
      expect(find.text('web'), findsOneWidget);
      await tester.tap(find.text('db'));
      await tester.pump();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(typed.toString(), "docker logs 'db' --tail 50");
    });

    testWidgets('history lists this host only, newest first; a tap types it',
        (tester) async {
      await pump(tester, history: [
        ('c1', 'docker compose up -d'),
        ('c2', 'reboot'),
        ('c1', 'sudo apt install tmux'),
      ]);
      expect(find.text('docker compose up -d'), findsOneWidget);
      expect(find.text('sudo apt install tmux'), findsOneWidget);
      expect(find.text('reboot'), findsNothing, reason: 'another host');
      final a = tester.getTopLeft(find.text('docker compose up -d')).dy;
      final b = tester.getTopLeft(find.text('sudo apt install tmux')).dy;
      expect(a, lessThan(b), reason: 'newest first');
      await tester.tap(find.text('sudo apt install tmux'));
      await tester.pump();
      expect(typed.toString(), 'sudo apt install tmux');
    });

    testWidgets('a command of several lines from history is typed line by line',
        (tester) async {
      await pump(tester, history: [('c1', 'for f in *.log\r\ndo gzip "\$f"\r\ndone')]);
      await tester.tap(find.textContaining('for f in'));
      await tester.pump();
      expect(typed.toString(), 'for f in *.log\rdo gzip "\$f"\rdone');
    });

    testWidgets('history off says so, and Turn on turns it on', (tester) async {
      final (c, _) = await pump(tester, historyOn: false, history: [
        ('c1', 'docker compose up -d'),
      ]);
      expect(find.text('Command history is off on this device'), findsOneWidget);
      expect(find.text('docker compose up -d'), findsNothing);
      await tester.tap(find.text('Turn on'));
      await tester.pump();
      expect(c.read(commandHistoryEnabledProvider), isTrue);
    });

    testWidgets('history on but empty here says so', (tester) async {
      await pump(tester, history: [('c2', 'reboot')]);
      expect(find.text('Nothing run on this host yet'), findsOneWidget);
    });
  });

  // As designed, the Tools tab shows this
  // host's snippets, recent commands and port forwards.
  group('Tools, this host', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    testWidgets("lists this host's snippets: its own first, then its folder's; another host's only by search",
        (tester) async {
      await pump(tester, snippets: [
        snip('d', 'Elsewhere', 'uptime', host: 'c3'),
        snip('b', 'Folder one', 'df -h', host: 'c2'),
        snip('a', 'Own one', 'docker ps'),
        snip('e', 'Loose', 'free -m', host: null),
      ]);
      expect(find.text(l10n.termToolsForThisHost.toUpperCase()), findsOneWidget);
      expect(find.text('Own one'), findsOneWidget);
      expect(find.text('Folder one'), findsOneWidget);
      expect(find.text('Elsewhere'), findsNothing, reason: 'another folder');
      expect(find.text('Loose'), findsNothing, reason: 'no host, never run');
      expect(tester.getTopLeft(find.text('Own one')).dy, lessThan(tester.getTopLeft(find.text('Folder one')).dy));
      await tester.enterText(find.byKey(const ValueKey('inspector-snippet-search')), 'elsew');
      await tester.pump();
      expect(find.text('Elsewhere'), findsOneWidget);
    });

    testWidgets('fills up with the ones run most, under Often used', (tester) async {
      await pump(tester, snippets: [
        snip('a', 'Own one', 'docker ps'),
        snip('d', 'Twice', 'uptime', host: 'c3'),
        snip('e', 'Five times', 'free -m', host: null),
        snip('f', 'Never', 'ls', host: null),
      ], runs: {'d': 2, 'e': 5});
      expect(find.text(l10n.termToolsOftenUsed.toUpperCase()), findsOneWidget);
      expect(find.text('Never'), findsNothing);
      final own = tester.getTopLeft(find.text('Own one')).dy;
      final five = tester.getTopLeft(find.text('Five times')).dy;
      final two = tester.getTopLeft(find.text('Twice')).dy;
      expect(own < five && five < two, isTrue, reason: "the host's own, then the most run");
    });

    testWidgets('with none for this host it says so, and All opens the Snippets page', (tester) async {
      final (c, _) = await pump(tester, snippets: [
        snip('d', 'Elsewhere', 'uptime', host: 'c3'),
        snip('e', 'Loose', 'free -m', host: null),
      ]);
      expect(find.text(l10n.termToolsNoHostSnippets), findsOneWidget);
      expect(find.text(l10n.termToolsAllCount(2)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inspector-snippets-all')));
      await tester.pump();
      expect(c.read(activeSidebarNavProvider), NavSection.snippets);
    });

    testWidgets('a run is counted, as the library counts one', (tester) async {
      final (c, _) = await pump(tester, snippets: [snip('a', 'Running containers', 'docker ps')]);
      await tester.tap(find.byTooltip('Run'));
      await tester.pumpAndSettle();
      expect(c.read(snippetUsageProvider)['a']?.runCount, 1);
    });

    testWidgets("a variable shows as a chip as the Snippets page shows it: its placeholder, in the brand's tint",
        (tester) async {
      await pump(tester, snippets: [snip('a', 'Logs', r'docker logs ${CONTAINER} --tail 50')]);
      // It was the bare name, grey (as a design review found).
      expect(find.text('CONTAINER'), findsNothing);
      final chip = tester.widget<Text>(find.text(r'${CONTAINER}'));
      expect(chip.style!.color, ZestTokens.brandInk);
    });

    testWidgets('Run again enters a command from history, as it ran', (tester) async {
      await pump(tester, history: [('c1', r'echo ${HOME}')]);
      await tester.tap(find.byTooltip(l10n.termToolsRunAgain));
      await tester.pumpAndSettle();
      expect(typed.toString(), 'echo \${HOME}\r', reason: 'entered, and nothing in it taken for a variable');
    });

    testWidgets('Run again asks before a risky command, and a cancel types nothing', (tester) async {
      await pump(tester, history: [('c1', 'reboot')]);
      await tester.tap(find.byTooltip(l10n.termToolsRunAgain));
      await tester.pumpAndSettle();
      expect(find.text(l10n.dangerRunAnyway), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(typed.toString(), isEmpty);
      await tester.tap(find.byTooltip(l10n.termToolsRunAgain));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.dangerRunAnyway));
      await tester.pumpAndSettle();
      expect(typed.toString(), 'reboot\r');
    });

    testWidgets('Copy puts the command on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      // The notice as a phone shows it: this rig has no notification centre.
      debugTopSnackBarOnPhone = true;
      addTearDown(() => debugTopSnackBarOnPhone = null);
      await pump(tester, history: [('c1', 'journalctl -u nginx')]);
      await tester.tap(find.byTooltip(l10n.copy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(copied, 'journalctl -u nginx');
      expect(find.text(l10n.termToolsCommandCopied), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a command that failed shows its exit status in red; History opens the History page', (tester) async {
      final (c, _) = await pump(tester, history: [('c1', 'make test'), ('c1', 'ls')], exitCodes: {'make test': 2, 'ls': 0});
      final exit = tester.widget<Text>(find.text(l10n.termToolsExitCode(2)));
      expect(exit.style?.color, ZestColors.statusError);
      expect(find.text(l10n.termToolsExitCode(0)), findsNothing, reason: 'one that worked shows when it ran');
      await tester.tap(find.byKey(const ValueKey('inspector-history-all')));
      await tester.pump();
      expect(c.read(activeSidebarNavProvider), NavSection.commandHistory);
    });

    testWidgets("lists this host's port forwards with their state, and starts and stops them", (tester) async {
      final (c, _) = await pump(tester, forwards: [('c1', 3000), ('c2', 4000)]);
      final sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
      expect(find.textContaining('3000'), findsOneWidget);
      expect(find.textContaining('4000'), findsNothing, reason: 'another host');
      expect(tester.widget<ZestStatusPill>(find.byKey(const ValueKey('inspector-forward-state-pf3000'))).kind,
          ZestStatusKind.neutral);
      expect(find.text(l10n.zestPfStateStopped), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inspector-forward-toggle-pf3000')));
      await tester.pump();
      expect(sessions.started, ['pf3000']);
      c.read(activeForwardIdsProvider.notifier).state = {'pf3000'};
      await tester.pump();
      expect(tester.widget<ZestStatusPill>(find.byKey(const ValueKey('inspector-forward-state-pf3000'))).kind,
          ZestStatusKind.healthy);
      expect(find.text(l10n.portForwardStop), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inspector-forward-toggle-pf3000')));
      await tester.pump();
      expect(sessions.stopped, ['pf3000']);
    });

    testWidgets('a host without port forwards says so', (tester) async {
      await pump(tester, forwards: [('c2', 4000)]);
      expect(find.text(l10n.termToolsNoForwards), findsOneWidget);
    });
  });

  group('Session', () {
    testWidgets('Port forwards is a row as its siblings are: their label, its value at the right, a rule under it',
        (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final (c, _) = await pump(tester, tab: InspectorTab.session, forwards: [('c1', 3000)]);
      c.read(activeForwardIdsProvider.notifier).state = {'pf3000'};
      await tester.pump();
      final row = find.byKey(const ValueKey('inspector-port-forwards'));
      expect(row, findsOneWidget);
      final label = tester.widget<Text>(find.descendant(of: row, matching: find.text(l10n.sessionDetailsPortForwards)));
      final host = tester.widget<Text>(find.text(l10n.inspectorHost).first);
      expect((label.style!.fontSize, label.style!.color), (host.style!.fontSize, host.style!.color));
      final value = find.descendant(of: row, matching: find.textContaining('3000'));
      expect(tester.getRect(value).right, closeTo(tester.getRect(row).right, 0.5));
      final border = (tester.widget<Container>(row).decoration! as BoxDecoration).border! as Border;
      expect(border.bottom.width, greaterThan(0));
    });

    testWidgets('no load is made up when Server Monitor is not watching',
        (tester) async {
      await pump(tester, tab: InspectorTab.session);
      expect(find.text('Server monitor is not watching this host'),
          findsOneWidget);
      expect(find.text('CPU'), findsNothing);
    });

    testWidgets('real load when it is', (tester) async {
      await pump(tester, tab: InspectorTab.session, prefsExtra: {
        'cached_server_stats':
            '{"c1":{"cpuPercent":37.0,"ramUsedMB":4096,"ramTotalMB":8192,'
                '"diskPercent":93.0,"collectedAt":1790000000000,"source":"ssh"}}',
      });
      expect(find.text('37%'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('93%'), findsOneWidget);
    });

    testWidgets('the protocol row claims SSH only for an SSH shell',
        (tester) async {
      await pump(tester, tab: InspectorTab.session, ssh: false);
      expect(find.text('SSH'), findsNothing);
    });

    // Found in a code review: a session disconnected or failed said
    // Connecting, in amber.
    for (final (status, kind) in [
      (SessionStatus.connected, ZestStatusKind.healthy),
      (SessionStatus.connecting, ZestStatusKind.pending),
      (SessionStatus.disconnected, ZestStatusKind.neutral),
      (SessionStatus.error, ZestStatusKind.critical),
    ]) {
      testWidgets('the state says ${status.name}, as a ${kind.name} pill', (tester) async {
        await pump(tester, tab: InspectorTab.session, status: status);
        final l10n = lookupAppLocalizations(const Locale('en'));
        final pill = tester.widget<ZestStatusPill>(find.byKey(const ValueKey('inspector-state')));
        expect(pill.kind, kind);
        expect(
            pill.label,
            switch (status) {
              SessionStatus.connected => l10n.sessionInfoStatusConnected,
              SessionStatus.connecting => l10n.sessionInfoStatusConnecting,
              SessionStatus.disconnected => l10n.sessionInfoStatusDisconnected,
              SessionStatus.error => l10n.sessionInfoStatusError,
            });
      });
    }

    testWidgets('the tabs switch', (tester) async {
      final (c, _) = await pump(tester, seedHosts: false);
      await tester.tap(find.byKey(const ValueKey('inspector-tab-session')));
      await tester.pump();
      expect(c.read(inspectorTabProvider), InspectorTab.session);
      expect(find.text('CONNECTION'), findsOneWidget);
    });
  });

  group('Appearance', () {
    // "Match terminal to app theme" is on by default and Graphite is the app
    // theme: a swatch picked here is the terminal drawn, where Dracula, Nord,
    // Tokyo Night and Light did nothing visible.
    for (final id in [app_themes.TerminalThemes.dracula, app_themes.TerminalThemes.nord, app_themes.TerminalThemes.tokyoNight, app_themes.TerminalThemes.light]) {
      testWidgets('a tap on $id draws the terminal in it', (tester) async {
        final (c, _) = await pump(tester, tab: InspectorTab.appearance);
        expect(c.read(shownTerminalThemeIdProvider), app_themes.TerminalThemes.zestNight);
        await tester.tap(find.byKey(ValueKey('inspector-theme-$id')));
        await tester.pump();
        expect(c.read(shownTerminalThemeIdProvider), id);
        expect(c.read(terminalThemeProvider).background, app_themes.TerminalThemes.all[id]!.background);
      });
    }

    testWidgets('the font size stops at the shared ends, 8 and 28', (tester) async {
      final (c, _) = await pump(tester, tab: InspectorTab.appearance, prefsExtra: {'terminal_font_size': 27.0});
      await tester.tap(find.byKey(const ValueKey('inspector-font-larger')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('inspector-font-larger')));
      await tester.pump();
      expect(c.read(terminalFontSizeProvider), kTerminalFontSizeMax);
      expect(kTerminalFontSizeMax, 28);
      expect(kTerminalFontSizeMin, 8);
    });

    // Click the number to type a size.
    group('the number takes a size typed in it', () {
      Future<void> typeSize(WidgetTester tester, String size) async {
        await tester.tap(find.byKey(const ValueKey('inspector-font-size')));
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('inspector-font-size-field')), size);
        await tester.pump();
      }

      testWidgets('Enter keeps it, and the number shows it', (tester) async {
        final (c, _) = await pump(tester, tab: InspectorTab.appearance);
        await typeSize(tester, '17');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), 17);
        expect(find.byKey(const ValueKey('inspector-font-size-field')), findsNothing);
        expect(find.text('17'), findsOneWidget);
      });

      testWidgets('a size past the ends is held to them, and half a size is kept', (tester) async {
        final (c, _) = await pump(tester, tab: InspectorTab.appearance);
        await typeSize(tester, '40');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), kTerminalFontSizeMax);
        await typeSize(tester, '3');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), kTerminalFontSizeMin);
        // A decimal comma, as a German keyboard types it.
        await typeSize(tester, '12,5');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), 12.5);
        expect(find.text('12.5'), findsOneWidget);
      });

      testWidgets('Esc leaves the size as it was; so does nothing typed', (tester) async {
        final (c, _) = await pump(tester, tab: InspectorTab.appearance, prefsExtra: {'terminal_font_size': 15.0});
        await typeSize(tester, '22');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), 15);
        expect(find.byKey(const ValueKey('inspector-font-size-field')), findsNothing);
        await typeSize(tester, '');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), 15);
      });

      testWidgets('leaving the box keeps it', (tester) async {
        final (c, _) = await pump(tester, tab: InspectorTab.appearance);
        await typeSize(tester, '19');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), 19);
      });

      testWidgets('the minus and plus still step from it', (tester) async {
        final (c, _) = await pump(tester, tab: InspectorTab.appearance);
        await typeSize(tester, '19');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('inspector-font-larger')));
        await tester.pump();
        expect(c.read(terminalFontSizeProvider), 20);
      });
    });

    testWidgets('a size kept beyond the ends (a synced 40) comes in held to them', (tester) async {
      final (c, _) = await pump(tester, tab: InspectorTab.appearance, prefsExtra: {'terminal_font_size': 40.0});
      expect(c.read(terminalFontSizeProvider), kTerminalFontSizeMax);
    });

    // "Match terminal to app theme" in the
    // Inspector too, and a quick way to the rest of Appearance.
    testWidgets('"Match terminal to app theme" is the same switch as in Settings', (tester) async {
      final (c, _) = await pump(tester, tab: InspectorTab.appearance);
      final match = find.byKey(const ValueKey('inspector-match-app-theme'));
      expect(match, findsOneWidget);
      expect(c.read(themesSyncedProvider), isTrue);
      expect(tester.widget<ZestSwitch>(match).value, isTrue);
      await tester.tap(match);
      await tester.pump();
      expect(c.read(themesSyncedProvider), isFalse);
      expect(tester.widget<ZestSwitch>(match).value, isFalse);
    });

    // The terminal's colours and font are Terminal and SSH's (4.0).
    testWidgets('"More appearance settings" opens Settings on Terminal and SSH', (tester) async {
      final (c, _) = await pump(tester, tab: InspectorTab.appearance);
      final more = find.byKey(const ValueKey('inspector-more-appearance'));
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await tester.pump();
      expect(c.read(settingsJumpProvider), SettingsJumpTarget.terminal);
      expect(c.read(settingsPopupOpenProvider), isTrue);
    });
  });

  // 4.0 accessibility pass: every control of each of the Inspector's tabs
  // says what it does to a screen reader, and its text reads against what is
  // behind it.
  group('accessibility', () {
    for (final tab in InspectorTab.values) {
      testWidgets('${tab.name}: every control named, its text readable', (tester) async {
        final semantics = tester.ensureSemantics();
        await pump(tester, tab: tab);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        semantics.dispose();
      });
    }
  });
}
