import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/wol_service.dart';

/// Wake-on-LAN, as the app sends it itself (3.0).
///
/// Until now a package sent the packet. It took an address to wake only in
/// the form with colons, while the host editor takes any form with 12
/// hexadecimal digits (Windows prints them with dashes): a host saved the
/// way its owner copied the address showed a Wake button that always ended
/// in "Failed to send". It never looked at whether a packet went out, so
/// "sent" could be said of one that had not; and it sent the one way the
/// system picks, which on a computer with several networks can be the
/// wrong one.
void main() {
  final mac = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0x0D, 0x0E, 0x0F]);

  group('the address to wake', () {
    test('is taken however it is written, as the host editor takes it', () {
      for (final written in [
        'AA:BB:CC:0D:0E:0F',
        'aa:bb:cc:0d:0e:0f',
        'AA-BB-CC-0D-0E-0F',
        'aabb.cc0d.0e0f',
        'AABBCC0D0E0F',
        ' AA BB CC 0D 0E 0F ',
      ]) {
        expect(WolService.macBytes(written), mac, reason: written);
        expect(WolService.isValidMac(written), isTrue, reason: written);
      }
    });

    test('is none without exactly twelve hexadecimal digits', () {
      for (final written in ['', 'AA:BB:CC:0D:0E', 'AA:BB:CC:0D:0E:0F:10', 'not a mac', 'GG:HH:II:JJ:KK:LL', '192.168.10.31']) {
        expect(WolService.macBytes(written), isNull, reason: written);
        expect(WolService.isValidMac(written), isFalse, reason: written);
      }
    });
  });

  test('the host editor asks this class what an address to wake is, and has no rule of its own', () {
    // (One rule for what may be saved and what can be sent: with two, an
    // address was saved that could never be woken.)
    final editor = File('lib/ui/screens/connection/connection_edit_screen.dart').readAsStringSync();
    expect(editor, contains('return WolService.isValidMac(v) ? null : l10n.connectionMacAddressInvalid;'));
    expect(editor, isNot(contains("replaceAll(RegExp(r'[^a-fA-F0-9]'), '')")));
  });

  test('the magic packet is six bytes of 0xFF and the address sixteen times', () {
    final packet = WolService.magicPacket(mac);
    expect(packet, hasLength(102));
    expect(packet.sublist(0, 6), List.filled(6, 0xFF));
    for (var i = 0; i < 16; i++) {
      expect(packet.sublist(6 + i * 6, 12 + i * 6), mac, reason: 'copy ${i + 1}');
    }
  });

  group('sending', () {
    /// What was sent, by a stand-in for the sockets: (from, to, port).
    late List<(String, String, int)> sends;
    late List<List<int>> packets;

    setUp(() {
      sends = [];
      packets = [];
    });

    /// A stand-in that sends nothing and says every packet went out, but
    /// for the sources named in [dead] (nothing goes out there) and [broken]
    /// (the system refuses).
    WolSendFrom sender({Set<String> dead = const {}, Set<String> broken = const {}}) =>
        (source, packet, target, port) async {
          sends.add((source.address, target.address, port));
          packets.add(packet);
          if (broken.contains(source.address)) throw const SocketException('Network is unreachable');
          return dead.contains(source.address) ? 0 : packet.length;
        };

    Future<List<InternetAddress>> none() async => [];

    /// No name is looked up for real by these tests.
    Future<List<InternetAddress>> noLookup(String name) async => throw SocketException('not looked up: $name');
    Future<List<InternetAddress>> two() async => [InternetAddress('192.168.10.50'), InternetAddress('192.168.20.50')];

    test('goes out the way the system picks and on each network of the device, to every machine by default',
        () async {
      final result = await WolService.send(macAddress: 'AA-BB-CC-0D-0E-0F', interfaces: two, sendFrom: sender());
      expect(result.sent, isTrue);
      expect(result.problem, isNull);
      expect(result.ways, 3);
      expect(sends, [
        ('0.0.0.0', '255.255.255.255', 9),
        ('192.168.10.50', '255.255.255.255', 9),
        ('192.168.20.50', '255.255.255.255', 9),
      ]);
      for (final packet in packets) {
        expect(packet, WolService.magicPacket(mac));
      }
    });

    test('to the address and the port the host names', () async {
      final result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          broadcastAddress: ' 192.168.10.255 ',
          port: 7,
          interfaces: none,
          lookup: noLookup,
          sendFrom: sender());
      expect(result.sent, isTrue);
      expect(sends, [('0.0.0.0', '192.168.10.255', 7)]);
    });

    test('an address left empty is every machine on the local network', () async {
      final result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F', broadcastAddress: '  ', interfaces: none, lookup: noLookup, sendFrom: sender());
      expect(result.sent, isTrue);
      expect(sends.single.$2, '255.255.255.255');
    });

    test('a name is looked up, for a machine reached through a forwarded port', () async {
      final asked = <String>[];
      final result = await WolService.send(
        macAddress: 'AA:BB:CC:0D:0E:0F',
        broadcastAddress: 'home.example.com',
        interfaces: none,
        lookup: (name) async {
          asked.add(name);
          return [InternetAddress('2001:db8::7'), InternetAddress('203.0.113.7')];
        },
        sendFrom: sender(),
      );
      expect(result.sent, isTrue);
      expect(asked, ['home.example.com']);
      expect(sends, [('0.0.0.0', '203.0.113.7', 9)], reason: 'its IPv4 address where it has one');
    });

    test('a name with no address, or that cannot be looked up, is said as that, and nothing is sent', () async {
      var result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          broadcastAddress: 'nowhere.example.com',
          interfaces: none,
          lookup: (_) async => [],
          sendFrom: sender());
      expect(result.sent, isFalse);
      expect(result.problem, WolProblem.badAddress);
      expect(result.detail, contains('nowhere.example.com'));
      result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          broadcastAddress: 'nowhere.example.com',
          interfaces: none,
          lookup: (_) async => throw const SocketException('Failed host lookup'),
          sendFrom: sender());
      expect(result.problem, WolProblem.badAddress);
      expect(result.detail, contains('Failed host lookup'));
      expect(sends, isEmpty);
    });

    test('an IPv6 address is sent to once, the way the system picks', () async {
      final result =
          await WolService.send(macAddress: 'AA:BB:CC:0D:0E:0F', broadcastAddress: 'ff02::1', interfaces: two, sendFrom: sender());
      expect(result.sent, isTrue);
      expect(sends, [('::', 'ff02::1', 9)]);
    });

    test('an address that is not a MAC address, or a port that is none: said as that, and nothing is sent', () async {
      var result = await WolService.send(macAddress: 'AA:BB:CC', interfaces: two, sendFrom: sender());
      expect(result.sent, isFalse);
      expect(result.problem, WolProblem.badMacAddress);
      for (final port in [0, -1, 65536]) {
        result = await WolService.send(macAddress: 'AA:BB:CC:0D:0E:0F', port: port, interfaces: two, sendFrom: sender());
        expect(result.problem, WolProblem.badPort, reason: '$port');
        expect(result.detail, '$port');
      }
      for (final port in [1, 65535]) {
        expect((await WolService.send(macAddress: 'AA:BB:CC:0D:0E:0F', port: port, interfaces: none, sendFrom: sender())).sent,
            isTrue,
            reason: '$port');
      }
      expect(sends, hasLength(2), reason: 'only the two that could be sent');
    });

    test('sent is said where at least one way took it, and counts only those', () async {
      // The system's own choice is refused (a VPN that took the default
      // route, say) and one network of the device takes nothing; the other
      // takes it.
      final result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          interfaces: two,
          sendFrom: sender(broken: {'0.0.0.0'}, dead: {'192.168.10.50'}));
      expect(result.sent, isTrue);
      expect(result.ways, 1);
      expect(sends, hasLength(3), reason: 'every way is tried, whatever the ones before did');
    });

    test('where no way took it, it was not sent, with what stopped the first of them', () async {
      // The first way was refused, the others took nothing: the refusal is
      // what is kept.
      var result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          interfaces: two,
          sendFrom: sender(broken: {'0.0.0.0'}, dead: {'192.168.10.50', '192.168.20.50'}));
      expect(result.sent, isFalse);
      expect(result.problem, WolProblem.notSent);
      expect(result.ways, 0);
      expect(result.detail, contains('Network is unreachable'));
      expect(sends, hasLength(3));
      // The first way took nothing, the others were refused: that nothing
      // went out there is what is kept.
      sends.clear();
      result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          interfaces: two,
          sendFrom: sender(dead: {'0.0.0.0'}, broken: {'192.168.10.50', '192.168.20.50'}));
      expect(result.problem, WolProblem.notSent);
      expect(result.detail, 'nothing went out from 0.0.0.0');
      expect(sends, hasLength(3));
    });

    test('networks that cannot be listed leave the way the system picks; one listed twice is used once', () async {
      var result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          interfaces: () async => throw const SocketException('not allowed'),
          sendFrom: sender());
      expect(result.sent, isTrue);
      expect(sends, [('0.0.0.0', '255.255.255.255', 9)]);
      sends.clear();
      result = await WolService.send(
          macAddress: 'AA:BB:CC:0D:0E:0F',
          interfaces: () async => [InternetAddress('192.168.10.50'), InternetAddress('192.168.10.50'), InternetAddress.anyIPv4],
          sendFrom: sender());
      expect(sends.map((s) => s.$1), ['0.0.0.0', '192.168.10.50']);
      expect(result.ways, 2);
    });

    test('with nothing put in its place, it goes through the real sockets and networks of this machine', () async {
      final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(receiver.close);
      final result =
          await WolService.send(macAddress: 'AA-BB-CC-0D-0E-0F', broadcastAddress: '127.0.0.1', port: receiver.port);
      expect(result.sent, isTrue);
      expect(result.ways, greaterThanOrEqualTo(1), reason: 'the way the system picks, at the least');
    });
  });

  test('a real packet arrives as it should: 102 bytes, on the port asked for', () async {
    final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(receiver.close);
    final arrived = Completer<Uint8List>();
    receiver.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = receiver.receive();
      if (datagram != null && !arrived.isCompleted) arrived.complete(datagram.data);
    });
    final result = await WolService.send(
      macAddress: 'AA-BB-CC-0D-0E-0F',
      broadcastAddress: '127.0.0.1',
      port: receiver.port,
      interfaces: () async => [],
    );
    expect(result.sent, isTrue);
    expect(result.ways, 1);
    expect(await arrived.future.timeout(const Duration(seconds: 5)), WolService.magicPacket(mac));
  });
}
