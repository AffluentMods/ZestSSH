// CTAP2 over USB (CTAPHID, CTAP 2.1, section 11.2): a plugged-in security
// key is a HID device that takes and gives reports of 64 bytes. A message
// is cut into packets on a channel the key hands out; its answer comes back
// the same way, with "still working" and "touch me" packets in between.
//
// The phone's side is only [HidChannel]: write one report, read one report
// (Android's interrupt endpoints of the FIDO interface). All the framing is
// here, where it is tested without a key.
import 'dart:math';
import 'dart:typed_data';

import 'package:zestssh/services/fido/ctap2.dart';

/// The FIDO interface of a plugged-in key: reports of [packetSize] bytes
/// out and in. [read] gives the next report, or throws when none comes in
/// [timeout] or the key is unplugged.
abstract interface class HidChannel {
  Future<void> write(Uint8List report);
  Future<Uint8List> read(Duration timeout);
}

/// A plugged-in security key, as a [CtapDevice].
class HidCtapDevice implements CtapDevice {
  HidCtapDevice(this.channel, {this.onWaiting, Random? random, this.answerTimeout = const Duration(seconds: 60)})
      : _random = random ?? Random.secure();

  final HidChannel channel;

  /// Told while the key works: [touchNeeded] when it waits for a touch.
  final void Function({required bool touchNeeded})? onWaiting;

  /// How long an answer is waited for in all (a touch included).
  final Duration answerTimeout;

  final Random _random;

  static const int packetSize = 64;
  static const int _broadcast = 0xffffffff;
  static const int _cmdInit = 0x06;
  static const int _cmdCbor = 0x10;
  static const int _cmdCancel = 0x11;
  static const int _cmdKeepalive = 0x3b;
  static const int _cmdError = 0x3f;

  /// The longest message CTAPHID carries: 57 bytes and 128 packets of 59.
  static const int maxMessage = 57 + 128 * 59;

  int? _channelId;

  /// What the key said of itself at INIT: bit 0x04 says it speaks CBOR.
  int capabilities = 0;

  Future<void> _write(Uint8List report) async {
    try {
      await channel.write(report);
    } catch (e) {
      throw CtapTransportError('the key was unplugged or did not take a packet ($e)');
    }
  }

  Future<Uint8List> _read(Duration timeout) async {
    final Uint8List report;
    try {
      report = await channel.read(timeout);
    } catch (e) {
      throw CtapTransportError('the key was unplugged or did not answer ($e)');
    }
    if (report.length != packetSize) throw const CtapTransportError('a USB packet that is not 64 bytes');
    return report;
  }

  static int _cid(Uint8List report) => (report[0] << 24) | (report[1] << 16) | (report[2] << 8) | report[3];

  Future<void> _send(int cid, int command, List<int> payload) async {
    if (payload.length > maxMessage) throw const CtapTransportError('a message longer than USB carries');
    final first = Uint8List(packetSize)
      ..[0] = (cid >> 24) & 0xff
      ..[1] = (cid >> 16) & 0xff
      ..[2] = (cid >> 8) & 0xff
      ..[3] = cid & 0xff
      ..[4] = 0x80 | command
      ..[5] = payload.length >> 8
      ..[6] = payload.length & 0xff;
    var at = payload.length < 57 ? payload.length : 57;
    first.setRange(7, 7 + at, payload);
    await _write(first);
    for (var seq = 0; at < payload.length; seq++) {
      final next = Uint8List(packetSize)
        ..[0] = (cid >> 24) & 0xff
        ..[1] = (cid >> 16) & 0xff
        ..[2] = (cid >> 8) & 0xff
        ..[3] = cid & 0xff
        ..[4] = seq;
      final end = at + 59 < payload.length ? at + 59 : payload.length;
      next.setRange(5, 5 + (end - at), payload, at);
      at = end;
      await _write(next);
    }
  }

