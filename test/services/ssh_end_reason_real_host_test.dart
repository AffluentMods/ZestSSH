import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Why a connection ended, as the SSH service says it (3.0: a
/// session whose connection dropped says why), on a real OpenSSH server: the
/// host closing it, the network breaking under it, and the host no longer
/// answering (a connection that went quiet was held to be open for as long
/// as the system held it to be: a terminal that took typing and showed
/// nothing).
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (the one
/// test/features/orchards/certs/team_certificate_login_test.dart uses); its
/// own client key logs in. Skips itself when the server is not running.
/// Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;
  SSHKeyPair? key;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    } catch (_) {
      up = false;
    }
  });

  SshService service({SSHSocket? socket, int keepAliveSeconds = 15, List<String>? log}) => SshService(
        host: host,
        port: port,
        username: user,
        keyPairs: [key!],
        keepAliveSeconds: keepAliveSeconds,
        onHostKeyVerify: (_, _, _) async => true,
        onLog: log?.add,
        tunnelSocket: socket,
      );

  test('it is a shell that can say why its connection ended (the session asks it so)', () {
    final ssh = SshService(host: host, port: port, username: 'demo', onHostKeyVerify: (_, _, _) async => true);
    expect(ssh, isA<ShellEndReason>());
  });

  test('the host closes it: said so, and not as a shell that ended', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final ssh = service();
    await ssh.connect();
    final dropped = ssh.connectionState.firstWhere((connected) => !connected);
    // The shell's parent is the server's process for this connection.
    ssh.write(Uint8List.fromList(utf8.encode('kill -9 \$PPID\r')));
    await dropped.timeout(const Duration(seconds: 15));
    expect(await ssh.endReason.timeout(const Duration(seconds: 5)), hostClosedConnection);
    expect(ssh.exitedCleanly, isFalse, reason: 'a dropped connection, not a shell that ended');
    await ssh.disconnect();
  });

  test('the network breaks under it: what the network said', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final socket = _Breakable(await SSHSocket.connect(host, port));
    final ssh = service(socket: socket);
    await ssh.connect();
    final dropped = ssh.connectionState.firstWhere((connected) => !connected);
    socket.breakWith(const SocketException('Connection reset by peer'));
    await dropped.timeout(const Duration(seconds: 15));
    final reason = await ssh.endReason.timeout(const Duration(seconds: 5));
    expect(reason, contains('Connection reset by peer'));
    expect(reason, isNot(hostClosedConnection));
    await ssh.disconnect();
  });

  test('more keys than the host lets a connection try: connecting fails with the host\'s own reason, said as its '
      'own', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    // Eight keys the host does not know: it ends the connection at the sixth.
    final unknown = <SSHKeyPair>[
      for (var i = 0; i < 8; i++)
        SSHKeyPair.fromPem((await KeyGenerationService().generateEd25519(comment: 'unknown-$i')).privatePem).single,
    ];
    final log = <String>[];
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: unknown,
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
    );
    Object? failure;
    try {
      await ssh.connect().timeout(const Duration(seconds: 30));
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<SSHAuthAbortError>());
    // Signing in comes after the keys and the host's key: these are its own words.
    expect(connectionFailureText(failure!),
        'ZestSSH: The host ended the connection. Its reason: Too many authentication failures');
    expect(ssh.isConnected, isFalse);
    // With the reason code in the connection's log, for a report.
    expect(
      log,
      contains('error: Underlying cause - SSHDisconnectError(The server ended the connection: Too many '
          'authentication failures (reason code 2))'),
    );
  });

  test('the host stops answering: the connection is given up after three keep-alives, and says so', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final socket = _Breakable(await SSHSocket.connect(host, port));
    final log = <String>[];
    final ssh = service(socket: socket, keepAliveSeconds: 1, log: log);
    await ssh.connect();
    final dropped = ssh.connectionState.firstWhere((connected) => !connected);
    // Idle and answering, it stays: two keep-alives' time, and it is still there.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(ssh.isConnected, isTrue);
    socket.quiet = true;
    final clock = Stopwatch()..start();
    await dropped.timeout(const Duration(seconds: 15));
    expect(clock.elapsed, greaterThan(const Duration(seconds: 2)), reason: 'three keep-alives, not the first');
    expect(await ssh.endReason.timeout(const Duration(seconds: 5)), hostStoppedAnswering);
    expect(ssh.exitedCleanly, isFalse, reason: 'a dropped connection, not a shell that ended');
    expect(log.where((line) => line.startsWith('ssh_keepalive: ')),
        ['ssh_keepalive: Nothing came from the server for 3 seconds: 3 keep-alives went unanswered']);
    await ssh.disconnect();
  });

  test('with keep-alives off, a connection that goes quiet is not given up by the app', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final socket = _Breakable(await SSHSocket.connect(host, port));
    final ssh = service(socket: socket, keepAliveSeconds: 0);
    await ssh.connect();
    socket.quiet = true;
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(ssh.isConnected, isTrue);
    await ssh.disconnect();
  });
}

/// A connection to the server whose network can be made to break, or to go
/// quiet.
class _Breakable implements SSHSocket {
  _Breakable(this._inner) {
    _sub = _inner.stream.listen(
      (data) {
        if (!quiet) _out.add(data);
      },
      onError: _out.addError,
      onDone: _out.close,
    );
  }

  /// While true, nothing the host says arrives.
  bool quiet = false;

  final SSHSocket _inner;
  final _out = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _sub;

  void breakWith(Object error) => _out.addError(error);

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() {
    _sub.cancel();
    _inner.destroy();
  }
}
