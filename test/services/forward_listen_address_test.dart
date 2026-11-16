import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/forward_relay.dart';
import 'package:zestssh/services/socks5_service.dart';

/// A client the proxy only keeps until a connection comes; none comes here.
class _NoClient implements SSHClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A forward with an empty bind address (found in a security
/// review). The app counts an empty bind address as this device's loopback and
/// shows it as 127.0.0.1, but `ServerSocket.bind('')` asks the system for an
/// address of this computer: on Windows it listened on a link-local address of
/// a network card, so a SOCKS forward from a shared host file or a backup with
/// no bind address was open to anyone on the same Wi-Fi. It listens on the
/// loopback now, as the app says.
void main() {
  test('an empty or blank bind address is the loopback, any other is kept', () {
    expect(forwardListenAddress(''), '127.0.0.1');
    expect(forwardListenAddress('   '), '127.0.0.1');
    expect(forwardListenAddress('127.0.0.1'), '127.0.0.1');
    expect(forwardListenAddress('::1'), '::1');
    expect(
      forwardListenAddress('0.0.0.0'),
      '0.0.0.0',
      reason: 'chosen by the person, and asked about',
    );
    expect(forwardListenAddress('192.168.1.20'), '192.168.1.20');
  });

  test(
    'a SOCKS forward with an empty bind address listens on this device\'s loopback',
    () async {
      final proxy = Socks5ProxyServer();
      await proxy.start(_NoClient(), bindAddress: '', bindPort: 0);
      try {
        // Where it listens, not only that the loopback reaches it: a listener
        // on every address (0.0.0.0) answered the loopback too, so the test
        // could not have caught the regression (found in a review).
        expect(proxy.bindAddress, '127.0.0.1');
        expect(InternetAddress(proxy.bindAddress!).isLoopback, isTrue);
        final port = proxy.bindPort!;
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
      } finally {
        await proxy.stop();
      }
    },
  );
}