  /// The next whole message on [cid]: its command and payload. Packets of
  /// other channels are another program's and are passed over.
  Future<(int, Uint8List)> _receive(int cid, Stopwatch clock) async {
    while (true) {
      final left = answerTimeout - clock.elapsed;
      if (left <= Duration.zero) throw const CtapTransportError('the key did not answer in time');
      final first = await _read(left);
      if (_cid(first) != cid) continue;
      if (first[4] & 0x80 == 0) continue; // a continuation with no start: not ours to assemble
      final command = first[4] & 0x7f;
      final length = (first[5] << 8) | first[6];
      if (length > maxMessage) throw const CtapTransportError('a USB message longer than CTAPHID carries');
      final payload = Uint8List(length);
      var at = length < 57 ? length : 57;
      payload.setRange(0, at, first, 7);
      for (var seq = 0; at < length;) {
        final left = answerTimeout - clock.elapsed;
        if (left <= Duration.zero) throw const CtapTransportError('the key stopped in the middle of an answer');
        final next = await _read(left);
        if (_cid(next) != cid) continue;
        if (next[4] != seq) throw const CtapTransportError('USB packets out of order');
        final take = length - at < 59 ? length - at : 59;
        payload.setRange(at, at + take, next, 5);
        at += take;
        seq++;
      }
      return (command, payload);
    }
  }

  /// Asks the key for a channel of its own (once).
  Future<void> open() async {
    if (_channelId != null) return;
    final nonce = Uint8List.fromList(List.generate(8, (_) => _random.nextInt(256)));
    final clock = Stopwatch()..start();
    await _send(_broadcast, _cmdInit, nonce);
    while (true) {
      final (command, payload) = await _receive(_broadcast, clock);
      if (command == _cmdError) throw CtapTransportError('the key refused to open a channel (${_errorName(payload)})');
      if (command != _cmdInit || payload.length < 17) continue;
      // (Another program's INIT is answered on the same broadcast channel:
      // ours is the one that carries our nonce.)
      var ours = true;
      for (var i = 0; i < 8; i++) {
        if (payload[i] != nonce[i]) ours = false;
      }
      if (!ours) continue;
      final cid = (payload[8] << 24) | (payload[9] << 16) | (payload[10] << 8) | payload[11];
      if (cid == _broadcast || cid == 0) throw const CtapTransportError('the key gave a channel that cannot be used');
      _channelId = cid;
      capabilities = payload[16];
      return;
    }
  }

  @override
  Future<Uint8List> cbor(Uint8List request) async {
    await open();
    final cid = _channelId!;
    final clock = Stopwatch()..start();
    await _send(cid, _cmdCbor, request);
    while (true) {
      final (command, payload) = await _receive(cid, clock);
      switch (command) {
        case _cmdCbor:
          return payload;
        case _cmdKeepalive:
          // 1: working; 2: waiting for a touch.
          onWaiting?.call(touchNeeded: payload.isNotEmpty && payload[0] == 2);
        case _cmdError:
          throw CtapTransportError('the key answered with a USB error (${_errorName(payload)})');
        default:
          throw CtapTransportError('the key answered with another command (0x${command.toRadixString(16)})');
      }
    }
  }

  /// Tells the key to stop waiting for a touch (the person cancelled). The
  /// request under way then ends with CTAP2's "cancelled" status.
  Future<void> cancel() async {
    final cid = _channelId;
    if (cid != null) await _send(cid, _cmdCancel, const []);
  }

  static String _errorName(Uint8List payload) => switch (payload.isEmpty ? -1 : payload[0]) {
        0x01 => 'invalid command',
        0x02 => 'invalid parameter',
        0x03 => 'invalid length',
        0x04 => 'invalid sequence',
        0x05 => 'message timeout',
        0x06 => 'channel busy',
        0x0a => 'lock required',
        0x0b => 'invalid channel',
        _ => 'other',
      };
}
