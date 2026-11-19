// Remote screens (4.0): an RDP host's RD Gateway in its
// options, read leniently, written only where there is one, and a gateway this
// version cannot read kept as it came (the host is then refused, never opened
// without it).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/model/rdp_gateway_offered.dart';
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

  test('a column too long drops the keys it keeps for later versions, but never a gateway it cannot read', () {
    final raw = jsonEncode({
      'v': 1,
      'gateway': {'host': 'a b'},
      'later': 'x' * (ScreenOptions.maxChars - 200),
      'later2': 'y' * 300,
    });
    final o = ScreenOptions.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final saved = jsonDecode(o.encode()) as Map<String, Object?>;
    expect(saved.containsKey('later'), isFalse);
    expect(saved['gateway'], {'host': 'a b'}, reason: 'without it the host would open directly');
  });

  test('every build offers the gateway once it ships; before that, only a development build made to try it', () {
    expect(kRdpGatewayShipped, isTrue);
    expect(ProviderContainer().read(rdpGatewayOfferedProvider), isTrue);
    for (final official in [false, true]) {
      for (final tryBuild in [false, true]) {
        expect(rdpGatewayOffered(shipped: true, tryBuild: tryBuild, official: official), isTrue);
      }
    }
    expect(rdpGatewayOffered(shipped: false, tryBuild: false, official: false), isFalse);
    expect(rdpGatewayOffered(shipped: false, tryBuild: true, official: false), isTrue);
    expect(rdpGatewayOffered(shipped: false, tryBuild: true, official: true), isFalse,
        reason: "never by an official build's .env");
  });

  test('a column this version cannot read at all that names a gateway is a gateway it cannot read, never none', () {
    for (final raw in [
      '{"v":1,"gateway":{"host":"rdg.example.test"},"x":"${'x' * ScreenOptions.maxChars}"}',
      '{"v":1,"gateway":{"host":"rdg.example.test"}',
      '["gateway"]',
    ]) {
      final o = ScreenOptions.decode(raw);
      expect(o.gateway, ScreenGateway.unreadable, reason: raw.length > 30 ? raw.substring(0, 30) : raw);
      // Written back as one: still refused, never opened directly.
      expect(ScreenOptions.decode(o.encode()).gateway, ScreenGateway.unreadable);
    }
    expect(ScreenOptions.decode('{"v":1,"x":"${'x' * ScreenOptions.maxChars}"}').gateway, isNull);
    expect(ScreenOptions.decode('not json').gateway, isNull);
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
