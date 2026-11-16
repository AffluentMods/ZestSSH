import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/passkeys/passkey_json.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/utils/windows_programs.dart';

// Windows' own passkey ceremonies (3.3; the two-step contract, section 4):
// webauthn.dll, the system's WebAuthn, through dart:ffi. Windows Hello, a
// security key over USB, NFC or Bluetooth, and a phone by QR code (hybrid,
// Windows 11) all answer through it, in the system's own dialog.
//
// Windows does not tie an app that is not packaged to a domain, so the app
// writes the clientDataJSON itself, with the origin https://zestssh.com; the
// DLL hashes it (SHA-256) for the authenticator and the app hands the same
// bytes to ZestSSH Cloud, which checks the origin, the challenge and the
// signature over them. For the same reason the app makes and uses passkeys
// for one RP ID only, zestssh.com: the options cannot have it make one for
// another site.
//
// The structs follow webauthn.h of the Windows SDK (10.0.26100, API version
// 9). Each carries its own version, and the DLL takes every version up to
// its own: the app hands over the oldest that holds what it needs (making:
// version 3, or 4 where the DLL is API version 3 or later and takes "prefer
// a passkey that signs in by itself"; using: version 4) and reads only the
// fields of the version the DLL hands back. Everything the DLL hands back is
// freed with its own free function; everything the app hands over lives in
// an Arena for the call.
//
// The calls block until the person is done with the dialog, so they run on
// an isolate of their own (windows_passkeys.dart): the app's window keeps
// drawing, and the dialog is that window's.

// ── Versions ───────────────────────────────────────────────────────

/// The structs' versions the app hands over (webauthn.h).
const kRpEntityVersion = 1;
const kUserEntityVersion = 1;
const kClientDataVersion = 1;
const kCoseParameterVersion = 1;
const kCredentialExVersion = 1;
const kGetAssertionOptionsVersion = 4;

/// The version of WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS for a DLL of
/// [apiVersion]: 4 (bPreferResidentKey) from API version 3 on, else 3
/// (pExcludeCredentialList), which every DLL takes.
int makeCredentialOptionsVersion(int apiVersion) => apiVersion >= 3 ? 4 : 3;

// ── Constants ──────────────────────────────────────────────────────

const kTransportUsb = 0x01;
const kTransportNfc = 0x02;
const kTransportBle = 0x04;
const kTransportTest = 0x08;
const kTransportInternal = 0x10;
const kTransportHybrid = 0x20;
const kTransportSmartCard = 0x40;

const kAttachmentAny = 0;
const kAttachmentPlatform = 1;
const kAttachmentCrossPlatform = 2;

const kUserVerificationAny = 0;
const kUserVerificationRequired = 1;
const kUserVerificationPreferred = 2;
const kUserVerificationDiscouraged = 3;

const kAttestationNone = 1;
const kAttestationIndirect = 2;
const kAttestationDirect = 3;

/// The HRESULTs told apart (winerror.h), as unsigned 32-bit numbers.
const kNteUserCancelled = 0x80090036;
const kNteExists = 0x8009000F;
const kNteNotFound = 0x80090011;
const kNteDeviceNotFound = 0x80090035;
const kNteInvalidParameter = 0x80090027;
const kNteNotSupported = 0x80090029;
const kNteTokenKeysetStorageFull = 0x80090023;
const kHrCancelled = 0x800704C7; // HRESULT_FROM_WIN32(ERROR_CANCELLED)
const kHrTimeout = 0x800705B4; // HRESULT_FROM_WIN32(ERROR_TIMEOUT)
const kHrNotSupported = 0x80070032; // HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)

/// The RP ID the app makes and uses passkeys for on Windows, and the origin
/// it writes for it: ZestSSH Cloud's (a staging server's own with
/// --dart-define=ZEST_PASSKEY_RP_ID=... and ZEST_PASSKEY_ORIGIN=...).
String get kWindowsPasskeyRpId => kZestPasskeyRpId;
String get kWindowsPasskeyOrigin => kZestPasskeyOrigin;

// ── Structs (webauthn.h) ───────────────────────────────────────────

final class WebAuthnRpEntityInformation extends Struct {
  @Uint32()
  external int dwVersion;
  external Pointer<Utf16> pwszId;
  external Pointer<Utf16> pwszName;
  external Pointer<Utf16> pwszIcon;
}

final class WebAuthnUserEntityInformation extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbId;
  external Pointer<Uint8> pbId;
  external Pointer<Utf16> pwszName;
  external Pointer<Utf16> pwszIcon;
  external Pointer<Utf16> pwszDisplayName;
}

final class WebAuthnClientData extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbClientDataJSON;
  external Pointer<Uint8> pbClientDataJSON;
  external Pointer<Utf16> pwszHashAlgId;
}

final class WebAuthnCoseCredentialParameter extends Struct {
  @Uint32()
  external int dwVersion;
  external Pointer<Utf16> pwszCredentialType;
  @Int32()
  external int lAlg;
}

final class WebAuthnCoseCredentialParameters extends Struct {
  @Uint32()
  external int cCredentialParameters;
  external Pointer<WebAuthnCoseCredentialParameter> pCredentialParameters;
}

final class WebAuthnCredential extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbId;
  external Pointer<Uint8> pbId;
  external Pointer<Utf16> pwszCredentialType;
}

final class WebAuthnCredentials extends Struct {
  @Uint32()
  external int cCredentials;
  external Pointer<WebAuthnCredential> pCredentials;
}

final class WebAuthnCredentialEx extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbId;
  external Pointer<Uint8> pbId;
  external Pointer<Utf16> pwszCredentialType;
  @Uint32()
  external int dwTransports;
}

