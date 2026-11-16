import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
// What a host says of itself with is not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_ext_info.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A host that says what it has to say of itself while its key is still
/// being asked about (3.0, from the SSH core's audit).
///
/// A host says which kinds of signature it takes, and more, right after its
/// new keys (SSH_MSG_EXT_INFO), to a client that asks for it, as the SSH
/// core does now. That is before the app has an answer about the host's
/// key: its person may be reading a fingerprint. The SSH core took nothing
/// at that point but the messages that may come at any time, and ended the
/// connection over any other.
///
/// The host is played by the test.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  test('the app\'s own service, asked about a host\'s key while the host says which signatures it takes: the '
      'connection waits for the answer, and is made with it', () async {
    final server = PlayedServer();
    final asked = Completer<void>();
    final answer = Completer<bool>();
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) {
        asked.complete();
        return answer.future;
      },
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    Object? failure;
    var ended = false;
    final connecting = ssh.connect().timeout(const Duration(seconds: 15)).then<void>((_) {
      ended = true;
    }, onError: (Object error) {
      failure = error;
      ended = true;
    });
    final letIn = server.letIn(afterNewKeys: [
      SSH_Message_ExtInfo({
        'server-sig-algs': latin1.encode('ssh-ed25519,rsa-sha2-512,rsa-sha2-256'),
        'ping@openssh.com': latin1.encode('0'),
      }).encode(),
    ]).then((_) {}, onError: (Object _) {});
    await asked.future.timeout(const Duration(seconds: 10));
    // The host has said its piece by now, and the app's person has not answered.
    await server.settle();
    await server.settle();
    expect(ended, isFalse, reason: 'the connection ended while the host\'s key was being asked about: $failure');

    answer.complete(true);
    await letIn;
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success]);
    await connecting;
    expect(failure, isNull);
    expect(ssh.isConnected, isTrue);
  });
}
