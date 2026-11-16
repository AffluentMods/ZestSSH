import 'dart:convert';

/// A single sample of an /v1/entitlements call. Captured by
/// [PurchaseService.fetchWebEntitlements] every time it runs and
/// surfaced to the in-app diagnostic dialog so we (and the user) can
/// see exactly what the backend is returning instead of guessing.
class EntitlementDiagnostic {
  final DateTime at;
  final String endpoint;
  final int? httpStatus;
  final String responseBodySnippet;
  final String? error;

  /// Length of the bearer token that was sent, or null if no token
  /// was available at call time. **Never the value** - only the
  /// length, since the token is a 30-day account-impersonation
  /// credential.
  final int? tokenBytes;

  /// Source of the bearer token - either "firebase_id_token" (mobile
  /// path) or "desktop_session_token" (Windows / Linux path) or null.
  final String? tokenSource;

  /// Decoded JWT payload, if the token could be parsed. The signature
  /// is stripped before this is populated. Contains the firebase_uid
  /// and email that the backend will see.
  final Map<String, dynamic>? decodedPayload;

  const EntitlementDiagnostic({
    required this.at,
    required this.endpoint,
    this.httpStatus,
    this.responseBodySnippet = '',
    this.error,
    this.tokenBytes,
    this.tokenSource,
    this.decodedPayload,
  });

  /// firebase_uid extracted from the decoded JWT payload (the backend
  /// uses this field name in its session JWTs - see
  /// ZestSSH Cloud's src/routes/auth.js).
  String? get firebaseUid => decodedPayload?['firebaseUid'] as String?;

  /// Email extracted from the decoded JWT payload.
  String? get email => decodedPayload?['email'] as String?;

  /// User row id from the decoded JWT payload.
  Object? get userId => decodedPayload?['userId'];

  /// Build a sanitized markdown blob safe to paste into Discord / a
  /// support thread. The raw bearer token is NEVER included - only
  /// length + decoded non-secret claims.
  String toShareableMarkdown() {
    final lines = <String>[
      '**ZestSSH entitlement diagnostic**',
      '',
      '- At: ${at.toIso8601String()}',
      '- Endpoint: $endpoint',
      '- HTTP status: ${httpStatus ?? "(no response)"}',
      if (error != null) '- Error: $error',
      '- Token: ${tokenBytes == null ? "absent" : "$tokenSource ($tokenBytes bytes, value redacted)"}',
      if (decodedPayload != null) ...[
        '- firebase_uid: ${firebaseUid ?? "(missing)"}',
        '- Email: ${email ?? "(missing)"}',
        if (userId != null) '- userId: $userId',
      ],
      '',
      '**Response body:**',
      '```',
      responseBodySnippet.isEmpty ? '(empty)' : responseBodySnippet,
      '```',
    ];
    return lines.join('\n');
  }
}

/// Decode the payload section of a JWT - header.payload.signature.
///
/// JWTs are designed to be readable by the holder; only the signature
/// needs the secret to verify. We strip the signature entirely
/// before returning, so even if this map leaks through logging or a
/// shareable diagnostic blob, it can't be replayed against the
/// backend. Returns null on malformed input.
Map<String, dynamic>? decodeJwtPayload(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    // Base64-URL decode the payload (middle segment).
    var payload = parts[1];
    // Pad to length multiple of 4 - base64Url decoder requires it.
    final padNeeded = (4 - payload.length % 4) % 4;
    payload = payload + '=' * padNeeded;
    final bytes = base64Url.decode(payload);
    final json = utf8.decode(bytes);
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    return decoded;
  } catch (_) {
    return null;
  }
}