final class WebAuthnCredentialList extends Struct {
  @Uint32()
  external int cCredentials;
  external Pointer<Pointer<WebAuthnCredentialEx>> ppCredentials;
}

final class WebAuthnExtension extends Struct {
  external Pointer<Utf16> pwszExtensionIdentifier;
  @Uint32()
  external int cbExtension;
  external Pointer<Void> pvExtension;
}

final class WebAuthnExtensions extends Struct {
  @Uint32()
  external int cExtensions;
  external Pointer<WebAuthnExtension> pExtensions;
}

/// WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS, every version's fields
/// (the app fills those of version 3 or 4).
final class WebAuthnMakeCredentialOptions extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int dwTimeoutMilliseconds;
  external WebAuthnCredentials credentialList;
  external WebAuthnExtensions extensions;
  @Uint32()
  external int dwAuthenticatorAttachment;
  @Int32()
  external int bRequireResidentKey;
  @Uint32()
  external int dwUserVerificationRequirement;
  @Uint32()
  external int dwAttestationConveyancePreference;
  @Uint32()
  external int dwFlags;
  // Version 2.
  external Pointer<Void> pCancellationId;
  // Version 3.
  external Pointer<WebAuthnCredentialList> pExcludeCredentialList;
  // Version 4.
  @Uint32()
  external int dwEnterpriseAttestation;
  @Uint32()
  external int dwLargeBlobSupport;
  @Int32()
  external int bPreferResidentKey;
  // Version 5.
  @Int32()
  external int bBrowserInPrivateMode;
  // Version 6.
  @Int32()
  external int bEnablePrf;
  // Version 7.
  external Pointer<Void> pLinkedDevice;
  @Uint32()
  external int cbJsonExt;
  external Pointer<Uint8> pbJsonExt;
  // Version 8.
  external Pointer<Void> pPRFGlobalEval;
  @Uint32()
  external int cCredentialHints;
  external Pointer<Pointer<Utf16>> ppwszCredentialHints;
  @Int32()
  external int bThirdPartyPayment;
  // Version 9.
  external Pointer<Utf16> pwszRemoteWebOrigin;
  @Uint32()
  external int cbPublicKeyCredentialCreationOptionsJSON;
  external Pointer<Uint8> pbPublicKeyCredentialCreationOptionsJSON;
  @Uint32()
  external int cbAuthenticatorId;
  external Pointer<Uint8> pbAuthenticatorId;
}

/// WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS, every version's fields (the
/// app fills those of version 4).
final class WebAuthnGetAssertionOptions extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int dwTimeoutMilliseconds;
  external WebAuthnCredentials credentialList;
  external WebAuthnExtensions extensions;
  @Uint32()
  external int dwAuthenticatorAttachment;
  @Uint32()
  external int dwUserVerificationRequirement;
  @Uint32()
  external int dwFlags;
  // Version 2.
  external Pointer<Utf16> pwszU2fAppId;
  external Pointer<Int32> pbU2fAppId;
  // Version 3.
  external Pointer<Void> pCancellationId;
  // Version 4.
  external Pointer<WebAuthnCredentialList> pAllowCredentialList;
  // Version 5.
  @Uint32()
  external int dwCredLargeBlobOperation;
  @Uint32()
  external int cbCredLargeBlob;
  external Pointer<Uint8> pbCredLargeBlob;
  // Version 6.
  external Pointer<Void> pHmacSecretSaltValues;
  @Int32()
  external int bBrowserInPrivateMode;
  // Version 7.
  external Pointer<Void> pLinkedDevice;
  @Int32()
  external int bAutoFill;
  @Uint32()
  external int cbJsonExt;
  external Pointer<Uint8> pbJsonExt;
  // Version 8.
  @Uint32()
  external int cCredentialHints;
  external Pointer<Pointer<Utf16>> ppwszCredentialHints;
  // Version 9.
  external Pointer<Utf16> pwszRemoteWebOrigin;
  @Uint32()
  external int cbPublicKeyCredentialRequestOptionsJSON;
  external Pointer<Uint8> pbPublicKeyCredentialRequestOptionsJSON;
  @Uint32()
  external int cbAuthenticatorId;
  external Pointer<Uint8> pbAuthenticatorId;
}

/// WEBAUTHN_CREDENTIAL_ATTESTATION, every version's fields; only those of
/// the version the DLL wrote are read.
final class WebAuthnCredentialAttestation extends Struct {
  @Uint32()
  external int dwVersion;
  external Pointer<Utf16> pwszFormatType;
  @Uint32()
  external int cbAuthenticatorData;
  external Pointer<Uint8> pbAuthenticatorData;
  @Uint32()
  external int cbAttestation;
  external Pointer<Uint8> pbAttestation;
  @Uint32()
  external int dwAttestationDecodeType;
  external Pointer<Void> pvAttestationDecode;
  @Uint32()
  external int cbAttestationObject;
  external Pointer<Uint8> pbAttestationObject;
  @Uint32()
  external int cbCredentialId;
  external Pointer<Uint8> pbCredentialId;
  // Version 2.
  external WebAuthnExtensions extensions;
  // Version 3.
  @Uint32()
  external int dwUsedTransport;
  // Version 4.
  @Int32()
  external int bEpAtt;
  @Int32()
  external int bLargeBlobSupported;
  @Int32()
  external int bResidentKey;
  // Version 5.
  @Int32()
  external int bPrfEnabled;
  // Version 6.
  @Uint32()
  external int cbUnsignedExtensionOutputs;
  external Pointer<Uint8> pbUnsignedExtensionOutputs;
  // Version 7.
  external Pointer<Void> pHmacSecret;
  @Int32()
  external int bThirdPartyPayment;
  // Version 8.
  @Uint32()
  external int dwTransports;
  @Uint32()
  external int cbClientDataJSON;
  external Pointer<Uint8> pbClientDataJSON;
  @Uint32()
  external int cbRegistrationResponseJSON;
  external Pointer<Uint8> pbRegistrationResponseJSON;
}

