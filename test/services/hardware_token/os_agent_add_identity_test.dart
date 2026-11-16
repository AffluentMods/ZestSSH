import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_agent.dart';
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';
import 'package:zestssh/services/key_generation_service.dart';

/// Add to agent through the app's own agent client (os_ssh_agent.dart) and
/// a fake agent on a socket of its own: the request framed as the agent
/// protocol frames it, the agent's yes taken, its no said. (A real
/// OpenSSH agent takes the same request: the core's
/// ssh_agent_add_identity_test.dart.) Unix sockets only: skipped where the
/// system has none for Dart (Windows).
void main() {
  late Directory dir;
  late String path;
  ServerSocket? server;
  final received = <Uint8List>[];
  var answer = SSHAgentProtocol.success;

  setUp(() async {
    received.clear();
    answer = SSHAgentProtocol.success;
    dir = await Directory.systemTemp.createTemp('zest_agent_');
    path = '${dir.path}/agent.sock';
    try {
      server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    } catch (_) {
      server = null;
      return;
    }
    server!.listen((socket) {
      final buffer = <int>[];
      socket.listen((chunk) {
        buffer.addAll(chunk);
        while (buffer.length >= 4) {
          final length = ByteData.sublistView(Uint8List.fromList(buffer.sublist(0, 4))).getUint32(0);
          if (buffer.length < 4 + length) return;
          final body = Uint8List.fromList(buffer.sublist(4, 4 + length));
          buffer.removeRange(0, 4 + length);
          final reply = body[0] == SSHAgentProtocol.requestIdentities ? [12, 0, 0, 0, 0] : [answer];
          if (body[0] != SSHAgentProtocol.requestIdentities) received.add(body);
          socket.add([0, 0, 0, reply.length, ...reply]);
        }
      });
    });
  });

  tearDown(() async {
    await server?.close();
    await dir.delete(recursive: true);
  });

  test('the key is given to the agent framed as the protocol frames it, and its yes is taken', () async {
    // Windows: the app's agent there is the named pipe (Dart 3.14 binds Unix sockets on
    // Windows too, which this test took for an agent the app would talk to).
    if (server == null || Platform.isWindows) return markTestSkipped('no Unix socket agent here');
    final made = await KeyGenerationService().generateEd25519(comment: 'x');
    final key = SSHKeyPair.fromPem(made.privatePem).single;
    final request = SSHAgentProtocol.addIdentityRequest(key, comment: 'deploy', lifetime: const Duration(hours: 1));
    final agent = await OsSshAgent.open(socketPath: path);
    try {
      await addIdentityToOsAgent(agent, request);
    } finally {
      await agent.close();
    }
    expect(received.single, request);
  });

  test("the agent's no is said as a refusal", () async {
    // Windows: the app's agent there is the named pipe (Dart 3.14 binds Unix sockets on
    // Windows too, which this test took for an agent the app would talk to).
    if (server == null || Platform.isWindows) return markTestSkipped('no Unix socket agent here');
    answer = SSHAgentProtocol.failure;
    final made = await KeyGenerationService().generateEd25519(comment: 'x');
    final request = SSHAgentProtocol.addIdentityRequest(SSHKeyPair.fromPem(made.privatePem).single);
    final agent = await OsSshAgent.open(socketPath: path);
    try {
      await expectLater(addIdentityToOsAgent(agent, request), throwsA(isA<OsAgentException>()));
    } finally {
      await agent.close();
    }
  });

  test('a key sealed under a passphrase not given is said as that, before any agent is asked', () async {
    final made = await KeyGenerationService().generateEd25519(comment: 'x');
    final sealed = OpenSSHKeyFile.rewrite(made.privatePem, newPassphrase: 'p');
    final agent = _NoAgent();
    await expectLater(
      addKeyToAgent(agent, _key, sealed),
      throwsA(isA<AgentAddFailed>().having((e) => e.why, 'why', AgentAddRefusal.needsPassphrase)),
    );
    await expectLater(
      addKeyToAgent(agent, _key, sealed, passphrase: 'wrong'),
      throwsA(isA<AgentAddFailed>().having((e) => e.why, 'why', AgentAddRefusal.wrongPassphrase)),
    );
    expect(agent.asked, 0);
    await addKeyToAgent(agent, _key, sealed, passphrase: 'p');
    expect(agent.asked, 1);
  });
}

final _key = Identity(
  id: 'k',
  label: 'deploy',
  username: 'ops',
  authMethod: 'publicKey',
  usesAgent: false,
  colorIndex: 0,
  isDefault: false,
  allowUnattended: false,
  passwordAfterKey: false,
  createdAt: DateTime(2026),
);

class _NoAgent implements SystemAgent {
  @override
  Future<void> remove(Set<String> fingerprints) async {}

  var asked = 0;

  @override
  Future<void> add(Uint8List request) async => asked++;

  @override
  Future<Set<String>> fingerprints() async => const {};
}
