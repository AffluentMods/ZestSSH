/// Bounds for the remembered remote folder as it crosses the sync boundary
/// (remember-last-folder spec, section 2/4). A peer's blob is untrusted: a
/// lying device must not be able to bloat the row or smuggle control /
/// bidirectional-override characters into the path bar.
const int kRemotePathMaxLength = 4096;
const int kRemoteUserMaxLength = 255;

// C0/DEL controls plus the bidi marks and isolates/overrides (U+200E/F,
// U+202A-202E, U+2066-2069), written as escapes so the source reads as it is.
final RegExp _controlChars =
    RegExp(r'[\x00-\x1f\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069]');

/// A stored remote path from an untrusted source, or null when it is not a
/// usable absolute POSIX path. Never throws.
String? sanitizeRemotePath(Object? v) {
  if (v is! String) return null;
  var s = v.replaceAll(_controlChars, '').trim();
  if (s.isEmpty || !s.startsWith('/')) return null;
  if (s.length > kRemotePathMaxLength) return null;
  // Collapse duplicate separators and drop a trailing one (except root) so
  // the stored form is the one `realpath` would have produced.
  s = s.replaceAll(RegExp(r'/{2,}'), '/');
  if (s.length > 1 && s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
}

/// A stored username from an untrusted source, or null.
String? sanitizeRemoteUser(Object? v) {
  if (v is! String) return null;
  final s = v.replaceAll(_controlChars, '').trim();
  if (s.isEmpty || s.length > kRemoteUserMaxLength) return null;
  return s;
}
