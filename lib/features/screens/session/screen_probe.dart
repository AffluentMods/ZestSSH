// The host editor's Test of a remote screen (4.0). Through its
// carrier: the SSH host signed in (with no terminal), the channel to the
// screen's address and port or socket opened, and the VNC server's greeting
// read (RFC 6143 7.1.1 and 7.1.2: its protocol version and the security types
// it offers), then closed before any type is chosen: no VNC password is sent.
// Reached directly: the socket, the greeting, and VeNCrypt's exchange before
// TLS (its version and the subtypes offered), stopped before a subtype is
// chosen; the certificate is checked, and asked about, when connecting.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zest_native/screen.dart' show ScreenChannel, screenServerText;
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/services/ssh_service.dart' show SshService;
import 'package:zestssh/utils/type_name.dart';

/// What a VNC server said at its door: its protocol version ("3.8") and the
/// security types it offers (RFC 6143's numbers, in its order).
class RfbGreeting {
  const RfbGreeting({required this.version, required this.securityTypes, this.vencryptSubtypes});

  final String version;
  final List<int> securityTypes;

  /// VeNCrypt's subtypes (260 X509None, 261 X509Vnc, 262 X509Plain, ...),
  /// where they were asked for and it is offered.
  final List<int>? vencryptSubtypes;

  /// Whether VeNCrypt offers a subtype the app takes (with a certificate).
  bool get vencryptTaken => vencryptSubtypes?.any(vencryptSubtypesTaken.contains) ?? false;

  /// Whether one of [securityTypes] is one the app takes (as the engine
  /// chooses: None, VNC password, VeNCrypt, Apple's sign-in).
  bool get offersOneTaken => securityTypes.any(rfbSecurityTypesTaken.contains);
}

/// The security types the engine takes (rust/src/vnc/engine/client/connect.rs).
const rfbSecurityTypesTaken = {1, 2, 19, 30};

/// VeNCrypt's subtypes the engine takes: the X509 ones, whose certificate can
/// be checked (rust/src/vnc/engine/client/vencrypt.rs).
const vencryptSubtypesTaken = {260, 261, 262};

/// A security type as RFC 6143 and the engine name it.
String rfbSecurityName(int type) => switch (type) {
      1 => 'None',
      2 => 'VncAuth',
      5 => 'RA2',
      6 => 'RA2ne',
      16 => 'Tight',
      19 => 'VeNCrypt',
      30 => 'AppleRemoteDesktop',
      _ => 'type $type',
    };

/// A VeNCrypt subtype as the engine names it.
String vencryptSubtypeName(int subtype) => switch (subtype) {
      256 => 'Plain',
      257 => 'TLSNone',
      258 => 'TLSVnc',
      259 => 'TLSPlain',
      260 => 'X509None',
      261 => 'X509Vnc',
      262 => 'X509Plain',
      _ => 'subtype $subtype',
    };

/// The answer at the screen's address is not a VNC server's ([said]: its
/// first bytes, made printable, for Copy details).
class RfbNotVnc implements Exception, HasTypeName {
  const RfbNotVnc(this.said);
  final String said;

  @override
  String get typeName => 'RfbNotVnc';

  @override
  String toString() => 'RfbNotVnc($said)';
}

/// The VNC server turned the connection away before offering anything, and
/// said why ([reason], as it said it).
class RfbRefused implements Exception, HasTypeName {
  const RfbRefused(this.reason);
  final String reason;

  @override
  String get typeName => 'RfbRefused';

  @override
  String toString() => 'RfbRefused($reason)';
}

/// What an RDP server answered to the connection request ([readRdpAnswer]):
/// the security it picked, its refusal, or neither (a server from before
/// TLS, whose answer has no such part).
class RdpAnswer {
  const RdpAnswer({this.selected, this.failure});

  /// The security it picked (RDP_NEG_RSP's selectedProtocol, [MS-RDPBCGR]
  /// 2.2.1.2.1): 0 RDP's own old encryption, 1 TLS, 2 Network Level
  /// Authentication, 8 the same with its early result.
  final int? selected;

  /// Its refusal (RDP_NEG_FAILURE's failureCode, 2.2.1.2.2): 1 it has TLS
  /// only where NLA was asked for, 2 it allows no TLS, 5 and 6 it requires
  /// NLA, the others its own trouble.
  final int? failure;

