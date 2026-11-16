import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/services/passkeys/passkey_platform.dart';

// What every platform's ceremony hands through (3.3; the two-step contract,
// sections 3.3, 3.4 and 4): ZestSSH Cloud's options, cleaned for the system
// that makes or uses the passkey, and the system's answer, made into what the
// server reads (lib/passkeys.js there): byte strings in base64url without
// padding, an id that is its rawId, the type public-key, the fields of the
// response, and a clientDataJSON of the ceremony that was asked for, for the
// challenge that was asked. Android and iOS hand their answer over as JSON;
// on Windows it is built from what webauthn.dll gives (windows_passkeys.dart)
// and checked here the same way.
//
// Nothing here keeps, logs or shows a challenge or a credential: they only
// pass through.

/// The transports WebAuthn names, as ZestSSH Cloud keeps them.
const kPasskeyTransports = {'usb', 'nfc', 'ble', 'internal', 'hybrid', 'smart-card'};

/// The transports a phone's system is handed in a list of passkeys: those it
/// knows. 'smart-card' (Windows only) is left out, as Android's parser has
/// refused a transport it does not know; a transport is only a hint, and a
/// passkey with none listed is looked for everywhere.
const kPhoneTransports = {'usb', 'nfc', 'ble', 'internal', 'hybrid'};

/// The longest credential id ZestSSH Cloud takes (1023 bytes, WebAuthn's own
/// limit).
const kMaxCredentialId = 1023;

final _b64uText = RegExp(r'^[A-Za-z0-9_-]+$');
final _anyBase64Text = RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$');

/// [bytes] as base64url without padding.
String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// [text] as bytes where it is base64url without padding of 1 to [max] bytes,
/// written the one way those bytes are written (as ZestSSH Cloud reads it);
/// null otherwise.
Uint8List? fromB64u(Object? text, {int max = 16 * 1024}) {
  if (text is! String || text.isEmpty || text.length % 4 == 1 || !_b64uText.hasMatch(text)) return null;
  if (text.length > (max * 4 + 2) ~/ 3 + 1) return null;
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(base64Url.normalize(text));
  } on FormatException {
    return null;
  }
  if (bytes.isEmpty || bytes.length > max || b64u(bytes) != text) return null;
  return bytes;
}

/// [text] as bytes where it is base64 of either alphabet, with or without
/// padding, of 1 to [max] bytes: what a system's answer may carry (some
/// passkey providers on Android pad, or write the standard alphabet). Null
/// otherwise.
Uint8List? fromAnyBase64(Object? text, {int max = 64 * 1024}) {
  if (text is! String || text.isEmpty || !_anyBase64Text.hasMatch(text)) return null;
  final bare = text.replaceAll('=', '');
  if (bare.isEmpty || bare.length % 4 == 1 || bare.length > (max * 4 + 2) ~/ 3 + 1) return null;
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(base64Url.normalize(bare));
  } on FormatException {
    return null;
  }
  return bytes.isEmpty || bytes.length > max ? null : bytes;
}

/// [value] with every null left out of its maps, at every depth (Android's
/// parser refuses a null where it wants a list or a word), and its maps keyed
/// by text.
Object? _withoutNulls(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries)
        if (e.value != null) '${e.key}': _withoutNulls(e.value),
    };
  }
  if (value is List) return [for (final v in value) _withoutNulls(v)];
  return value;
}

/// A list of credentials ([raw], the options' excludeCredentials or
/// allowCredentials) as a system takes it: each with an id that is
/// base64url, the type public-key, and only the transports of [allowed]
/// (none listed where it has none of them).
List<Map<String, Object?>> _descriptors(Object? raw, Set<String> allowed) {
  if (raw is! List) return const [];
  final out = <Map<String, Object?>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final id = item['id'];
    if (fromB64u(id, max: kMaxCredentialId) == null) continue;
    if (item['type'] != null && item['type'] != 'public-key') continue;
    final transports = transportsOf(item['transports'], allowed);
    out.add({'type': 'public-key', 'id': id, if (transports.isNotEmpty) 'transports': transports});
  }
  return out;
}

/// The transports of [raw] that [allowed] names, each once, in the order
/// given.
List<String> transportsOf(Object? raw, [Set<String> allowed = kPasskeyTransports]) {
  if (raw is! List) return const [];
  final seen = <String>{};
  return [
    for (final t in raw)
      if (t is String && allowed.contains(t) && seen.add(t)) t,
  ];
}

/// ZestSSH Cloud's registration options (PublicKeyCredentialCreationOptionsJSON)
/// as a phone's system is handed them: every null left out, and the passkeys
/// to leave out each with its id and the transports [allowed]. Everything
/// else as the server wrote it.
Map<String, Object?> creationOptionsForPlatform(Map<String, Object?> options,
    {Set<String> allowed = kPhoneTransports}) {
  final out = _withoutNulls(options)! as Map<String, Object?>;
  final exclude = _descriptors(out['excludeCredentials'], allowed);
  if (exclude.isEmpty) {
    out.remove('excludeCredentials');
  } else {
    out['excludeCredentials'] = exclude;
  }
  return out;
}

