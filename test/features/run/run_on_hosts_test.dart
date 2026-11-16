import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// What a played host reads of the client is not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/run/run_client.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/played_sign_in.dart';

/// A host the test plays: it takes the key (unless it [refuses]), runs what
/// it is asked, prints [output] and [errors], and ends with [status] or
/// [signal], unless it [hangs]. [chunks] of output come one after another.
class _Played {
  _Played({
    this.output = '',
    this.errors = '',
    this.status = 0,
    this.signal,
    this.hangs = false,
    this.refuses = false,
    this.chunks = const [],
    this.reads = false,
  });

  final String output;
  final String errors;
  final int status;
  final String? signal;
  final bool hangs;
  final bool refuses;
  final List<String> chunks;

  /// Whether it reads what it is given (until its end) before it prints.
  final bool reads;

  /// What it read.
  String? read;

  final server = PlayedServer();

  /// What it was asked to run.
  String? command;

  Future<void> play({required bool Function() over}) async {
    await server.greet();
    final signIn = PlayedSignIn(ways: ['publickey'], takesKey: !refuses);
    if (!await signIn.play(server, over: over)) return;
    final channel = await server.confirmChannel();
    final request = await channel.nextRequest();
    expect(request.requestType, 'exec');
    command = request.command;
    server.send([channel.success]);
    if (reads) {
      read = utf8.decode(SSH_Message_Channel_Data.decode(await server.next(SSH_Message_Channel_Data.messageId)).data);
      await server.next(SSH_Message_Channel_EOF.messageId);
    }
    server.send([
      for (final c in chunks) channel.data(c),
      if (output.isNotEmpty) channel.data(output),
      if (errors.isNotEmpty) channel.errorData(errors),
    ]);
    if (hangs) return;
    server.send([
      if (signal case final s?) channel.exitSignal(s) else channel.exitStatus(status),
      channel.eof,
      channel.close,
    ]);
  }
}

