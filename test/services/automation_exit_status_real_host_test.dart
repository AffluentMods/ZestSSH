import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

/// What a task says of a command by how the command ended (3.0, from the
/// SSH core's audit), on a real OpenSSH server.
///
/// Two things were wrong. How a command ended was lost when it ended at
/// once: the server's word of it came in the same read as its yes to the
/// command, and the SSH library dropped it. And a command with no exit
/// status counted as one that succeeded: so a command that failed at once
/// was now and then recorded as done, and so was every command that a
/// signal ended, or whose connection dropped under it.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it); its own client key logs in. Skips itself when the server is
/// not running. Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT /
/// _USER / _DIR.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  List<SSHKeyPair>? keys;
  SSHHostKey? hostKey;
  late AppDatabase tree;
  late AutomationService tasks;

  setUpAll(() async {
    try {
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (!up) return;
      keys = SSHKeyPair.fromPem(file.readAsStringSync());
      // The server's host key, as a person approves it once before a task may run there.
      final client = SSHClient(
        await SSHSocket.connect(host, port, timeout: const Duration(seconds: 2)),
        username: user,
        identities: keys,
        onVerifyHostKey: (type, bytes) {
          hostKey = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
          return true;
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 20));
      client.close();
    } catch (_) {
      up = false;
    }
  });

  setUp(() async {
    L10nGlobal.update(en);
    FlutterSecureStorage.setMockInitialValues({});
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    tasks = AutomationService(tree, const FlutterSecureStorage());
    if (up) await KnownHostsService(tree.knownHostsDao).trustHost(host, port, hostKey!);
  });

  tearDown(() async {
    tasks.dispose();
    await tree.close();
  });

  /// [command] as a task runs it, on a connection that hands over what the
  /// server sends once it has stopped sending for a moment: the server's
  /// yes to a command and the end of a command that ends at once come in
  /// one read, as they do on a link that is slow, or through a jump host.
  Future<AutomationResult> run(String command, {List<SSHKeyPair>? as, Duration? timeout}) async =>
      tasks.debugExecute(
        host: host,
        port: port,
        username: user,
        keyPairs: as ?? keys,
        command: command,
        timeout: timeout ?? const Duration(seconds: 30),
        socket: _InBatches(await SSHSocket.connect(host, port)),
      );

  test('a command that fails at once is a task that failed, with its exit status', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final result = await run('exit 3');
    expect(result.exitCode, 3);
    expect(result.success, isFalse);
    expect(result.error, isEmpty);
  });

  test('with what it printed, and a command that ends well is a task that succeeded', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final failed = await run('echo out; echo no such file >&2; exit 2');
    expect(failed.success, isFalse);
    expect(failed.exitCode, 2);
    expect(failed.output, 'out\n');
    expect(failed.error, 'no such file\n');

    final done = await run('echo done');
    expect(done.success, isTrue);
    expect(done.exitCode, 0);
    expect(done.output, 'done\n');
  });

  test('a command that a signal ended is no success, and the task says which signal', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final result = await run(r'echo started; kill -TERM $$');
    expect(result.success, isFalse);
    expect(result.exitCode, isNull);
    expect(result.output, 'started\n');
    expect(result.error, en.automationSvcEndedBySignal('TERM'));
  });

  test('a command whose connection ended under it is no success, and the task says so', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    // The command ends the server's side of its own connection, as a
    // network that breaks or a host that goes down ends it.
    // (It waits a moment first, so that what it printed has gone out.)
    final result = await run(r'echo half way; echo warn >&2; sleep 0.5; kill -KILL $PPID; sleep 5');
    expect(result.success, isFalse);
    expect(result.exitCode, isNull);
    expect(result.output, 'half way\n');
    expect(result.error, 'warn\n${en.automationSvcConnectionEnded}');
  });

  test('a command that closes what it prints to and goes on running, past the time allowed for it: no success, '
      'and the task says so, with what it had printed', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final result = await run('echo step 1; exec >&- 2>&-; sleep 30', timeout: const Duration(seconds: 6));
    expect(result.success, isFalse);
    expect(result.exitCode, isNull);
    expect(result.output, 'step 1\n');
    expect(result.error, en.automationSvcStillRunning);
  });

  test('a command that is still printing when the time allowed for it is up: no success, and the task has what the '
      'command had printed until then, and says that it had not ended', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final result = await run('echo started; echo careful >&2; sleep 20', timeout: const Duration(seconds: 5));
    expect(result.success, isFalse);
    expect(result.exitCode, isNull);
    expect(result.output, 'started\n');
    expect(result.error, 'careful\n${en.automationSvcStillRunning}');
    expect(result.elapsed, lessThan(const Duration(seconds: 9)));
  });

  test('a host that does not answer the sign-in in the time allowed for the task: said in the app\'s words, with '
      'how long that was', () async {
    final result = await tasks.debugExecute(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      command: 'echo never',
      timeout: const Duration(seconds: 2),
      socket: _Silent(),
    );
    expect(result.success, isFalse);
    expect(result.output, isEmpty);
    expect(result.error, 'The sign-in had not finished when the time allowed was up (2s).');
  });

  test('a host that refuses the connection: the task says what a session would be told', () async {
    // A port of this device that nothing listens on.
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = taken.port;
    await taken.close();
    final result = await tasks.debugExecute(host: '127.0.0.1', port: closed, username: 'deploy', command: 'echo never');
    expect(result.success, isFalse);
    expect(result.output, isEmpty);
    expect(result.error, '127.0.0.1 is not accepting connections on port $closed.');
  });

  test('a host that knows none of the keys: the task says what a session would be told', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final unknown = SSHKeyPair.fromPem((await KeyGenerationService().generateEd25519(comment: 'unknown')).privatePem);
    final result = await run('echo never', as: unknown);
    expect(result.success, isFalse);
    expect(result.output, isEmpty);
    // (It was "The server closed the connection before completing login.", which a session was given for it too:
    // the host refused the key, and closed nothing. The key is all that was tried, and so it is the key.)
    expect(result.error, 'The server rejected your SSH key. ($user@$host)');
  });

  test('a host whose key this device does not know, or knows another of: nothing is run, and the task says which, '
      'and what to do', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    // A device that never connected to the host.
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    final unattended = AutomationService(fresh, const FlutterSecureStorage());
    addTearDown(() async {
      unattended.dispose();
      await fresh.close();
    });
    Future<AutomationResult> on(AutomationService service) =>
        service.debugExecute(host: host, port: port, username: user, keyPairs: keys, command: 'echo ran');
    final unknown = await on(unattended);
    expect(unknown.success, isFalse);
    expect(unknown.output, isEmpty);
    expect(unknown.error, en.automationSvcHostKeyUnknown);
    expect(await fresh.knownHostsDao.getAll(), isEmpty, reason: 'and the key is not taken for known from here on');

    // A device that knows another key for it.
    final other = SSHHostKey(type: hostKey!.type, bytes: Uint8List.fromList(hostKey!.bytes.reversed.toList()));
    await KnownHostsService(fresh.knownHostsDao).trustHost(host, port, other);
    final changed = await on(unattended);
    expect(changed.success, isFalse);
    expect(changed.output, isEmpty);
    expect(changed.error, en.automationSvcHostKeyChanged);

    // The device of the other tests knows it: the same command runs.
    expect((await on(tasks)).output, 'ran\n');
  });

  test('a command that prints far more than a task keeps goes on to its end: the task has the first megabyte, says '
      'that the rest was cut, and how the command ended', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    // (Three letters first, and a moment before the rest, so that they come as a piece of their own and the
    // megabyte does not end where a piece of what the host sends ends.)
    final result = await run("printf abc; sleep 1; head -c 6000000 /dev/zero | tr '\\0' a; echo; echo the end >&2; exit 3",
        timeout: const Duration(seconds: 40));
    expect(result.exitCode, 3);
    expect(result.success, isFalse);
    expect(result.error, 'the end\n');
    const megabyte = 1024 * 1024;
    expect(result.output.length, megabyte + '\n[output truncated at 1024 KiB]'.length);
    expect(result.output.substring(0, megabyte), 'abc${'a' * (megabyte - 3)}');
    expect(result.output.substring(megabyte), '\n[output truncated at 1024 KiB]');
    expect(result.elapsed, lessThan(const Duration(seconds: 30)));
  });

  test('a command that prints what is no text: the task has it as far as it can be read', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final result = await run("printf 'caf\\351 ok\\n'; printf 'not\\377text\\n' >&2");
    final unread = String.fromCharCode(0xFFFD);
    expect(result.success, isTrue);
    expect(result.output, 'caf$unread ok\n');
    expect(result.error, 'not${unread}text\n');
  });

  test('a host that ends the connection at sign-in, saying why: the task failed with the host\'s reason', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    // Eight keys the host does not know: it ends the connection at the sixth.
    final unknown = <SSHKeyPair>[
      for (var i = 0; i < 8; i++)
        SSHKeyPair.fromPem((await KeyGenerationService().generateEd25519(comment: 'unknown-$i')).privatePem).single,
    ];
    final result = await run('echo never', as: unknown);
    expect(result.success, isFalse);
    expect(result.output, isEmpty);
    expect(result.error, 'The host ended the connection. Its reason: Too many authentication failures');
  });
}

/// A connection whose other side takes what it is sent and says nothing.
class _Silent implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>()..stream.drain<void>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (_done.isCompleted) return;
    _done.complete();
    _incoming.close();
  }
}

/// A real socket that hands over what the other side sends once nothing
/// more has come for a moment, all of it as one read.
class _InBatches implements SSHSocket {
  _InBatches(this._socket) {
    _socket.stream.listen(
      (data) {
        _kept.add(data);
        _timer?.cancel();
        _timer = Timer(const Duration(milliseconds: 250), _handOver);
      },
      onError: _incoming.addError,
      onDone: () {
        _timer?.cancel();
        _handOver();
        _incoming.close();
      },
    );
  }

  final SSHSocket _socket;
  final _incoming = StreamController<Uint8List>(sync: true);
  final _kept = BytesBuilder();
  Timer? _timer;

  void _handOver() {
    if (_kept.isNotEmpty && !_incoming.isClosed) _incoming.add(_kept.takeBytes());
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _socket.sink;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();
}
