// Remote screens (4.0): an RDP host's RD Gateway in its
// options, read leniently, written only where there is one, and a gateway this
// version cannot read kept as it came (the host is then refused, never opened
// without it).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';

void main() {
  test('a gateway is written only where a host has one: the port where it is not 443, the key where there is one', () {
    expect(ScreenOptions.defaults.encode().contains('gateway'), isFalse, reason: 'a host without one keeps its column');
    const own = ScreenOptions(gateway: ScreenGateway(host: 'rdg.example.test'));
    expect(jsonDecode(own.encode())['gateway'], {'host': 'rdg.example.test'});
    const keyed = ScreenOptions(gateway: ScreenGateway(host: 'rdg.example.test', port: 8443, keyId: 'k1'));
    expect(jsonDecode(keyed.encode())['gateway'], {'host': 'rdg.example.test', 'port': 8443, 'key': 'k1'});
    expect(ScreenOptions.decode(keyed.encode()).gateway, keyed.gateway);
    expect(ScreenOptions.decode(own.encode()).gateway, const ScreenGateway(host: 'rdg.example.test'));
  });

  test('a gateway this version cannot read is unreadable, kept as it came, and replaced only by one set here', () {
    for (final bad in <Object?>[
      'rdg.example.test',
      {'port': 443},
      {'host': ''},
      {'host': '-oProxyCommand=x'},
      {'host': 'rdg example'},
      {'host': 'user@rdg.example.test'},
      {'host': 'rdg.example.test/path'},
      {'host': 'rdg.example.test', 'port': 0},
      {'host': 'rdg.example.test', 'port': 70000},
      {'host': 'rdg.example.test', 'port': '443'},
      {'host': 'rdg.example.test', 'key': ''},
      {'host': 'rdg.example.test', 'key': 'a b'},
      {'host': 'a' * 254},
    ]) {
      final raw = jsonEncode({'v': 1, 'target': 'tcp', 'gateway': bad});
      final o = ScreenOptions.decode(raw);
      expect(o.gateway, ScreenGateway.unreadable, reason: '$bad');
      expect(o.gateway!.readable, isFalse);
      expect(jsonDecode(o.encode())['gateway'], bad, reason: 'kept as it came: $bad');
      expect(jsonDecode(o.copyWith(viewOnly: true).encode())['gateway'], bad, reason: 'an edit keeps it');
      final set = o.copyWith(gateway: const ScreenGateway(host: 'rdg.example.test'));
      expect(jsonDecode(set.encode())['gateway'], {'host': 'rdg.example.test'});
      expect(jsonDecode(o.copyWith(clearGateway: true).encode()).containsKey('gateway'), isFalse);
    }
  });

  test('the addresses a gateway may have', () {
    for (final ok in ['rdg.example.test', '192.0.2.10', '2001:db8::7', '[2001:db8::7]', 'RDG-1', 'fe80::1%eth0']) {
      expect(ScreenGateway.hostOk(ok), isTrue, reason: ok);
    }
    for (final bad in <Object?>[null, 5, '', ' rdg', 'rdg ', '-rdg', 'a/b', r'a\b', 'a@b', 'a;b', 'a\nb', "a'b", 'a' * 254]) {
      expect(ScreenGateway.hostOk(bad), isFalse, reason: '$bad');
    }
  });
}
