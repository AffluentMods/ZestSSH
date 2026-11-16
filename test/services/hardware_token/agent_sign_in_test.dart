import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText, reconnectCannotHelp;
import 'package:zestssh/services/hardware_token/os_agent_key_pair.dart';
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';
import 'package:zestssh/services/serial_service.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_cert/ssh_wire.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// A sign-in with a key that an SSH agent or a hardware key holds (3.0, the
/// SSH core's audit, found while what is said of a sign-in that did not
/// happen was put right).
///
/// Two things were wrong. An agent that could not sign (not running, the
/// key no longer in it, a hardware key that was not touched) ended the
/// sign-in, as it must, with an English text that was shown as a key the
/// server had rejected, or as a connection the server had closed. And the
/// time a server is given to answer ran while the agent signed: a hardware
/// key signs when its person has touched it, which takes a person's time,
/// so a touch after more than fifteen seconds was a sign-in that failed.
///
/// The real server is the WSL test sshd on 127.0.0.1:2299 (the tests that
/// need it skip themselves when it is not running; ZESTSSH_TEST_SSHD_HOST /
/// _PORT / _USER / _DIR say where it is). No test talks to an agent of this
/// machine: the agent is played by the test, and the key pair is given the
/// name of a pipe or socket that is not there besides.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  late bool up;
  SSHKeyPair? key;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File(_keyFile());
      up = file.existsSync();
      if (up) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    } catch (_) {
      up = false;
    }
  });

  setUp(() => L10nGlobal.update(en));
  tearDown(() {
    AuthDeadline.debugPatience = null;
    OsAgentKeyPair.debugOpenAgent = null;
  });

  ConnectionError said(Object e) =>
      ConnectionError.translate(connectionFailureText(e), host: 'web-01', port: 22, username: 'deploy');

  /// The test server's client key as a key that the agent [agent] plays
  /// holds, or does not.
  OsAgentKeyPair heldBy(Future<OsSshAgent> Function({String? socketPath}) agent) {
    OsAgentKeyPair.debugOpenAgent = agent;
    return OsAgentKeyPair(
      publicKeyBlob: key!.toPublicKey().encode(),
      algorithm: 'ssh-ed25519',
      comment: 'deploy key',
      socketPath: _noAgent,
    );
  }

  /// A session that signs in with [keys], and has a saved password besides.
  (SshService, List<String>) session(List<SSHKeyPair> keys) {
    final log = <String>[];
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: keys,
      password: 'not-sent',
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
    );
    return (ssh, log);
  }

  Future<Object> failureOf(SshService ssh) async {
    try {
      await ssh.connect();
    } catch (e) {
      expect(ssh.isConnected, isFalse);
      return e;
    }
    fail('it connected');
  }

  const couldNotSign = 'The SSH agent or hardware key did not sign for this sign-in. Check that it is plugged in and '
      'unlocked: a hardware key may have been waiting for a touch or for its PIN. No other way of signing in was tried '
      'in its place.';
  const notLoaded = 'The key of this sign-in is not in the SSH agent any more. Load it into the agent again, or plug '
      'in the hardware key it is on, and connect again. No other way of signing in was tried in its place.';

  test('an agent that is not there: the sign-in is ended, and said as the agent\'s not signing', () async {
    final held = OsAgentKeyPair(
      publicKeyBlob: Uint8List.fromList(List.filled(51, 7)),
      algorithm: 'ssh-ed25519',
      socketPath: _noAgent,
    );
    Object? e;
    try {
      await held.signAsync(Uint8List(32));
    } catch (error) {
      e = error;
    }
    // It ends the sign-in for good: nothing else is tried in the key's place.
    expect(e, isA<AgentSignInAborted>());
    expect(e, isA<SSHAuthAbortError>());
    expect((e! as AgentSignInAborted).keyNotLoaded, isFalse);
    // What it could not do, for the connection's log: the name that was asked for is in it.
    expect('$e', startsWith('SSHAuthAbortError(The SSH agent or hardware key did not sign: '));
    expect('$e', contains('zestssh-test-no-such-agent'));
    expect('$e', endsWith('No other way of signing in was tried in its place.)'));
    final shown = said(e);
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, couldNotSign);
  });

  test("an agent's pipe that another account's program serves (Windows): the sign-in is ended, said as that with its "
      'code, and nothing was asked of it', () async {
    final held = OsAgentKeyPair(
      publicKeyBlob: Uint8List.fromList(List.filled(51, 7)),
      algorithm: 'ssh-ed25519',
      socketPath: _noAgent,
    );
    OsAgentKeyPair.debugOpenAgent = agentPipeOfAnotherAccount;
    Object? e;
    try {
      await held.signAsync(Uint8List(32));
    } catch (error) {
      e = error;
    }
    expect(e, isA<SSHAuthAbortError>());
    expect(e, isA<AgentSignInAborted>().having((a) => a.pipeNotYours, 'pipeNotYours', isTrue));
    expect((e! as AgentSignInAborted).keyNotLoaded, isFalse);
    expect('$e', contains('another account'));
    expect('$e', endsWith('No other way of signing in was tried in its place.)'));
    final shown = said(e);
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, ErrorCodes.withCode(en.agentPipeNotYours, ErrorCodes.agentPipeNotYours));
    expect(shown.description, endsWith('(ZS-1701)'));
  });

  test('an agent that holds the key signs in to a real server', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final (ssh, log) = session([heldBy(agentWithTheKey)]);
    await ssh.connect();
    expect(ssh.isConnected, isTrue);
    expect(log.where((line) => line.contains('Sending credentials')), isEmpty, reason: 'the key was enough');
    await ssh.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('an agent that no longer holds the key: the sign-in is ended and said as that, and the saved password is not '
      'tried in the key\'s place', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final (ssh, log) = session([heldBy(agentWithoutTheKey)]);
    final e = await failureOf(ssh);
    expect(e, isA<AgentSignInAborted>());
    expect((e as AgentSignInAborted).keyNotLoaded, isTrue);
    expect('$e', startsWith('SSHAuthAbortError(The key of this sign-in is no longer loaded in the SSH agent'));
    final shown = said(e);
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, notLoaded);
    expect(log.where((line) => line.contains('Sending credentials')), isEmpty);
    expect(log.where((line) => line.startsWith('error: Auth failed - SSHAuthAbortError(The key of this sign-in')),
        hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('an agent that will not sign, and one that answers with what is no signature: ended, said as its not signing, '
      'and nothing tried in its place', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    for (final (agent, why) in [
      (agentThatRefuses, 'Agent refused to sign: nobody touched the hardware key'),
      (agentThatAnswersNonsense, 'Agent returned a signature with no algorithm string'),
    ]) {
      final (ssh, log) = session([heldBy(agent)]);
      final e = await failureOf(ssh);
      expect(e, isA<AgentSignInAborted>(), reason: why);
      expect((e as AgentSignInAborted).keyNotLoaded, isFalse);
      expect('$e', contains(why), reason: 'what it failed with is in the log');
      expect(said(e).description, couldNotSign);
      expect(log.where((line) => line.contains('Sending credentials')), isEmpty, reason: why);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  /// A key of another host's, which the test server does not take, held by
  /// an agent that would not sign with it: a hardware key nobody touches.
  OsAgentKeyPair forAnotherHost() {
    OsAgentKeyPair.debugOpenAgent = agentThatRefuses;
    return OsAgentKeyPair(
      publicKeyBlob: _keyOfAnotherHost().toPublicKey().encode(),
      algorithm: 'ssh-ed25519',
      comment: 'the key of another host',
      socketPath: _noAgent,
    );
  }

  test('a key in the agent that the server does not take: the agent is never asked to sign with it, and the sign-in '
      'is one the server refused', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final (ssh, log) = session([forAnotherHost()]);
    final e = await failureOf(ssh);
    expect(e, isA<SSHAuthFailError>(), reason: 'the agent was asked to sign for a server that does not take its key');
    expect((e as SSHAuthFailError).methodsTried, ['publickey']);
    expect(e.serverTakes, ['publickey']);
    expect(log.where((line) => line.contains('agent') || line.contains('Agent')), isEmpty,
        reason: 'nothing is said of an agent that was not asked');
    expect(log.where((line) => line.contains('Sending credentials')), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('such a key before one the server takes does not stand in its way: signed in, with the agent never asked',
      () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final (ssh, _) = session([forAnotherHost(), key!]);
    await ssh.connect();
    expect(ssh.isConnected, isTrue);
    await ssh.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a hardware key that is touched later than a server is given to answer signs in all the same', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    // The server gets one second; the agent signs after three, as when a hardware key waits to be touched.
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final (ssh, _) = session([heldBy(agentThatTakesItsTime)]);
    final waited = Stopwatch()..start();
    await ssh.connect();
    expect(ssh.isConnected, isTrue);
    expect(waited.elapsed, greaterThan(const Duration(seconds: 3)), reason: 'the key was waited for');
    await ssh.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('any key that takes longer to sign than a server is given: signed in, at a host and at a console server', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final (ssh, _) = session([_SlowKey(key!, const Duration(seconds: 3))]);
    final waited = Stopwatch()..start();
    await ssh.connect();
    expect(ssh.isConnected, isTrue);
    expect(waited.elapsed, greaterThan(const Duration(seconds: 3)));
    await ssh.disconnect();

    final serial = SerialOverSshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [_SlowKey(key!, const Duration(seconds: 3))],
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async => true,
    );
    await serial.connect();
    expect(serial.isConnected, isTrue);
    await serial.disconnect();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('the clock still runs for the server while no key is signing: one that goes quiet after the key is given up '
      'on', () async {
    // A listener that takes the connection and says nothing: no key is ever asked to sign.
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
    final ssh = SshService(
      host: '127.0.0.1',
      port: silent.port,
      username: 'deploy',
      keyPairs: [_SlowKey(_Unasked(), const Duration(seconds: 30))],
      onHostKeyVerify: (_, _, _) async => true,
    );
    final waited = Stopwatch()..start();
    expect(await failureOf(ssh), isA<SignInTimedOut>());
    expect(waited.elapsed, lessThan(const Duration(seconds: 10)));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a jump host on the way is given its keys the same way (read from its file: no test signs in to one with an '
      'agent)', () {
    final source = File('lib/providers/terminal_providers.dart').readAsStringSync();
    expect(source, contains('identities: signingOffTheClock(hopCreds.keyPairs, hopDeadline),'));
  });

  test('connecting again by itself cannot help: the agent will not sign the next try either', () {
    expect(reconnectCannotHelp(AgentSignInAborted.keyNotLoaded()), isTrue);
    expect(reconnectCannotHelp(AgentSignInAborted.couldNotSign('the touch was not given')), isTrue);
    expect(reconnectCannotHelp(AgentSignInAborted.pipeNotYours('Refused the pipe.')), isTrue);
    // (Any other sign-in that was cut off is worth the next try, as before.)
    expect(reconnectCannotHelp(SSHAuthAbortError('Connection closed before authentication')), isFalse);
  });

  test('in every language, each its own, and neither a key that the server rejected', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      final gone = said(AgentSignInAborted.keyNotLoaded());
      final unsigned = said(AgentSignInAborted.couldNotSign('the touch was not given'));
      expect((gone.type, gone.description), (ConnectionErrorType.saidByApp, l10n.connAgentKeyNotLoaded), reason: '$locale');
      expect((unsigned.type, unsigned.description), (ConnectionErrorType.saidByApp, l10n.connAgentCouldNotSign),
          reason: '$locale');
      expect(gone.description, isNot(unsigned.description), reason: '$locale');
      final notYours = said(AgentSignInAborted.pipeNotYours('Refused the pipe.'));
      expect((notYours.type, notYours.description),
          (ConnectionErrorType.saidByApp, ErrorCodes.withCode(l10n.agentPipeNotYours, ErrorCodes.agentPipeNotYours)),
          reason: '$locale');
      expect(notYours.description, contains('OpenSSH Authentication Agent'), reason: '$locale');
      if (locale.languageCode != 'en') expect(l10n.agentPipeNotYours, isNot(en.agentPipeNotYours), reason: '$locale');
      for (final sentence in [gone.description, unsigned.description]) {
        expect(sentence, contains('SSH'), reason: '$locale');
        expect(sentence, isNot(contains(l10n.errKeyAuthFailedDesc)), reason: '$locale');
      }
      if (locale.languageCode == 'en') continue;
      expect(l10n.connAgentKeyNotLoaded, isNot(en.connAgentKeyNotLoaded), reason: '$locale');
      expect(l10n.connAgentCouldNotSign, isNot(en.connAgentCouldNotSign), reason: '$locale');
    }
  });
}

/// A pipe (on Windows) or a socket that nothing answers on.
final _noAgent = Platform.isWindows ? r'\\.\pipe\zestssh-test-no-such-agent' : '/nonexistent/zestssh-test-agent.sock';

/// Where the test server's own client key is. (Worked out here and not in
/// the tests' main: an agent that is played runs in another isolate.)
String _keyFile() {
  final env = Platform.environment;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  return '$dir/client_ed25519';
}

// What answers as the agent. Each is a top-level function: it is called in
// the isolate the signing is done in.

Future<OsSshAgent> agentWithTheKey({String? socketPath}) async => _PlayedAgent();

Future<OsSshAgent> agentWithoutTheKey({String? socketPath}) async => _PlayedAgent(holdsTheKey: false);

Future<OsSshAgent> agentThatRefuses({String? socketPath}) async => _PlayedAgent(signs: false);

Future<OsSshAgent> agentThatAnswersNonsense({String? socketPath}) async => _PlayedAgent(nonsense: true);

/// On Windows, the agent's pipe served by another account's program: refused
/// before anything is sent ([AgentPipeNotYours]).
Future<OsSshAgent> agentPipeOfAnotherAccount({String? socketPath}) async =>
    throw AgentPipeNotYours(AgentPipeServer.otherAccount);

Future<OsSshAgent> agentThatTakesItsTime({String? socketPath}) async =>
    _PlayedAgent(takes: const Duration(seconds: 3));

/// A key that the test server does not take: the key of another host.
SSHKeyPair _keyOfAnotherHost() =>
    SSHKeyPair.fromPem(File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync()).single;

/// An agent that holds the test server's client key, the key of another
/// host, and a key that is nobody's.
class _PlayedAgent implements OsSshAgent {
  _PlayedAgent({this.holdsTheKey = true, this.signs = true, this.nonsense = false, this.takes = Duration.zero});

  final bool holdsTheKey;
  final bool signs;
  final bool nonsense;
  final Duration takes;
  late final SSHKeyPair _key = SSHKeyPair.fromPem(File(_keyFile()).readAsStringSync()).single;

  @override
  Future<List<OsAgentIdentity>> listIdentities() async => [
        OsAgentIdentity(
          publicKeyBlob: (SshWireWriter()
                ..writeUtf8String('ssh-ed25519')
                ..writeString(Uint8List.fromList(List.filled(32, 9))))
              .takeBytes(),
          comment: 'another key',
        ),
        OsAgentIdentity(publicKeyBlob: _keyOfAnotherHost().toPublicKey().encode(), comment: 'the key of another host'),
        if (holdsTheKey) OsAgentIdentity(publicKeyBlob: _key.toPublicKey().encode(), comment: 'deploy key'),
      ];

  @override
  Future<Uint8List> sign({required Uint8List keyBlob, required Uint8List data, int flags = 0}) async {
    await Future<void>.delayed(takes);
    if (!signs) throw OsAgentException('Agent refused to sign: nobody touched the hardware key');
    if (nonsense) return Uint8List.fromList([0, 0, 0, 200, 1, 2, 3]);
    return _key.sign(data).encode();
  }

  @override
  Future<void> close() async {}
}

/// [_key], signing only after [_takes]: what a key on a hardware key does
/// that waits for its person's touch.
class _SlowKey extends SSHKeyPair {
  _SlowKey(this._key, this._takes);

  final SSHKeyPair _key;
  final Duration _takes;

  @override
  String get name => _key.name;

  @override
  String get type => _key.type;

  // (What it returns is the package's type of a public key, which the package does not hand out by name.)
  @override
  toPublicKey() => _key.toPublicKey();

  @override
  SSHSignature sign(Uint8List data) => _key.sign(data);

  @override
  Future<SSHSignature> signAsync(Uint8List data) async {
    await Future<void>.delayed(_takes);
    return _key.sign(data);
  }

  @override
  String toPem() => _key.toPem();
}

/// A key that no server asks to sign.
class _Unasked extends SSHKeyPair {
  @override
  String get name => 'ssh-ed25519';

  @override
  String get type => 'ssh-ed25519';

  @override
  toPublicKey() => throw StateError('nothing asks for this key');

  @override
  SSHSignature sign(Uint8List data) => throw StateError('nothing asks for this key');

  @override
  String toPem() => throw StateError('nothing asks for this key');
}