/// ZestSSH Cloud's sign-in options (PublicKeyCredentialRequestOptionsJSON) as
/// a phone's system is handed them: every null left out, and the account's
/// passkeys each with its id and the transports [allowed].
Map<String, Object?> requestOptionsForPlatform(Map<String, Object?> options,
    {Set<String> allowed = kPhoneTransports}) {
  final out = _withoutNulls(options)! as Map<String, Object?>;
  final allow = _descriptors(out['allowCredentials'], allowed);
  if (allow.isEmpty) {
    out.remove('allowCredentials');
  } else {
    out['allowCredentials'] = allow;
  }
  return out;
}

/// The challenge of [options], as text: base64url of 16 bytes or more, as
/// ZestSSH Cloud makes them (32). Throws [PasskeyError] ('failed') otherwise:
/// no system is handed options it cannot answer.
String challengeOf(Map<String, Object?> options) {
  final challenge = options['challenge'];
  final bytes = fromB64u(challenge, max: 1024);
  if (bytes == null || bytes.length < 16) throw const PasskeyError('failed', 'options: no challenge');
  return challenge! as String;
}

/// The clientDataJSON of a ceremony the app makes itself (Windows, where the
/// system writes none): WebAuthn's own order of members, and no topOrigin.
/// [type] is 'webauthn.create' or 'webauthn.get'; [challenge] the options'
/// own text.
Uint8List clientDataJson({required String type, required String challenge, required String origin}) {
  final data = <String, Object?>{'type': type, 'challenge': challenge, 'origin': origin, 'crossOrigin': false};
  return Uint8List.fromList(utf8.encode(jsonEncode(data)));
}

/// The new passkey a system handed over ([raw]: its JSON text, or the object),
/// as ZestSSH Cloud reads a RegistrationResponseJSON. Throws [PasskeyError]
/// ('failed') where it lacks what the server needs, or answers another
/// ceremony or another [challenge].
Map<String, Object?> registrationResponseOf(Object? raw, {required String challenge}) => _responseOf(
      raw,
      ceremony: 'webauthn.create',
      challenge: challenge,
      needed: const ['clientDataJSON', 'attestationObject'],
      optional: const ['authenticatorData', 'publicKey'],
    );

/// A passkey's answer a system handed over ([raw]), as ZestSSH Cloud reads an
/// AuthenticationResponseJSON. Throws as [registrationResponseOf].
Map<String, Object?> authenticationResponseOf(Object? raw, {required String challenge}) => _responseOf(
      raw,
      ceremony: 'webauthn.get',
      challenge: challenge,
      needed: const ['clientDataJSON', 'authenticatorData', 'signature'],
      optional: const ['userHandle'],
    );

Map<String, Object?> _responseOf(
  Object? raw, {
  required String ceremony,
  required String challenge,
  required List<String> needed,
  required List<String> optional,
}) {
  Object? decoded = raw;
  if (raw is String) {
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const PasskeyError('failed', 'response: not JSON');
    }
  }
  if (decoded is! Map) throw const PasskeyError('failed', 'response: not an object');
  final json = _withoutNulls(decoded)! as Map<String, Object?>;

  // The credential's id: the server takes it only where id is rawId, in
  // base64url without padding.
  final id = fromAnyBase64(json['id'], max: kMaxCredentialId);
  final rawId = fromAnyBase64(json['rawId'], max: kMaxCredentialId);
  final credential = id ?? rawId;
  if (credential == null) throw const PasskeyError('failed', 'response: no credential id');
  if (id != null && rawId != null && b64u(id) != b64u(rawId)) {
    throw const PasskeyError('failed', 'response: id is not rawId');
  }
  json['id'] = b64u(credential);
  json['rawId'] = b64u(credential);

  final type = json['type'] ?? 'public-key';
  if (type != 'public-key') throw const PasskeyError('failed', 'response: not a public key');
  json['type'] = type;

  final inner = json['response'];
  if (inner is! Map<String, Object?>) throw const PasskeyError('failed', 'response: no response');
  for (final field in needed) {
    final bytes = fromAnyBase64(inner[field]);
    if (bytes == null) throw PasskeyError('failed', 'response: no $field');
    inner[field] = b64u(bytes);
  }
  for (final field in optional) {
    final value = inner[field];
    if (value == null || value == '') {
      inner.remove(field);
      continue;
    }
    final bytes = fromAnyBase64(value);
    if (bytes == null) {
      // A user handle the server cannot read would fail the sign-in there:
      // said here instead. The others the server does not read.
      if (field == 'userHandle') throw const PasskeyError('failed', 'response: unreadable userHandle');
      inner.remove(field);
      continue;
    }
    inner[field] = b64u(bytes);
  }
  if (inner.containsKey('transports')) inner['transports'] = transportsOf(inner['transports']);

  // The clientDataJSON the system wrote, read as the server reads it.
  final Object? clientData;
  try {
    clientData = jsonDecode(utf8.decode(fromAnyBase64(inner['clientDataJSON'])!));
  } on FormatException {
    throw const PasskeyError('failed', 'response: unreadable clientDataJSON');
  }
  if (clientData is! Map || clientData['type'] != ceremony) {
    throw const PasskeyError('failed', 'response: another ceremony');
  }
  if (clientData['challenge'] != challenge) throw const PasskeyError('failed', 'response: another challenge');

  final attachment = json['authenticatorAttachment'];
  if (attachment != 'platform' && attachment != 'cross-platform') json.remove('authenticatorAttachment');
  if (json['clientExtensionResults'] is! Map) json['clientExtensionResults'] = <String, Object?>{};
  return json;
}
