// CTAP2 over NFC (CTAP 2.1, section 11.3): a security key held to the
// phone is an ISO 7816-4 card. The FIDO applet is selected, a message goes
// to it as one command (cut into chained pieces where it is long), and its
// answer is collected, asking again while the key says "still working".
//
// The phone's side is only [ApduChannel]: one command in, one answer out
// (Android's IsoDep.transceive, iOS's NFCISO7816Tag.sendCommand). All the
// framing is here, where it is tested without a phone.
import 'dart:typed_data';

import 'package:zestssh/services/fido/ctap2.dart';

/// One ISO 7816-4 exchange with the card in the field. Throws when the key
/// has left the field or the phone's NFC gave up.
abstract interface class ApduChannel {
  Future<Uint8List> transceive(Uint8List command);
}

/// The FIDO applet's name (its AID).
const List<int> kFidoAid = [0xa0, 0x00, 0x00, 0x06, 0x47, 0x2f, 0x00, 0x01];

/// A security key in the NFC field, as a [CtapDevice].
class NfcCtapDevice implements CtapDevice {
  NfcCtapDevice(this.channel, {this.onWaiting, this.pause});

  final ApduChannel channel;

  /// Told each time the key says it is still working.
  final void Function()? onWaiting;

  /// Waits between two asks of a key that is still working; a test's own
  /// waits no time.
  final Future<void> Function()? pause;

  /// The most data in one piece of a chained command.
  static const int _piece = 240;

  /// The longest answer collected, and the most rounds spent collecting it
  /// or waiting: a key that never finishes is given up on.
  static const int _maxAnswer = 64 * 1024;
  static const int _maxRounds = 600;

  bool _selected = false;

  /// What the applet answered when selected: "U2F_V2" or "FIDO_2_0".
  String? appletVersion;

  Future<(Uint8List, int)> _exchange(List<int> apdu) async {
    final Uint8List answer;
    try {
      answer = await channel.transceive(Uint8List.fromList(apdu));
    } on CtapTransportError {
      rethrow;
    } catch (e) {
      throw CtapTransportError('the key left the NFC field or did not answer ($e)');
    }
    if (answer.length < 2) throw const CtapTransportError('an NFC answer with no status');
    final sw = (answer[answer.length - 2] << 8) | answer[answer.length - 1];
    return (Uint8List.sublistView(answer, 0, answer.length - 2), sw);
  }

  /// Selects the FIDO applet (once). Throws [CtapTransportError] where the
  /// card has none: it is not a security key.
  Future<void> select() async {
    if (_selected) return;
    final (data, sw) = await _exchange([0x00, 0xa4, 0x04, 0x00, kFidoAid.length, ...kFidoAid, 0x00]);
    if (sw != 0x9000) throw const CtapTransportError('this NFC device is not a FIDO security key');
    appletVersion = String.fromCharCodes(data.where((b) => b >= 0x20 && b < 0x7f));
    _selected = true;
  }

  @override
  Future<Uint8List> cbor(Uint8List request) async {
    await select();
    // NFCCTAP_MSG: CLA 80, INS 10, P1 80 ("I can ask again while you work").
    // A long message goes in pieces, every piece but the last marked as
    // chained (CLA 90).
    late Uint8List data;
    late int sw;
    for (var at = 0; at == 0 || at < request.length; at += _piece) {
      final end = at + _piece < request.length ? at + _piece : request.length;
      final last = end == request.length;
      (data, sw) = await _exchange([last ? 0x80 : 0x90, 0x10, 0x80, 0x00, end - at, ...request.sublist(at, end), if (last) 0x00]);
      if (!last && sw != 0x9000) throw CtapTransportError('the key refused a piece of the message (${_hex(sw)})');
    }
    final answer = BytesBuilder(copy: false);
    for (var round = 0; round < _maxRounds; round++) {
      answer.add(data);
      if (answer.length > _maxAnswer) throw const CtapTransportError('an NFC answer longer than a key gives');
      if (sw == 0x9000) return answer.toBytes();
      if (sw >> 8 == 0x61) {
        // More of the answer waits: GET RESPONSE for as much as it says.
        (data, sw) = await _exchange([0x00, 0xc0, 0x00, 0x00, sw & 0xff]);
      } else if (sw == 0x9100) {
        // Still working (what came with it is a status, not the answer).
        answer.clear();
        onWaiting?.call();
        await (pause ?? () => Future<void>.delayed(const Duration(milliseconds: 100)))();
        (data, sw) = await _exchange([0x80, 0x11, 0x00, 0x00, 0x00]);
      } else {
        throw CtapTransportError('the key answered the message with ${_hex(sw)}');
      }
    }
    throw const CtapTransportError('the key did not finish answering');
  }

  static String _hex(int sw) => sw.toRadixString(16).padLeft(4, '0');
}