Connection _host(String id) => Connection(
      id: id,
      label: id,
      host: '$id.example.com',
      port: 22,
      colorIndex: 0,
      protocol: 'ssh',
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

/// Run on hosts (3.0): one command on many hosts at once, a few at a time,
/// without a terminal, and each host's result: what it printed, as errors
/// too, and how it ended; run again where it did not end well; stopped.
/// The hosts are played by the test, each signed in to with a key.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  final key = SSHKeyPair.fromPem(
          File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync())
      .single;

  /// The hosts as the test plays them, by id, and what the run signed in to.
  late Map<String, _Played> played;
  late List<String> opened;
  late List<SshService> services;

  setUp(() {
    played = {};
    opened = [];
    services = [];
  });

  /// Signs in to a played host as the app does for a run: its own service,
  /// with the key, on the host's line.
  Future<RunClient> open(Connection host) async {
    opened.add(host.id);
    final p = played[host.id]!;
    final ssh = SshService(
      host: host.host,
      port: host.port,
      username: 'deploy',
      keyPairs: [key],
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: p.server.socket,
    );
    services.add(ssh);
    var failed = false;
    unawaited(p.play(over: () => failed));
    try {
      await ssh.connectExec();
    } catch (_) {
      failed = true;
      await ssh.disconnect();
      rethrow;
    }
    return RunClient(ssh);
  }

  RunOnHostsNotifier notifier({int atOnce = kRunAtOnce, Duration timeout = kRunTimeout, void Function(List<Connection>)? starting}) {
    final n = RunOnHostsNotifier(open, atOnce: atOnce, timeout: timeout, starting: starting);
    addTearDown(n.dispose);
    return n;
  }

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('each host\'s result: what it printed, as errors too, and how it ended; the command run as a script, in the '
      'order chosen', () async {
    played = {
      'web1': _Played(output: 'up 3 days\n'),
      'web2': _Played(errors: 'disk full\n', status: 3),
      'web3': _Played(output: 'partial', signal: 'KILL'),
    };
    final started = <List<String>>[];
    final hosts = [_host('web1'), _host('web2'), _host('web3')];
    final withStart = notifier(starting: (h) => started.add([for (final c in h) c.id]));
    await withStart.run(hosts, 'uptime\r\necho done');
    final result = withStart.state!;
    expect(started, [
      ['web1', 'web2', 'web3']
    ], reason: 'told of the hosts as the run starts');
    expect(result.running, isFalse);
    expect([for (final h in result.hosts) h.host.id], ['web1', 'web2', 'web3']);
    expect([for (final h in result.hosts) h.state], everyElement(HostRunState.done));
    expect([for (final h in result.hosts) h.exitCode], [0, 3, null]);
    expect([for (final h in result.hosts) h.signal], [null, null, 'KILL']);
    expect([for (final h in result.hosts) h.output], ['up 3 days\n', '', 'partial']);
    expect([for (final h in result.hosts) h.errors], ['', 'disk full\n', '']);
    expect([for (final h in result.hosts) h.succeeded], [true, false, false]);
    expect([for (final h in result.hosts) hostRunStateWords(h, en)],
        [en.runOnHostsOk, en.runOnHostsExit('3'), en.runOnHostsSignal('KILL')]);
    expect((result.succeeded, result.notWell), (1, 2));
    expect([for (final h in result.hosts) h.took], everyElement(isNotNull));
    expect([for (final p in played.values) p.command], everyElement('uptime\necho done'),
        reason: 'each line ends in one line feed, as a shell is handed a script');
    // Each host is let go of once its command has ended.
    await until(() => services.every((s) => !s.isConnected), 'every host let go of');
  });

  test('a few at a time: never more than it is set to at once, and every host is run on', () async {
    played = {for (var i = 1; i <= 5; i++) 'web$i': _Played(output: 'ok $i\n')};
    final run = notifier(atOnce: 2);
    var most = 0;
    run.addListener((s) {
      final busy = s?.hosts.where((h) => h.state == HostRunState.signingIn || h.state == HostRunState.running).length ?? 0;
      if (busy > most) most = busy;
    });
    await run.run([for (var i = 1; i <= 5; i++) _host('web$i')], 'echo ok');
    expect(most, 2);
    expect(run.state!.succeeded, 5);
    expect([for (final h in run.state!.hosts) h.output], [for (var i = 1; i <= 5; i++) 'ok $i\n']);
  });

  test('a host that does not take the key fails, with why; the others run', () async {
    played = {'web1': _Played(refuses: true), 'web2': _Played(output: 'fine\n')};
    final run = notifier();
    await run.run([_host('web1'), _host('web2')], 'true');
    final (refused, fine) = (run.state!.hosts[0], run.state!.hosts[1]);
    expect(refused.state, HostRunState.failed);
    expect(refused.failure, isA<SSHAuthFailError>());
    expect(refused.succeeded, isFalse);
    expect(hostRunStateWords(refused, en), en.runOnHostsFailed);
    expect(fine.succeeded, isTrue);
    expect((run.state!.succeeded, run.state!.notWell), (1, 1));
  });

  test('a command that does not end in its time fails as that, what it printed by then is kept, the host is let '
      'go of, and the next host runs', () async {
    played = {'web1': _Played(output: 'still going\n', hangs: true), 'web2': _Played(output: 'next\n')};
    // (Room enough for the next host's command on a busy machine.)
    final run = notifier(atOnce: 1, timeout: const Duration(seconds: 3));
    await run.run([_host('web1'), _host('web2')], 'sleep 600');
    final slow = run.state!.hosts[0];
    expect(slow.state, HostRunState.failed);
    expect(slow.failure, isA<RunTookTooLong>());
    expect(slow.output, 'still going\n');
    expect(hostRunEndedWords(slow, en), en.runOnHostsTookTooLong(0));
    expect(hostRunStateWords(slow, en), en.runOnHostsFailed);
    await until(() => !services.first.isConnected, 'the slow host let go of');
    expect(run.state!.hosts[1].output, 'next\n');
    expect(run.state!.hosts[1].succeeded, isTrue);
  });

  test('run again: only where it did not end well, the others keep their results; with all, every host', () async {
    played = {'web1': _Played(output: 'one\n'), 'web2': _Played(status: 1), 'web3': _Played(refuses: true)};
    final run = notifier();
    await run.run([_host('web1'), _host('web2'), _host('web3')], 'deploy');
    final first = run.state!.hosts[0];
    expect(run.state!.notWell, 2);

    played = {'web2': _Played(output: 'two\n'), 'web3': _Played(output: 'three\n')};
    opened.clear();
    await run.again();
    expect(opened..sort(), ['web2', 'web3']);
    expect(identical(run.state!.hosts[0], first), isTrue, reason: 'what ended well is left as it was');
    expect([for (final h in run.state!.hosts) h.output], ['one\n', 'two\n', 'three\n']);
    expect(run.state!.succeeded, 3);
    expect(run.state!.command, 'deploy');

    // Nothing left to run again; with all, every host.
    opened.clear();
    await run.again();
    expect(opened, isEmpty);
    played = {for (final id in ['web1', 'web2', 'web3']) id: _Played(output: 'again $id\n')};
    await run.again(all: true);
    expect(opened..sort(), ['web1', 'web2', 'web3']);
    expect([for (final h in run.state!.hosts) h.output], ['again web1\n', 'again web2\n', 'again web3\n']);
  });

  test('stopped: the hosts not through are stopped, what is signed in to is let go of and nothing more is; what '
      'comes later leaves the stopped run as it is, and another can start', () async {
    played = {'web1': _Played(output: 'working\n', hangs: true), 'web2': _Played(), 'web3': _Played()};
    final run = notifier(atOnce: 1);
    final going = run.run([_host('web1'), _host('web2'), _host('web3')], 'make');
    await until(() => run.state!.hosts[0].state == HostRunState.running, 'the first host running');
    // Stopped once the host has the command: a stop before it (a busy
    // machine) ended the connection where the played host waits for it.
    await until(() => played['web1']!.command != null, 'the first host given the command');
    run.stop();
    expect(run.state!.running, isFalse);
    expect([for (final h in run.state!.hosts) h.state], everyElement(HostRunState.stopped));
    await going;
    await until(() => !services.single.isConnected, 'the first host let go of');
    expect(opened, ['web1'], reason: 'nothing more is signed in to');
    expect([for (final h in run.state!.hosts) h.state], everyElement(HostRunState.stopped),
        reason: 'the first host\'s end, which came after the stop, is not taken');

    played = {'web3': _Played(output: 'fresh\n')};
    await run.run([_host('web3')], 'echo fresh');
    expect(run.state!.hosts.single.output, 'fresh\n');
    expect(run.state!.command, 'echo fresh');
  });

  test('one run at a time: asked to run while one goes, nothing changes', () async {
    played = {'web1': _Played(hangs: true), 'web2': _Played()};
    final run = notifier(atOnce: 1);
    final going = run.run([_host('web1')], 'make');
    await until(() => run.state!.hosts[0].state == HostRunState.running, 'the first host running');
    // Stopped once the host has the command: a stop before it (a busy
    // machine) ended the connection where the played host waits for it.
    await until(() => played['web1']!.command != null, 'the first host given the command');
    await run.run([_host('web2')], 'other');
    await run.again(all: true);
    expect(run.state!.command, 'make');
    expect(opened, ['web1']);
    run.stop();
    await going;
  });

  test('more printed than is kept: the first part is kept, and it says so', () async {
    const chunk = 16 * 1024;
    final piece = 'x' * (chunk - 1);
    played = {
      'web1': _Played(chunks: [for (var i = 0; i < 20; i++) '$piece\n']),
    };
    final run = notifier();
    await run.run([_host('web1')], 'cat big');
    final h = run.state!.hosts.single;
    expect(h.output.length, kRunOutputKept);
    expect(h.cut, isTrue);
    expect(h.succeeded, isTrue);
  });

  test('masked values: hidden where the command is shown, and what was typed kept for a new run', () {
    const run = HostsRun(
      command: 'mysql -u deploy -phunter22 -e status',
      typed: r'mysql -u ${USER} -p${PW:secret} -e status',
      secrets: ['hunter22'],
      hosts: [],
    );
    expect(run.commandShown, 'mysql -u deploy -p•••••• -e status');
    expect(run.typed, r'mysql -u ${USER} -p${PW:secret} -e status');
    expect(const HostsRun(command: 'uptime', hosts: []).typed, 'uptime');
    expect(const HostsRun(command: 'uptime', hosts: []).commandShown, 'uptime');
    expect(run.copyWith(running: true).secrets, ['hunter22']);
    expect(run.copyWith(running: true).typed, run.typed);
  });

  test('what a command is given to read comes on its input, and then its end, run again too; who each host was '
      'signed in as is kept', () async {
    played = {'web1': _Played(reads: true, status: 1)};
    final run = notifier();
    await run.run([_host('web1')], 'cat >> list', input: 'ssh-ed25519 AAAAC3Nz test@example\n');
    expect(played['web1']!.read, 'ssh-ed25519 AAAAC3Nz test@example\n');
    expect(run.state!.hosts.single.user, 'deploy');
    expect(run.state!.input, 'ssh-ed25519 AAAAC3Nz test@example\n');

    played = {'web1': _Played(reads: true)};
    await run.again();
    expect(played['web1']!.read, 'ssh-ed25519 AAAAC3Nz test@example\n');
    expect(run.state!.hosts.single.succeeded, isTrue);
    expect(run.state!.hosts.single.user, 'deploy');
  });

  test('how a host that ended is said: no exit status, and stopped', () {
    expect(hostRunStateWords(HostRun(host: _host('a'), state: HostRunState.done), en), en.runOnHostsNoStatus);
    expect(HostRun(host: _host('a'), state: HostRunState.done).succeeded, isFalse);
    expect(hostRunStateWords(HostRun(host: _host('a'), state: HostRunState.stopped), en), en.runOnHostsStopped);
    expect(hostRunStateWords(HostRun(host: _host('a')), en), en.runOnHostsWaiting);
    expect(hostRunStateWords(HostRun(host: _host('a'), state: HostRunState.signingIn), en), en.runOnHostsSigningIn);
    expect(hostRunStateWords(HostRun(host: _host('a'), state: HostRunState.running), en), en.runOnHostsRunning);
  });
}
