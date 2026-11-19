// Signing with a security key on a phone, start to end: wait for the key
// to be held to the phone or plugged in, ask for its PIN where it needs
// one, ask it to sign or to make a key, check what it answered, and say
// what went wrong in a kind the screens have words for.
//
// What the person sees is [FidoSigner.prompt]: a sheet of the app's listens
// to it (lib/ui/widgets/fido_prompt_sheet.dart) and gives back a PIN or a
// Cancel. One conversation at a time; a second waits for the first.
//
// The PIN is held in a variable of the one operation that asked for it,
// for as long as that operation runs, and is never stored, logged or shown.
// A key that left the NFC field may already have counted a PIN it was sent
// as a wrong try, with its answer lost: so before a PIN is sent again
// without being typed again, the key's count of PIN tries is read, and
// where it fell since the PIN was last sent, or cannot be read, the PIN is
// dropped and asked for again.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/fido/cbor.dart';
import 'package:zestssh/services/fido/ctap2.dart';
import 'package:zestssh/services/fido/fido_hid.dart';
import 'package:zestssh/services/fido/fido_nfc.dart';
import 'package:zestssh/services/fido/fido_platform.dart';
import 'package:zestssh/services/fido/sk_ssh.dart';
import 'package:zestssh/utils/type_name.dart';

/// Why a security key did not sign or make a key.
enum FidoFailureKind {
  /// The person closed the sheet.
  cancelled,

  /// This device has no way to a security key (no NFC, no USB).
  noWay,

  /// NFC is switched off, and nothing is plugged in.
  nfcOff,

  /// The key left the NFC field or was unplugged, again and again.
  keyLeft,

  /// What was held to the phone is not a FIDO security key.
  notASecurityKey,

  /// It is a security key, but not the one this identity's key is on.
  wrongKey,

  /// The identity asks for the key's PIN (or making a key does), and the
  /// key has none set.
  pinNotSet,

  /// The PIN was wrong too many times: the key has blocked it for good.
  pinBlocked,

  /// The PIN was wrong three times in a row: the key takes no more tries
  /// until it is taken away and held or plugged in again.
  pinLocked,

  /// The key waited for a touch that did not come.
  timedOut,

  /// The key cannot make a key of the kind asked for (Ed25519 on an old
  /// key).
  cannotMakeKind,

  /// The key has no room for another key that lives on it.
  keyFull,

  /// The person did not allow the app to use the plugged-in key.
  denied,

  /// The key refused with a status the app has no better word for.
  refused,

  /// The key answered with something the protocol does not allow, or with
  /// a signature that is not this identity's.
  misbehaved,
}

/// A security key did not sign or make a key: [kind] for the screens,
/// [detail] for the connection's log (English, no secret in it).
class FidoFailure implements Exception, HasTypeName {
  const FidoFailure(this.kind, [this.detail]);

  final FidoFailureKind kind;
  final String? detail;

  @override
  String toString() => 'Security key: ${kind.name}${detail == null ? '' : ' ($detail)'}';

  @override
  String get typeName => 'FidoFailure';
}

/// What a conversation with a security key is for.
enum FidoPurpose { signIn, makeKey }

/// Where the conversation stands, as the sheet shows it.
enum FidoStep {
  /// The PIN is asked for.
  pin,

  /// The key is waited for: hold it to the phone, or plug it in.
  present,

  /// The plugged-in key blinks: touch it.
  touch,

  /// The key is being talked to.
  working,
}

/// What the sheet shows.
@immutable
class FidoPrompt {
  const FidoPrompt({
    required this.purpose,
    required this.label,
    required this.step,
    required this.ways,
    this.again = false,
    this.pinWrong = false,
    this.pinAgain = false,
    this.pinTriesLeft,
  });

  final FidoPurpose purpose;

  /// What is being signed in to, or the new key's name.
  final String label;
  final FidoStep step;
  final FidoWays ways;

