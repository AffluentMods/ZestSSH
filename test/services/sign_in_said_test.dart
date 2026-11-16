import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/serial_service.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// What a session is told of a sign-in that did not happen, through the
/// app's own service: with the other side played by the test, and against a
/// REAL OpenSSH server for a sign-in that is refused (the WSL test sshd on
/// 127.0.0.1:2299; that test skips itself when it is not running;
/// ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR say where it is).
///
/// Each of these was "Authentication Failed: The server closed the
/// connection before completing login.", with a tip to check the sign-in
/// details (test/utils/error_translator_sign_in_test.dart holds the
/// sentences one by one).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  late bool up;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      up = true;
    } catch (_) {
      up = false;
    }
  });

  setUp(() => L10nGlobal.update(en));
  tearDown(() => AuthDeadline.debugPatience = null);

  /// What connecting to the other side [socket] plays fails with.
  Future<Object> failure(_HandFed socket) async {
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-sent',
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: socket,
    );
    try {
      await ssh.connect().timeout(const Duration(seconds: 20));
    } catch (e) {
      expect(ssh.isConnected, isFalse);
      return e;
    }
    fail('it connected');
  }

  ConnectionError said(Object e) =>
      ConnectionError.translate(connectionFailureText(e), host: 'web-01', port: 22, username: 'deploy');

  test('a server so old that the two find nothing in common: which kind of algorithm, and the setting to turn on '
      'where that setting has something the server offers; what the server offers where it has not', () async {
    final cases = {
      // An old device that knows one thing of a kind, which the app has with Compatibility mode on.
      _kexInit(kex: ['diffie-hellman-group14-sha1']): (
        'No matching key exchange algorithm',
        en.errAlgoTypeKeyExchange,
        null,
      ),
      _kexInit(hostKeys: ['ssh-rsa']): ('No matching host key algorithm', en.errAlgoTypeHostKey, null),
      _kexInit(ciphers: ['aes128-cbc']): ('No matching client cipher algorithm', en.errAlgoTypeCipher, null),
      // And one that knows what the app has in neither mode. (Each of these was told to turn the mode on.)
      _kexInit(kex: ['diffie-hellman-group1-sha1']): (
        'No matching key exchange algorithm',
        en.errAlgoTypeKeyExchange,
        'diffie-hellman-group1-sha1',
      ),
      _kexInit(hostKeys: ['ssh-dss']): ('No matching host key algorithm', en.errAlgoTypeHostKey, 'ssh-dss'),
      _kexInit(ciphers: ['3des-cbc']): ('No matching client cipher algorithm', en.errAlgoTypeCipher, '3des-cbc'),
    };
    for (final MapEntry(key: kexInit, value: (thrown, kind, onlyOffers)) in cases.entries) {
      final socket = _HandFed()
        ..add(_line('SSH-2.0-OldBox_1.2'))
        ..add(kexInit);
      final e = await failure(socket);
      expect(e, isA<SSHAuthAbortError>(), reason: thrown);
      expect('${(e as SSHAuthAbortError).reason}', 'SSHHandshakeError($thrown)');
      final shown = said(e);
      expect(shown.type, ConnectionErrorType.algorithmMismatch, reason: thrown);
      expect(shown.title, 'Algorithm mismatch');
      if (onlyOffers == null) {
        expect(shown.description, en.errAlgorithmMismatchDesc(kind, 'web-01'), reason: thrown);
        expect(shown.tip, contains(en.connectionEditCompatibilityMode));
      } else {
        expect(shown.description, en.errAlgorithmNoneInCommonDesc(kind, 'web-01', onlyOffers), reason: thrown);
        expect(shown.tip, en.errAlgorithmNoneInCommonTip, reason: thrown);
      }
    }
  });

  test('a host that takes the connection and then says nothing, or says what no SSH server says: the sign-in timed '
      'out, and the port is the first thing to check', () async {
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    for (final first in [
      null,
      // What a mail server says to whoever connects; it then waits for its turn.
      '220 mail.example.com ESMTP ready',
      // An SSH server that says who it is and then stands still.
      'SSH-2.0-StandsStill',
    ]) {
      final socket = _HandFed();
      if (first != null) socket.add(_line(first));
      final waited = Stopwatch()..start();
      final e = await failure(socket);
      expect(e, isA<SignInTimedOut>(), reason: '$first');
      expect((e as SignInTimedOut).duration, const Duration(seconds: 1));
      expect(waited.elapsed, lessThan(const Duration(seconds: 10)));
      final shown = said(e);
      expect(shown.type, ConnectionErrorType.signInTimedOut);
      expect(shown.title, 'Sign-in timed out');
      expect(shown.description, 'web-01 did not finish the sign-in in time.');
      expect(shown.tip, contains('Check that the port is the one the SSH server listens on.'));
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a console server that takes the connection and then says nothing: the same, in the time it is given', () async {
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final taken = <Socket>[];
    silent.listen(taken.add);
    addTearDown(() async {
      for (final s in taken) {
        s.destroy();
      }
      await silent.close();
    });
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final serial = SerialOverSshService(
      host: '127.0.0.1',
      port: silent.port,
      username: 'deploy',
      password: 'not-sent',
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async => true,
    );
    final waited = Stopwatch()..start();
    Object? e;
    try {
      await serial.connect();
    } catch (error) {
      e = error;
    }
    expect(e, isA<SignInTimedOut>());
    expect((e! as SignInTimedOut).duration, const Duration(seconds: 1));
    expect(waited.elapsed, lessThan(const Duration(seconds: 10)), reason: 'the second it was given, not fifteen');
    expect(said(e).description, 'web-01 did not finish the sign-in in time.');
    expect(serial.debugClient, isNull, reason: 'and the connection is closed');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a connection that the other side closes before the sign-in is over, and one that the network breaks', () async {
    // Closed, with no word: what a server does that is set to turn this address away.
    final closing = _HandFed()..add(_line('SSH-2.0-TestServer'));
    unawaited(closing.end());
    final closed = said(await failure(closing));
    expect(closed.type, ConnectionErrorType.authFailed);
    expect(closed.description, 'The server closed the connection before completing login. (web-01)');

    // Broken on the way.
    final breaking = _HandFed()..add(_line('SSH-2.0-TestServer'));
    breaking.fail(const SocketException('Connection reset by peer'));
    final e = await failure(breaking);
    expect(e, isA<SSHAuthAbortError>());
    expect((e as SSHAuthAbortError).reason, isA<SSHSocketError>());
    final broken = said(e);
    expect(broken.type, ConnectionErrorType.networkError);
    expect(broken.description, en.errNetworkErrorDesc('web-01'));
    expect(broken.rawError, contains('Connection reset by peer'));
  });

  test('a real server that knows none of the keys offered: it refused the sign-in, and closed nothing', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final unknown = SSHKeyPair.fromPem((await KeyGenerationService().generateEd25519(comment: 'unknown')).privatePem);
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: unknown,
      onHostKeyVerify: (_, _, _) async => true,
    );
    Object? e;
    try {
      await ssh.connect();
    } catch (error) {
      e = error;
    }
    expect(e, isA<SSHAuthFailError>());
    final shown = ConnectionError.translate(connectionFailureText(e!), host: host, port: port, username: user);
    // The key is all that was tried, and keys are all this server takes: it is the key.
    expect(shown.type, ConnectionErrorType.authKeyRejected);
    expect(shown.title, 'Key authentication failed');
    expect(shown.description, 'The server rejected your SSH key. ($user@$host)');
    expect(shown.tip, contains('authorized_keys'));
    expect(shown.rawError,
        'SSHAuthFailError(All authentication methods failed) [tried: publickey] [the server takes: publickey]');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a real server that takes only keys, and a sign-in with a password alone: nothing is sent to it, and that is '
      'what is said, with what it takes', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final log = <String>[];
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      password: 'not-sent',
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
    );
    Object? e;
    try {
      await ssh.connect();
    } catch (error) {
      e = error;
    }
    expect(e, isA<SSHAuthFailError>());
    expect(log.where((line) => line.contains('Sending credentials')), isEmpty);
    final shown = ConnectionError.translate(connectionFailureText(e!), host: host, port: port, username: user);
    expect(shown.type, ConnectionErrorType.authFailed);
    expect(
      shown.description,
      'The server takes only this for a sign-in: a key. This sign-in has none of it, so nothing was sent to the '
      'server. ($user@$host)',
    );
    expect(shown.rawError, 'SSHAuthFailError(All authentication methods failed) [tried: ] [the server takes: publickey]');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a real server that takes only keys is not sent the saved password when it refuses the key', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    // (It was: the SSH core tried what it had in an order of its own, whatever the server said it takes.)
    final unknown = SSHKeyPair.fromPem((await KeyGenerationService().generateEd25519(comment: 'unknown')).privatePem);
    final log = <String>[];
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: unknown,
      password: 'not-sent',
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
    );
    Object? e;
    try {
      await ssh.connect();
    } catch (error) {
      e = error;
    }
    expect(e, isA<SSHAuthFailError>());
    final failed = e! as SSHAuthFailError;
    expect(failed.methodsTried, ['publickey']);
    expect(failed.serverTakes, ['publickey']);
    expect(log.where((line) => line.contains('Sending credentials')), isEmpty);
    expect(log.where((line) => line.contains('The server sent a message during sign-in')), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));
}

