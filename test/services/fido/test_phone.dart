import 'dart:async';
import 'dart:typed_data';

import 'package:zestssh/services/fido/fido_platform.dart';

import 'soft_key.dart';

/// A phone for tests: its NFC field and its USB port, each with a software
/// security key behind it or nothing.
class TestPhone implements FidoPlatform {
  TestPhone({this.waysNow = const FidoWays(nfc: true, nfcOn: true, usb: true)});

  FidoWays waysNow;

  /// The cards that will be held to the phone, in order; when none is left,
  /// the field stays empty until [nfcCancel].
  final List<SoftNfcCard> cards = [];

  /// The key that is plugged in, or null.
  SoftHid? plugged;
  bool usbDenied = false;

  int nfcBegun = 0;
  int nfcCancelled = 0;
  int usbClosed = 0;
  final List<String?> nfcEnded = [];
  Completer<FidoNfcSession>? _waiting;

  @override
  Future<FidoWays> ways() async => waysNow;

  @override
  Future<FidoNfcSession> nfc({required String prompt}) {
    nfcBegun++;
    if (cards.isNotEmpty) return Future.value(_Nfc(cards.removeAt(0), nfcEnded));
    return (_waiting = Completer<FidoNfcSession>()).future;
  }

  @override
  Future<void> nfcCancel() async {
    nfcCancelled++;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(const FidoPlatformError(FidoPlatformError.cancelled));
    }
  }

  @override
  Future<FidoUsbSession?> usb() async {
    if (usbDenied) throw const FidoPlatformError(FidoPlatformError.denied);
    final key = plugged;
    return key == null ? null : _Usb(key, () => usbClosed++);
  }
}

class _Nfc implements FidoNfcSession {
  _Nfc(this.card, this.ended);

  final SoftNfcCard card;
  final List<String?> ended;

  @override
  Future<Uint8List> transceive(Uint8List command) => card.transceive(command);

  @override
  Future<void> end({String? error}) async => ended.add(error);
}

class _Usb implements FidoUsbSession {
  _Usb(this.hid, this.onClose);

  final SoftHid hid;
  final void Function() onClose;

  @override
  Future<void> write(Uint8List report) => hid.write(report);

  @override
  Future<Uint8List> read(Duration timeout) => hid.read(timeout);

  @override
  Future<void> close() async => onClose();
}
