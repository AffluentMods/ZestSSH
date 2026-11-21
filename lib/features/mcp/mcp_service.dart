/// ZestSSH for the person's own AI (4.1 preview): the MCP server's switch,
/// port and token, the server itself while it runs, and the tools it offers.
///
/// What an AI app may do, and what the person decides:
///
/// * See the hosts of the person's own (Personal) list: names, addresses,
///   users, groups and tags. Never a password, a key, a note, a start-up
///   command or anything a team keeps: a team's hosts are the team's, and
///   the preview offers none of them (a team's rules, its watched vaults and
///   its session logs were made for people at the keyboard).
/// * See the sessions open on those hosts, and open one: the session opens
///   in ZestSSH as one the person opened would, asking them what it would ask
///   them (a host key, a password).
/// * Read what a session's terminal shows: the person allows it once for
///   each session, in ZestSSH's own window.
/// * Run a command: typed into the session's terminal, where the person sees
///   it, only once they allowed that very command, every time, in ZestSSH's
///   own window (an AI app could not be trusted to ask for them). The
///   dangerous command check runs on it first and its finding is shown.
///
/// Everything an AI app did is kept in the activity list (the automation
/// history of the person's Tree), without what the hosts printed.
///
/// The server runs only on a computer (Windows, macOS, Linux), only with
/// Squeezed (or a team seat, which has the full app), only while the switch
/// is on and the database open, and answers nothing while ZestSSH is locked.
/// A plan that ends stops it; the switch is kept for when it comes back.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart' show Terminal;
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/features/mcp/mcp_requests.dart';
import 'package:zestssh/features/mcp/mcp_server.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/terminal/terminal_reader.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

// ── Settings ─────────────────────────────────────────────────────────

/// Whether AI apps may use ZestSSH on this computer. Off until turned on.
final mcpEnabledProvider = NotifierProvider<McpEnabledNotifier, bool>(McpEnabledNotifier.new);

class McpEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(settingsServiceProvider).mcpEnabled;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(settingsServiceProvider).setMcpEnabled(value);
  }
}

/// The port the server listens on.
final mcpPortProvider = NotifierProvider<McpPortNotifier, int>(McpPortNotifier.new);

class McpPortNotifier extends Notifier<int> {
  @override
  int build() => ref.read(settingsServiceProvider).mcpPort;

  Future<void> set(int port) async {
    state = port;
    await ref.read(settingsServiceProvider).setMcpPort(port);
  }
}

/// Ports a person may pick: above the ones a system keeps for itself.
bool mcpPortIsValid(int port) => port >= 1024 && port <= 65535;

/// Where the token is kept: this computer's keychain.
const kMcpTokenKey = 'mcp_token';

/// The token AI apps send, made the first time it is asked for.
final mcpTokenProvider = AsyncNotifierProvider<McpTokenNotifier, String>(McpTokenNotifier.new);

class McpTokenNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final storage = ref.read(secureStorageProvider);
    final kept = await storage.read(key: kMcpTokenKey);
    if (kept != null && kept.startsWith('zmcp_')) return kept;
    final made = newMcpToken();
    await storage.write(key: kMcpTokenKey, value: made);
    return made;
  }

  /// A new token: every AI app set up with the old one stops working.
  Future<void> renew() async {
    final made = newMcpToken();
    await ref.read(secureStorageProvider).write(key: kMcpTokenKey, value: made);
    state = AsyncData(made);
  }
}

/// The endpoint for [port].
String mcpUrl(int port) => 'http://127.0.0.1:$port$kMcpPath';

// ── The server while it runs ─────────────────────────────────────────

sealed class McpStatus {
  const McpStatus();
}

/// Not running: the switch is off, the database closed, or not a computer.
class McpOff extends McpStatus {
  const McpOff();
}

class McpStarting extends McpStatus {
  const McpStarting();
}

class McpListening extends McpStatus {
  const McpListening(this.port);
  final int port;
}

/// Could not listen on [port]: [inUse] when another program has it.
class McpFailed extends McpStatus {
  const McpFailed(this.port, {required this.inUse});
  final int port;
  final bool inUse;
}

/// The server: started and stopped as the switch, the port, the token and
/// the database change. The app's root keeps it alive.
final mcpServerProvider = NotifierProvider<McpServerController, McpStatus>(McpServerController.new);

