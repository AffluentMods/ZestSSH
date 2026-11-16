// SPDX-License-Identifier: MIT
import 'package:test/test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zest_ssh_core/src/message/msg_userauth.dart';

import 'played_server.dart';

/// An `x11` channel the server opens is taken only where this connection
/// asked for X11 forwarding (the 4.0 X11 spike, 8 November 2026).
///
/// SSHClient confirmed every `x11` channel a server opened, whenever
/// onX11Forward was set, and only then handed it to the handler: a server
/// could open them on a connection that never sent an x11-req, and the
/// handler could only close what was already confirmed. Now one is refused
/// (administratively prohibited) unless a session of the connection asked
/// for X11, the server did not say no, and that session is still open; and
/// x11Filter decides before the confirmation. And the cookie of an x11-req
/// (the only lock between the host and the user's X display) was printed
/// whole in every trace by SSH_Message_Channel_Request.toString().
void main() {
  const cookie = '7c3f9a10d2e84b6f91a0c55e3d7b2f48';
  const x11 = SSHX11Config(authenticationCookie: cookie);

  /// A client signed in to a played server, with an X11 handler that keeps
  /// what it is given, and [filter] as its x11Filter.
  Future<(PlayedServer, List<SSHX11Channel>, List<String>)> signedIn({
    SSHX11ChannelFilter? filter,
    bool handler = true,
  }) async {
    final handed = <SSHX11Channel>[];
    final traces = <String>[];
    final server = await PlayedServer.signedIn(
      client: (socket, algorithms) => SSHClient(
        socket,
        username: 'deploy',
        algorithms: algorithms,
        keepAliveInterval: null,
        onX11Forward: handler ? handed.add : null,
        x11Filter: filter,
        printTrace: (line) => traces.add('$line'),
        printDebug: (line) => traces.add('$line'),
      ),
    );
    addTearDown(server.client.close);
    return (server, handed, traces);
  }

  /// The server opens an `x11` channel with its number [number].
  void openX11(PlayedServer server, int number, {String ip = '127.0.0.1', int port = 41234}) => server.send([
        SSH_Message_Channel_Open.x11(
          senderChannel: number,
          initialWindowSize: 1 << 20,
          maximumPacketSize: 32768,
          originatorIP: ip,
          originatorPort: port,
        ).encode(),
      ]);

  /// The client's refusal of the channel the server numbered [number].
  Future<SSH_Message_Channel_Open_Failure> refusal(PlayedServer server, int number) async {
    final failure = SSH_Message_Channel_Open_Failure.decode(
      await server.next(SSH_Message_Channel_Open_Failure.messageId),
    );
    expect(failure.recipientChannel, number);
    expect(failure.reasonCode, SSH_Message_Channel_Open_Failure.codeAdministrativelyProhibited);
    return failure;
  }

  /// A shell that asked for X11 forwarding, which the server granted (or
  /// refused, with [granted] false).
  Future<(PlayedChannel, Object?)> shellWithX11(PlayedServer server, {bool granted = true}) async {
    final shell = server.client.shell(pty: null, x11: x11).then<Object?>((_) => null, onError: (Object e) => e);
    final channel = await server.confirmChannel();
    final asked = await channel.nextRequest();
    expect(asked.requestType, 'x11-req');
    expect(asked.x11AuthenticationCookie, cookie, reason: 'the cookie itself still goes to the server');
    if (!granted) {
      server.send([channel.failure]);
      return (channel, await shell.timeout(PlayedServer.patience));
    }
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success]);
    return (channel, await shell.timeout(PlayedServer.patience));
  }

  group('an x11 channel the server opens', () {
    test('on a connection that never asked for X11 is refused, and never reaches the handler', () async {
      final (server, handed, _) = await signedIn();
      openX11(server, 900);
      final failure = await refusal(server, 900);
      expect(failure.description, contains('not requested'));
      expect(await server.sent(SSH_Message_Channel_Confirmation.messageId), isFalse);
      expect(handed, isEmpty);
      expect(server.client.isClosed, isFalse);
    });

    test('on a connection with a session that never asked for X11 is refused', () async {
      final (server, handed, _) = await signedIn();
      final shell = server.client.shell(pty: null);
      final channel = await server.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'shell');
      server.send([channel.success]);
      await shell.timeout(PlayedServer.patience);

      openX11(server, 901);
      await refusal(server, 901);
      expect(handed, isEmpty);
    });

    test('with no handler is refused, X11 asked for or not', () async {
      final (server, _, _) = await signedIn(handler: false);
      await shellWithX11(server);
      openX11(server, 902);
      final failure = await refusal(server, 902);
      expect(failure.description, contains('not enabled'));
    });

    test('on a session that asked for X11 is confirmed, then handed to the handler', () async {
      final (server, handed, _) = await signedIn();
      final (_, failed) = await shellWithX11(server);
      expect(failed, isNull);

      openX11(server, 903, ip: '127.0.0.1', port: 50123);
      final confirmed = SSH_Message_Channel_Confirmation.decode(
        await server.next(SSH_Message_Channel_Confirmation.messageId),
      );
      expect(confirmed.recipientChannel, 903);
      await server.settle();
      expect(handed, hasLength(1));
      expect(handed.single.originatorIP, '127.0.0.1');
      expect(handed.single.originatorPort, 50123);

      // Several, as OpenSSH allows unless single-connection was asked for.
      openX11(server, 904);
      await server.next(SSH_Message_Channel_Confirmation.messageId);
      await server.settle();
      expect(handed, hasLength(2));
    });

    test('after the server said no to X11 forwarding is refused', () async {
      final (server, handed, _) = await signedIn();
      final (_, failed) = await shellWithX11(server, granted: false);
      expect(failed, isA<SSHChannelRequestError>());
      openX11(server, 905);
      await refusal(server, 905);
      expect(handed, isEmpty);
    });

    test('after the session that asked for X11 has closed is refused', () async {
      final (server, handed, _) = await signedIn();
      final (channel, _) = await shellWithX11(server);
      server.send([channel.eof, channel.close]);
      await server.next(SSH_Message_Channel_Close.messageId);

      openX11(server, 906);
      await refusal(server, 906);
      expect(handed, isEmpty);
    });

    test('that the filter says no to is refused before it is confirmed; the filter is told where it is from', () async {
      final asked = <(String, int)>[];
      final (server, handed, _) = await signedIn(filter: (ip, port) {
        asked.add((ip, port));
        return port != 6666;
      });
      await shellWithX11(server);

      openX11(server, 907, port: 6666);
      final failure = await refusal(server, 907);
      expect(failure.description, contains('filter'));
      expect(handed, isEmpty);

      openX11(server, 908, port: 6667);
      await server.next(SSH_Message_Channel_Confirmation.messageId);
      await server.settle();
      expect(handed, hasLength(1));
      expect(asked, [('127.0.0.1', 6666), ('127.0.0.1', 6667)]);
    });

    test('that a filter throws on is refused, and the connection goes on', () async {
      final (server, handed, _) = await signedIn(filter: (_, __) => throw StateError('no display'));
      await shellWithX11(server);
      openX11(server, 909);
      await refusal(server, 909);
      expect(handed, isEmpty);
      expect(server.client.isClosed, isFalse);
    });
  });

  group('what a trace shows', () {
    test('the x11-req cookie never appears in the trace or debug lines of a connection that sent one', () async {
      final (server, _, traces) = await signedIn();
      await shellWithX11(server);
      expect(traces.where((line) => line.contains('x11-req')), isNotEmpty, reason: 'the request is traced');
      expect(traces.where((line) => line.contains(cookie)), isEmpty);
    });

    test('an x11-req says its cookie is there and how long it is, never what it is', () {
      final request = SSH_Message_Channel_Request.x11(
        recipientChannel: 3,
        wantReply: true,
        singleConnection: false,
        x11AuthenticationProtocol: 'MIT-MAGIC-COOKIE-1',
        x11AuthenticationCookie: cookie,
        x11ScreenNumber: 0,
      );
      for (final shown in ['$request', '${SSH_Message_Channel_Request.decode(request.encode())}']) {
        expect(shown, isNot(contains(cookie)));
        expect(shown, contains('MIT-MAGIC-COOKIE-1'));
        expect(shown, contains('<redacted, 32 chars>'));
      }
    });

    test('an environment variable shows its name, never its value', () {
      const value = 'ghp_s3cr3tT0kenValue';
      final request = SSH_Message_Channel_Request.env(
        recipientChannel: 3,
        variableName: 'GITHUB_TOKEN',
        variableValue: value,
        wantReply: true,
      );
      for (final shown in ['$request', '${SSH_Message_Channel_Request.decode(request.encode())}']) {
        expect(shown, isNot(contains(value)));
        expect(shown, contains('GITHUB_TOKEN'));
      }
    });

    test('an environment variable sent by a session never appears in its trace', () async {
      const value = 'hunter2-not-in-logs';
      final (server, _, traces) = await signedIn();
      final shell = server.client.shell(pty: null, environment: {'DB_PASSWORD': value});
      final channel = await server.confirmChannel();
      final asked = await channel.nextRequest();
      expect(asked.variableValue, value);
      server.send([channel.success]);
      expect((await channel.nextRequest()).requestType, 'shell');
      server.send([channel.success]);
      await shell.timeout(PlayedServer.patience);
      expect(traces.where((line) => line.contains('DB_PASSWORD')), isNotEmpty);
      expect(traces.where((line) => line.contains(value)), isEmpty);
    });

    test('a keyboard-interactive answer and a sign-in show no secret', () {
      const secret = 'correct horse battery staple';
      expect('${SSH_Message_Userauth_InfoResponse(responses: [secret])}', isNot(contains(secret)));
      expect('${SSH_Message_Userauth_Request.password(user: 'deploy', password: secret)}', isNot(contains(secret)));
      expect(
        '${SSH_Message_Userauth_Request.newPassword(user: 'deploy', oldPassword: secret, newPassword: secret)}',
        isNot(contains(secret)),
      );
    });
  });
}
