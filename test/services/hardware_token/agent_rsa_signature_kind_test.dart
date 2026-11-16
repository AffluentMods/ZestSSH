import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The classes of an RSA key and its signature are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/hostkey/hostkey_rsa.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/hardware_token/os_agent_key_pair.dart';
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';
import 'package:zestssh/services/ssh_service.dart';

/// An RSA key that an SSH agent or a hardware key holds signs in with the
/// kind of signature the host takes (3.0, from the SSH core's audit).
///
/// An agent makes the kind of RSA signature it is asked for. The app asked
/// for SHA-256 whatever the host had said it takes, so such a key was
/// refused by a host that takes only SHA-512, and by one that knows only
/// the first kind.
///
/// The agent is played by the test (no test talks to an agent of this
/// machine: the key pair is given the name of a pipe or socket that is not
/// there besides). The real servers are the two of tool/test_sshd.sh that
/// take one kind of signature from an RSA key each (127.0.0.1:2291 and
/// :2285); the tests that need them skip themselves where they are not
/// running.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final sha512Port = int.tryParse(env['ZESTSSH_TEST_SHA512_SSHD_PORT'] ?? '') ?? 2291;
  final sha1Port = int.tryParse(env['ZESTSSH_TEST_SHA1_SSHD_PORT'] ?? '') ?? 2285;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  const sha512 = 'rsa-sha2-512';
  const sha256 = 'rsa-sha2-256';
  const sha1 = 'ssh-rsa';
  final data = Uint8List.fromList('what a sign-in signs'.codeUnits);

  setUp(() => L10nGlobal.update(en));
  tearDown(() => OsAgentKeyPair.debugOpenAgent = null);

  /// Whether the server at [port] is running, and the RSA key it knows is
  /// there.
  Future<bool> up(int port) async {
    try {
      (await Socket.connect(host, port, timeout: const Duration(seconds: 2))).destroy();
      return File(_serversKeyFile()).existsSync();
    } catch (_) {
      return false;
    }
  }

  test('an RSA key in an agent says that it signs in the three ways, is announced as the kind it is made to sign '
      'with, and asks the agent for that kind; a key of another kind makes no RSA signature', () async {
    OsAgentKeyPair.debugOpenAgent = agentWithTheFixtureKey;
    final blob = _fixtureKey().toPublicKey().encode();
    final held = OsAgentKeyPair(publicKeyBlob: blob, algorithm: 'ssh-rsa', comment: 'an RSA key', socketPath: _noAgent);
    expect(held.type, sha256);
    expect(held.rsaSignatureTypes, [sha512, sha256, sha1]);
    expect(SSHRsaSignature.decode((await held.signAsync(data)).encode()).type, sha256);
    for (final kind in [sha512, sha256, sha1]) {
      final signing = held.signingAsRsa(kind);
      expect(signing, isA<OsAgentKeyPair>());
      signing as OsAgentKeyPair;
      expect(signing.type, kind);
      expect(signing.name, 'ssh-rsa');
      expect(signing.algorithm, 'ssh-rsa');
      expect(signing.comment, 'an RSA key');
      expect(signing.socketPath, _noAgent);
      expect(signing.toPublicKey().encode(), blob);
      final signature = SSHRsaSignature.decode((await signing.signAsync(data)).encode());
      expect(signature.type, kind, reason: 'the agent was asked for another kind of signature');
      expect(SSHRsaPublicKey.decode(blob).verify(data, signature), isTrue, reason: kind);
    }
    expect(() => held.signingAsRsa('rsa-sha2-384'), throwsArgumentError);

    final another = OsAgentKeyPair(
      publicKeyBlob: Uint8List.fromList(List.filled(51, 7)),
      algorithm: 'ssh-ed25519',
      socketPath: _noAgent,
    );
    expect(another.rsaSignatureTypes, isEmpty);
    expect(another.type, 'ssh-ed25519');
  });

  /// A session of the app's that signs in to the server at [port] with the
  /// RSA key the servers know, held by the agent [agent] plays.
  SshService session(int port, Future<OsSshAgent> Function({String? socketPath}) agent, {bool compatibilityMode = false}) {
    OsAgentKeyPair.debugOpenAgent = agent;
    final held = OsAgentKeyPair(
      publicKeyBlob: _serversKey().toPublicKey().encode(),
      algorithm: 'ssh-rsa',
      comment: 'an RSA key',
      socketPath: _noAgent,
    );
    return SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [held],
      compatibilityMode: compatibilityMode,
      onHostKeyVerify: (_, _, _) async => true,
    );
  }

  test('at a server that takes only SHA-512 from an RSA key: the key in the agent signs in', () async {
    if (!await up(sha512Port)) return markTestSkipped('no test sshd at $host:$sha512Port');
    final ssh = session(sha512Port, agentWithTheServersKey);
    await ssh.connect();
    expect(ssh.isConnected, isTrue);
    await ssh.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('at a server that takes only the first kind, with SHA-1: without Compatibility mode the key is not offered '
      'and the agent is never asked; with it, the key signs in', () async {
    if (!await up(sha1Port)) return markTestSkipped('no test sshd at $host:$sha1Port');
    // An agent that would not sign: were it asked, the sign-in would end as the agent's not signing.
    final without = session(sha1Port, agentWithTheServersKeyThatRefuses);
    Object? failure;
    try {
      await without.connect();
    } catch (e) {
      failure = e;
    }
    expect(without.isConnected, isFalse);
    expect(failure, isA<SSHAuthFailError>(), reason: 'the agent was asked to sign for a server that would refuse it');
    expect((failure! as SSHAuthFailError).keysPassedOver, ['ssh-rsa']);

    final withIt = session(sha1Port, agentWithTheServersKey, compatibilityMode: true);
    await withIt.connect();
    expect(withIt.isConnected, isTrue);
    await withIt.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));
}

/// A pipe (on Windows) or a socket that nothing answers on.
final _noAgent = Platform.isWindows ? r'\\.\pipe\zestssh-test-no-such-agent' : '/nonexistent/zestssh-test-agent.sock';

/// An RSA key of the package's fixtures. (Worked out here and not in the
/// tests' main: an agent that is played runs in another isolate.)
OpenSSHRsaKeyPair _fixtureKey() =>
    SSHKeyPair.fromPem(File('packages/zest_ssh_core/test/fixtures/ssh-rsa/ssh_host_rsa_key').readAsStringSync()).single
        as OpenSSHRsaKeyPair;

/// Where the RSA key is that the test servers know.
String _serversKeyFile() {
  final env = Platform.environment;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  return '$dir/client_bare_rsa';
}

OpenSSHRsaKeyPair _serversKey() =>
    SSHKeyPair.fromPem(File(_serversKeyFile()).readAsStringSync()).single as OpenSSHRsaKeyPair;

// What answers as the agent. Each is a top-level function: it is called in
// the isolate the signing is done in.

Future<OsSshAgent> agentWithTheFixtureKey({String? socketPath}) async => _PlayedAgent(_fixtureKey());

Future<OsSshAgent> agentWithTheServersKey({String? socketPath}) async => _PlayedAgent(_serversKey());

Future<OsSshAgent> agentWithTheServersKeyThatRefuses({String? socketPath}) async =>
    _PlayedAgent(_serversKey(), signs: false);

/// An agent that holds one RSA key, and signs with the kind of signature it
/// is asked for, as an agent does: with SHA-512 or SHA-256 by the flag of
/// the request, and with SHA-1 where there is none.
class _PlayedAgent implements OsSshAgent {
  _PlayedAgent(this._key, {this.signs = true});

  final OpenSSHRsaKeyPair _key;
  final bool signs;

  @override
  Future<List<OsAgentIdentity>> listIdentities() async =>
      [OsAgentIdentity(publicKeyBlob: _key.toPublicKey().encode(), comment: 'an RSA key')];

  @override
  Future<Uint8List> sign({required Uint8List keyBlob, required Uint8List data, int flags = 0}) async {
    if (!signs) throw OsAgentException('Agent refused to sign: nobody touched the hardware key');
    final kind = flags & OsAgentSignFlags.rsaSha2_512 != 0
        ? SSHRsaSignatureType.sha512
        : flags & OsAgentSignFlags.rsaSha2_256 != 0
            ? SSHRsaSignatureType.sha256
            : SSHRsaSignatureType.sha1;
    return _key.signingAsRsa(kind).sign(data).encode();
  }

  @override
  Future<void> close() async {}
}
