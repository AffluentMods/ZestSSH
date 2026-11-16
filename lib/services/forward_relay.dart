import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/utils/logger.dart';

/// Where a forward on this device listens for [bindAddress]: the address as it
/// is, except an empty or blank one, which is this device's own loopback, as
/// the app shows it everywhere (network_bind_confirm.dart, "127.0.0.1").
/// `ServerSocket.bind('')` asks the system for an address of this computer,
/// and on Windows that was one on the network (a link-local IPv6 address,
/// seen 4 November 2026): a SOCKS forward from a shared host file or a backup
/// with no bind address listened where anyone on the same Wi-Fi could use it
/// (found in a security review). Local forwards and the proxy listen through it.
String forwardListenAddress(String bindAddress) => bindAddress.trim().isEmpty ? '127.0.0.1' : bindAddress;

/// One connection of a port forward: a socket on this device and a channel
/// through the SSH connection, with what comes from either handed to the
/// other. Local forwards, remote forwards and the proxy all use it.
///
/// Each way is read no faster than the other side takes it. (A forward
/// handed on whatever came, as fast as it came: where one side read slower
/// than the other wrote, a download through a forward that is saved to a
/// slow disk or stopped for a while, everything the writer could send was
/// taken and waited in this app's memory.)
///
/// Each way ends by itself. A side that has sent all it has says so, and
/// is still sent what the other side has: the end of either way was taken
/// for the end of both, so a program that sends its request, says that it
/// is done and reads the answer had the answer cut off. The connection is
/// over when both ways are, or when the way from the host fails.
///
/// Whoever wants it over destroys the socket: its two ways end with it.
class ForwardRelay {
  ForwardRelay({
    required this.socket,
    required this.channel,
    required this.name,
    required this.onClosed,
    this.onBytes,
  });

  final Socket socket;
  final SSHForwardChannel channel;

  /// What this is a connection of, for the log.
  final String name;

  /// Called when the connection is over.
  final void Function() onClosed;

  /// Told the size of every piece that is handed on, either way.
  final void Function(int bytes)? onBytes;

  /// Begins. [fromSocket] is what is still to come from the socket where
  /// somebody has read from it already (the proxy, which reads where to
  /// connect to first), and the socket itself otherwise.
  void start({Stream<Uint8List>? fromSocket}) {
    // Small pieces leave at once, as with OpenSSH's own forwards. Left as a
    // socket is to begin with, the second of two small pieces waits until
    // the first has been acknowledged: forty milliseconds and more on Linux,
    // now and then, for an answer that comes in two pieces.
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on SocketException {
      // The socket is gone already (its forward was stopped while the host
      // opened the way). What follows is over at once.
    }
    unawaited(_run(fromSocket ?? socket));
  }

  Future<void> _run(Stream<Uint8List> outgoing) async {
    try {
      await Future.wait([_toHost(outgoing), _fromHost()], eagerError: true);
    } catch (error) {
      AppLogger.debug('$name: ended by $error');
    }
    // Whatever is still open of either end.
    channel.destroy();
    socket.destroy();
    onClosed();
  }

  /// From this device to the host, and then that no more comes. Over when
  /// that has been sent, or when the channel has ended: one that has takes
  /// nothing more, and where its other side never took anything, nothing
  /// that waited to be sent says so.
  Future<void> _toHost(Stream<Uint8List> outgoing) => Future.any([_send(outgoing), channel.done]);

  Future<void> _send(Stream<Uint8List> outgoing) async {
    // An error of the socket's is the end of what it sends, and nothing to
    // hand on: in the channel it would be thrown where nobody catches it.
    await channel.sink.addStream(_counted(outgoing.handleError((Object _) {})));
    // And that no more comes. (The sink has taken that when all that was
    // written before it has been sent.)
    await channel.sink.close();
  }

  /// From the host to this device, and then that no more comes.
  Future<void> _fromHost() async {
    await socket.addStream(_counted(channel.stream));
    await socket.close();
  }

  Stream<Uint8List> _counted(Stream<Uint8List> pieces) {
    final told = onBytes;
    if (told == null) return pieces;
    return pieces.map((piece) {
      told(piece.length);
      return piece;
    });
  }
}
