// A security key's key as SSH signs in with it.
//
// A key file of a security key (OpenSSHSkKeyPair) cannot sign by itself.
// On a phone the app speaks to the key ([FidoKeyPair], through
// [FidoSigner]); on a computer the system's SSH agent does, where the key
// was added to it (ssh-add), as for any hardware key.

import 'package:flutter/foundation.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;
import 'package:zestssh/services/fido/fido_signer.dart';
import 'package:zestssh/services/hardware_token/os_agent_key_pair.dart';

/// The app ended the sign-in itself: the security key did not sign
/// ([failure] says why). It ends the sign-in for good (an
/// [SSHAuthAbortError]): what else the sign-in could offer, a saved
/// password among it, is not tried in the key's place, which is what
/// taking a security key away would otherwise be good for.
class FidoSignInAborted extends SSHAuthAbortError {
  FidoSignInAborted(this.failure)
      : super('The security key did not sign (${failure.kind.name}'
            '${failure.detail == null ? '' : ': ${failure.detail}'}). No other way of signing in was tried in its place.');

  final FidoFailure failure;
}

/// A key on a security key, signing through the phone's NFC or USB.
class FidoKeyPair extends SSHKeyPair {
  FidoKeyPair(this.key, {required this.label, FidoSigner? signer}) : _signer = signer;

  final OpenSSHSkKeyPair key;

  /// What is being signed in to, for the sheet.
  final String label;

  final FidoSigner? _signer;

  @override
  String get name => key.type;

  @override
  String get type => key.type;

  @override
  core_hk.SSHHostKey toPublicKey() => key.toPublicKey();

  @override
  SSHSignature sign(Uint8List data) => throw UnsupportedError(
        'FidoKeyPair.sign(): a security key is asked with signAsync(): it waits for the key and for a touch.',
      );

  @override
  Future<SSHSignature> signAsync(Uint8List data) async {
    // Whatever goes wrong ends the sign-in: nothing here may fall through
    // to "try the next way".
    try {
      return _SkSignature(await (_signer ?? fidoSigner).sign(key, data, label: label));
    } on FidoFailure catch (failure) {
      throw FidoSignInAborted(failure);
    } catch (e) {
      throw FidoSignInAborted(FidoFailure(FidoFailureKind.misbehaved, '$e'));
    }
  }

  @override
  String toPem() => key.toPem();
}

/// A signature as the security key's conversation built and checked it.
class _SkSignature implements SSHSignature {
  _SkSignature(this._encoded);

  final Uint8List _encoded;

  @override
  Uint8List encode() => _encoded;
}

/// A test's word on whether this device is a phone (it speaks to a
/// security key itself); null asks the platform.
@visibleForTesting
bool? debugSpeaksToSecurityKeys;

/// Whether this device speaks to a security key itself: a phone or a
/// tablet. A computer leaves it to the system's SSH agent.
bool get speaksToSecurityKeys =>
    debugSpeaksToSecurityKeys ??
    (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS));

/// [pairs] as they sign in: a security key's key file among them signs
/// through the phone's own conversation with the key, or, on a computer,
/// through the system's SSH agent (which signs where the key was added to
/// it, and says it is not loaded where it was not). Every other key is
/// itself. [label] says what is signed in to.
List<SSHKeyPair> withSecurityKeySigners(List<SSHKeyPair> pairs, {required String label, FidoSigner? signer}) => [
      for (final pair in pairs)
        if (pair is! OpenSSHSkKeyPair)
          pair
        else if (speaksToSecurityKeys)
          FidoKeyPair(pair, label: label, signer: signer)
        else
          OsAgentKeyPair(publicKeyBlob: pair.toPublicKey().encode(), algorithm: pair.type, comment: label),
    ];
