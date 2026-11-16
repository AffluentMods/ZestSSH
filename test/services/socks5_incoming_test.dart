import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/socks5_service.dart';

/// What a program says to the proxy before it is let through, read from its
/// connection: a set number of bytes at a time, then the rest as it comes,
/// with the connection listened to once. (The proxy listened to it anew for
/// each part, which a socket allows once: nothing ever got through it. What
/// it does through a real server is in port_forward_real_host_test.dart.)
void main() {
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));
  Uint8List bytes(List<int> of) => Uint8List.fromList(of);

  test('a set number of bytes, however many pieces they come in; what came beyond them is the next to be taken',
      () async {
    final socket = StreamController<Uint8List>();
    final incoming = IncomingBytes(socket.stream);

    socket.add(bytes([1, 2, 3]));
    expect(await incoming.take(2), [1, 2]);

    final next = incoming.take(3);
    socket.add(bytes([4]));
    await settle();
    socket.add(bytes([5, 6]));
    expect(await next, [3, 4, 5]);
    expect(await incoming.take(1), [6]);
    expect(await incoming.take(0), isEmpty);
  });

  test('nothing is read while nobody waits for it: what a program sends before it is let through waits where '
      'it is', () async {
    final socket = StreamController<Uint8List>();
    final incoming = IncomingBytes(socket.stream);
    await settle();
    expect(socket.isPaused, isTrue, reason: 'nobody has asked for anything');

    final asked = incoming.take(2);
    await settle();
    expect(socket.isPaused, isFalse, reason: 'somebody waits');
    socket.add(bytes([1]));
    await settle();
    expect(socket.isPaused, isFalse, reason: 'not all of it has come');
    socket.add(bytes([2, 3, 4]));
    expect(await asked, [1, 2]);
    await settle();
    expect(socket.isPaused, isTrue, reason: 'what was asked for has come');

    // What is held already is handed over without reading on.
    expect(await incoming.take(2), [3, 4]);
    expect(socket.isPaused, isTrue);
  });

  test('the end, or an error, before they came: there are none, and nothing is thrown where nobody catches it',
      () async {
    final ended = StreamController<Uint8List>();
    final incoming = IncomingBytes(ended.stream);
    ended.add(bytes([1]));
    final asked = incoming.take(2);
    await settle();
    unawaited(ended.close());
    expect(await asked, isNull);

    final broken = StreamController<Uint8List>();
    final incoming2 = IncomingBytes(broken.stream);
    final asked2 = incoming2.take(2);
    await settle();
    // As a socket does it: the error, and then the end.
    broken.addError(const SocketException('Connection reset by peer'));
    unawaited(broken.close());
    expect(await asked2, isNull);
  });

  test('the rest: what was held and not taken first, then what comes, then the end', () async {
    final socket = StreamController<Uint8List>();
    final incoming = IncomingBytes(socket.stream);
    socket.add(bytes([1, 2, 3, 4]));
    expect(await incoming.take(2), [1, 2]);

    final came = <List<int>>[];
    var over = false;
    incoming.rest().listen(came.add, onDone: () => over = true);
    await settle();
    expect(came, [
      [3, 4]
    ]);
    socket.add(bytes([5]));
    await settle();
    expect(came, [
      [3, 4],
      [5]
    ]);
    expect(over, isFalse);
    unawaited(socket.close());
    await settle();
    expect(over, isTrue);
  });

  test('nothing held: the rest is what comes', () async {
    final socket = StreamController<Uint8List>();
    final incoming = IncomingBytes(socket.stream);
    socket.add(bytes([1, 2]));
    expect(await incoming.take(2), [1, 2]);
    final came = <List<int>>[];
    incoming.rest().listen(came.add);
    socket.add(bytes([3]));
    await settle();
    expect(came, [
      [3]
    ]);
  });

  test('the rest is read only as fast as it is taken, and no more once nobody takes it', () async {
    var cancelled = false;
    final socket = StreamController<Uint8List>(onCancel: () => cancelled = true);
    final incoming = IncomingBytes(socket.stream);
    socket.add(bytes([1, 2]));
    expect(await incoming.take(2), [1, 2]);

    final rest = incoming.rest();
    await settle();
    expect(socket.isPaused, isTrue, reason: 'nobody takes the rest yet');
    final taking = rest.listen((_) {});
    await settle();
    expect(socket.isPaused, isFalse);

    taking.pause();
    await settle();
    expect(socket.isPaused, isTrue, reason: 'whoever takes it has stopped');
    taking.resume();
    await settle();
    expect(socket.isPaused, isFalse);

    await taking.cancel();
    expect(cancelled, isTrue);
  });

  test('an error while the rest is taken ends it, and is handed to nobody', () async {
    final socket = StreamController<Uint8List>();
    final incoming = IncomingBytes(socket.stream);
    socket.add(bytes([1, 2]));
    expect(await incoming.take(2), [1, 2]);

    Object? failed;
    var over = false;
    incoming.rest().listen((_) {}, onError: (Object e) => failed = e, onDone: () => over = true);
    await settle();
    socket.addError(const SocketException('Connection reset by peer'));
    unawaited(socket.close());
    await settle();
    expect(failed, isNull);
    expect(over, isTrue);
  });
}