/// WEBAUTHN_ASSERTION, every version's fields; only those of the version the
/// DLL wrote are read.
final class WebAuthnAssertion extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbAuthenticatorData;
  external Pointer<Uint8> pbAuthenticatorData;
  @Uint32()
  external int cbSignature;
  external Pointer<Uint8> pbSignature;
  external WebAuthnCredential credential;
  @Uint32()
  external int cbUserId;
  external Pointer<Uint8> pbUserId;
  // Version 2.
  external WebAuthnExtensions extensions;
  @Uint32()
  external int cbCredLargeBlob;
  external Pointer<Uint8> pbCredLargeBlob;
  @Uint32()
  external int dwCredLargeBlobStatus;
  // Version 3.
  external Pointer<Void> pHmacSecret;
  // Version 4.
  @Uint32()
  external int dwUsedTransport;
  // Version 5.
  @Uint32()
  external int cbUnsignedExtensionOutputs;
  external Pointer<Uint8> pbUnsignedExtensionOutputs;
  // Version 6.
  @Uint32()
  external int cbClientDataJSON;
  external Pointer<Uint8> pbClientDataJSON;
  @Uint32()
  external int cbAuthenticationResponseJSON;
  external Pointer<Uint8> pbAuthenticationResponseJSON;
}

// ── What a ceremony is asked, from ZestSSH Cloud's options ─────────

/// A passkey of the account, as a list of them names it: its id and its
/// transports.
final class WinCredential {
  const WinCredential(this.id, this.transports);

  final Uint8List id;
  final List<String> transports;
}

/// One making of a passkey, read from ZestSSH Cloud's registration options:
/// plain values, handed to the isolate the call runs on.
final class WinCreation {
  const WinCreation({
    required this.rpId,
    required this.rpName,
    required this.userId,
    required this.userName,
    required this.userDisplayName,
    required this.algorithms,
    required this.exclude,
    required this.timeoutMs,
    required this.attachment,
    required this.requireResidentKey,
    required this.preferResidentKey,
    required this.userVerification,
    required this.attestation,
    required this.credProps,
    required this.challenge,
    required this.clientData,
  });

  final String rpId;
  final String rpName;
  final Uint8List userId;
  final String userName;
  final String userDisplayName;

  /// COSE algorithms, in the server's order of preference.
  final List<int> algorithms;
  final List<WinCredential> exclude;
  final int timeoutMs;
  final int attachment;
  final bool requireResidentKey;
  final bool preferResidentKey;
  final int userVerification;
  final int attestation;

  /// Whether the server asked for credProps (it is told whether the passkey
  /// signs in by itself, where the DLL says).
  final bool credProps;

  /// The options' challenge, as text.
  final String challenge;

  /// The clientDataJSON the app wrote for this making.
  final Uint8List clientData;
}

/// One use of a passkey, read from ZestSSH Cloud's sign-in options.
final class WinAssertionRequest {
  const WinAssertionRequest({
    required this.rpId,
    required this.allow,
    required this.timeoutMs,
    required this.userVerification,
    required this.challenge,
    required this.clientData,
  });

  final String rpId;
  final List<WinCredential> allow;
  final int timeoutMs;
  final int userVerification;
  final String challenge;
  final Uint8List clientData;
}

/// The longest user id webauthn.h takes (WEBAUTHN_MAX_USER_ID_LENGTH).
const _maxUserId = 64;

/// The longest the person is given to answer: what the server says, kept to
/// between 10 seconds and 10 minutes.
int _timeoutOf(Object? value, int otherwise) {
  final ms = value is num ? value.toInt() : otherwise;
  return ms.clamp(10 * 1000, 10 * 60 * 1000);
}

int _userVerificationOf(Object? value) => switch (value) {
      'required' => kUserVerificationRequired,
      'discouraged' => kUserVerificationDiscouraged,
      _ => kUserVerificationPreferred,
    };

/// The RP ID [given] by the options, where it is the one the app makes
/// passkeys for ([rpId]). Throws [PasskeyError] ('security') otherwise: the
/// app never makes or uses a passkey for another site.
String _ownRpId(Object? given, String rpId) {
  // A build that names no RP ID has no passkeys: it asks Windows for nobody's.
  if (rpId == '') throw const PasskeyError('failed', 'this build is set up for no passkeys');
  final id = given ?? rpId;
  if (id != rpId) throw const PasskeyError('security', 'options: another RP ID');
  return rpId;
}

List<WinCredential> _credentialsOf(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map && (item['type'] ?? 'public-key') == 'public-key')
        if (fromB64u(item['id'], max: kMaxCredentialId) case final id?) WinCredential(id, transportsOf(item['transports'])),
  ];
}

