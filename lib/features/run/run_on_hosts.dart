import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/run/run_client.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/snippet_providers.dart' show kMaskedValueShown;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/command_output.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/shell_fill.dart';
import 'package:zestssh/utils/type_name.dart';

// Run on hosts (3.0; Install key on hosts runs on it): one command
// on many hosts at once,
// without a terminal, and a
// result for each, what it printed and how it ended, to look at, copy, and
// run again on the hosts it failed on. Each host is signed in to as a
// session to it would be (ActiveSessionsNotifier.openRunClient): its network,
// its jump hosts, its default account, its space's rules, and what is asked
// of its person, one question at a time. A team's host whose sessions are
// logged has the run logged for its team.

/// How much of what a command prints is kept for each host and each of its
/// two streams.
const kRunOutputKept = 256 * 1024;

/// How many hosts are signed in to and run on at once.
const kRunAtOnce = 4;

/// How long a command is given on a host, from its start to its end. (A
/// sign-in has its own limits, and none while its person is asked.)
const kRunTimeout = Duration(minutes: 2);

/// Where one host's part in a run stands.
enum HostRunState {
  /// Its turn has not come.
  waiting,

  /// Being signed in to.
  signingIn,

  /// The command runs.
  running,

  /// The command ran and ended ([HostRun.exitCode] says how).
  done,

  /// It did not run, or did not end, by what [HostRun.failure] says.
  failed,

  /// The run was stopped before this host was through.
  stopped,
}

/// A command that had not ended once its time ([limit]) was up: it was let
/// go of, and may still be running on the host.
class RunTookTooLong implements Exception, HasTypeName {
  const RunTookTooLong(this.limit);

  final Duration limit;

  @override
  String toString() => 'The command had not ended after ${limit.inSeconds} s';

  @override
  String get typeName => 'RunTookTooLong';
}

/// One host's part in a run.
@immutable
class HostRun {
  const HostRun({
    required this.host,
    this.state = HostRunState.waiting,
    this.exitCode,
    this.signal,
    this.output = '',
    this.errors = '',
    this.cut = false,
    this.failure,
    this.took,
    this.logged = false,
    this.user,
  });

  final Connection host;
  final HostRunState state;

  /// How the command ended: its exit status, or the signal that ended it.
  final int? exitCode;
  final String? signal;

  /// What it printed, and printed as errors (each kept up to [kRunOutputKept]).
  final String output;
  final String errors;

  /// Whether it printed more than is kept.
  final bool cut;

  /// What stopped it, where it [HostRunState.failed].
  final Object? failure;

  /// How long it took, from its sign-in to the end of its command.
  final Duration? took;

  /// Whether the run is logged for the host's team.
  final bool logged;

  /// The account it was signed in to as (what a key installed there is
  /// installed for).
  final String? user;

  /// Whether the command ran and ended well (exit status 0).
  bool get succeeded => state == HostRunState.done && exitCode == 0 && signal == null;

  /// Whether it is through, one way or the other.
  bool get over => state == HostRunState.done || state == HostRunState.failed || state == HostRunState.stopped;

  HostRun copyWith({HostRunState? state, bool? logged, String? user}) => HostRun(
        host: host,
        state: state ?? this.state,
        exitCode: exitCode,
        signal: signal,
        output: output,
        errors: errors,
        cut: cut,
        failure: failure,
        took: took,
        logged: logged ?? this.logged,
        user: user ?? this.user,
      );

  /// As it was before its run: waiting.
  HostRun again() => HostRun(host: host);
}

/// A run: the command, and each host's part in it, in the order chosen.
@immutable
class HostsRun {
  const HostsRun({
    required this.command,
    String? typed,
    this.secrets = const [],
    this.shown,
    this.input,
    required this.hosts,
    this.running = false,
  }) : typed = typed ?? command;

  /// What is run, its variables filled in.
  final String command;

  /// What was typed for it, its variables as they were written (what a new
  /// run starts from).
  final String typed;

  /// The masked values filled into it (`${VAR:secret}`): never shown, and
  /// left out of its team's log.
  final List<String> secrets;

  /// What the command is given to read (its standard input), then the end
  /// of it; null: nothing. Never shown, and not in a team's log.
  final String? input;

  final List<HostRun> hosts;

  /// Whether hosts are still being run on.
  final bool running;

  int get succeeded => hosts.where((h) => h.succeeded).length;

  /// The hosts that are through and did not end well.
  int get notWell => hosts.where((h) => h.over && !h.succeeded).length;

  /// The command with its masked values filled by stand-ins, where whoever
  /// filled it made it so: a value is not as it was typed once it is written for
  /// where it landed (`it's` in quotes, `a$b` in double ones), and was not found
  /// in the command to hide.
  final String? shown;

