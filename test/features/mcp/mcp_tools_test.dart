// ignore_for_file: invalid_use_of_protected_member
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/features/mcp/mcp_requests.dart';
import 'package:zestssh/features/mcp/mcp_server.dart';
import 'package:zestssh/features/mcp/mcp_service.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// What an AI app can do through ZestSSH's MCP tools (4.1), and what the
/// person decides: hosts of their own list without a secret, sessions on
/// them (a team's are not offered), a session read only once allowed, and a
/// command typed only once that very command is allowed. Names and
/// addresses are made up.

/// A shell that keeps what was typed and answers as a host would.
class _Shell extends ShellService {
  _Shell(this.terminal);

  final Terminal terminal;
  final typed = <String>[];

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {
    final text = utf8.decode(data);
    typed.add(text);
    terminal.write('${text.replaceAll('\r', '')}\r\n');
    terminal.write('total 8\r\nnginx.conf\r\ndeploy@web-01:~\$ ');
  }

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

final _toolsProvider = Provider<McpTools>(McpTools.new);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late ProviderContainer container;
  late AppDatabase tree;
  late McpTools tools;
  late Terminal terminal;
  late _Shell shell;
  final asked = <McpRequest>[];
  var answer = true;
  // Questions are left open (as the person would, away from the screen).
  var hold = false;
  const caller = McpCaller(name: 'Claude Code');

