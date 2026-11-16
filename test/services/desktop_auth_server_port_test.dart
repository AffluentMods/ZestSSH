import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/desktop_auth_server.dart';

/// The website refuses a loopback callback below port 32768 (found in a security
/// review), so a sign-in on a computer must come back on one at or above it,
/// whatever the system hands out.
void main() {
  /// A server that says it is on [port].
  Future<HttpServer> real() => HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  test('the system\'s choice as it comes, on every computer as they come', () async {
    final auth = DesktopAuthServer();
    addTearDown(auth.stop);
    final url = await auth.start(nonce: 'n');
    expect(Uri.parse(url).port, greaterThanOrEqualTo(DesktopAuthServer.kLowestCallbackPort));
    expect(Uri.parse(url).host, '127.0.0.1');
  });

  test('a port too low is not used: the system is asked again, each low one held until a good one comes', () async {
    final asked = <int>[];
    final low = <_Fixed>[];
    late final HttpServer good;
    final auth = DesktopAuthServer(bind: (port) async {
      asked.add(port);
      if (asked.length < 3) {
        final server = _Fixed(1024 + asked.length, await real());
        low.add(server);
        return server;
      }
      return good = await real();
    });
    addTearDown(auth.stop);
    final url = await auth.start(nonce: 'n');
    expect(asked, [0, 0, 0]);
    expect(Uri.parse(url).port, good.port);
    expect(low.every((s) => s.closed), isTrue, reason: 'the low ones are let go');
  });

  test('where the system only hands out low ones, a port of the private range is picked here', () async {
    final asked = <int>[];
    final low = <_Fixed>[];
    late final HttpServer good;
    final auth = DesktopAuthServer(bind: (port) async {
      asked.add(port);
      if (port == 0) {
        final server = _Fixed(5000, await real());
        low.add(server);
        return server;
      }
      // The first picked is taken; the next is free.
      if (asked.where((p) => p != 0).length == 1) throw const SocketException('Address already in use');
      return good = await real();
    });
    addTearDown(auth.stop);
    final url = await auth.start(nonce: 'n');
    final picked = asked.where((p) => p != 0).toList();
    expect(picked, hasLength(2));
    expect(picked.every((p) => p >= 49152 && p <= 65535), isTrue, reason: '$picked');
    expect(Uri.parse(url).port, good.port);
    expect(low.every((s) => s.closed), isTrue);
  });

  test('none to be had: a clear error with its code, and nothing is left open', () async {
    final low = <_Fixed>[];
    var tries = 0;
    final auth = DesktopAuthServer(bind: (port) async {
      tries++;
      if (port == 0) {
        final server = _Fixed(5000, await real());
        low.add(server);
        return server;
      }
      throw SocketException('Permission denied (port $port)');
    });
    await expectLater(
      auth.start(nonce: 'n'),
      throwsA(isA<NoSignInPort>().having((e) => '$e', 'what it says', allOf(contains(ErrorCodes.signInNoPort.code), contains('Permission denied')))),
    );
    expect(tries, greaterThan(5));
    expect(low.every((s) => s.closed), isTrue);
  });
}

/// A real server that says it listens on another port.
class _Fixed implements HttpServer {
  _Fixed(this.port, this._inner);

  @override
  final int port;
  final HttpServer _inner;
  bool closed = false;

  @override
  Future<void> close({bool force = false}) {
    closed = true;
    return _inner.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
