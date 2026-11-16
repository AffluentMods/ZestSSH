import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// The messages a played server reads and sends are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_userauth.dart' show SSHUserInfoPrompt;

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A host's part in a sign-in, played by a test: it takes the ways [ways]
/// (as the names of RFC 4252); it says yes to a key where [takesKey], and to
/// [password] as a password or as the answer to its questions; its
/// keyboard-interactive questions are [rounds], one request each, in order,
/// as (text, echo).
class PlayedSignIn {
  PlayedSignIn({required this.ways, this.takesKey = false, this.password, this.rounds = const []});

  final List<String> ways;
  final bool takesKey;
  final String? password;
  final List<List<(String, bool)>> rounds;

  /// What the host saw, in order: `key?` (asked about a key), `key!`
  /// (signed with it), `password:<it>`, `questions` (asked for its
  /// questions) and `answers:<them, by commas>`.
  final seen = <String>[];

  /// The kind of each key the host was asked about, in order (a key's own,
  /// "ssh-ed25519", or its certificate's, "ssh-ed25519-cert-v01@openssh.com").
  final offered = <String>[];

  /// Plays the sign-in on [server], greeted up to the client's first request
  /// (which asks which ways the host takes), until the client is let in
  /// (true), or [over] says the client has given up, or [patience] runs out
  /// (false).
  Future<bool> play(
    PlayedServer server, {
    bool Function()? over,
    Duration patience = const Duration(seconds: 15),
  }) async {
    final first = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(first.methodName, 'none');
    Uint8List refusal() => SSH_Message_Userauth_Failure(methodsLeft: ways).encode();
    server.send([refusal()]);
    var round = 0;
    void ask() {
      final questions = rounds[round++];
      server.send([
        SSH_Message_Userauth_InfoRequest(
          name: '',
          instruction: '',
          lang: '',
          prompts: [for (final (text, echo) in questions) SSHUserInfoPrompt(text, echo)],
        ).encode(),
      ]);
    }

    void letIn() => server.send([SSH_Message_Userauth_Success().encode()]);

    final clock = Stopwatch()..start();
    while (clock.elapsed < patience && !(over?.call() ?? false)) {
      for (final payload in server.takeSent()) {
        if (payload[0] == SSH_Message_Userauth_Request.messageId) {
          final request = SSH_Message_Userauth_Request.decode(payload);
          switch (request.methodName) {
            case 'publickey' when request.signature == null:
              seen.add('key?');
              offered.add(request.publicKeyAlgorithm ?? '');
              if (takesKey) {
                server.takesKey(request);
              } else {
                server.send([refusal()]);
              }
            case 'publickey':
              seen.add('key!');
              letIn();
              return true;
            case 'password':
              seen.add('password:${request.password}');
              if (password != null && request.password == password) {
                letIn();
                return true;
              }
              server.send([refusal()]);
            case 'keyboard-interactive':
              seen.add('questions');
              ask();
          }
        } else if (payload[0] == SSH_Message_Userauth_InfoResponse.messageId) {
          final responses = SSH_Message_Userauth_InfoResponse.decode(payload).responses;
          seen.add('answers:${responses.join(',')}');
          if (round < rounds.length) {
            ask();
          } else if (password != null && responses.contains(password)) {
            letIn();
            return true;
          } else {
            server.send([refusal()]);
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  /// What a host does next for a client it let in that opens a terminal:
  /// the channel, and yes to its terminal and its shell.
  static Future<void> openShell(PlayedServer server) async {
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success]);
  }
}