  setUp(() async {
    asked.clear();
    answer = true;
    hold = false;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    final at = DateTime(2026, 11, 1);
    await tree.into(tree.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: at));
    for (final (id, label, host, protocol) in const [
      ('h1', 'web-01', '10.50.0.11', 'ssh'),
      ('h2', 'db-01', '10.50.0.21', 'ssh'),
      ('h3', 'old-switch', '10.50.0.99', 'telnet'),
    ]) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id, label: label, host: host, createdAt: at, updatedAt: at).copyWith(
        protocol: Value(protocol),
        groupId: Value(id == 'h1' ? 'g1' : null),
        startupCommand: const Value('export TOKEN=s3cret'),
        note: const Value('the root password is hunter2'),
      ));
    }
    await tree.connectionTagsDao.setTagsForConnection('h1', ['prod', 'nginx']);
    terminal = Terminal();
    terminal.write('deploy@web-01:~\$ ');
    shell = _Shell(terminal);
    container.read(activeSessionsProvider.notifier).state = {
      's1': SessionState(
        status: SessionStatus.connected,
        connectionId: 'h1',
        connectionLabel: 'web-01',
        host: '10.50.0.11',
        port: 22,
        session: TerminalSession(id: 's1', connectionId: 'h1', terminal: terminal, shell: shell, startedAt: at),
      ),
      // A session of a host that is not in the person's own list (a team's).
      's9': SessionState(
        status: SessionStatus.connected,
        connectionId: 'team-host',
        connectionLabel: 'acme-prod',
        session: TerminalSession(
            id: 's9', connectionId: 'team-host', terminal: Terminal(), shell: _Shell(Terminal()), startedAt: at),
      ),
    };
    container.listen<McpRequest?>(mcpRequestProvider, (_, request) {
      if (request == null) return;
      asked.add(request);
      if (!hold) request.reply(answer);
    });
    tools = container.read(_toolsProvider);
  });

  tearDown(() async {
    container.read(activeSessionsProvider.notifier).state = {};
    container.dispose();
    await tree.close();
  });

  McpTool tool(String name) => tools.all().singleWhere((t) => t.name == name);

  Future<List<AutomationHistoryData>> activity() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return [for (final e in await tree.automationHistoryDao.getAll()) if (e.action.startsWith('mcp_')) e];
  }

  test('the tools and their hints: reading ones read only, run_command destructive', () {
    final names = [for (final t in tools.all()) t.name];
    expect(names, ['list_hosts', 'list_sessions', 'open_session', 'read_output', 'run_command']);
    expect(tool('list_hosts').readOnly, isTrue);
    expect(tool('read_output').readOnly, isTrue);
    expect(tool('run_command').destructive, isTrue);
  });

  test('list_hosts: the person\'s hosts with group and tags, never a note or a start-up command', () async {
    final r = await tool('list_hosts').run(const {}, caller);
    expect(r.isError, isFalse);
    final hosts = (r.structured! as Map)['hosts'] as List;
    expect([for (final h in hosts) (h as Map)['name']], containsAll(['web-01', 'db-01', 'old-switch']));
    final web = hosts.cast<Map>().singleWhere((h) => h['id'] == 'h1');
    expect(web['group'], 'Web');
    expect(web['tags'], ['nginx', 'prod']);
    expect(web['session_open'], isTrue);
    expect(web.keys.toSet(), {'id', 'name', 'address', 'port', 'user', 'protocol', 'group', 'tags', 'session_open'});
    final all = jsonEncode(r.structured) + r.text;
    expect(all, isNot(contains('s3cret')));
    expect(all, isNot(contains('hunter2')));

    final filtered = await tool('list_hosts').run(const {'query': 'NGINX'}, caller);
    expect(((filtered.structured! as Map)['hosts'] as List).single, containsPair('id', 'h1'));
    expect((await activity()).map((e) => e.action), contains('mcp_list_hosts'));
  });

  test('list_sessions: sessions on the person\'s own hosts only', () async {
    final r = await tool('list_sessions').run(const {}, caller);
    final sessions = (r.structured! as Map)['sessions'] as List;
    expect(sessions.single, containsPair('session_id', 's1'));
    expect(r.text, isNot(contains('acme-prod')));
  });

  test('read_output: asked once per session; a no reads nothing', () async {
    terminal.write('ls\r\nREADME.md\r\n');
    answer = false;
    final no = await tool('read_output').run(const {'session_id': 's1'}, caller);
    expect(no.isError, isTrue);
    expect(no.text, isNot(contains('README')));
    expect(asked.single, isA<McpReadRequest>());
    expect(asked.single.caller.shownName, 'Claude Code');
    expect(asked.single.hostName, 'web-01');

    answer = true;
    final yes = await tool('read_output').run(const {'session_id': 's1', 'lines': 50}, caller);
    expect(yes.isError, isFalse);
    expect(yes.text, contains('README.md'));
    final again = await tool('read_output').run(const {'session_id': 's1'}, caller);
    expect(again.isError, isFalse);
    expect(asked, hasLength(2), reason: 'allowed once for the session, not asked again');

    final team = await tool('read_output').run(const {'session_id': 's9'}, caller);
    expect(team.isError, isTrue);
    expect(asked, hasLength(2), reason: 'a team\'s session is not offered, so nothing is asked');
  });

  test('run_command: typed only once that command is allowed, its output returned and kept in the activity', () async {
    answer = false;
    final no = await tool('run_command').run(const {'session_id': 's1', 'command': 'ls -la', 'wait_seconds': 0}, caller);
    expect(no.isError, isTrue);
    expect(shell.typed, isEmpty);
    final request = asked.single as McpRunRequest;
    expect(request.command, 'ls -la');
    expect(request.dangers, isEmpty);

    answer = true;
    final yes = await tool('run_command').run(const {'session_id': 's1', 'command': 'ls -la', 'wait_seconds': 2}, caller);
    expect(yes.isError, isFalse);
    expect(shell.typed, ['ls -la\r']);
    expect(yes.text, contains('nginx.conf'));
    final log = await activity();
    final runs = [for (final e in log) if (e.action == 'mcp_run_command') e];
    expect(runs.map((e) => e.success).toSet(), {true, false});
    expect(runs.first.command, 'ls -la');
    expect(runs.first.snippetName, 'Claude Code');
    expect(runs.first.stdout, isEmpty, reason: 'what the host printed is not kept');
  });

  test('run_command: a dangerous command says so; a line break or another control character is refused unasked', () async {
    answer = false;
    await tool('run_command').run(const {'session_id': 's1', 'command': 'rm -rf /', 'wait_seconds': 0}, caller);
    expect((asked.single as McpRunRequest).dangers, isNotEmpty);
    // (The last two would show other text than what runs: a right-to-left
    // override, a zero-width space.)
    for (final bad in ['ls\nreboot', 'ls\x15reboot', 'echo \x1b[2J', 'rm -rf ~ #\u202Egnp.olleh', 'ls\u200B-la']) {
      final r = await tool('run_command').run({'session_id': 's1', 'command': bad}, caller);
      expect(r.isError, isTrue);
    }
    expect(asked, hasLength(1));
    expect(shell.typed, isEmpty);
  });

  test('an AI app that gives up on its call (notifications/cancelled, as the SDKs send after their minute) takes '
      'its question back: nothing is typed, even if the person then allows it', () async {
    hold = true;
    final protocol = McpProtocol(serverName: 'ZestSSH', serverVersion: '4.1.0', instructions: '', tools: tools.all);
    Future<McpResponse> post(Map<String, Object?> message, {String session = 'session-a'}) => protocol.handle(
          'POST',
          {'mcp-session-id': session, 'mcp-protocol-version': '2025-11-25'},
          jsonEncode({'jsonrpc': '2.0', ...message}),
          newSessionId: () => 'unused',
        );
    final call = post({
      'id': 7,
      'method': 'tools/call',
      'params': {
        'name': 'run_command',
        'arguments': {'session_id': 's1', 'command': 'uptime', 'wait_seconds': 0},
      },
    });
    await pumpEventQueue();
    final question = asked.single as McpRunRequest;
    expect(question.isOpen, isTrue);

    // Another session's request 7 is not this one.
    await post({'method': 'notifications/cancelled', 'params': {'requestId': 7}}, session: 'session-b');
    await pumpEventQueue();
    expect(question.isOpen, isTrue);

    final cancelled = await post({
      'method': 'notifications/cancelled',
      'params': {'requestId': 7, 'reason': 'Request timed out'},
    });
    expect(cancelled.status, 202);
    final answered = await call.timeout(const Duration(seconds: 5));
    expect(question.isOpen, isFalse, reason: 'the question is taken back');
    expect(((answered.json!['result'] as Map)['isError']), isTrue);
    expect(container.read(mcpRequestProvider), isNull);

    question.reply(true); // the person clicks Allow on what was taken back
    await pumpEventQueue();
    expect(shell.typed, isEmpty);
  });

  test('an allowed command returns what it printed, and no more: reading the session is still asked', () async {
    terminal.write('cat notes.txt\r\nthe vault password is opensesame\r\ndeploy@web-01:~\$ ');
    final ran = await tool('run_command').run(const {'session_id': 's1', 'command': 'ls', 'wait_seconds': 2}, caller);
    expect(ran.isError, isFalse);
    expect(ran.text, contains('nginx.conf'));
    expect(ran.text, isNot(contains('opensesame')));

    answer = false;
    final read = await tool('read_output').run(const {'session_id': 's1'}, caller);
    expect(asked.last, isA<McpReadRequest>(), reason: 'the run question did not allow reading the session');
    expect(read.isError, isTrue);
    expect(read.text, isNot(contains('opensesame')));
  });

  test('AI apps turned off (the server stopped: the switch, a new token, the plan) take back a question still on '
      'screen: nothing is typed', () async {
    hold = true;
    final protocol = McpProtocol(serverName: 'ZestSSH', serverVersion: '4.1.0', instructions: '', tools: tools.all);
    final server = McpServer(protocol: protocol, token: 'zmcp_t', port: 0);
    await server.start();
    final call = protocol.handle(
      'POST',
      const {'mcp-protocol-version': '2025-11-25'},
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'session_id': 's1', 'command': 'uptime', 'wait_seconds': 0},
        },
      }),
      newSessionId: () => 'unused',
    );
    await pumpEventQueue();
    final question = asked.single;
    expect(question.isOpen, isTrue);
    await server.stop();
    await call.timeout(const Duration(seconds: 5));
    expect(question.isOpen, isFalse);
    question.reply(true);
    await pumpEventQueue();
    expect(shell.typed, isEmpty);
  });

  test('open_session: a telnet host is not opened; an unknown host says so', () async {
    final telnet = await tool('open_session').run(const {'host_id': 'h3'}, caller);
    expect(telnet.isError, isTrue);
    expect(telnet.text, contains('telnet'));
    final unknown = await tool('open_session').run(const {'host_id': 'nope'}, caller);
    expect(unknown.isError, isTrue);
  });

  test('a missing argument is the model\'s to fix', () async {
    await expectLater(tool('read_output').run(const {}, caller), throwsA(isA<McpArgumentError>()));
    await expectLater(
        tool('read_output').run(const {'session_id': 's1', 'lines': 99999}, caller), throwsA(isA<McpArgumentError>()));
  });
}