/// ZestSSH Cloud's registration [options] as one making of a passkey for
/// [rpId], whose clientDataJSON carries [origin]. Throws [PasskeyError]
/// ('failed') where the options lack what a passkey needs, ('security') where
/// they name another RP ID.
WinCreation winCreationOf(Map<String, Object?> options, {String? rpId, String? origin}) {
  rpId ??= kWindowsPasskeyRpId;
  origin ??= kWindowsPasskeyOrigin;
  final challenge = challengeOf(options);
  final rp = options['rp'];
  if (rp is! Map) throw const PasskeyError('failed', 'options: no rp');
  final ownRpId = _ownRpId(rp['id'], rpId);
  final rpName = rp['name'] is String && (rp['name'] as String).isNotEmpty ? rp['name'] as String : ownRpId;

  final user = options['user'];
  if (user is! Map) throw const PasskeyError('failed', 'options: no user');
  final userId = fromB64u(user['id'], max: _maxUserId);
  final userName = user['name'];
  if (userId == null || userName is! String || userName.isEmpty) {
    throw const PasskeyError('failed', 'options: no user');
  }
  final displayName = user['displayName'] is String && (user['displayName'] as String).isNotEmpty
      ? user['displayName'] as String
      : userName;

  // The algorithms of public-key parameters, each once; WebAuthn's own
  // (ES256, RS256) where the server named none.
  final algorithms = <int>[];
  final params = options['pubKeyCredParams'];
  if (params is List) {
    for (final p in params) {
      if (p is Map && (p['type'] ?? 'public-key') == 'public-key' && p['alg'] is int) {
        final alg = p['alg'] as int;
        if (!algorithms.contains(alg)) algorithms.add(alg);
      }
    }
  }
  if (algorithms.isEmpty) algorithms.addAll(const [-7, -257]);

  final selection = options['authenticatorSelection'] is Map ? options['authenticatorSelection'] as Map : const {};
  final attachment = switch (selection['authenticatorAttachment']) {
    'platform' => kAttachmentPlatform,
    'cross-platform' => kAttachmentCrossPlatform,
    _ => kAttachmentAny,
  };
  // residentKey as WebAuthn reads it, and requireResidentKey where an older
  // server sent only that.
  final residentKey = selection['residentKey'] ?? (selection['requireResidentKey'] == true ? 'required' : 'discouraged');

  final extensions = options['extensions'];
  return WinCreation(
    rpId: ownRpId,
    rpName: rpName,
    userId: userId,
    userName: userName,
    userDisplayName: displayName,
    algorithms: algorithms,
    exclude: _credentialsOf(options['excludeCredentials']),
    timeoutMs: _timeoutOf(options['timeout'], 5 * 60 * 1000),
    attachment: attachment,
    requireResidentKey: residentKey == 'required',
    preferResidentKey: residentKey == 'preferred',
    userVerification: _userVerificationOf(selection['userVerification']),
    attestation: switch (options['attestation']) {
      'indirect' => kAttestationIndirect,
      'direct' || 'enterprise' => kAttestationDirect,
      _ => kAttestationNone,
    },
    credProps: extensions is Map && extensions['credProps'] == true,
    challenge: challenge,
    clientData: clientDataJson(type: 'webauthn.create', challenge: challenge, origin: origin),
  );
}

/// ZestSSH Cloud's sign-in [options] as one use of a passkey for [rpId].
/// Throws as [winCreationOf].
WinAssertionRequest winAssertionRequestOf(Map<String, Object?> options, {String? rpId, String? origin}) {
  rpId ??= kWindowsPasskeyRpId;
  origin ??= kWindowsPasskeyOrigin;
  final challenge = challengeOf(options);
  return WinAssertionRequest(
    rpId: _ownRpId(options['rpId'], rpId),
    allow: _credentialsOf(options['allowCredentials']),
    timeoutMs: _timeoutOf(options['timeout'], 2 * 60 * 1000),
    userVerification: _userVerificationOf(options['userVerification']),
    challenge: challenge,
    clientData: clientDataJson(type: 'webauthn.get', challenge: challenge, origin: origin),
  );
}

/// [transports] as webauthn.h's bits, for a DLL of [apiVersion]: hybrid from
/// version 6 (it came then) and smart-card from version 9 only (the newest
/// header has it, and an older DLL might refuse a bit it does not know). 0,
/// which says "any transport", where none is left.
int transportMask(List<String> transports, int apiVersion) {
  var mask = 0;
  for (final t in transports) {
    mask |= switch (t) {
      'usb' => kTransportUsb,
      'nfc' => kTransportNfc,
      'ble' => kTransportBle,
      'internal' => kTransportInternal,
      'hybrid' when apiVersion >= 6 => kTransportHybrid,
      'smart-card' when apiVersion >= 9 => kTransportSmartCard,
      _ => 0,
    };
  }
  return mask;
}

/// The transports [mask] names, as WebAuthn names them, in its order of
/// names.
List<String> transportsOfMask(int mask) => [
      if (mask & kTransportBle != 0) 'ble',
      if (mask & kTransportHybrid != 0) 'hybrid',
      if (mask & kTransportInternal != 0) 'internal',
      if (mask & kTransportNfc != 0) 'nfc',
      if (mask & kTransportSmartCard != 0) 'smart-card',
      if (mask & kTransportUsb != 0) 'usb',
    ];

/// The authenticator's attachment by the transport it answered over: Windows
/// Hello is the platform's own, a key or a phone is not. Null where the DLL
/// does not say.
String? attachmentOfTransport(int used) {
  if (used & kTransportInternal != 0) return 'platform';
  if (used & (kTransportUsb | kTransportNfc | kTransportBle | kTransportHybrid | kTransportSmartCard) != 0) {
    return 'cross-platform';
  }
  return null;
}

// ── The structs of a call, in an Arena ─────────────────────────────

/// What WebAuthNAuthenticatorMakeCredential is handed.
final class MakeCredentialArgs {
  const MakeCredentialArgs(this.rp, this.user, this.parameters, this.clientData, this.options);

  final Pointer<WebAuthnRpEntityInformation> rp;
  final Pointer<WebAuthnUserEntityInformation> user;
  final Pointer<WebAuthnCoseCredentialParameters> parameters;
  final Pointer<WebAuthnClientData> clientData;
  final Pointer<WebAuthnMakeCredentialOptions> options;
}