  /// [command] as it is shown and copied: its masked values hidden.
  String get commandShown {
    final filled = shown;
    if (filled != null) return filled;
    var masked = command;
    for (final s in secrets) {
      if (s.isNotEmpty) masked = masked.replaceAll(s, kMaskedValueShown);
    }
    return masked;
  }

  HostsRun copyWith({List<HostRun>? hosts, bool? running}) => HostsRun(
        command: command,
        typed: typed,
        secrets: secrets,
        shown: shown,
        input: input,
        hosts: hosts ?? this.hosts,
        running: running ?? this.running,
      );
}

/// What a host's part in a run is called, as a word or two.
String hostRunStateWords(HostRun h, AppLocalizations l10n) => switch (h.state) {
      HostRunState.waiting => l10n.runOnHostsWaiting,
      HostRunState.signingIn => l10n.runOnHostsSigningIn,
      HostRunState.running => l10n.runOnHostsRunning,
      HostRunState.done when h.signal != null => l10n.runOnHostsSignal(h.signal!),
      HostRunState.done when h.exitCode == null => l10n.runOnHostsNoStatus,
      HostRunState.done when h.exitCode == 0 => l10n.runOnHostsOk,
      HostRunState.done => l10n.runOnHostsExit('${h.exitCode}'),
      HostRunState.failed => l10n.runOnHostsFailed,
      HostRunState.stopped => l10n.runOnHostsStopped,
    };

/// How a host's part in a run ended, as its team's log says it.
String hostRunEndedWords(HostRun h, AppLocalizations l10n) => switch (h.failure) {
      RunTookTooLong(:final limit) when h.state == HostRunState.failed => l10n.runOnHostsTookTooLong(limit.inMinutes),
      _ => hostRunStateWords(h, l10n),
    };

/// Runs one command on many hosts, [atOnce] at a time, each command given
/// [timeout] from its start to its end; keeps each host's result. One run
/// at a time: a new one is started once the last is over.
class RunOnHostsNotifier extends StateNotifier<HostsRun?> {
  RunOnHostsNotifier(
    this._open, {
    this.starting,
    this.atOnce = kRunAtOnce,
    this.timeout = kRunTimeout,
  }) : super(null);

  /// Signs in to a host for a run ([ActiveSessionsNotifier.openRunClient]).
  final Future<RunClient> Function(Connection host) _open;

  /// Told of the hosts as a run starts, before any is signed in to
  /// ([ActiveSessionsNotifier.runStarting]).
  final void Function(List<Connection> hosts)? starting;

  final int atOnce;
  final Duration timeout;

  /// What is signed in to now, so a stop ends it.
  final _signedIn = <RunClient>{};

  /// Which run this is: a stop or a new run leaves an older one's results
  /// where they are.
  var _round = 0;

  /// Runs [command] on [hosts] ([typed] is what was typed for it, [secrets] the
  /// masked values filled into it and [shown] it with them hidden, where they
  /// are), giving it [input] to read
  /// where there is one. Completes when every host is through, or the run
  /// is stopped. Not while another runs.
  Future<void> run(
    List<Connection> hosts,
    String command, {
    String? typed,
    List<String> secrets = const [],
    String? shown,
    String? input,
  }) async {
    if (state?.running ?? false) return;
    starting?.call(hosts);
    state = HostsRun(
      command: command,
      typed: typed,
      secrets: secrets,
      shown: shown,
      input: input,
      hosts: [for (final h in hosts) HostRun(host: h)],
      running: true,
    );
    await _go([for (var i = 0; i < hosts.length; i++) i]);
  }

  /// Runs the last command again on the hosts that did not end well (with
  /// [all], on every host). Not while it runs.
  Future<void> again({bool all = false}) async {
    final last = state;
    if (last == null || last.running) return;
    final which = [
      for (var i = 0; i < last.hosts.length; i++)
        if (all || !last.hosts[i].succeeded) i,
    ];
    if (which.isEmpty) return;
    state = last.copyWith(
      hosts: [for (var i = 0; i < last.hosts.length; i++) which.contains(i) ? last.hosts[i].again() : last.hosts[i]],
      running: true,
    );
    await _go(which);
  }

  /// Stops the run: hosts whose turn has not come are not run on, and what
  /// is signed in to is let go of (a command running there may go on).
  void stop() {
    final now = state;
    if (now == null || !now.running) return;
    _round++;
    _letGo();
    state = now.copyWith(
      hosts: [for (final h in now.hosts) h.over ? h : h.copyWith(state: HostRunState.stopped)],
      running: false,
    );
  }

  void _letGo() {
    for (final client in _signedIn.toList()) {
      unawaited(client.ssh.disconnect());
    }
    _signedIn.clear();
  }

