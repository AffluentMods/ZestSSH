import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/services/serial_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// A host that signs someone in and then gives them no terminal, on a real
/// OpenSSH server: a key the server allows no terminal (`no-pty` in
/// authorized_keys, as on accounts kept for commands or forwarding only).
/// Connecting failed, as it must, and left the signed-in connection open
/// behind the failure: nothing held it any more, so nothing ever closed it,
/// and it stayed, kept alive, until the app was closed. And what the person
/// was told was the SSH library's own text, as "an unexpected error".
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it and makes the keys); `client_restricted_ed25519` is the key it
/// gives no terminal. Skips itself when the server is not running. Override
/// the location with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  SSHKeyPair? restricted;
  SSHKeyPair? free;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final restrictedFile = File('$dir/client_restricted_ed25519');
      final freeFile = File('$dir/client_ed25519');
      up = restrictedFile.existsSync() && freeFile.existsSync();
      if (up) {
        restricted = SSHKeyPair.fromPem(restrictedFile.readAsStringSync()).single;
        free = SSHKeyPair.fromPem(freeFile.readAsStringSync()).single;
      }
    } catch (_) {
      up = false;
    }
  });

  setUp(() => L10nGlobal.update(en));

  SshService service(
    SSHKeyPair key,
    SSHSocket socket, {
    List<String>? log,
    List<SSHClient>? jumps,
    void Function(String line)? onLog,
  }) =>
      SshService(
        host: host,
        port: port,
        username: user,
        keyPairs: [key],
        onHostKeyVerify: (_, _, _) async => true,
        onLog: onLog ?? log?.add,
        tunnelSocket: socket,
        jumpClients: jumps,
      );

  test('signed in and then refused a terminal: said as that, and the connection is closed with it', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    // A connection it came through, as a jump host is one.
    final jump = SSHClient(await SSHSocket.connect(host, port), username: user, identities: [free!]);
    addTearDown(jump.close);
    await jump.authenticated;

    final socket = _Watched(await SSHSocket.connect(host, port));
    final log = <String>[];
    final ssh = service(restricted!, socket, log: log, jumps: [jump]);
    Object? failure;
    try {
      await ssh.connect().timeout(const Duration(seconds: 20));
    } catch (e) {
      failure = e;
    }
    expect(log.where((line) => line.startsWith('ssh_auth: SSH_AUTH_SUCCESS')), hasLength(1), reason: 'it signed in');

    // What it is: the host's refusal of a terminal, with what the library
    // said kept for the report.
    expect(failure, isA<SshNoSessionException>());
    final noSession = failure! as SshNoSessionException;
    expect(noSession.kind, NoSessionKind.terminal);
    expect(noSession.cause, isA<SSHChannelRequestError>().having((e) => e.message, 'message', 'Failed to start pty'));
    expect('$noSession', 'No session after sign-in (terminal): SSHChannelRequestError(Failed to start pty)');
    expect(log, contains('ssh_channel: No session - SSHChannelRequestError(Failed to start pty)'));

    // What the person is told: the app's own words, shown as they are.
    final kept = connectionFailureText(noSession);
    expect(kept, '$kSaidByApp${en.connNoTerminal}');
    final shown = ConnectionError.translate(kept, host: 'web-01', port: 22, username: 'deploy');
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, en.connNoTerminal);

    // Nothing holds the connection after the failure: it is closed with it,
    // and so is what it came through.
    await socket.ended.timeout(const Duration(seconds: 5));
    await jump.done.timeout(const Duration(seconds: 5));
    expect(jump.isClosed, isTrue);
    expect(ssh.isConnected, isFalse);
    // (Asked to disconnect after that, as a session that goes away asks: nothing more to do, and no error.)
    await ssh.disconnect();
  });

  test('a console server reached over SSH that gives no terminal: the same, said and closed', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final log = <String>[];
    final serial = SerialOverSshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [restricted!],
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
    );
    Object? failure;
    try {
      await serial.connect().timeout(const Duration(seconds: 20));
    } catch (e) {
      failure = e;
    }
    expect(log.where((line) => line.startsWith('ssh_auth: SSH_AUTH_SUCCESS')), hasLength(1), reason: 'it signed in');
    expect(failure, isA<SshNoSessionException>().having((e) => e.kind, 'kind', NoSessionKind.terminal));
    expect(connectionFailureText(failure!), '$kSaidByApp${en.connNoTerminal}');
    expect(log, contains('serial: No session - SSHChannelRequestError(Failed to start pty)'));
    final client = serial.debugClient!;
    await client.done.timeout(const Duration(seconds: 5));
    expect(client.isClosed, isTrue);
    expect(serial.isConnected, isFalse);
    await serial.disconnect();
  });

  test('a key that may have a terminal connects as before, and its connection stays', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final socket = _Watched(await SSHSocket.connect(host, port));
    final ssh = service(free!, socket);
    await ssh.connect().timeout(const Duration(seconds: 20));
    expect(ssh.isConnected, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(socket.isEnded, isFalse);
    await ssh.disconnect();
    await socket.ended.timeout(const Duration(seconds: 5));
  });

  /// Connects with a key that may have a terminal. From the moment the
  /// session is asked for, nothing the host says is heard (the channel for
  /// the session is being opened, and its answer does not come), and a
  /// moment later [then] is done to the connection. What connecting failed
  /// with, and the connection.
  Future<(Object?, _Watched, SshService)> interrupted(void Function(_Watched socket) then) async {
    final socket = _Watched(await SSHSocket.connect(host, port));
    final ssh = service(free!, socket, onLog: (line) {
      if (line != 'ssh_channel: Opening PTY (xterm-256color)') return;
      socket.hold = true;
      Future<void>.delayed(const Duration(milliseconds: 300), () => then(socket));
    });
    Object? failure;
    try {
      await ssh.connect().timeout(const Duration(seconds: 20));
    } catch (e) {
      failure = e;
    }
    expect(socket.hold, isTrue, reason: 'the session was asked for');
    return (failure, socket, ssh);
  }

  test('the network breaking while the session is asked for is said as the network breaking, and closed too',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    const reset = SocketException('Connection reset by peer');
    final (failure, socket, ssh) = await interrupted((socket) => socket.breakWith(reset));
    expect(failure, isNot(isA<SshNoSessionException>()), reason: 'not something the host did not give');
    expect(failure, isA<SSHSocketError>());
    // The library speaking, put into words as a network error ever was.
    expect(connectionFailureText(failure!), '$failure');
    expect(ConnectionError.translate('$failure', host: 'web-01', port: 22).type, ConnectionErrorType.networkError);
    await socket.ended.timeout(const Duration(seconds: 5));
    expect(ssh.isConnected, isFalse);
  });

  test('the connection closing then, with nothing said of why: said as that, where it read as a failed handshake',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final (failure, socket, ssh) = await interrupted((socket) => socket.end());
    expect(failure, isA<SshNoSessionException>());
    final noSession = failure! as SshNoSessionException;
    expect(noSession.kind, NoSessionKind.closed);
    expect(noSession.cause, isA<SSHStateError>());
    // (What it read as: the library's text, taken for an error of the SSH protocol.)
    expect(ConnectionError.translate('${noSession.cause}', host: 'web-01', port: 22).type,
        ConnectionErrorType.sshProtocol);
    final shown = ConnectionError.translate(connectionFailureText(noSession), host: 'web-01', port: 22);
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, en.connNoSessionClosed);
    await socket.ended.timeout(const Duration(seconds: 5));
    expect(ssh.isConnected, isFalse);
  });
}

/// A connection to the server that says when the client has closed it, and
/// whose network can be made to break.
class _Watched implements SSHSocket {
  _Watched(this._inner) {
    _sub = _inner.stream.listen(
      (data) {
        if (!hold) _out.add(data);
      },
      onError: _out.addError,
      onDone: _out.close,
    );
  }

  /// While true, what the host sends is dropped.
  bool hold = false;

  final SSHSocket _inner;
  final _out = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _sub;
  final _ended = Completer<void>();

  /// Completes once the client has closed or destroyed the connection.
  Future<void> get ended => _ended.future;
  bool get isEnded => _ended.isCompleted;

  void breakWith(Object error) => _out.addError(error);

  /// The other side closes the connection, with no error.
  void end() => _out.close();

  void _end() {
    if (!_ended.isCompleted) _ended.complete();
  }

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() {
    _end();
    return _inner.close();
  }

  @override
  void destroy() {
    _end();
    _sub.cancel();
    _inner.destroy();
  }
}