  /// The key left before it was done: hold it again, and longer.
  final bool again;

  /// The PIN just given was wrong.
  final bool pinWrong;

  /// The key left before it answered the PIN just given, and could not say
  /// whether it counted it as a wrong try: it is typed again.
  final bool pinAgain;

  /// How many tries of the PIN the key still gives, where it said.
  final int? pinTriesLeft;
}

/// A key made on a security key: its key file's parts ([key]), and whether
/// the security key itself uses it only after its PIN ([keyRequiresPin]:
/// made with credProtect at its highest level). Where the PIN was asked for
/// every time and the security key does not, that rule is the app's own,
/// held in the key file's flags.
@immutable
class FidoMadeKey {
  const FidoMadeKey(this.key, {required this.keyRequiresPin});

  final OpenSSHSkKeyPair key;
  final bool keyRequiresPin;
}

class _Present {
  _Present(this.device, this.end, {this.hid});

  final CtapDevice device;
  final Future<void> Function({String? error}) end;
  final HidCtapDevice? hid;
}

/// The one conversation with a security key at a time.
class FidoSigner {
  FidoSigner({FidoPlatform? platform, Random? random})
      : platform = platform ?? const MethodChannelFidoPlatform(),
        _random = random ?? Random.secure();

  /// The phone's side; a test's own stands in.
  FidoPlatform platform;

  final Random _random;

  /// What the person is shown, or null while nothing is asked of them.
  final ValueNotifier<FidoPrompt?> prompt = ValueNotifier(null);

  /// What an iPhone's own NFC sheet says while it waits (the app's words,
  /// set by the screens in the person's language).
  String nfcSheetText = 'Hold your security key near the top of the phone.';

  /// How often a key that left is waited for again before giving up.
  static const int _presentations = 5;

  /// How long a key is waited for to be plugged in.
  Duration plugWait = const Duration(minutes: 2);

  /// How often it is looked for meanwhile.
  Duration plugPoll = const Duration(milliseconds: 700);

  Future<void> _queue = Future.value();
  Completer<String>? _pin;
  Completer<void>? _stopWaiting;
  HidCtapDevice? _touching;
  bool _cancelled = false;

  /// The PIN the person typed, from the sheet.
  void submitPin(String pin) {
    final waiting = _pin;
    if (waiting != null && !waiting.isCompleted) waiting.complete(pin);
  }

  /// The person closed the sheet: whatever is waited for ends.
  void cancel() {
    _cancelled = true;
    final pin = _pin;
    if (pin != null && !pin.isCompleted) pin.completeError(const FidoFailure(FidoFailureKind.cancelled));
    final waiting = _stopWaiting;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    unawaited(platform.nfcCancel());
    unawaited(_touching?.cancel().catchError((Object _) {}));
  }

  /// Signs [data] with the security key [key] is on: the signature as SSH
  /// sends it, checked. [label] says what for, in the sheet. Throws
  /// [FidoFailure].
  Future<Uint8List> sign(OpenSSHSkKeyPair key, Uint8List data, {required String label}) {
    final sk = SkKey(
      algorithm: key.type,
      publicKey: key.publicKey,
      application: key.application,
      keyHandle: key.keyHandle,
      flags: key.flags,
    );
    return _run(FidoPurpose.signIn, label, pinFirst: sk.verifyRequired, body: (ctap, info, token) async {
      PinToken? pin;
      if (sk.verifyRequired) {
        if (info.pinSet != true) throw const FidoFailure(FidoFailureKind.pinNotSet);
        pin = await token(kPinPermissionGetAssertion, sk.application);
      }
      Future<Assertion> ask() => ctap.getAssertion(
            rpId: sk.application,
            clientDataHash: sha256Of(data),
            credentialId: sk.keyHandle,
            userPresence: sk.touchRequired,
            pin: pin,
          );
      Assertion assertion;
      try {
        assertion = await ask();
      } on CtapError catch (e) {
        // A key set to ask for its PIN every time, whatever the identity says.
        if (pin != null || e.status != CtapError.pinRequired) rethrow;
        pin = await token(kPinPermissionGetAssertion, sk.application);
        assertion = await ask();
      }
      return skSignature(sk, data, assertion);
    });
  }

