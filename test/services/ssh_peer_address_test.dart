import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A connection's socket that ends at once: enough for SshService to have
/// opened it and read its peer before the sign-in fails.
class _Socket implements SSHSocket {
  _Socket() {
    _out.stream.listen((_) {});
    scheduleMicrotask(_in.close);
  }

  final _in = StreamController<Uint8List>();
  final _out = StreamController<List<int>>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _in.stream;

  @override
  StreamSink<List<int>> get sink => _out.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// The platform's own TCP socket, which knows the address it reached.
class _PeerSocket extends _Socket implements SSHSocketPeer {
  @override
  String? get remoteAddress => '192.0.2.50';
}

/// SshService.peerAddress, where a built-in Mosh session sends its UDP, is
/// the address of the server itself or null: a direct connection's, never a
/// jump host's or a proxy's, whose socket's peer is not the server. (Found in a
/// security review of Mosh.)
void main() {
  late List<String> opened;

  SshService service({SSHSocket? tunnel}) => SshService(
        host: 'web.example.com',
        port: 22,
        username: 'demo',
        password: 'not used',
        onHostKeyVerify: (host, port, key) async => true,
        tunnelSocket: tunnel,
      );

  setUp(() => opened = []);
  tearDown(() => SshService.debugOpenSocket = null);

  test('a direct connection gives the address its socket reached', () async {
    SshService.debugOpenSocket = (host, port, timeout) async {
      opened.add(host);
      return _PeerSocket();
    };
    final ssh = service();
    await expectLater(ssh.connectExec(), throwsA(anything));
    expect(opened, ['web.example.com']);
    expect(ssh.peerAddress, '192.0.2.50');
  });

  test('a socket that does not know its peer as the server (a proxy\'s) gives null', () async {
    SshService.debugOpenSocket = (host, port, timeout) async {
      opened.add(host);
      return _Socket();
    };
    final ssh = service();
    await expectLater(ssh.connectExec(), throwsA(anything));
    expect(opened, ['web.example.com']);
    expect(ssh.peerAddress, isNull);
  });

  test('through a jump host (a tunnel) it is null, even where the tunnel knows a peer', () async {
    SshService.debugOpenSocket = (host, port, timeout) async {
      opened.add(host);
      return _PeerSocket();
    };
    final ssh = service(tunnel: _PeerSocket());
    await expectLater(ssh.connectExec(), throwsA(anything));
    expect(opened, isEmpty, reason: 'the tunnel is the connection: nothing is dialled');
    expect(ssh.peerAddress, isNull);
  });
}
