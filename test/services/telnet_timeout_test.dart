// Telnet is held to the Connection timeout of Settings, as SSH and serial
// are: it opened its socket with no timeout, so a host that did not answer
// was waited for as long as the system waits (some twenty seconds or more),
// whatever the setting said (found while checking the 3.0 docs).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/telnet_service.dart';

void main() {
  tearDown(() => TelnetService.openSocket = Socket.connect);

  test('the socket is opened with the timeout the service was given', () async {
    Duration? asked;
    TelnetService.openSocket = (host, port, {timeout}) async {
      asked = timeout;
      throw const SocketException('no answer');
    };
    final telnet = TelnetService(host: 'switch.example.com', port: 23, connectTimeout: const Duration(seconds: 7));
    await expectLater(telnet.connect(), throwsA(isA<SocketException>()));
    expect(asked, const Duration(seconds: 7));
  });

}
