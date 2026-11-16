import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:zestssh/utils/logger.dart';

/// Why a Wake-on-LAN packet was not sent.
enum WolProblem {
  /// The address to wake is not a MAC address: it needs 12 hexadecimal
  /// digits, written with or without separators.
  badMacAddress,

  /// Where to send it is neither an address nor a name that could be found.
  badAddress,

  /// The port is not one (1 to 65535).
  badPort,

  /// No network of this device took the packet.
  notSent,
}

/// How sending a Wake-on-LAN packet went. A packet that was sent says
/// nothing about the machine it is for: nothing answers a magic packet, so
/// whether that machine woke is not known here.
class WolResult {
  const WolResult.sent(this.ways)
      : problem = null,
        detail = null;

  const WolResult.failed(WolProblem this.problem, [this.detail]) : ways = 0;

  /// How many ways out of this device the packet took (one for the system's
  /// own choice, one for each network of the device).
  final int ways;

  /// Why nothing was sent; null where the packet went out.
  final WolProblem? problem;

  /// What was caught or found, for whoever copies the details of a message.
  final String? detail;

  bool get sent => problem == null;

  @override
  String toString() => sent ? 'WolResult(sent, $ways)' : 'WolResult(${problem!.name}${detail == null ? '' : ': $detail'})';
}

/// Sends one packet from [source] (port 0) to [target]:[port] and gives the
/// number of bytes that went out: the packet's length, or 0.
typedef WolSendFrom = Future<int> Function(InternetAddress source, List<int> packet, InternetAddress target, int port);

/// Wake-on-LAN: sends the magic packet that powers on a machine set up for
/// it.
///
/// The packet is sent by this class itself, and each send is looked at: it
/// goes out once the way the system picks and once on each IPv4 network of
/// the device, since a computer often has several (a VPN that takes the
/// default route, virtual adapters) and a broadcast that leaves on the wrong
/// one wakes nothing. "Sent" is said only where at least one send went out.
class WolService {
  /// The port Wake-on-LAN is specified for.
  static const int defaultPort = 9;

  /// Where a packet goes when a host names no address: every machine on the
  /// local network.
  static const String defaultBroadcast = '255.255.255.255';

  /// How long a name is given to be looked up.
  static const Duration lookupPatience = Duration(seconds: 5);

  static final RegExp _notHex = RegExp('[^0-9a-fA-F]');

  /// The six bytes of [mac], or null where it is not a MAC address. Any way
  /// of writing one is taken, as the host editor takes it: what counts is
  /// 12 hexadecimal digits, whatever stands between them
  /// (`AA:BB:CC:DD:EE:FF`, `AA-BB-CC-DD-EE-FF`, `aabb.ccdd.eeff`,
  /// `AABBCCDDEEFF`).
  static Uint8List? macBytes(String mac) {
    final digits = mac.replaceAll(_notHex, '');
    if (digits.length != 12) return null;
    return Uint8List.fromList([
      for (var i = 0; i < 12; i += 2) int.parse(digits.substring(i, i + 2), radix: 16),
    ]);
  }

  /// Whether [mac] is a MAC address this class can send for. The host
  /// editor asks this before it saves one.
  static bool isValidMac(String mac) => macBytes(mac) != null;

  /// The magic packet for the machine with the address [mac] (six bytes):
  /// six bytes of 0xFF, then the address sixteen times. 102 bytes.
  static Uint8List magicPacket(Uint8List mac) {
    assert(mac.length == 6);
    final packet = Uint8List(6 + 16 * 6)..fillRange(0, 6, 0xFF);
    for (var i = 0; i < 16; i++) {
      packet.setRange(6 + i * 6, 12 + i * 6, mac);
    }
    return packet;
  }

