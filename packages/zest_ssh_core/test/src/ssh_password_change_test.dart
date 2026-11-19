// SPDX-License-Identifier: MIT
import 'package:test/test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_ssh_core/src/message/msg_userauth.dart';

import 'played_server.dart';

/// A server that answers a password with "change it first"
/// (SSH_MSG_USERAUTH_PASSWD_CHANGEREQ, RFC 4252 8, an expired password):
/// with no [SSHClient.onChangePasswordRequest], the client goes on to the
/// next way of signing in, as it does when that handler answers nothing. It
/// threw a null check before, and the connection ended with an internal
/// error (dartssh2 #253).
void main() {
  Future<(PlayedServer, Future<Object?>)> start({SSHChangePasswordRequestHandler? onChange}) async {
    final server = PlayedServer();
    final client = SSHClient(
      server.socket,
      username: 'deploy',
      algorithms: server.speaks,
      keepAliveInterval: null,
      onPasswordRequest: () => 'old-password',
      onUserInfoRequest: (_) => const [],
      onChangePasswordRequest: onChange,
    );
    addTearDown(client.close);
    final ended = client.authenticated.then<Object?>((_) => null, onError: (Object e) => e);
    await server.greet();
    final first = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(first.methodName, 'none');
    server.send([SSH_Message_Userauth_Failure(methodsLeft: const ['password', 'keyboard-interactive']).encode()]);
    final password = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(password.methodName, 'password');
    server.send([SSH_Message_Userauth_Passwd_ChangeReq(prompt: 'Your password has expired').encode()]);
    return (server, ended);
  }

  test('with no handler: the next way of signing in is asked, nothing thrown', () async {
    final (server, ended) = await start();
    final next = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(next.methodName, 'keyboard-interactive');
    var done = false;
    unawaited(ended.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(done, isFalse, reason: 'the sign-in goes on');
  });

  test('a handler that answers nothing: the same', () async {
    final asked = <String>[];
    final (server, _) = await start(onChange: (prompt) {
      asked.add(prompt);
      return null;
    });
    final next = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(next.methodName, 'keyboard-interactive');
    expect(asked, ['Your password has expired']);
  });
}

void unawaited(Future<void> f) {}
