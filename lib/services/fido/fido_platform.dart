// The phone's side of a security key: only what carries bytes to it. NFC
// gives one ISO 7816-4 exchange at a time, USB one 64 byte report at a
// time; everything that reads or writes a meaning is in Dart
// (fido_nfc.dart, fido_hid.dart, ctap2.dart).
//
// Android: NFC (reader mode, IsoDep) and USB (the FIDO HID interface of a
// plugged-in key, which Android asks the person to allow). iPhone: NFC
// (CoreNFC). iPad and USB keys on iOS: not there (Apple gives an app no
// raw channel to a USB security key).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/services/fido/fido_hid.dart';
import 'package:zestssh/services/fido/fido_nfc.dart';
import 'package:zestssh/utils/type_name.dart';

/// Which ways to a security key this device has right now.
class FidoWays {
  const FidoWays({required this.nfc, required this.nfcOn, required this.usb});

  /// No way at all: a computer, an iPad, a phone with neither.
  static const none = FidoWays(nfc: false, nfcOn: false, usb: false);

  /// The device has NFC that can speak to a security key.
  final bool nfc;

  /// NFC is switched on in the system's settings.
  final bool nfcOn;

  /// A USB security key can be plugged in (Android with USB host).
  final bool usb;

  bool get any => nfc || usb;
}

/// Why the phone could not reach a key; [code] is one of the constants.
class FidoPlatformError implements Exception, HasTypeName {
  const FidoPlatformError(this.code, [this.detail]);

  static const String cancelled = 'cancelled';
  static const String nfcOff = 'nfc_off';
  static const String unavailable = 'unavailable';
  static const String denied = 'denied';
  static const String lost = 'lost';
  static const String timeout = 'timeout';

  final String code;
  final String? detail;

  @override
  String toString() => 'FidoPlatformError($code${detail == null ? '' : ': $detail'})';

  @override
  String get typeName => 'FidoPlatformError';
}

/// A security key in the NFC field. [end] gives the field back (and on an
/// iPhone closes the system's sheet, with [error] shown in it where given).
abstract interface class FidoNfcSession implements ApduChannel {
  Future<void> end({String? error});
}

/// A plugged-in security key's FIDO interface, opened.
abstract interface class FidoUsbSession implements HidChannel {
  Future<void> close();
}

/// What a phone gives of the two ways.
abstract interface class FidoPlatform {
  Future<FidoWays> ways();

  /// Waits for a security key to be held to the phone. [prompt] is what an
  /// iPhone's own NFC sheet says. Throws [FidoPlatformError]
  /// ([FidoPlatformError.cancelled], [FidoPlatformError.nfcOff],
  /// [FidoPlatformError.timeout], [FidoPlatformError.unavailable]).
  Future<FidoNfcSession> nfc({required String prompt});

  /// Stops waiting for a key in the field (the person cancelled, or a USB
  /// key was plugged in meanwhile).
  Future<void> nfcCancel();

  /// The plugged-in security key, opened, or null where none is plugged in.
  /// Throws [FidoPlatformError.denied] where the person did not allow it.
  Future<FidoUsbSession?> usb();
}

/// The app's own channel to Android's and iOS's side (FidoChannel.kt,
/// FidoChannel.swift).
class MethodChannelFidoPlatform implements FidoPlatform {
  const MethodChannelFidoPlatform();

  static const MethodChannel _channel = MethodChannel('zestssh/fido');

  static bool get _phone =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const FidoPlatformError(FidoPlatformError.unavailable);
    } on PlatformException catch (e) {
      throw FidoPlatformError(e.code, e.message);
    }
  }

  @override
  Future<FidoWays> ways() async {
    if (!_phone) return FidoWays.none;
    try {
      final m = await _call<Map<Object?, Object?>>('ways');
      return FidoWays(nfc: m?['nfc'] == true, nfcOn: m?['nfcOn'] == true, usb: m?['usb'] == true);
    } on FidoPlatformError {
      return FidoWays.none;
    }
  }

  @override
  Future<FidoNfcSession> nfc({required String prompt}) async {
    await _call<void>('nfcBegin', {'prompt': prompt});
    return const _NfcSession();
  }

  @override
  Future<void> nfcCancel() async {
    try {
      await _call<void>('nfcEnd');
    } on FidoPlatformError {
      // (Nothing was waiting.)
    }
  }

  @override
  Future<FidoUsbSession?> usb() async => await _call<bool>('usbOpen') == true ? const _UsbSession() : null;
}

class _NfcSession implements FidoNfcSession {
  const _NfcSession();

  @override
  Future<Uint8List> transceive(Uint8List command) async {
    final answer = await MethodChannelFidoPlatform._call<Uint8List>('nfcTransceive', command);
    if (answer == null) throw const FidoPlatformError(FidoPlatformError.lost);
    return answer;
  }

  @override
  Future<void> end({String? error}) async {
    try {
      await MethodChannelFidoPlatform._call<void>('nfcEnd', {'error': error});
    } on FidoPlatformError {
      // (Already ended.)
    }
  }
}

class _UsbSession implements FidoUsbSession {
  const _UsbSession();

  @override
  Future<void> write(Uint8List report) => MethodChannelFidoPlatform._call<void>('usbWrite', report);

  @override
  Future<Uint8List> read(Duration timeout) async {
    final report = await MethodChannelFidoPlatform._call<Uint8List>('usbRead', timeout.inMilliseconds);
    if (report == null) throw const FidoPlatformError(FidoPlatformError.timeout);
    return report;
  }

  @override
  Future<void> close() async {
    try {
      await MethodChannelFidoPlatform._call<void>('usbClose');
    } on FidoPlatformError {
      // (Already closed, or unplugged.)
    }
  }
}