class McpServerController extends Notifier<McpStatus> {
  @override
  McpStatus build() {
    final enabled = ref.watch(mcpEnabledProvider);
    final port = ref.watch(mcpPortProvider);
    final dbReady = ref.watch(dbReadyProvider);
    final token = ref.watch(mcpTokenProvider);
    final squeezed = ref.watch(isProProvider);
    if (!isDesktopPlatform || !enabled || !dbReady || !squeezed) return const McpOff();
    final value = token.valueOrNull;
    if (value == null) return const McpStarting();

    final tools = McpTools(ref);
    final server = McpServer(
      protocol: McpProtocol(
        serverName: 'ZestSSH',
        serverVersion: ref.read(appVersionProvider).valueOrNull ?? '4.1',
        instructions: kMcpInstructions,
        tools: tools.all,
      ),
      token: value,
      port: port,
    );
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      unawaited(server.stop());
    });
    unawaited(() async {
      try {
        await server.start();
        if (!disposed) state = McpListening(port);
      } on SocketException catch (e) {
        AppLogger.warning('MCP server could not listen on $port: ${e.osError?.errorCode}');
        if (!disposed) state = McpFailed(port, inUse: true);
      } catch (e) {
        AppLogger.warning('MCP server did not start: ${errorKind(e)}');
        if (!disposed) state = McpFailed(port, inUse: false);
      }
    }());
    return const McpStarting();
  }
}

/// What the server tells an AI app about itself.
const kMcpInstructions =
    'ZestSSH is the SSH client of the person you work for. These tools reach the hosts in their own (Personal) '
    'host list and the terminal sessions open in ZestSSH on this computer. Start with list_hosts or list_sessions. '
    'open_session opens a host in ZestSSH, where the person can see it. read_output needs the person to allow '
    'reading each session once; run_command types one command into a session and needs the person to allow that '
    'command, every time, in ZestSSH\'s window, so say what you are about to run and why. Passwords and keys are '
    'never given out. Team hosts are not offered.';

// ── The tools ────────────────────────────────────────────────────────

/// Unicode's invisible format characters (category Cf): direction marks
/// and overrides, zero-width characters.
final _formatCharacter = RegExp(r'\p{Cf}', unicode: true);

/// Protocols a session can be opened for and typed into: those with a
/// terminal and an encrypted connection.
const _openable = {'ssh', 'mosh', 'et'};

class McpTools {
  McpTools(this._ref);

  final Ref _ref;

  /// Sessions whose terminal the person let an AI app read, by session id.
  final _readable = <String>{};