/// What WebAuthNAuthenticatorGetAssertion is handed.
final class GetAssertionArgs {
  const GetAssertionArgs(this.rpId, this.clientData, this.options);

  final Pointer<Utf16> rpId;
  final Pointer<WebAuthnClientData> clientData;
  final Pointer<WebAuthnGetAssertionOptions> options;
}

Pointer<Uint8> _bytes(Allocator arena, Uint8List data) {
  final p = arena<Uint8>(data.isEmpty ? 1 : data.length);
  p.asTypedList(data.length).setAll(0, data);
  return p;
}

Pointer<WebAuthnClientData> _clientData(Allocator arena, Uint8List json) {
  final p = arena<WebAuthnClientData>();
  p.ref
    ..dwVersion = kClientDataVersion
    ..cbClientDataJSON = json.length
    ..pbClientDataJSON = _bytes(arena, json)
    ..pwszHashAlgId = 'SHA-256'.toNativeUtf16(allocator: arena);
  return p;
}

/// [list] as a WEBAUTHN_CREDENTIAL_LIST for a DLL of [apiVersion]; nullptr
/// where it is empty.
Pointer<WebAuthnCredentialList> _credentialList(Allocator arena, List<WinCredential> list, int apiVersion) {
  if (list.isEmpty) return nullptr;
  final items = arena<WebAuthnCredentialEx>(list.length);
  final pointers = arena<Pointer<WebAuthnCredentialEx>>(list.length);
  final type = 'public-key'.toNativeUtf16(allocator: arena);
  for (var i = 0; i < list.length; i++) {
    items[i]
      ..dwVersion = kCredentialExVersion
      ..cbId = list[i].id.length
      ..pbId = _bytes(arena, list[i].id)
      ..pwszCredentialType = type
      ..dwTransports = transportMask(list[i].transports, apiVersion);
    pointers[i] = items + i;
  }
  final out = arena<WebAuthnCredentialList>();
  out.ref
    ..cCredentials = list.length
    ..ppCredentials = pointers;
  return out;
}

/// The structs of [c] for a DLL of [apiVersion], in [arena].
MakeCredentialArgs makeCredentialArgs(Allocator arena, WinCreation c, int apiVersion) {
  final rp = arena<WebAuthnRpEntityInformation>();
  rp.ref
    ..dwVersion = kRpEntityVersion
    ..pwszId = c.rpId.toNativeUtf16(allocator: arena)
    ..pwszName = c.rpName.toNativeUtf16(allocator: arena)
    ..pwszIcon = nullptr;

  final user = arena<WebAuthnUserEntityInformation>();
  user.ref
    ..dwVersion = kUserEntityVersion
    ..cbId = c.userId.length
    ..pbId = _bytes(arena, c.userId)
    ..pwszName = c.userName.toNativeUtf16(allocator: arena)
    ..pwszIcon = nullptr
    ..pwszDisplayName = c.userDisplayName.toNativeUtf16(allocator: arena);

  final params = arena<WebAuthnCoseCredentialParameter>(c.algorithms.length);
  final type = 'public-key'.toNativeUtf16(allocator: arena);
  for (var i = 0; i < c.algorithms.length; i++) {
    params[i]
      ..dwVersion = kCoseParameterVersion
      ..pwszCredentialType = type
      ..lAlg = c.algorithms[i];
  }
  final parameters = arena<WebAuthnCoseCredentialParameters>();
  parameters.ref
    ..cCredentialParameters = c.algorithms.length
    ..pCredentialParameters = params;

  final version = makeCredentialOptionsVersion(apiVersion);
  final options = arena<WebAuthnMakeCredentialOptions>();
  options.ref
    ..dwVersion = version
    ..dwTimeoutMilliseconds = c.timeoutMs
    ..dwAuthenticatorAttachment = c.attachment
    // Version 3 has no "preferred": a passkey that must sign in by itself
    // only where the server requires it.
    ..bRequireResidentKey = c.requireResidentKey ? 1 : 0
    ..dwUserVerificationRequirement = c.userVerification
    ..dwAttestationConveyancePreference = c.attestation
    ..dwFlags = 0
    ..pCancellationId = nullptr
    ..pExcludeCredentialList = _credentialList(arena, c.exclude, apiVersion);
  if (version >= 4) options.ref.bPreferResidentKey = c.preferResidentKey ? 1 : 0;

  return MakeCredentialArgs(rp, user, parameters, _clientData(arena, c.clientData), options);
}

/// The structs of [r] for a DLL of [apiVersion], in [arena].
GetAssertionArgs getAssertionArgs(Allocator arena, WinAssertionRequest r, int apiVersion) {
  final options = arena<WebAuthnGetAssertionOptions>();
  options.ref
    ..dwVersion = kGetAssertionOptionsVersion
    ..dwTimeoutMilliseconds = r.timeoutMs
    ..dwAuthenticatorAttachment = kAttachmentAny
    ..dwUserVerificationRequirement = r.userVerification
    ..dwFlags = 0
    ..pwszU2fAppId = nullptr
    ..pbU2fAppId = nullptr
    ..pCancellationId = nullptr
    ..pAllowCredentialList = _credentialList(arena, r.allow, apiVersion);
  return GetAssertionArgs(r.rpId.toNativeUtf16(allocator: arena), _clientData(arena, r.clientData), options);
}

// ── What the DLL hands back, read ──────────────────────────────────