  /// Makes a new key on a security key: Ed25519 ([ed25519]) or P-256, for
  /// [application], asking for the key's PIN at every use where
  /// [verifyRequired]. Its key file's parts, nothing secret, and whether
  /// the security key itself holds to the PIN (credProtect, where it has
  /// it). Throws [FidoFailure].
  Future<FidoMadeKey> makeKey({
    required bool ed25519,
    required bool verifyRequired,
    required String label,
    String application = 'ssh:',
    String comment = '',
  }) {
    final alg = ed25519 ? kCoseEdDsa : kCoseEs256;
    return _run(FidoPurpose.makeKey, label, pinFirst: false, body: (ctap, info, token) async {
      if (!info.makes(alg)) throw const FidoFailure(FidoFailureKind.cannotMakeKind);
      PinToken? pin;
      if (info.pinSet == true) {
        pin = await token(kPinPermissionMakeCredential, application);
      } else if (verifyRequired) {
        throw const FidoFailure(FidoFailureKind.pinNotSet);
      }
      // Asking for the PIN every time is the key file's flag, which the app
      // holds to; the file is not secret, so where the security key can be
      // told, it is told too, and then signs with this key only after the
      // PIN, whoever asks.
      final protect = verifyRequired && info.credProtect;
      final made = await ctap.makeCredential(
        clientDataHash: _bytes(32),
        rpId: application,
        userId: _bytes(32),
        userName: 'openssh',
        alg: alg,
        pin: pin,
        credProtect: protect ? kCredProtectUvRequired : null,
      );
      final sk = SkKey.made(
        made,
        application: application,
        flags: kSkUserPresenceRequired | (verifyRequired ? kSkUserVerificationRequired : 0),
      );
      return FidoMadeKey(
        OpenSSHSkKeyPair(
          type: sk.algorithm,
          publicKey: sk.publicKey,
          application: application,
          flags: sk.flags,
          keyHandle: sk.keyHandle,
          comment: comment,
        ),
        // (A key that lists credProtect but does not say it used the level
        // asked for is not taken to hold to it.)
        keyRequiresPin: protect && made.credProtect == kCredProtectUvRequired,
      );
    });
  }

  Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  void _show(FidoPrompt p) => prompt.value = p;