  /// Sends the magic packet for [macAddress] to [broadcastAddress] (an
  /// address, or a name that is looked up, for a machine reached through a
  /// forwarded port) on [port], and says how that went.
  ///
  /// [interfaces], [lookup] and [sendFrom] are for tests: the device's own
  /// IPv4 addresses, how a name is looked up, and how one packet is sent.
  static Future<WolResult> send({
    required String macAddress,
    String broadcastAddress = defaultBroadcast,
    int port = defaultPort,
    Future<List<InternetAddress>> Function()? interfaces,
    Future<List<InternetAddress>> Function(String name)? lookup,
    WolSendFrom? sendFrom,
  }) async {
    final mac = macBytes(macAddress);
    if (mac == null) {
      AppLogger.warning('WoL: not a MAC address');
      return const WolResult.failed(WolProblem.badMacAddress);
    }
    if (port < 1 || port > 65535) {
      AppLogger.warning('WoL: not a port ($port)');
      return WolResult.failed(WolProblem.badPort, '$port');
    }
    final InternetAddress target;
    try {
      target = await _targetOf(broadcastAddress, lookup ?? _lookup);
    } catch (e) {
      AppLogger.warning('WoL: where to send it could not be found ($e)');
      return WolResult.failed(WolProblem.badAddress, '$e');
    }

    final packet = magicPacket(mac);
    // The way the system picks first, then each network of the device.
    final any = target.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4;
    final sources = <InternetAddress>[any];
    if (target.type == InternetAddressType.IPv4) {
      try {
        for (final address in await (interfaces ?? _ipv4Interfaces)()) {
          if (!sources.any((s) => s.address == address.address)) sources.add(address);
        }
      } catch (e) {
        // The system's own choice is still tried.
        AppLogger.warning('WoL: the networks of this device could not be listed ($e)');
      }
    }
    final send = sendFrom ?? _sendFrom;
    var ways = 0;
    Object? stopped;
    for (final source in sources) {
      try {
        if (await send(source, packet, target, port) == packet.length) {
          ways++;
        } else {
          stopped ??= 'nothing went out from ${source.address}';
        }
      } catch (e) {
        stopped ??= e;
      }
    }
    if (ways == 0) {
      AppLogger.warning('WoL: the packet was not sent ($stopped)');
      return WolResult.failed(WolProblem.notSent, stopped == null ? null : '$stopped');
    }
    AppLogger.info('WoL: packet sent, $ways of ${sources.length} ways out');
    return WolResult.sent(ways);
  }

  /// [address] as where to send to: itself where it is an address, the
  /// first IPv4 address of the name it is otherwise (any address where the
  /// name has no IPv4 one).
  static Future<InternetAddress> _targetOf(
      String address, Future<List<InternetAddress>> Function(String name) lookup) async {
    final text = address.trim();
    if (text.isEmpty) return InternetAddress(defaultBroadcast);
    final literal = InternetAddress.tryParse(text);
    if (literal != null) return literal;
    final found = await lookup(text);
    if (found.isEmpty) throw SocketException('No address for $text');
    return found.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => found.first);
  }

  static Future<List<InternetAddress>> _lookup(String name) => InternetAddress.lookup(name).timeout(lookupPatience);

  /// The IPv4 addresses of this device's networks (the system lists them
  /// without its loopback).
  static Future<List<InternetAddress>> _ipv4Interfaces() async => [
        for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) ...interface.addresses,
      ];

  static Future<int> _sendFrom(InternetAddress source, List<int> packet, InternetAddress target, int port) async {
    final socket = await RawDatagramSocket.bind(source, 0);
    try {
      if (target.type == InternetAddressType.IPv4) socket.broadcastEnabled = true;
      // What the system reports of a send that failed arrives as an event:
      // it is taken here, so that it is nobody's unhandled error.
      Object? failed;
      final events = socket.listen((_) {}, onError: (Object e) => failed = e);
      final sent = socket.send(packet, target, port);
      await Future<void>.delayed(Duration.zero);
      await events.cancel();
      if (failed != null) throw failed!;
      return sent;
    } finally {
      socket.close();
    }
  }
}
