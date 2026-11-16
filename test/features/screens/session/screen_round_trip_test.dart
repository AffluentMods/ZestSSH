// Remote screens (4.0): whose round trip a session's details may
// show. Only a screen on the SSH host that carries it has one: the time to
// the SSH host is then the time to the screen. A screen on another computer
// behind the host, and one reached directly, show none.
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/session/screen_round_trip.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';

void main() {
  test('the computer itself by its names: localhost and the loopback addresses, with or without brackets', () {
    for (final host in ['localhost', 'LOCALHOST', ' localhost ', '127.0.0.1', '127.0.1.1', '127.255.255.254', '::1', '[::1]', '0:0:0:0:0:0:0:1']) {
      expect(isLoopbackHost(host), isTrue, reason: host);
    }
    for (final host in [
      '',
      '10.50.0.7',
      '192.0.2.10',
      '126.0.0.1',
      '128.0.0.1',
      '127.0.0',
      '127.0.0.1.5',
      '127.0.0.256',
      '127.0.0.x',
      '127.0.0.0001',
      '1127.0.0.1',
      'localhost.example.test',
      'notlocalhost',
      '::2',
      '[::1',
      'pc.example.test',
    ]) {
      expect(isLoopbackHost(host), isFalse, reason: host);
    }
  });

  test('a screen is on its SSH host where it is a socket or a program there, or a port of the host itself', () {
    expect(screenIsOnItsCarrier(const UnixSocketTarget('~/.vnc/desk.sock')), isTrue);
    expect(screenIsOnItsCarrier(XProgramTarget('xterm', 1280, 800)), isTrue);
    expect(screenIsOnItsCarrier(const TcpTarget('localhost', 5901)), isTrue);
    expect(screenIsOnItsCarrier(const TcpTarget('127.0.0.1', 3389)), isTrue);
    expect(screenIsOnItsCarrier(const TcpTarget('[::1]', 5900)), isTrue);
    // Another computer behind the SSH host: the host's time is not the screen's.
    expect(screenIsOnItsCarrier(const TcpTarget('10.50.0.7', 3389)), isFalse);
    expect(screenIsOnItsCarrier(const TcpTarget('desk.example.test', 5900)), isFalse);
    // Reached directly: no SSH connection to ask.
    expect(screenIsOnItsCarrier(const DirectTlsTarget('desk.example.test', 5900)), isFalse);
  });
}
