import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_requests.dart' show ProviderRead;
import 'package:zestssh/providers/snippet_providers.dart' show commandWithDefaults, snippetRunsUnattended;
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/utils/logger.dart';

// What a team's host types as its session starts (found in a security
// review). Its variables, its start-up command and its snippet on connect travel
// in its record, so anyone who may add or edit hosts in a vault, or someone with
// their account, chooses what runs under the name of whoever connects next, on
// that host, with no word to them. So the first time each exact text is to be
// typed for a host on this device, its person sees it and says yes, as for a
// password going to a new address (password_manager_approvals.dart). A changed
// text asks again. A session nobody is at (restored as the app starts, connected
// again by itself, a run with nobody there) asks nothing and types nothing it
// has no yes for, and says so. Kept in the Orchard's own database, on this device
// only, as hashes: nothing here names a host or a command. A Tree's hosts are
// only ever changed by their owner, so they are not asked about.

/// How many allowed texts one Orchard remembers on a device, newest kept.
const kMaxTeamCommandApprovals = 500;

/// The most of it that is ever asked about: what is longer cannot be read in a
/// question, so it is not run.
const kMaxTeamCommandChars = 16 * 1024;

const _key = 'orchards.connect_command_approvals';

/// What a team's host would type as a session of it starts, as its row says now:
/// what is approved is what is typed, whatever the row says by the time the
/// person answers.
class TeamConnectCommands {
  const TeamConnectCommands({this.variables = const {}, this.startup, this.snippet});

  /// The variables it sets, by the names that are typed.
  final Map<String, String> variables;

  /// Its start-up command, trimmed; null for none.
  final String? startup;

  /// The command its snippet on connect runs; null for none, or for a snippet
  /// that does not run by itself.
  final String? snippet;

  bool get isEmpty => variables.isEmpty && startup == null && snippet == null;

  /// What it comes to, a line for each, with everything in it showing as what it
  /// is ([visibleCommand]: a line break as `\n`, so that none can push what it
  /// runs out of sight).
  List<String> get shown => [
        for (final e in variables.entries) visibleCommand("export ${e.key}='${e.value}'"),
        ?(startup == null ? null : visibleCommand(startup!)),
        ?(snippet == null ? null : visibleCommand(snippet!)),
      ];

  /// Too long to be read in a question.
  bool get tooLong => shown.fold<int>(0, (n, line) => n + line.length) > kMaxTeamCommandChars;

  /// The one thing allowed: these exact texts on the host [hostId].
  String useOn(String hostId) {
    final text = jsonEncode([
      'zestssh-team-connect-commands-v1',
      hostId,
      [
        for (final e in variables.entries) [e.key, e.value],
      ],
      startup,
      snippet,
    ]);
    return base64Url.encode(sha256.convert(utf8.encode(text)).bytes).replaceAll('=', '');
  }
}

/// What [connection] of the Orchard database [db] would type: with [startup]
/// false only its variables (something else is typed in place of its own
/// commands: "Open terminal here").
Future<TeamConnectCommands> teamConnectCommandsOf(AppDatabase db, Connection connection, {bool startup = true}) async {
  final command = startup ? connection.startupCommand?.trim() ?? '' : '';
  String? snippet;
  final snippetId = connection.snippetId;
  if (startup && snippetId != null && snippetId.isNotEmpty) {
    final row = await db.snippetsDao.getById(snippetId);
    if (row != null && snippetRunsUnattended(row.command, confirmBeforeRun: row.confirmBeforeRun)) {
      snippet = commandWithDefaults(row.command);
    }
  }
  return TeamConnectCommands(
    variables: _variablesIn(connection.envVars),
    startup: command.isEmpty ? null : command,
    snippet: snippet,
  );
}

/// The variables in [json] whose names are typed at all.
Map<String, String> _variablesIn(String json) {
  if (json.isEmpty) return const {};
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return const {};
    return {
      for (final e in decoded.entries)
        if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(e.key)) e.key: '${e.value}',
    };
  } on FormatException {
    return const {};
  }
}

Future<List<String>> _read(LocalStateStore store) async {
  try {
    final raw = await store.read(_key);
    final list = raw == null ? null : jsonDecode(raw);
    return [
      if (list is List)
        for (final d in list)
          if (d is String) d,
    ];
  } catch (_) {
    return const [];
  }
}

/// Whether [use] was allowed before in the Orchard database [db].
Future<bool> teamCommandsAllowedIn(AppDatabase db, String use) async => (await _read(LocalStateStore(db))).contains(use);

/// Remembers that the person allowed [use] in the Orchard database [db].
Future<void> rememberTeamCommandsIn(AppDatabase db, String use) async {
  final store = LocalStateStore(db);
  final list = [
    for (final d in await _read(store))
      if (d != use) d,
    use,
  ];
  final kept = list.length > kMaxTeamCommandApprovals ? list.sublist(list.length - kMaxTeamCommandApprovals) : list;
  await store.write(_key, jsonEncode(kept));
}

/// Whether what [connection]'s session would type is to be typed, as asked.
class TeamCommandsRequest {
  TeamCommandsRequest({required this.hostLabel, required this.address, required this.commands});

  final String hostLabel;
  final String address;
  final TeamConnectCommands commands;

  final _answer = Completer<bool>();

  Future<bool> get answer => _answer.future;

  bool get isOpen => !_answer.isCompleted;

  void reply(bool value) {
    if (isOpen) _answer.complete(value);
  }
}

/// The question waiting for the person, if any. A session has no screen of its
/// own: the app answers this on screen, one at a time.
final teamCommandsRequestProvider = StateProvider<TeamCommandsRequest?>((ref) => null);

/// How long a question waits: nothing answering counts as no.
const kTeamCommandsRequestTimeout = Duration(minutes: 2);

/// Puts [request] to the person, after any question already open, and waits for
/// the answer. No answer in time is a no.
Future<bool> askTeamCommands(ProviderRead read, TeamCommandsRequest request) async {
  while (true) {
    final open = read(teamCommandsRequestProvider);
    if (open == null || !open.isOpen) break;
    await open.answer;
  }
  final controller = read(teamCommandsRequestProvider.notifier);
  controller.state = request;
  try {
    return await request.answer.timeout(kTeamCommandsRequestTimeout, onTimeout: () {
      AppLogger.warning('Team host commands: nobody answered in time');
      request.reply(false);
      return false;
    });
  } finally {
    if (identical(controller.state, request)) controller.state = null;
  }
}