/// A new passkey, as WEBAUTHN_CREDENTIAL_ATTESTATION gave it.
final class WinRegistration {
  const WinRegistration({
    required this.credentialId,
    required this.attestationObject,
    required this.transports,
    required this.attachment,
    required this.residentKey,
  });

  final Uint8List credentialId;
  final Uint8List attestationObject;
  final List<String> transports;
  final String? attachment;

  /// Whether it signs in by itself; null where the DLL does not say.
  final bool? residentKey;
}

/// A passkey's answer, as WEBAUTHN_ASSERTION gave it.
final class WinAssertion {
  const WinAssertion({
    required this.credentialId,
    required this.authenticatorData,
    required this.signature,
    required this.userHandle,
    required this.attachment,
  });

  final Uint8List credentialId;
  final Uint8List authenticatorData;
  final Uint8List signature;
  final Uint8List userHandle;
  final String? attachment;
}

Uint8List _copy(Pointer<Uint8> p, int length) =>
    p == nullptr || length <= 0 ? Uint8List(0) : Uint8List.fromList(p.asTypedList(length));

/// The credential id in [authData]'s attested credential data (rpIdHash 32,
/// flags 1, counter 4, AAGUID 16, the id's length 2 and the id); null where
/// it holds none.
Uint8List? credentialIdOfAuthData(Uint8List authData) {
  const at = 0x40;
  if (authData.length < 55 || authData[32] & at == 0) return null;
  final length = (authData[53] << 8) | authData[54];
  if (length == 0 || length > kMaxCredentialId || authData.length < 55 + length) return null;
  return Uint8List.sublistView(authData, 55, 55 + length);
}

/// What [p] (written by the DLL) says of the new passkey: only the fields of
/// the version it carries are read.
WinRegistration readCredentialAttestation(Pointer<WebAuthnCredentialAttestation> p) {
  final a = p.ref;
  final version = a.dwVersion;
  var id = _copy(a.pbCredentialId, a.cbCredentialId);
  if (id.isEmpty) id = credentialIdOfAuthData(_copy(a.pbAuthenticatorData, a.cbAuthenticatorData)) ?? id;
  final used = version >= 3 ? a.dwUsedTransport : 0;
  final supported = version >= 8 ? a.dwTransports : 0;
  return WinRegistration(
    credentialId: id,
    attestationObject: _copy(a.pbAttestationObject, a.cbAttestationObject),
    // The transports the passkey has where the DLL says (version 8), else the
    // one it was made over.
    transports: transportsOfMask(supported != 0 ? supported : used),
    attachment: attachmentOfTransport(used),
    residentKey: version >= 4 ? a.bResidentKey != 0 : null,
  );
}

/// What [p] (written by the DLL) says of the passkey's answer. [allow]: the
/// passkeys asked for; where only one was and the DLL names none, it is the
/// one that answered (CTAP lets an authenticator leave the id out then).
WinAssertion readAssertion(Pointer<WebAuthnAssertion> p, List<WinCredential> allow) {
  final a = p.ref;
  var id = _copy(a.credential.pbId, a.credential.cbId);
  if (id.isEmpty && allow.length == 1) id = allow.single.id;
  return WinAssertion(
    credentialId: id,
    authenticatorData: _copy(a.pbAuthenticatorData, a.cbAuthenticatorData),
    signature: _copy(a.pbSignature, a.cbSignature),
    userHandle: _copy(a.pbUserId, a.cbUserId),
    attachment: attachmentOfTransport(a.dwVersion >= 4 ? a.dwUsedTransport : 0),
  );
}

/// [r] as a RegistrationResponseJSON, with the clientDataJSON the app wrote
/// ([clientData]). [credProps]: the server asked whether it signs in by
/// itself.
Map<String, Object?> registrationJsonOf(WinRegistration r, Uint8List clientData, {required bool credProps}) {
  final id = b64u(r.credentialId);
  return {
    'id': id,
    'rawId': id,
    'type': 'public-key',
    'response': {
      'clientDataJSON': b64u(clientData),
      'attestationObject': b64u(r.attestationObject),
      'transports': r.transports,
    },
    if (r.attachment != null) 'authenticatorAttachment': r.attachment,
    'clientExtensionResults': {
      if (credProps && r.residentKey != null) 'credProps': {'rk': r.residentKey},
    },
  };
}

/// [a] as an AuthenticationResponseJSON, with the clientDataJSON the app
/// wrote ([clientData]).
Map<String, Object?> authenticationJsonOf(WinAssertion a, Uint8List clientData) {
  final id = b64u(a.credentialId);
  return {
    'id': id,
    'rawId': id,
    'type': 'public-key',
    'response': {
      'clientDataJSON': b64u(clientData),
      'authenticatorData': b64u(a.authenticatorData),
      'signature': b64u(a.signature),
      if (a.userHandle.isNotEmpty) 'userHandle': b64u(a.userHandle),
    },
    if (a.attachment != null) 'authenticatorAttachment': a.attachment,
    'clientExtensionResults': <String, Object?>{},
  };
}

// ── What a failure means ───────────────────────────────────────────

