import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// A channel as the client makes one, and the messages it sends and is sent,
// are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_channel.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_message.dart';
import 'package:zestssh/services/forward_relay.dart';

/// One connection of a port forward, with both of its ends played by the
/// test: what no real socket and no real server do when a test wants it.
/// (What a forward does through a real server is in
/// port_forward_real_host_test.dart.)
void main() {
  /// Waits for what is [expected] to have come about (for no longer than five
  /// seconds), and then a little more, for anything else that would.
  Future<void> settle([bool Function()? expected]) async {
    final clock = Stopwatch()..start();
    while (expected != null && !expected() && clock.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('what comes from either end is handed to the other, and counted', () async {
    final played = Played();
    played.socket.sends.add(Uint8List(100));
    played.fromHost(200);
    await settle(() => played.toHost == 100 && played.socket.written.length == 200);
    expect(played.toHost, 100);
    expect(played.socket.written, hasLength(200));
    expect(played.counted, [100, 200]);
    expect(played.closed, 0);
  });

  test('each way ends by itself, and the connection is over when both have: this end first', () async {
    final played = Played();
    played.socket.sends.add(Uint8List(100));
    await played.socket.sends.close();
    await settle(() => played.saidDoneToHost);
    expect(played.toHost, 100);
    expect(played.saidDoneToHost, isTrue, reason: 'the host is told that no more comes');
    expect((played.closed, played.socket.destroyed, played.socket.saidDone), (0, false, false),
        reason: 'the host can still send');

    played.fromHost(300);
    await settle(() => played.socket.written.length == 300);
    expect(played.socket.written, hasLength(300));

    played.hostSaysDone();
    await settle(() => played.closed == 1);
    expect(played.socket.saidDone, isTrue, reason: 'this end is told that no more comes');
    expect((played.closed, played.socket.destroyed), (1, true));
    expect(played.channelClosed, isTrue);
  });

  test('the host first', () async {
    final played = Played();
    played.fromHost(300);
    played.hostSaysDone();
    await settle(() => played.socket.saidDone);
    expect(played.socket.written, hasLength(300));
    expect(played.socket.saidDone, isTrue);
    expect((played.closed, played.socket.destroyed, played.saidDoneToHost), (0, false, false),
        reason: 'this end can still send');

    played.socket.sends.add(Uint8List(100));
    await settle(() => played.toHost == 100);
    expect(played.toHost, 100);

    await played.socket.sends.close();
    await settle(() => played.closed == 1);
    expect(played.saidDoneToHost, isTrue);
    expect((played.closed, played.socket.destroyed), (1, true));
    expect(played.channelClosed, isTrue);
  });

  test('all that this end sent is sent to the host before the connection is ended, however long the host takes '
      'to take it', () async {
    // The host takes a thousand bytes, and no more for now.
    final played = Played(hostTakes: 1000);
    played.hostSaysDone();
    played.socket.sends.add(Uint8List(1200));
    played.socket.sends.add(Uint8List(1200));
    played.socket.sends.add(Uint8List(600));
    unawaited(played.socket.sends.close());
    await settle(() => played.toHost == 1000);
    expect(played.toHost, 1000);
    expect((played.saidDoneToHost, played.closed, played.channelClosed), (false, 0, false),
        reason: 'two thousand bytes still wait for the host');

    played.hostTakesMore(5000);
    await settle(() => played.closed == 1);
    expect(played.toHost, 3000, reason: 'the end of it was cut off');
    expect(played.saidDoneToHost, isTrue);
    expect((played.closed, played.channelClosed), (1, true));
  });

  test('an error of the socket ends what it sends: the host is told that no more comes, and is not handed the '
      'error', () async {
    final played = Played();
    played.hostSaysDone();
    played.socket.sends.add(Uint8List(100));
    played.socket.sends.addError(const SocketException('Connection reset by peer'));
    unawaited(played.socket.sends.close());
    await settle(() => played.closed == 1);
    // Nothing was thrown where nobody could catch it: this test would have failed with it.
    expect(played.toHost, 100);
    expect(played.saidDoneToHost, isTrue);
    expect((played.closed, played.socket.destroyed), (1, true));
  });

  test('writing to the socket fails: the connection is over at once, whatever this end still has to say',
      () async {
    final played = Played();
    played.socket.writeFails = const SocketException('Broken pipe');
    played.fromHost(300);
    await settle(() => played.closed == 1);
    expect((played.closed, played.socket.destroyed), (1, true));
    expect(played.channelClosed, isTrue, reason: 'the connection on the host was left open');
  });

  test('a host that ends the channel while this end still sends: the connection is over, also where the host '
      'never took a byte of it', () async {
    final played = Played();
    played.socket.sends.add(Uint8List(100));
    await settle(() => played.toHost == 100);
    played.hostCloses();
    await settle(() => played.closed == 1);
    expect((played.closed, played.socket.destroyed, played.socket.saidDone), (1, true, true));

    final never = Played(hostTakes: 0);
    never.socket.sends.add(Uint8List(100));
    await settle();
    expect(never.toHost, 0);
    never.hostCloses();
    await settle(() => never.closed == 1);
    expect((never.closed, never.socket.destroyed), (1, true));
  });

  test('small pieces are not held back: its socket is asked to send them at once', () async {
    final played = Played();
    expect(played.socket.noDelay, isTrue);
  });

  test('its socket is gone before it begins, as when its forward was stopped while the host opened the way: the '
      'channel is closed on the host, and the connection is over', () async {
    final played = Played(socketGone: true);
    await settle(() => played.closed == 1);
    expect((played.closed, played.channelClosed), (1, true));
    expect(played.socket.written, isEmpty);
  });

  test('its socket is destroyed under it, as when its forward is stopped: the channel is closed on the host, '
      'and the connection is over', () async {
    final played = Played();
    played.socket.sends.add(Uint8List(100));
    played.fromHost(200);
    await settle(() => played.toHost == 100 && played.socket.written.length == 200);
    expect(played.closed, 0);

    played.socket.destroy();
    await settle(() => played.closed == 1);
    expect((played.closed, played.channelClosed), (1, true));
  });
}

/// A connection of a forward whose socket is played by the test, and whose
/// channel is the client's own with the host played by the test.
class Played {
  Played({int hostTakes = 1 << 20, bool socketGone = false}) {
    if (socketGone) socket.destroy();
    _controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 1 << 21,
      remoteId: 2,
      remoteMaximumPacketSize: 32768,
      remoteInitialWindowSize: hostTakes,
      sendMessage: _sent.add,
    );
    relay = ForwardRelay(
      socket: socket,
      channel: SSHForwardChannel(_controller.channel),
      name: 'a played forward',
      onBytes: counted.add,
      onClosed: () => closed++,
    )..start();
  }

  late final SSHChannelController _controller;
  final _sent = <SSHMessage>[];
  final socket = PlayedSocket();
  late final ForwardRelay relay;

  /// The size of each piece that was handed on, either way.
  final counted = <int>[];

  /// How many times the connection said that it is over.
  var closed = 0;

  /// How many bytes were sent to the host.
  int get toHost => _sent.whereType<SSH_Message_Channel_Data>().fold(0, (sum, message) => sum + message.data.length);

  /// Whether the host was told that no more comes, after everything else.
  bool get saidDoneToHost {
    final end = _sent.indexWhere((message) => message is SSH_Message_Channel_EOF);
    return end != -1 && !_sent.skip(end).any((message) => message is SSH_Message_Channel_Data);
  }

  /// Whether the channel was closed on the host.
  bool get channelClosed => _sent.any((message) => message is SSH_Message_Channel_Close);

  void fromHost(int bytes) =>
      _controller.handleMessage(SSH_Message_Channel_Data(recipientChannel: 1, data: Uint8List(bytes)));

  void hostSaysDone() => _controller.handleMessage(SSH_Message_Channel_EOF(recipientChannel: 1));

  void hostCloses() => _controller.handleMessage(SSH_Message_Channel_Close(recipientChannel: 1));

  void hostTakesMore(int bytes) =>
      _controller.handleMessage(SSH_Message_Channel_Window_Adjust(recipientChannel: 1, bytesToAdd: bytes));
}

/// A socket played by the test. What the program at this end sends is put
/// into [sends]; what is written to it is kept in [written], or fails with
/// [writeFails]. Destroyed, it does what a socket of dart:io was seen to
/// do: its own stream ends, a stream that is being added to it is let go
/// of with its adding over, one that is added afterwards is over at once
/// and never listened to, and asking it for anything fails.
class PlayedSocket extends Stream<Uint8List> implements Socket {
  final sends = StreamController<Uint8List>();
  final written = <int>[];
  Object? writeFails;

  /// Whether it was told that no more comes.
  var saidDone = false;
  var destroyed = false;

  /// What it was asked for: whether small pieces leave it at once.
  bool? noDelay;

  StreamSubscription<List<int>>? _adding;
  Completer<void>? _added;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      sends.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  bool setOption(SocketOption option, bool enabled) {
    if (destroyed) throw const SocketException('Socket has been closed');
    if (option == SocketOption.tcpNoDelay) noDelay = enabled;
    return true;
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    // To one that is gone nothing is added, and nothing is waited for.
    if (destroyed) return Future<void>.value();
    final added = _added = Completer<void>();
    _adding = stream.listen(
      (piece) {
        final fails = writeFails;
        if (fails == null) {
          written.addAll(piece);
        } else if (!added.isCompleted) {
          _adding?.cancel();
          added.completeError(fails);
        }
      },
      onDone: () {
        if (!added.isCompleted) added.complete();
      },
    );
    return added.future;
  }

  @override
  Future<void> close() async => saidDone = true;

  @override
  void destroy() {
    destroyed = true;
    if (!sends.isClosed) unawaited(sends.close());
    _adding?.cancel();
    final added = _added;
    if (added != null && !added.isCompleted) added.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