  Future<T> _run<T>(
    FidoPurpose purpose,
    String label, {
    required bool pinFirst,
    required Future<T> Function(
      Ctap2 ctap,
      AuthenticatorInfo info,
      Future<PinToken> Function(int permissions, String rpId) token,
    ) body,
  }) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await _converse(purpose, label, pinFirst: pinFirst, body: body));
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        prompt.value = null;
        _pin = null;
        _stopWaiting = null;
        _touching = null;
      }
    });
    return done.future;
  }

  Future<T> _converse<T>(
    FidoPurpose purpose,
    String label, {
    required bool pinFirst,
    required Future<T> Function(
      Ctap2 ctap,
      AuthenticatorInfo info,
      Future<PinToken> Function(int permissions, String rpId) token,
    ) body,
  }) async {
    _cancelled = false;
    final ways = await platform.ways();
    if (!ways.any) throw const FidoFailure(FidoFailureKind.noWay);
    if (!ways.usb && !ways.nfcOn) throw const FidoFailure(FidoFailureKind.nfcOff);

    String? pin;
    // Whether [pin] was sent to a key already, and the key's count of PIN
    // tries just before it was (null where it did not say).
    var pinSent = false;
    int? triesBeforeSent;
    Future<String> askPin({bool wrong = false, bool again = false, int? triesLeft}) {
      final asked = _pin = Completer<String>();
      pinSent = false;
      _show(FidoPrompt(
        purpose: purpose,
        label: label,
        step: FidoStep.pin,
        ways: ways,
        pinWrong: wrong,
        pinAgain: again,
        pinTriesLeft: triesLeft,
      ));
      return asked.future;
    }

    if (pinFirst) pin = await askPin();

    for (var presented = 0; presented < _presentations; presented++) {
      if (_cancelled) throw const FidoFailure(FidoFailureKind.cancelled);
      _show(FidoPrompt(purpose: purpose, label: label, step: FidoStep.present, ways: ways, again: presented > 0));
      final present = await _present(ways, () {
        _show(FidoPrompt(purpose: purpose, label: label, step: FidoStep.touch, ways: ways));
      });
      try {
        _show(FidoPrompt(purpose: purpose, label: label, step: FidoStep.working, ways: ways));
        final ctap = Ctap2(present.device);
        final info = await ctap.getInfo();
        // The key's count of PIN tries, or null where it does not say.
        Future<int?> triesLeft() async {
          try {
            return await ctap.pinRetries(protocol: info.pinProtocol ?? 1);
          } on CtapError {
            return null;
          } on CtapProtocolError {
            return null;
          }
        }

        Future<PinToken> token(int permissions, String rpId) async {
          while (true) {
            pin ??= await askPin();
            _show(FidoPrompt(purpose: purpose, label: label, step: FidoStep.working, ways: ways));
            final now = await triesLeft();
            if (pinSent) {
              // Sent before, to a key that then left: a count that fell
              // since says the key took it as a wrong try (its answer lost),
              // and one it does not give says nothing. Either way it is not
              // sent again untyped.
              final earlier = triesBeforeSent;
              if (now == null || earlier == null || now < earlier) {
                final fell = now != null && earlier != null;
                pin = null;
                pin = await askPin(wrong: fell, again: !fell, triesLeft: now);
                continue;
              }
            }
            triesBeforeSent = now;
            pinSent = true;
            try {
              return await ctap.pinToken(info, utf8.encode(pin!), permissions: permissions, rpId: rpId);
            } on CtapError catch (e) {
              if (e.status != CtapError.pinInvalid) rethrow;
              pin = null;
              // (Where it does not say, the sheet says wrong, with no count.)
              pin = await askPin(wrong: true, triesLeft: await triesLeft());
            }
          }
        }

        _touching = present.hid;
        return await body(ctap, info, token);
      } on CtapTransportError catch (e) {
        if (_cancelled) throw const FidoFailure(FidoFailureKind.cancelled);
        if (e.message.contains('not a FIDO security key')) {
          throw const FidoFailure(FidoFailureKind.notASecurityKey);
        }
        // The key left: wait for it again, with what was typed kept. A PIN
        // already sent is sent again only where the key's count of tries
        // shows it was not taken as a wrong one (token).
        continue;
      } on CtapError catch (e) {
        throw _refusal(e);
      } on CtapProtocolError catch (e) {
        throw FidoFailure(FidoFailureKind.misbehaved, e.message);
      } on CborError catch (e) {
        throw FidoFailure(FidoFailureKind.misbehaved, e.message);
      } on SkSignatureError catch (e) {
        throw FidoFailure(FidoFailureKind.misbehaved, e.message);
      } on SSHKeyDecodeError catch (e) {
        throw FidoFailure(FidoFailureKind.misbehaved, e.message);
      } finally {
        _touching = null;
        // (What went wrong is said by the app, in the person's language: the
        // line for the log is not put into an iPhone's own NFC sheet.)
        await present.end();
      }
    }
    throw const FidoFailure(FidoFailureKind.keyLeft);
  }

  FidoFailure _refusal(CtapError e) {
    if (_cancelled) return const FidoFailure(FidoFailureKind.cancelled);
    final kind = switch (e.status) {
      CtapError.noCredentials => FidoFailureKind.wrongKey,
      CtapError.pinBlocked => FidoFailureKind.pinBlocked,
      CtapError.pinAuthBlocked => FidoFailureKind.pinLocked,
      CtapError.pinNotSet => FidoFailureKind.pinNotSet,
      CtapError.userActionTimeout || CtapError.actionTimeout => FidoFailureKind.timedOut,
      CtapError.keepaliveCancel => FidoFailureKind.cancelled,
      CtapError.unsupportedAlgorithm => FidoFailureKind.cannotMakeKind,
      CtapError.keyStoreFull => FidoFailureKind.keyFull,
      _ => FidoFailureKind.refused,
    };
    return FidoFailure(kind, '$e');
  }

  /// Waits for a security key: one that is plugged in, else one held to the
  /// phone, else whichever comes first.
  Future<_Present> _present(FidoWays ways, void Function() onTouch) async {
    _Present ofUsb(FidoUsbSession usb) {
      final hid = HidCtapDevice(usb, onWaiting: ({required touchNeeded}) {
        if (touchNeeded) onTouch();
      });
      return _Present(hid, ({String? error}) => usb.close(), hid: hid);
    }

    Future<FidoUsbSession?> plugged() async {
      try {
        return await platform.usb();
      } on FidoPlatformError catch (e) {
        if (e.code == FidoPlatformError.denied) throw const FidoFailure(FidoFailureKind.denied);
        return null;
      }
    }

    if (ways.usb) {
      final usb = await plugged();
      if (usb != null) return ofUsb(usb);
    }
    final stop = _stopWaiting = Completer<void>();
    final found = Completer<_Present>();
    var waitingNfc = false;
    if (ways.nfc && ways.nfcOn) {
      waitingNfc = true;
      unawaited(platform.nfc(prompt: nfcSheetText).then((nfc) {
        if (found.isCompleted) {
          unawaited(nfc.end());
          return;
        }
        found.complete(_Present(NfcCtapDevice(nfc), nfc.end));
      }, onError: (Object e) {
        if (found.isCompleted) return;
        final code = e is FidoPlatformError ? e.code : '';
        found.completeError(switch (code) {
          FidoPlatformError.cancelled => const FidoFailure(FidoFailureKind.cancelled),
          FidoPlatformError.nfcOff => const FidoFailure(FidoFailureKind.nfcOff),
          FidoPlatformError.timeout => const FidoFailure(FidoFailureKind.timedOut),
          _ => FidoFailure(FidoFailureKind.noWay, '$e'),
        });
      }));
    }
    Timer? poll;
    if (ways.usb) {
      final clock = Stopwatch()..start();
      var asking = false;
      poll = Timer.periodic(plugPoll, (_) async {
        if (asking || found.isCompleted) return;
        if (!waitingNfc && clock.elapsed > plugWait) {
          found.completeError(const FidoFailure(FidoFailureKind.timedOut));
          return;
        }
        asking = true;
        try {
          final usb = await plugged();
          if (usb == null) return;
          if (found.isCompleted) {
            unawaited(usb.close());
            return;
          }
          found.complete(ofUsb(usb));
          if (waitingNfc) unawaited(platform.nfcCancel());
        } on FidoFailure catch (e) {
          if (!found.isCompleted) found.completeError(e);
        } finally {
          asking = false;
        }
      });
    }
    unawaited(stop.future.then((_) {
      if (!found.isCompleted) found.completeError(const FidoFailure(FidoFailureKind.cancelled));
    }));
    try {
      return await found.future;
    } finally {
      poll?.cancel();
    }
  }
}

/// The one [FidoSigner] of the app. (A test puts one of its own in its
/// place: a conversation begun in one test's time must not hold up the
/// next test's.)
FidoSigner fidoSigner = FidoSigner();