/// What webauthn.dll's [hr] (which WebAuthNGetErrorName calls [name]) means,
/// when signing in ([signIn]) or making a passkey: the person's own cancel,
/// or a closed or timed-out dialog, is [PasskeyCancelled]; the rest a
/// [PasskeyError] with the HRESULT and its name as the detail.
Exception windowsFailureOf(int hr, String? name, {required bool signIn}) {
  final code = hr & 0xFFFFFFFF;
  final detail = '0x${code.toRadixString(16).toUpperCase().padLeft(8, '0')}'
      '${name == null || name.isEmpty ? '' : ' $name'}';
  switch (code) {
    case kNteUserCancelled || kHrCancelled || kHrTimeout:
      return const PasskeyCancelled();
    case kNteExists:
      // InvalidStateError: this authenticator holds one of the passkeys the
      // server listed to leave out.
      return PasskeyError('invalid-state', detail);
    case kNteNotFound || kNteDeviceNotFound:
      return PasskeyError(signIn ? 'no-credential' : 'failed', detail);
    case kNteInvalidParameter || kNteNotSupported || kNteTokenKeysetStorageFull || kHrNotSupported:
      // NotSupportedError and ConstraintError: nothing here can make or use
      // a passkey as asked (no algorithm it has, a key that is full).
      return PasskeyError('unsupported', detail);
  }
  return PasskeyError('failed', detail);
}

// ── webauthn.dll ───────────────────────────────────────────────────

typedef _GetApiVersionNative = Uint32 Function();
typedef _GetApiVersion = int Function();
typedef _IsPlatformAvailableNative = Int32 Function(Pointer<Int32>);
typedef _IsPlatformAvailable = int Function(Pointer<Int32>);
typedef _MakeCredentialNative = Int32 Function(
    IntPtr,
    Pointer<WebAuthnRpEntityInformation>,
    Pointer<WebAuthnUserEntityInformation>,
    Pointer<WebAuthnCoseCredentialParameters>,
    Pointer<WebAuthnClientData>,
    Pointer<WebAuthnMakeCredentialOptions>,
    Pointer<Pointer<WebAuthnCredentialAttestation>>);
typedef _MakeCredential = int Function(
    int,
    Pointer<WebAuthnRpEntityInformation>,
    Pointer<WebAuthnUserEntityInformation>,
    Pointer<WebAuthnCoseCredentialParameters>,
    Pointer<WebAuthnClientData>,
    Pointer<WebAuthnMakeCredentialOptions>,
    Pointer<Pointer<WebAuthnCredentialAttestation>>);
typedef _GetAssertionNative = Int32 Function(IntPtr, Pointer<Utf16>, Pointer<WebAuthnClientData>,
    Pointer<WebAuthnGetAssertionOptions>, Pointer<Pointer<WebAuthnAssertion>>);
typedef _GetAssertion = int Function(int, Pointer<Utf16>, Pointer<WebAuthnClientData>,
    Pointer<WebAuthnGetAssertionOptions>, Pointer<Pointer<WebAuthnAssertion>>);
typedef _FreeAttestationNative = Void Function(Pointer<WebAuthnCredentialAttestation>);
typedef _FreeAttestation = void Function(Pointer<WebAuthnCredentialAttestation>);
typedef _FreeAssertionNative = Void Function(Pointer<WebAuthnAssertion>);
typedef _FreeAssertion = void Function(Pointer<WebAuthnAssertion>);
typedef _GetErrorNameNative = Pointer<Utf16> Function(Int32);
typedef _GetErrorName = Pointer<Utf16> Function(int);

/// webauthn.dll's functions, looked up in the isolate that calls them.
final class WebAuthnDll {
  WebAuthnDll._(DynamicLibrary dll)
      : _apiVersion = dll.lookupFunction<_GetApiVersionNative, _GetApiVersion>('WebAuthNGetApiVersionNumber'),
        _isPlatformAvailable = dll.lookupFunction<_IsPlatformAvailableNative, _IsPlatformAvailable>(
            'WebAuthNIsUserVerifyingPlatformAuthenticatorAvailable'),
        _makeCredential =
            dll.lookupFunction<_MakeCredentialNative, _MakeCredential>('WebAuthNAuthenticatorMakeCredential'),
        _getAssertion = dll.lookupFunction<_GetAssertionNative, _GetAssertion>('WebAuthNAuthenticatorGetAssertion'),
        _freeAttestation =
            dll.lookupFunction<_FreeAttestationNative, _FreeAttestation>('WebAuthNFreeCredentialAttestation'),
        _freeAssertion = dll.lookupFunction<_FreeAssertionNative, _FreeAssertion>('WebAuthNFreeAssertion'),
        _getErrorName = dll.lookupFunction<_GetErrorNameNative, _GetErrorName>('WebAuthNGetErrorName');

  final _GetApiVersion _apiVersion;
  final _IsPlatformAvailable _isPlatformAvailable;
  final _MakeCredential _makeCredential;
  final _GetAssertion _getAssertion;
  final _FreeAttestation _freeAttestation;
  final _FreeAssertion _freeAssertion;
  final _GetErrorName _getErrorName;

  /// webauthn.dll from System32, by its full path (lib/utils/
  /// windows_programs.dart): it is no KnownDLL, so a bare name would be
  /// looked for in the app's own folder first, where a planted one could
  /// read every ceremony (CWE-427). Null where it is not there (Windows 10
  /// before 1903) or lacks what the app calls.
  static WebAuthnDll? open() {
    if (!Platform.isWindows) return null;
    try {
      return WebAuthnDll._(DynamicLibrary.open('$windowsRoot\\System32\\webauthn.dll'));
    } on ArgumentError {
      return null;
    } on UnsupportedError {
      return null;
    }
  }

  /// The DLL's WEBAUTHN_API_VERSION (1 on Windows 10 1903).
  int apiVersion() => _apiVersion();

  /// Whether Windows Hello can make and use passkeys on this PC (asks no
  /// one, shows nothing).
  bool platformAuthenticatorAvailable() => using((arena) {
        final available = arena<Int32>();
        return _isPlatformAvailable(available) == 0 && available.value != 0;
      });

