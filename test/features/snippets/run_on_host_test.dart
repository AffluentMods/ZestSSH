import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A snippet run on a host from a computer's snippet library and editor
/// (found in a docs check). The editor's Run sent the raw command,
/// `${VAR}` and all, with no dangerous-command check; with no session open to
/// the host the command was copied and nothing ran; a snippet's default host
/// was saved and never used; and "Press Enter after pasting a snippet" did
/// nothing on a computer (the palette and the Inspector never entered it).
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  bool full = false;
  final opened = <String>[];
  final sent = <(String, String)>[];

  /// What the session was told of what is typed into a terminal, when.
  final noted = <String>[];

  @override
  void noteFilledSecrets(Terminal terminal, Iterable<String> secrets) => noted.addAll(secrets);

  SessionState _state(String id, String connectionId, SessionStatus status) => SessionState(
        status: status,
        connectionId: connectionId,
        connectionLabel: connectionId,
        host: '$connectionId.example.com',
        port: 22,
        session: TerminalSession(
          id: id,
          connectionId: connectionId,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 10, 22),
        ),
      );

  void seedConnected(String id, String connectionId) =>
      state = {...state, id: _state(id, connectionId, SessionStatus.connected)};

  void set(String id, SessionStatus status) =>
      state = {...state, id: _state(id, state[id]!.connectionId!, status)};

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      Space? space}) {
    if (full) return null;
    final id = 's-${connection.id}';
    opened.add(id);
    state = {...state, id: _state(id, connection.id, SessionStatus.connecting)};
    return id;
  }

  @override
  bool sendInput(String sessionId, Uint8List bytes, {bool atStart = false}) {
    sent.add((sessionId, utf8.decode(bytes)));
    return true;
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

Connection _host(String id, {String protocol = 'ssh'}) => Connection(
      id: id,
      label: id,
      host: '$id.example.com',
      port: 22,
      colorIndex: 0,
      protocol: protocol,
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: DateTime(2026, 10, 15),
      updatedAt: DateTime(2026, 10, 15),
    );

Snippet _snippet(String command, {bool confirm = false, String? metadata}) => Snippet(
      id: 'sn-1',
      label: 'Disk',
      command: command,
      confirmBeforeRun: confirm,
      isDefault: false,
      metadata: metadata,
      sortOrder: 0,
      createdAt: DateTime(2026, 10, 22),
      updatedAt: DateTime(2026, 10, 22),
    );

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late ProviderContainer container;
  late _Sessions sessions;

  /// A button that does [run] with the app's context and ref.
  Future<void> pump(WidgetTester tester, Future<void> Function(BuildContext, WidgetRef) run,
      {Map<String, Object> prefs = const {}}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(p),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(container.dispose);
    sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => run(context, ref),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
  }

  Future<void> go(WidgetTester tester) async {
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  group('on a host', () {
    Future<bool?> Function(BuildContext, WidgetRef) onHost(String host, String command,
        {bool confirm = false, bool literal = false, List<bool?>? into, String protocol = 'ssh'}) {
      return (context, ref) async {
        final done = await runCommandOnHost(context, ref,
            host: ConnectionWithDetails(connection: _host(host, protocol: protocol)),
            command: command,
            label: 'Disk',
            confirmFirst: confirm,
            literal: literal,
            snippetId: 'sn-1');
        into?.add(done);
        return done;
      };
    }

    testWidgets('a host that is SFTP only: nothing is opened, nothing sent, and why is said', (tester) async {
      final done = <bool?>[];
      await pump(tester, onHost('files-01', 'df -h', into: done, protocol: 'sftp'));
      await go(tester);
      expect(sessions.opened, isEmpty);
      expect(sessions.sent, isEmpty);
      expect(done, [false]);
      expect(find.text(l10n.hostSftpOnlyNoTerminal), findsOneWidget);
      expect(container.read(snippetUsageProvider)['sn-1'], isNull, reason: 'not counted');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('with a live session: its variables filled in, entered there, counted', (tester) async {
      final done = <bool?>[];
      await pump(tester, onHost('h1', r'df -h ${MOUNT:-/srv}', into: done));
      sessions.seedConnected('live-1', 'h1');
      await go(tester);
      expect(sessions.sent, [('live-1', "df -h '/srv'\r")], reason: 'a value goes in quoted, as everywhere');
      expect(sessions.opened, isEmpty, reason: 'nothing new is opened');
      expect(done, [true]);
      expect(container.read(snippetUsageProvider)['sn-1']?.runCount, 1);
      expect(find.text(l10n.zestSnippetsRunSent('h1')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    // A command run again from History is a shell line: what looks like a
    // snippet's variable is the shell's (found while checking the History
    // page).
    testWidgets('literal: \${HOME} and \$[1+1] reach the session exactly as written, nothing asked', (tester) async {
      await pump(tester, onHost('h1', r'echo ${HOME} $[1+1]', literal: true));
      sessions.seedConnected('live-1', 'h1');
      await go(tester);
      expect(find.byType(TextField), findsNothing, reason: 'no variable is asked for');
      expect(sessions.sent, [('live-1', r'echo ${HOME} $[1+1]' '\r')]);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets("not literal: the same line is a snippet's, and its variables are asked for first", (tester) async {
      await pump(tester, onHost('h1', r'echo ${HOME} $[1+1]'));
      sessions.seedConnected('live-1', 'h1');
      await go(tester);
      expect(sessions.sent, isEmpty, reason: 'not before its variables are answered');
      expect(find.byType(TextField), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(sessions.sent, isEmpty);
    });

    testWidgets('literal, and risky: still checked first', (tester) async {
      await pump(tester, onHost('h1', r'rm -rf /var/www ${HOME}', literal: true));
      container.read(dangerousCommandProtectionProvider.notifier).state = true;
      sessions.seedConnected('live-1', 'h1');
      await go(tester);
      expect(find.text(l10n.dangerCommandTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(sessions.sent, isEmpty);
    });

    testWidgets('a risky command is checked first; cancelled, nothing runs and nothing is counted', (tester) async {
      await pump(tester, onHost('h1', 'rm -rf /'), prefs: {'dangerous_command_protection': true});
      container.read(dangerousCommandProtectionProvider.notifier).state = true;
      sessions.seedConnected('live-1', 'h1');
      await go(tester);
      expect(find.text(l10n.cancel), findsWidgets, reason: 'the dangerous-command check asks');
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(sessions.sent, isEmpty);
      expect(container.read(snippetUsageProvider)['sn-1'], isNull);
    });

    testWidgets('a value goes in quotes, and the check reads past them', (tester) async {
      await pump(tester, onHost('h1', r'rm -rf ${DIR:-/}'), prefs: {'dangerous_command_protection': true});
      container.read(dangerousCommandProtectionProvider.notifier).state = true;
      sessions.seedConnected('live-1', 'h1');
      await go(tester);
      expect(find.text(l10n.dangerCommandTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(sessions.sent, isEmpty);
    });

    testWidgets('its own "confirm before running" asks; declined, nothing runs', (tester) async {
      await pump(tester, onHost('h1', 'uptime', confirm: true));
      container.read(dangerousCommandProtectionProvider.notifier).state = true;
      sessions.seedConnected('live-1', 'h1');
      await go(tester);
      expect(find.text(l10n.snippetRunConfirmTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(sessions.sent, isEmpty);
    });

    testWidgets('with no session: one is opened in front, and the command is entered once it is connected',
        (tester) async {
      await pump(tester, onHost('h2', 'uptime'));
      await go(tester);
      expect(sessions.opened, ['s-h2']);
      expect(container.read(sidebarSectionProvider), SidebarSection.sessions);
      expect(container.read(v3ActiveSessionTabProvider), 's-h2');
      expect(find.text(l10n.docCheckSnippetOpening('h2')), findsOneWidget);
      expect(sessions.sent, isEmpty, reason: 'not before it is connected');

      sessions.set('s-h2', SessionStatus.connected);
      await tester.pump(const Duration(milliseconds: 100));
      expect(sessions.sent, isEmpty, reason: "the app's own work on a new connection goes first");
      await tester.pump(const Duration(milliseconds: 500));
      expect(sessions.sent, [('s-h2', 'uptime\r')]);
      expect(container.read(snippetUsageProvider)['sn-1']?.runCount, 1);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a session that does not connect runs nothing, and that is said', (tester) async {
      await pump(tester, onHost('h2', 'uptime'));
      await go(tester);
      sessions.set('s-h2', SessionStatus.error);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(sessions.sent, isEmpty);
      expect(find.text(l10n.docCheckSnippetNotRun('h2')), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('the free plan full: nothing opens, and that is said', (tester) async {
      final done = <bool?>[];
      await pump(tester, onHost('h2', 'uptime', into: done));
      sessions.full = true;
      await go(tester);
      expect(done, [false]);
      expect(sessions.sent, isEmpty);
      expect(find.text(l10n.desktopShellFreeTierLimit(freeSessionLimit)), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
    });
  });

  test('a snippet\'s default host: the one its metadata names, while it still exists', () {
    final hosts = [ConnectionWithDetails(connection: _host('h1')), ConnectionWithDetails(connection: _host('h2'))];
    String meta(String? id) => encodeSnippetMetadata(SnippetMetadata(defaultConnectionId: id)) ?? '';
    expect(defaultHostOf(hosts, meta('h2'))?.connection.id, 'h2');
    expect(defaultHostOf(hosts, meta('h-gone')), isNull, reason: 'deleted since');
    expect(defaultHostOf(hosts, null), isNull);
    expect(defaultHostOf(hosts, meta(null)), isNull);
  });

  group('typed at a session\'s prompt (the palette, the Inspector)', () {
    testWidgets('its masked values are told to the session before a key of it is typed', (tester) async {
      final terminal = Terminal();
      final notedWhenTyped = <List<String>>[];
      terminal.onOutput = (_) => notedWhenTyped.add([...sessions.noted]);
      await pump(tester, (context, ref) async {
        await runSnippetIn(context, ref, _snippet(r'login ${PW:secret}'), terminal);
      });
      await go(tester);
      await tester.enterText(find.byType(TextFormField), 'hunter22');
      await tester.pumpAndSettle();
      await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).snippetVarPaste));
      await tester.pumpAndSettle();
      expect(notedWhenTyped, isNotEmpty);
      expect(notedWhenTyped.first, ['hunter22']);
    });

    for (final (pressEnter, typed) in [(false, 'free -m'), (true, 'free -m\r')]) {
      testWidgets('"Press Enter after pasting a snippet" ${pressEnter ? 'on: entered' : 'off: typed, waiting'}',
          (tester) async {
        final terminal = Terminal();
        final out = StringBuffer();
        terminal.onOutput = out.write;
        await pump(tester, (context, ref) async {
          await runSnippetIn(context, ref, _snippet('free -m'), terminal);
        });
        container.read(autoExecuteSnippetsProvider.notifier).state = pressEnter;
        await go(tester);
        expect(out.toString(), typed);
      });
    }
  });
}