/// [text] as a line of the exchange of versions.
Uint8List _line(String text) => Uint8List.fromList(utf8.encode('$text\r\n'));

/// What a server offers for a key exchange (SSH_MSG_KEXINIT), as a packet
/// before any keys. What is not given is what any server of today offers.
Uint8List _kexInit({
  List<String> kex = const ['curve25519-sha256'],
  List<String> hostKeys = const ['ssh-ed25519'],
  List<String> ciphers = const ['aes256-ctr'],
}) {
  Uint8List names(List<String> list) {
    final text = utf8.encode(list.join(','));
    return (BytesBuilder()
          ..add(_uint32(text.length))
          ..add(text))
        .takeBytes();
  }

  final payload = (BytesBuilder()
        ..addByte(20)
        ..add(Uint8List(16)) // the cookie
        ..add(names(kex))
        ..add(names(hostKeys))
        ..add(names(ciphers))
        ..add(names(ciphers))
        ..add(names(const ['hmac-sha2-256']))
        ..add(names(const ['hmac-sha2-256']))
        ..add(names(const ['none']))
        ..add(names(const ['none']))
        ..add(names(const []))
        ..add(names(const []))
        ..addByte(0) // no guessed packet follows
        ..add(_uint32(0)))
      .takeBytes();
  var padding = 8 - ((5 + payload.length) % 8);
  if (padding < 4) padding += 8;
  return (BytesBuilder()
        ..add(_uint32(1 + payload.length + padding))
        ..addByte(padding)
        ..add(payload)
        ..add(Uint8List(padding)))
      .takeBytes();
}

Uint8List _uint32(int value) => (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

/// A connection whose other side is the test: what is added comes in as the
/// server's bytes, and what the app sends goes nowhere.
class _HandFed implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _done = Completer<void>();

  /// Bytes from the other side.
  void add(Uint8List bytes) => _incoming.add(bytes);

  /// The other side closes the connection, with no error.
  Future<void> end() => close();

  /// The connection breaks with [error].
  void fail(Object error) => _incoming.addError(error);

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _Nowhere();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _incoming.close();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_incoming.close());
  }
}

class _Nowhere implements StreamSink<List<int>> {
  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Completer<void>().future;
}