  /// Whether it picked Network Level Authentication.
  bool get nla => selected == 2 || selected == 8;
}

/// The answer at the screen's address is not an RDP server's ([said]: its
/// first bytes, made printable, for Copy details).
class RdpNotRdp implements Exception, HasTypeName {
  const RdpNotRdp(this.said);
  final String said;

  @override
  String get typeName => 'RdpNotRdp';

  @override
  String toString() => 'RdpNotRdp($said)';
}

/// The connection request an RDP session of the app sends (the engine's, in
/// rust/src/rdp: a test there reads the same bytes): with [nla], Network
/// Level Authentication and nothing less; without, TLS alone. No cookie and
/// no user name: nothing of the account is in it.
Uint8List rdpConnectionRequest({required bool nla}) => Uint8List.fromList([
      3, 0, 0, 19, // TPKT: version 3, 19 bytes in all.
      14, 0xe0, 0, 0, 0, 0, 0, // X.224 Connection Request.
      1, 0, 8, 0, nla ? 0x0a : 0x01, 0, 0, 0, // RDP_NEG_REQ: the security asked for.
    ]);

/// Sends [rdpConnectionRequest] to the RDP server at the other end of
/// [channel] and reads its answer, and nothing more: TLS is not begun, so no
/// certificate is taken and no user name or password is sent; the caller
/// closes the channel. Throws [RdpNotRdp] where the answer is not an RDP
/// server's, [TimeoutException] past [timeout], and a [ScreenFailure] where
/// the channel ended first.
Future<RdpAnswer> readRdpAnswer(ScreenChannel channel,
    {required bool nla, Duration timeout = const Duration(seconds: 10)}) async {
  final reader = _Reader(channel.input);
  try {
    return await _rdpAnswer(reader, channel.output, nla: nla).timeout(timeout);
  } finally {
    await reader.cancel();
  }
}

Future<RdpAnswer> _rdpAnswer(_Reader reader, StreamSink<List<int>> output, {required bool nla}) async {
  output.add(rdpConnectionRequest(nla: nla));
  // TPKT: 3, 0, and the whole length. A Connection Confirm is 11 bytes, 19
  // with the negotiation's answer.
  final head = await reader.take(4);
  final length = (head[2] << 8) | head[3];
  if (head[0] != 3 || length < 11 || length > 64) throw RdpNotRdp(_printable(head));
  final rest = await reader.take(length - 4);
  // X.224's Connection Confirm (the high four bits of its code are 1101).
  if (rest[1] & 0xf0 != 0xd0) throw RdpNotRdp(_printable([...head, ...rest]));
  if (length < 19) return const RdpAnswer();
  final value = ByteData.sublistView(rest, 11, 15).getUint32(0, Endian.little);
  return switch (rest[7]) {
    2 => RdpAnswer(selected: value),
    3 => RdpAnswer(failure: value),
    _ => const RdpAnswer(),
  };
}

/// The most of a refusal's reason that is read (a server's words, shown).
const _maxReason = 1024;

/// Reads the greeting of the VNC server at the other end of [channel]: its
/// version (12 bytes), the version answered (3.8, or 3.3 to a 3.3 server),
/// and the security types. With [vencrypt], where VeNCrypt is offered, it is
/// chosen and its exchange before TLS read (version 0.2, and its subtypes);
/// no subtype is chosen. Nothing else is written, so no password is sent and
/// no TLS begins; the caller closes the channel. Throws [RfbNotVnc] where
/// the answer is not RFB, [RfbRefused] where the server turned it away,
/// [TimeoutException] past [timeout], and a [ScreenFailure] where the
/// channel ended first.
Future<RfbGreeting> readRfbGreeting(ScreenChannel channel,
    {bool vencrypt = false, Duration timeout = const Duration(seconds: 10)}) async {
  final reader = _Reader(channel.input);
  try {
    return await _greeting(reader, channel.output, vencrypt: vencrypt).timeout(timeout);
  } finally {
    await reader.cancel();
  }
}

