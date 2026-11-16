import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// The messages of a channel are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A jump host, played: it lets a client in, takes its request for a way
/// on, and carries that way: to a real server ([carryTo]), where what the
/// client writes on the channel goes to the server and what the server
/// writes comes back on it, or to another played server behind this one
/// ([carryToAPlayedServer]), which is given the channel as its line.
///
/// What the test does with [server] is what the jump host does to its own
/// connection: hang up, say why it ends, ask for new keys.
class PlayedJumpHost {
  /// A jump host on a line of the test's making ([line]: a connection that
  /// was dialled, or a way that another played jump host carries), or one
  /// that a client is made on in the test itself ([PlayedServer.socket]).
  PlayedJumpHost({PlayedLine? line, PlayedHostKey? hostKey}) : server = PlayedServer(line: line, hostKey: hostKey);

  final PlayedServer server;
  PlayedChannel? _way;
  Socket? _target;
  var _stopped = false;
  var _quiet = false;

  /// Plays the jump host up to the point where the client is signed in.
  Future<void> letIn() => server.letIn();

  /// Takes the way on that the client asks for, and carries it to the real
  /// server at [host]:[port].
  Future<void> carryTo(String host, int port) async {
    final way = _way = await server.confirmChannel();
    final target = _target = await Socket.connect(host, port);
    target.listen(
      (bytes) {
        if (_stopped || _quiet) return;
        _send(way, bytes);
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
    unawaited(_pump(target.add));
  }

  /// Takes the way on that the client asks for, and gives it as the line
  /// of a played server behind this jump host: another jump host.
  Future<PlayedLine> carryToAPlayedServer() async {
    final way = _way = await server.confirmChannel();
    final line = _CarriedLine(this, way);
    unawaited(_pump(line._written.add));
    return line;
  }

  /// Nothing more of what the server behind writes is carried back: for
  /// while the jump host does something with its own connection that takes
  /// no other message in between (an exchange for new keys).
  void quiet() => _quiet = true;

  /// The jump host closes the way on, and keeps its connection: the server
  /// behind it ended the connection, or the jump host gave the way up.
  void closeWay() {
    final way = _way;
    if (way == null) return;
    _target?.destroy();
    server.send([
      SSH_Message_Channel_EOF(recipientChannel: way.clientId).encode(),
      SSH_Message_Channel_Close(recipientChannel: way.clientId).encode(),
    ]);
  }

  /// The end of the test: nothing is carried any more.
  void stop() {
    _stopped = true;
    _target?.destroy();
  }

  void _send(PlayedChannel way, List<int> bytes) {
    // In pieces a channel takes.
    for (var at = 0; at < bytes.length; at += 16384) {
      server.send([
        SSH_Message_Channel_Data(
          recipientChannel: way.clientId,
          data: Uint8List.fromList(bytes.sublist(at, math.min(at + 16384, bytes.length))),
        ).encode(),
      ]);
    }
  }

  /// Hands on what the client writes on the way.
  Future<void> _pump(void Function(Uint8List data) onward) async {
    while (!_stopped) {
      try {
        onward(SSH_Message_Channel_Data.decode(await server.next(SSH_Message_Channel_Data.messageId)).data);
      } on StateError {
        // Nothing came for a while, or the client has gone.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }
}

/// The way a [PlayedJumpHost] carries, as the line of a played server
/// behind it: what that server says goes to the client as data of the
/// channel, and what the client writes on the channel is what it reads.
class _CarriedLine implements PlayedLine {
  _CarriedLine(this._jump, this._way);

  final PlayedJumpHost _jump;
  final PlayedChannel _way;
  final _written = BytesBuilder(copy: true);
  var _ended = false;

  @override
  void feed(List<int> bytes) {
    if (_ended || _jump._stopped) return;
    _jump._send(_way, bytes);
  }

  @override
  Uint8List takeOutput() => _written.takeBytes();

  /// The server behind ends its side: the jump host closes the way.
  @override
  void end() {
    if (_ended) return;
    _ended = true;
    _jump.server.send([
      SSH_Message_Channel_EOF(recipientChannel: _way.clientId).encode(),
      SSH_Message_Channel_Close(recipientChannel: _way.clientId).encode(),
    ]);
  }

  /// A packet can come in more than one message of the channel.
  @override
  bool get wholePackets => false;

  @override
  bool get clientGone => _ended || _jump._stopped;
}