  List<McpTool> all() => [
        McpTool(
          name: 'list_hosts',
          title: 'List hosts',
          description: 'Lists the SSH hosts in the person\'s own ZestSSH host list: id, name, address, port, user, '
              'protocol, group, tags, and whether a session is open. Optionally filtered by text in the name, '
              'address, group or tags. Never returns passwords or keys.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': 'Only hosts whose name, address, group or tags contain this text.'},
            },
            'additionalProperties': false,
          },
          readOnly: true,
          idempotent: true,
          run: _listHosts,
        ),
        McpTool(
          name: 'list_sessions',
          title: 'List open sessions',
          description: 'Lists the terminal sessions open in ZestSSH on the person\'s own hosts: session id, host id, '
              'host name, status (connecting, connected, disconnected, error) and when it started.',
          inputSchema: const {'type': 'object', 'additionalProperties': false},
          readOnly: true,
          idempotent: true,
          run: _listSessions,
        ),
        McpTool(
          name: 'open_session',
          title: 'Open a session',
          description: 'Opens a terminal session to a host (by its id from list_hosts) in ZestSSH, where the person '
              'can see it, or returns the session already open to it. Waits up to 30 seconds for it to connect; '
              'ZestSSH may ask the person something first (a host key, a password).',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'host_id': {'type': 'string', 'description': 'The host\'s id, from list_hosts.'},
            },
            'required': ['host_id'],
            'additionalProperties': false,
          },
          run: _openSession,
        ),
        McpTool(
          name: 'read_output',
          title: 'Read a session\'s output',
          description: 'Returns the last lines a session\'s terminal shows, scrollback included. The person is asked '
              'once per session to allow it.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'session_id': {'type': 'string', 'description': 'The session\'s id, from list_sessions or open_session.'},
              'lines': {'type': 'integer', 'minimum': 1, 'maximum': 2000, 'description': 'How many lines (default 100).'},
            },
            'required': ['session_id'],
            'additionalProperties': false,
          },
          readOnly: true,
          run: _readOutput,
        ),
        McpTool(
          name: 'run_command',
          title: 'Run a command',
          description: 'Types one command line into a session\'s terminal and returns what it printed. The person '
              'must allow this exact command in ZestSSH first, every time; a refusal or no answer in 2 minutes '
              'means nothing was typed. Waits for the output to settle, up to wait_seconds.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'session_id': {'type': 'string', 'description': 'The session\'s id.'},
              'command': {'type': 'string', 'description': 'One command line, no line breaks.'},
              'wait_seconds': {
                'type': 'integer',
                'minimum': 0,
                'maximum': 120,
                'description': 'How long to wait for output (default 10).',
              },
            },
            'required': ['session_id', 'command'],
            'additionalProperties': false,
          },
          destructive: true,
          run: _runCommand,
        ),
      ];

  // ── Shared ──

  /// Why nothing can be done now, or null.
  String? _blocked() {
    if (!_ref.read(dbReadyProvider) || _ref.read(isAppLockedProvider)) {
      return 'ZestSSH is locked on this computer. Ask the person to unlock it, then try again.';
    }
    return null;
  }

  AppDatabase get _tree => _ref.read(treeDatabaseProvider);

  Future<List<ConnectionWithDetails>> _hosts() => _tree.connectionsDao.watchAllWithDetails().first;

  ActiveSessionsNotifier get _sessions => _ref.read(activeSessionsProvider.notifier);

  /// The session [id], where it is a terminal of a host in the person's
  /// Tree, working in the Tree (not a team's session).
  Future<({SessionState state, String connectionId})?> _ownSession(String id, {Set<String>? treeHosts}) async {
    final state = _ref.read(activeSessionsProvider)[id];
    final connId = state?.connectionId;
    if (state == null || connId == null) return null;
    if (_sessions.spaceOfConnection(connId) is OrchardSpace) return null;
    if (_sessions.isFilesOnly(id) || _sessions.isScreen(id)) return null;
    final own = treeHosts ?? await _treeHostIds();
    if (!own.contains(connId)) return null;
    return (state: state, connectionId: connId);
  }

  Future<Set<String>> _treeHostIds() async => {for (final c in await _tree.connectionsDao.getAll()) c.id};

  void _log(String action, McpCaller caller, {String connectionId = '', String command = '', required bool success}) {
    try {
      final dao = _tree.automationHistoryDao;
      unawaited(dao.insert(AutomationHistoryCompanion(
        id: Value(const Uuid().v4()),
        timestamp: Value(DateTime.now()),
        action: Value(action),
        connectionId: Value(connectionId),
        command: Value(command),
        snippetName: Value(caller.shownName ?? 'AI app'),
        success: Value(success),
        elapsedMs: const Value(0),
      )).then((_) => dao.trim(500)));
    } catch (e) {
      AppLogger.warning('MCP: the activity was not kept (${errorKind(e)})');
    }
  }

  // ── list_hosts ──

  Future<McpToolResult> _listHosts(Map<String, Object?> args, McpCaller caller) async {
    final why = _blocked();
    if (why != null) return McpToolResult.error(why);
    final query = args.optionalString('query')?.trim().toLowerCase();
    final hosts = await _hosts();
    final tags = await _tree.connectionTagsDao.getAllAssignments();
    final open = {
      for (final s in _ref.read(activeSessionsProvider).values)
        if (s.connectionId != null && s.status != SessionStatus.disconnected) s.connectionId!,
    };
    final out = <Map<String, Object?>>[];
    for (final h in hosts) {
      final c = h.connection;
      final hostTags = tags[c.id] ?? const <String>[];
      final entry = <String, Object?>{
        'id': c.id,
        'name': c.label,
        'address': c.host,
        'port': c.port,
        'user': h.identity?.username,
        'protocol': c.protocol,
        'group': h.group?.name,
        'tags': hostTags,
        'session_open': open.contains(c.id),
      };
      if (query != null && query.isNotEmpty) {
        final hay = [c.label, c.host, h.group?.name ?? '', ...hostTags].join(' ').toLowerCase();
        if (!hay.contains(query)) continue;
      }
      out.add(entry);
    }
    _log('mcp_list_hosts', caller, success: true);
    final text = out.isEmpty
        ? 'No hosts${query == null || query.isEmpty ? '' : ' match "$query"'}.'
        : out.map((h) {
            final user = h['user'] == null ? '' : '${h['user']}@';
            final group = h['group'] == null ? '' : ', group ${h['group']}';
            final tagText = (h['tags'] as List).isEmpty ? '' : ', tags ${(h['tags'] as List).join(', ')}';
            final openText = h['session_open'] == true ? ', session open' : '';
            return '- ${h['name']} (id ${h['id']}): $user${h['address']}:${h['port']} ${h['protocol']}$group$tagText$openText';
          }).join('\n');
    return McpToolResult(text, structured: {'hosts': out});
  }

  // ── list_sessions ──

  Future<McpToolResult> _listSessions(Map<String, Object?> args, McpCaller caller) async {
    final why = _blocked();
    if (why != null) return McpToolResult.error(why);
    final out = <Map<String, Object?>>[];
    final treeHosts = await _treeHostIds();
    for (final MapEntry(key: id, value: s) in _ref.read(activeSessionsProvider).entries) {
      if (await _ownSession(id, treeHosts: treeHosts) == null) continue;
      out.add({
        'session_id': id,
        'host_id': s.connectionId,
        'host_name': s.connectionLabel,
        'status': s.status.name,
        'started_at': s.startedAt?.toUtc().toIso8601String(),
      });
    }
    _log('mcp_list_sessions', caller, success: true);
    final text = out.isEmpty
        ? 'No sessions are open on the person\'s own hosts.'
        : out.map((s) => '- ${s['host_name']} (session ${s['session_id']}): ${s['status']}').join('\n');
    return McpToolResult(text, structured: {'sessions': out});
  }

  // ── open_session ──

  Future<McpToolResult> _openSession(Map<String, Object?> args, McpCaller caller) async {
    final why = _blocked();
    if (why != null) return McpToolResult.error(why);
    final hostId = args.requireString('host_id');
    final host = (await _hosts()).where((h) => h.connection.id == hostId).firstOrNull;
    if (host == null) return McpToolResult.error('No host with id $hostId in the person\'s own host list.');
    final c = host.connection;
    if (!_openable.contains(c.protocol)) {
      _log('mcp_open_session', caller, connectionId: c.id, success: false);
      return McpToolResult.error('${c.label} is a ${c.protocol} host; only SSH, Mosh and Eternal Terminal hosts can be '
          'opened from here. The person can open it in ZestSSH.');
    }
    final id = _sessions.startSession(c, space: const TreeSpace());
    if (id == null) {
      _log('mcp_open_session', caller, connectionId: c.id, success: false);
      return const McpToolResult.error('ZestSSH has as many sessions open as the person\'s plan allows. '
          'Ask them to close one, or use a session already open (list_sessions).');
    }
    final status = await _settled(id, const Duration(seconds: 30));
    final ok = status == SessionStatus.connected;
    _log('mcp_open_session', caller, connectionId: c.id, success: ok);
    final s = _ref.read(activeSessionsProvider)[id];
    final text = switch (status) {
      SessionStatus.connected => 'Connected to ${c.label}. Session id: $id',
      SessionStatus.connecting =>
        'Still connecting to ${c.label} (ZestSSH may be asking the person something). Session id: $id',
      _ => 'Could not connect to ${c.label}${s?.errorMessage == null ? '' : ': ${s!.errorMessage}'}. Session id: $id',
    };
    return McpToolResult(text,
        structured: {'session_id': id, 'host_id': c.id, 'status': status?.name ?? 'disconnected'}, isError: !ok && status != SessionStatus.connecting);
  }

  /// The session's status once it is no longer connecting, or after [limit].
  Future<SessionStatus?> _settled(String id, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (true) {
      final status = _ref.read(activeSessionsProvider)[id]?.status;
      if (status != SessionStatus.connecting || DateTime.now().isAfter(end)) return status;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  // ── read_output ──

  Future<McpToolResult> _readOutput(Map<String, Object?> args, McpCaller caller) async {
    final why = _blocked();
    if (why != null) return McpToolResult.error(why);
    final id = args.requireString('session_id');
    final lines = args.optionalInt('lines', fallback: 100, min: 1, max: 2000);
    final own = await _ownSession(id);
    if (own == null) return McpToolResult.error('No terminal session $id on the person\'s own hosts (list_sessions).');
    if (!_readable.contains(id)) {
      final allowed = await askMcp(_ref.read, McpReadRequest(caller: caller, hostName: own.state.connectionLabel),
          cancelled: caller.cancelled);
      if (!allowed) {
        _log('mcp_read_output', caller, connectionId: own.connectionId, success: false);
        return const McpToolResult.error('The person did not allow reading this session.');
      }
      _readable.add(id);
    }
    final terminal = _ref.read(activeSessionsProvider)[id]?.session?.terminal;
    if (terminal == null) return const McpToolResult.error('The session has no terminal yet (still connecting).');
    final text = _capped(TerminalText.all(terminal, last: lines).join('\n'));
    _log('mcp_read_output', caller, connectionId: own.connectionId, success: true);
    return McpToolResult(text.isEmpty ? '(the terminal is empty)' : text);
  }

  // ── run_command ──

  Future<McpToolResult> _runCommand(Map<String, Object?> args, McpCaller caller) async {
    final why = _blocked();
    if (why != null) return McpToolResult.error(why);
    final id = args.requireString('session_id');
    final command = args.requireString('command');
    final waitSeconds = args.optionalInt('wait_seconds', fallback: 10, min: 0, max: 120);
    if (command.length > 4096) return const McpToolResult.error('The command is longer than 4096 characters.');
    if (!CommandText.mayBeTyped(command)) {
      return const McpToolResult.error('The command has a line break or another control character; send one line.');
    }
    // Invisible format characters (right-to-left overrides, zero-width
    // ones) could make the question show other text than what would run.
    if (_formatCharacter.hasMatch(command)) {
      return const McpToolResult.error('The command has an invisible format character (a direction mark or a '
          'zero-width character); send it without one.');
    }
    final own = await _ownSession(id);
    if (own == null) return McpToolResult.error('No terminal session $id on the person\'s own hosts (list_sessions).');
    if (own.state.status != SessionStatus.connected) {
      return McpToolResult.error('The session is ${own.state.status.name}, not connected.');
    }
    final dangers = [for (final m in DangerousCommandService.checkFilled(command)) m.pattern];
    final allowed = await askMcp(
      _ref.read,
      McpRunRequest(caller: caller, hostName: own.state.connectionLabel, command: command, dangers: dangers),
      cancelled: caller.cancelled,
    );
    if (!allowed) {
      _log('mcp_run_command', caller, connectionId: own.connectionId, command: command, success: false);
      return const McpToolResult.error('The person did not allow this command. Nothing was typed.');
    }
    final terminal = _ref.read(activeSessionsProvider)[id]?.session?.terminal;
    if (terminal == null) return const McpToolResult.error('The session has gone.');
    final before = TerminalText.all(terminal);
    final sent = _sessions.sendInput(id, Uint8List.fromList(utf8.encode(CommandText.entered(command))));
    _log('mcp_run_command', caller, connectionId: own.connectionId, command: command, success: sent);
    if (!sent) return const McpToolResult.error('The session has no shell to type into.');
    // What it printed is returned here, as the question says; reading the
    // rest of the session (its scrollback, what comes later) stays read_output's
    // own question.
    await _quiet(terminal, Duration(seconds: waitSeconds));
    final after = TerminalText.all(terminal);
    final start = before.isEmpty ? 0 : before.length - 1;
    final printed = after.length >= before.length && start <= after.length
        ? after.sublist(start)
        : after.sublist(after.length > 200 ? after.length - 200 : 0);
    final text = _capped(printed.join('\n'));
    return McpToolResult(text.isEmpty ? '(nothing printed yet)' : text);
  }

  /// Waits until the terminal's text has not changed for a second after it
  /// first changed, or [limit] went by.
  Future<void> _quiet(Terminal terminal, Duration limit) async {
    if (limit == Duration.zero) return;
    final end = DateTime.now().add(limit);
    var last = TerminalText.all(terminal).join('\n');
    var stillSince = DateTime.now();
    var changed = false;
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final now = TerminalText.all(terminal).join('\n');
      if (now != last) {
        last = now;
        changed = true;
        stillSince = DateTime.now();
      } else if (changed && DateTime.now().difference(stillSince) >= const Duration(seconds: 1)) {
        return;
      }
    }
  }

  /// At most 64 KB of text, the end of it kept.
  static String _capped(String text) {
    const max = 64 * 1024;
    if (text.length <= max) return text;
    return '(earlier output cut)\n${text.substring(text.length - max)}';
  }
}
