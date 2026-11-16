import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A stand-in for ZestSSH Cloud's live line (ZestSSH Cloud's lib/stream.js)
/// on a local port. A test sees each connection, the address it asked for
/// and its sign-in message, and answers or closes it as the server would.
class FakeStreamServer {
  FakeStreamServer._(this._http);

  final HttpServer _http;

  /// Every connection so far, oldest first.
  final connections = <FakeStreamConnection>[];
  final _arrived = StreamController<FakeStreamConnection>.broadcast();
  int _taken = 0;

  static Future<FakeStreamServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = FakeStreamServer._(http);
    http.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      final connection = FakeStreamConnection._(request.uri, socket);
      server.connections.add(connection);
      server._arrived.add(connection);
    });
    return server;
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_http.port}/v1/stream');

  /// The next connection not yet taken, waiting for it to arrive.
  Future<FakeStreamConnection> next({Duration within = const Duration(seconds: 5)}) async {
    if (_taken < connections.length) return connections[_taken++];
    final connection = await _arrived.stream.first.timeout(within);
    _taken++;
    return connection;
  }

  Future<void> close() async {
    for (final c in connections) {
      await c.socket.close();
    }
    await _http.close(force: true);
    await _arrived.close();
  }
}

class FakeStreamConnection {
  FakeStreamConnection._(this.uri, this.socket) {
    socket.listen(
      (message) {
        if (!_first.isCompleted) _first.complete('$message');
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
      onError: (Object _) {},
    );
  }

  /// The address the app asked for.
  final Uri uri;
  final WebSocket socket;
  final _first = Completer<String>();
  final _done = Completer<void>();

  /// The app's first message, its sign-in.
  Future<Map<String, dynamic>> get signIn async =>
      jsonDecode(await _first.future.timeout(const Duration(seconds: 5))) as Map<String, dynamic>;

  /// Signs the app in.
  void ready() => send({'type': 'ready'});

  void send(Object message) => socket.add(message is String ? message : jsonEncode(message));

  /// Closes the line the way the server does, with one of its codes.
  Future<void> close(int code, [String reason = '']) => socket.close(code, reason);

  /// Drops the line without a word.
  Future<void> drop() => socket.close();

  /// Completes once the line is closed from either side.
  Future<void> get closed => _done.future.timeout(const Duration(seconds: 5));

  /// How the app closed the line, once it did.
  int? get closeCode => socket.closeCode;
}

/// Waits until [done] holds, checking every few milliseconds, and fails the
/// test if it never does.
Future<void> eventually(bool Function() done, {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('never happened', within);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