  Future<void> _go(List<int> which) async {
    final round = ++_round;
    final queue = [...which];
    Future<void> worker() async {
      while (queue.isNotEmpty && round == _round && mounted) {
        await _runOne(queue.removeAt(0), round);
      }
    }

    await Future.wait([for (var i = 0; i < atOnce && i < which.length; i++) worker()]);
    if (round == _round && mounted) state = state?.copyWith(running: false);
  }

  void _set(int index, int round, HostRun Function(HostRun h) change) {
    final now = state;
    if (now == null || round != _round || !mounted) return;
    state = now.copyWith(hosts: [for (var i = 0; i < now.hosts.length; i++) i == index ? change(now.hosts[i]) : now.hosts[i]]);
  }

  Future<void> _runOne(int index, int round) async {
    final run = state!;
    final host = run.hosts[index].host;
    final clock = Stopwatch()..start();
    _set(index, round, (h) => h.copyWith(state: HostRunState.signingIn));
    RunClient? client;
    CommandOutput? out;
    CommandOutput? err;
    HostRun? ended;
    try {
      client = await _open(host);
      if (round != _round || !mounted) return;
      _signedIn.add(client);
      final log = client.teamLog;
      if (log != null) {
        // The masked values filled into it are left out of its team's log.
        for (final s in run.secrets) {
          filledForms(s).forEach(TeamSessionLogs.addSecret);
        }
        TeamSessionLogs.append(log, '[ZestSSH] ${gl10n.runOnHostsLogLine}\r\n\$ ${run.shown ?? run.command}\r\n');
      }
      final user = client.ssh.username;
      _set(index, round, (h) => h.copyWith(state: HostRunState.running, logged: log != null, user: user));
      void toLog(String text) {
        if (log != null) TeamSessionLogs.append(log, text);
      }

      final commandClock = Stopwatch()..start();
      final session = await client.ssh.client.execute(CommandText.script(run.command)).timeout(timeout);
      out = CommandOutput(session.stdout, kRunOutputKept, alsoTo: toLog);
      err = CommandOutput(session.stderr, kRunOutputKept, alsoTo: toLog);
      // What it reads, and then the end of it.
      final input = run.input;
      if (input != null) {
        session.stdin.add(utf8.encode(input));
        unawaited(session.stdin.close());
      }
      await Future.wait([out.ended, err.ended, session.done]).timeout(timeout - commandClock.elapsed);
      ended = HostRun(
        host: host,
        state: HostRunState.done,
        exitCode: session.exitCode,
        signal: session.exitSignal?.signalName,
        output: out.kept,
        errors: err.kept,
        cut: out.cut || err.cut,
        took: clock.elapsed,
        logged: log != null,
        user: user,
      );
    } catch (e) {
      // What it printed before it failed is kept.
      ended = HostRun(
        host: host,
        state: HostRunState.failed,
        failure: e is TimeoutException ? RunTookTooLong(timeout) : e,
        output: out?.kept ?? '',
        errors: err?.kept ?? '',
        cut: (out?.cut ?? false) || (err?.cut ?? false),
        took: clock.elapsed,
        logged: client?.teamLog != null,
        user: client?.ssh.username,
      );
    } finally {
      // The end of a host of a run stopped meanwhile leaves the run as it
      // is ([_set]), and its team's log says it was stopped.
      final end = ended;
      if (end != null) _set(index, round, (_) => end);
      final log = client?.teamLog;
      if (log != null) {
        final words =
            end == null || round != _round || !mounted ? gl10n.runOnHostsStopped : hostRunEndedWords(end, gl10n);
        TeamSessionLogs.append(log, '\r\n[ZestSSH] $words\r\n');
        unawaited(TeamSessionLogs.end(log));
      }
      if (client != null) {
        _signedIn.remove(client);
        unawaited(client.ssh.disconnect());
      }
    }
  }

  @override
  void dispose() {
    _round++;
    _letGo();
    super.dispose();
  }
}

/// A run of this window on hosts, signed in to as their sessions would be.
RunOnHostsNotifier _runOfThisWindow(Ref ref) => RunOnHostsNotifier(
      (host) => ref.read(activeSessionsProvider.notifier).openRunClient(host),
      starting: (hosts) => ref.read(activeSessionsProvider.notifier).runStarting([for (final h in hosts) h.id]),
    );

/// The run on hosts of this window: one at a time, kept until the next.
final runOnHostsProvider = StateNotifierProvider<RunOnHostsNotifier, HostsRun?>(_runOfThisWindow);

/// The install of a key on hosts of this window (3.0): a run of its own, so
/// it never takes the place of a run on hosts.
final installKeyRunProvider = StateNotifierProvider<RunOnHostsNotifier, HostsRun?>(_runOfThisWindow);
