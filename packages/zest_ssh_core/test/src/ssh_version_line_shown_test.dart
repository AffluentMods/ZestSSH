// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_ssh_core/src/transport/ssh_events.dart';

/// The server's version line is shown and said as text of the protocol's own
/// characters, and no longer than 255 (found in a security review of
/// November 2026). It may be up to 10 KB of anything but a line feed, and it was
/// kept as it came for the session's details and for the errors that name
/// it, which reach the connection log: a carriage return, an escape (a
/// terminal's colours, its title, a link), a NUL. The line as it came still
/// goes into the exchange hash, as it must (played_server_openssh_test and
/// every test of a played server hold that).
void main() {
  test('a version line with control characters, and long: shown filtered and cut', () async {
    final hostile = 'SSH-2.0-Evil\x1b]0;owned\x07\x00\rX${'A' * 2000}';
    final socket = _QuietServerSocket();
    final client = SSHClient(socket, username: 'demo', kexInitPatience: const Duration(milliseconds: 200));
    final events = <SSHEvent>[];
    final listening = client.events.listen(events.add);
    socket.say('$hostile\r\n');

    final error = await client.authenticated.then<Object?>((_) => null, onError: (Object e) => e);
    final reason = error is SSHAuthAbortError ? error.reason : error;
    expect(reason, isA<SSHHandshakeError>());
    final said = (reason! as SSHHandshakeError).message;

    final shown = client.remoteVersion!;
    expect(shown, startsWith('SSH-2.0-Evil?'));
    expect(shown.length, lessThanOrEqualTo(255));
    expect(shown, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
    expect(said, contains(shown));
    expect(said, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
    expect(said.length, lessThan(500));
    final exchanged = events.whereType<SSHEventVersionExchange>().single;
    expect(exchanged.remoteVersion, shown);

    await listening.cancel();
    client.close();
  });

  test('a plain version line is shown as it came', () async {
    final socket = _QuietServerSocket();
    final client = SSHClient(socket, username: 'demo', kexInitPatience: const Duration(milliseconds: 100));
    socket.say('SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5\r\n');
    await client.authenticated.then<Object?>((_) => null, onError: (Object e) => e);
    expect(client.remoteVersion, 'SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5');
    client.close();
  });

  test('a line that is no SSH version is said filtered too', () async {
    final socket = _QuietServerSocket();
    final client = SSHClient(socket, username: 'demo');
    socket.say('SSH-1.5-old\x1b[2J\r\n');
    final error = await client.authenticated.then<Object?>((_) => null, onError: (Object e) => e);
    final reason = error is SSHAuthAbortError ? error.reason : error;
    expect('$reason', contains('Invalid version: SSH-1.5-old??2J'));
    client.close();
  });
}

class _QuietServerSocket implements SSHSocket {
  final _input = StreamController<Uint8List>();
  final _done = Completer<void>();

  void say(String text) => _input.add(Uint8List.fromList(latin1.encode(text)));

  @override
  Future<void> flush() async {}

  @override
  Stream<Uint8List> get stream => _input.stream;

  @override
  StreamSink<List<int>> get sink => _DroppingSink();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _input.close();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_input.close());
  }
}

class _DroppingSink implements StreamSink<List<int>> {
  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}
}