  /// WebAuthNAuthenticatorMakeCredential: shows the system's dialog and
  /// waits for the person.
  int makeCredential(int hwnd, MakeCredentialArgs args, Pointer<Pointer<WebAuthnCredentialAttestation>> out) =>
      _makeCredential(hwnd, args.rp, args.user, args.parameters, args.clientData, args.options, out);

  /// WebAuthNAuthenticatorGetAssertion: shows the system's dialog and waits
  /// for the person.
  int getAssertion(int hwnd, GetAssertionArgs args, Pointer<Pointer<WebAuthnAssertion>> out) =>
      _getAssertion(hwnd, args.rpId, args.clientData, args.options, out);

  void freeCredentialAttestation(Pointer<WebAuthnCredentialAttestation> p) => _freeAttestation(p);

  void freeAssertion(Pointer<WebAuthnAssertion> p) => _freeAssertion(p);

  /// The DOM error's name the DLL gives [hr] ("NotAllowedError" and so on).
  String? errorName(int hr) {
    final name = _getErrorName(hr.toSigned(32));
    return name == nullptr ? null : name.toDartString();
  }
}

// ── One ceremony, on the isolate it runs on ────────────────────────

/// What one ceremony came to, as plain values (it comes back from the
/// isolate the call ran on): a failure's HRESULT and its name, or what was
/// made or used. [broken] says what the DLL left out where it answered S_OK
/// with nothing.
final class WinOutcome {
  const WinOutcome.failed(this.hr, this.errorName)
      : registration = null,
        assertion = null,
        broken = null,
        unavailable = false;
  const WinOutcome.registered(WinRegistration this.registration)
      : hr = 0,
        errorName = null,
        assertion = null,
        broken = null,
        unavailable = false;
  const WinOutcome.asserted(WinAssertion this.assertion)
      : hr = 0,
        errorName = null,
        registration = null,
        broken = null,
        unavailable = false;
  const WinOutcome.broken(String this.broken)
      : hr = 0,
        errorName = null,
        registration = null,
        assertion = null,
        unavailable = false;
  const WinOutcome.unavailable()
      : hr = 0,
        errorName = null,
        registration = null,
        assertion = null,
        broken = null,
        unavailable = true;

  final int hr;
  final String? errorName;
  final WinRegistration? registration;
  final WinAssertion? assertion;
  final String? broken;
  final bool unavailable;
}

/// Makes a passkey for [c] in the dialog of the window [hwnd]: blocks until
/// the person is done. Run on an isolate of its own.
WinOutcome makeCredentialBlocking(WinCreation c, int hwnd) {
  final dll = WebAuthnDll.open();
  if (dll == null) return const WinOutcome.unavailable();
  final apiVersion = dll.apiVersion();
  return using((arena) {
    final args = makeCredentialArgs(arena, c, apiVersion);
    final out = arena<Pointer<WebAuthnCredentialAttestation>>();
    final hr = dll.makeCredential(hwnd, args, out);
    final attestation = out.value;
    try {
      if (hr != 0) return WinOutcome.failed(hr, dll.errorName(hr));
      if (attestation == nullptr) return const WinOutcome.broken('no attestation');
      final made = readCredentialAttestation(attestation);
      if (made.credentialId.isEmpty) return const WinOutcome.broken('no credential id');
      if (made.attestationObject.isEmpty) return const WinOutcome.broken('no attestation object');
      return WinOutcome.registered(made);
    } finally {
      if (attestation != nullptr) dll.freeCredentialAttestation(attestation);
    }
  });
}

/// Uses a passkey for [r] in the dialog of the window [hwnd]: blocks until
/// the person is done. Run on an isolate of its own.
WinOutcome getAssertionBlocking(WinAssertionRequest r, int hwnd) {
  final dll = WebAuthnDll.open();
  if (dll == null) return const WinOutcome.unavailable();
  final apiVersion = dll.apiVersion();
  return using((arena) {
    final args = getAssertionArgs(arena, r, apiVersion);
    final out = arena<Pointer<WebAuthnAssertion>>();
    final hr = dll.getAssertion(hwnd, args, out);
    final assertion = out.value;
    try {
      if (hr != 0) return WinOutcome.failed(hr, dll.errorName(hr));
      if (assertion == nullptr) return const WinOutcome.broken('no assertion');
      final used = readAssertion(assertion, r.allow);
      if (used.credentialId.isEmpty) return const WinOutcome.broken('no credential id');
      if (used.authenticatorData.isEmpty || used.signature.isEmpty) return const WinOutcome.broken('no signature');
      return WinOutcome.asserted(used);
    } finally {
      if (assertion != nullptr) dll.freeAssertion(assertion);
    }
  });
}

// ── The app's window ───────────────────────────────────────────────

/// The window webauthn.dll's dialog belongs to: the one in front where it is
/// this app's (the person just clicked in it), else the app's main window.
/// 0 where there is none.
int appWindowHandle() {
  if (!Platform.isWindows) return 0;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final foreground = user32.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
    final threadProcessId = user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
    final findWindowEx = user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
    final currentProcessId = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
    final me = currentProcessId();
    return using((arena) {
      final pid = arena<Uint32>();
      bool ours(int hwnd) {
        if (hwnd == 0) return false;
        pid.value = 0;
        threadProcessId(hwnd, pid);
        return pid.value == me;
      }

      final front = foreground();
      if (ours(front)) return front;
      // Flutter's runner registers its main window under this class
      // (windows/runner/win32_window.cpp).
      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena);
      var hwnd = 0;
      for (var i = 0; i < 64; i++) {
        hwnd = findWindowEx(0, hwnd, cls, nullptr);
        if (hwnd == 0 || ours(hwnd)) return hwnd;
      }
      return 0;
    });
  } on ArgumentError {
    return 0;
  }
}