Future<RfbGreeting> _greeting(_Reader reader, StreamSink<List<int>> output, {required bool vencrypt}) async {
  final banner = await reader.take(12);
  final text = latin1.decode(banner);
  final m = RegExp(r'^RFB (\d{3})\.(\d{3})\n$').firstMatch(text);
  if (m == null) throw RfbNotVnc(_printable(banner));
  final major = int.parse(m.group(1)!);
  final minor = int.parse(m.group(2)!);
  final version = '$major.$minor';
  // A 3.3 server names the one type it wants; 3.7 and later (Apple's
  // 3.889 among them) list theirs, and 3.8 is answered.
  final old = major == 3 && minor < 7;
  output.add(ascii.encode(old ? 'RFB 003.003\n' : 'RFB 003.008\n'));
  if (old) {
    final type = ByteData.sublistView(await reader.take(4)).getUint32(0);
    if (type == 0) throw RfbRefused(await _reason(reader));
    return RfbGreeting(version: version, securityTypes: [type]);
  }
  final count = (await reader.take(1))[0];
  if (count == 0) throw RfbRefused(await _reason(reader));
  final types = List.of(await reader.take(count));
  if (!vencrypt || !types.contains(19)) return RfbGreeting(version: version, securityTypes: types);
  // VeNCrypt (19): the server's version, ours (0.2), its yes, its subtypes.
  output.add([19]);
  final vv = await reader.take(2);
  if (vv[0] != 0 || vv[1] < 2) {
    return RfbGreeting(version: version, securityTypes: types, vencryptSubtypes: const []);
  }
  output.add([0, 2]);
  if ((await reader.take(1))[0] != 0) {
    return RfbGreeting(version: version, securityTypes: types, vencryptSubtypes: const []);
  }
  final n = (await reader.take(1))[0];
  final raw = ByteData.sublistView(await reader.take(n * 4));
  return RfbGreeting(
    version: version,
    securityTypes: types,
    vencryptSubtypes: [for (var i = 0; i < n; i++) raw.getUint32(i * 4)],
  );
}

/// A refusal's reason: its length, then its words (UTF-8 as 3.8 has it).
Future<String> _reason(_Reader reader) async {
  final length = ByteData.sublistView(await reader.take(4)).getUint32(0);
  if (length == 0) return '';
  final words = await reader.take(length > _maxReason ? _maxReason : length);
  // The server's words, shown and in Copy details: no control or hiding
  // characters, and not a page of them (found in a security review).
  return screenServerText(utf8.decode(words, allowMalformed: true), max: 300);
}

String _printable(List<int> bytes) =>
    String.fromCharCodes([for (final b in bytes) b >= 0x20 && b < 0x7f ? b : 0x2e]);

/// Bytes from a stream, so many at a time.
class _Reader {
  _Reader(Stream<Uint8List> input) {
    _sub = input.listen(
      (data) {
        _buffer.add(data);
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder();
  Object? _error;
  bool _done = false;
  Completer<void>? _waiting;

  void _wake() {
    final w = _waiting;
    _waiting = null;
    w?.complete();
  }

  Future<Uint8List> take(int n) async {
    while (_buffer.length < n) {
      final error = _error;
      if (error != null) throw error;
      if (_done) {
        throw const ScreenFailure(ScreenFailureKind.serverEnded, 'the connection ended during the VNC greeting');
      }
      await (_waiting = Completer<void>()).future;
    }
    final all = _buffer.takeBytes();
    if (all.length > n) _buffer.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }

  Future<void> cancel() => _sub.cancel();
}

/// How the test of a screen reached through an SSH host goes: the carrier
/// signed in already; [open] gives the channel to the screen, [close] signs
/// out of the carrier.
abstract interface class ScreenProbeRoute {
  Future<ScreenChannel> open();
  Future<void> close();
}

/// The route of a screen's test over the app's SSH connection to its carrier,
/// as the session's: a `~` in the socket's path is the carrier account's
/// home, and a refused channel is said in a screen's words.
class SshScreenProbeRoute implements ScreenProbeRoute {
  SshScreenProbeRoute(this.carrier, this.target, {this.carrierLabel});

  final SshService carrier;
  final ScreenTarget target;
  final String? carrierLabel;

  @override
  Future<ScreenChannel> open() async => openScreenChannelVia(carrier, target,
      socketPath: await screenSocketPathOn(carrier, target), carrierLabel: carrierLabel);

  @override
  Future<void> close() async {
    try {
      await carrier.disconnect();
    } catch (_) {
      // Closing what is gone already.
    }
  }
}
