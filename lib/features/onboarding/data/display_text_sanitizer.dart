// Sanitizer for free-text fields ingested from an UNTRUSTED `~/.ssh/config`
// during F1 onboarding import. Mirrors the exact bar the cloud-sync importer
// applies to untrusted blob fields (`_renderUnsafe` + `_capText` in
// `lib/services/sync_data_service.dart`) so that config-derived labels, notes
// and usernames are held to the same standard before they render on host cards.

/// Control / format code points stripped from every display-bound free-text
/// field pulled from an untrusted SSH config. Kept byte-for-byte in sync with
/// `sync_data_service.dart`'s `_renderUnsafe` -- both paths MUST strip the same
/// set so the two importers agree:
///   * C0 controls **except** TAB (U+0009), LF (U+000A) and CR (U+000D), so
///     multi-line notes survive but NUL/BEL/ESC etc. cannot.
///   * DEL + the C1 block (U+007F-U+009F).
///   * The Unicode bidi / format controls abused for homoglyph and
///     right-to-left label spoofing: U+200E, U+200F, U+202A-U+202E,
///     U+2066-U+2069.
///
/// Written with `\uXXXX` escapes inside a raw string (the RegExp engine, not
/// Dart, expands them) so this source file stays free of the very characters it
/// strips.
final RegExp _displayUnsafe = RegExp(
    r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f'
    r'\u200e\u200f\u202a-\u202e\u2066-\u2069]');

/// Strip control/bidi spoofing characters from [input] and cap it at [maxLen]
/// code units.
///
/// Stripping happens BEFORE truncation so removed characters don't eat into the
/// visible budget, and the cap prevents a multi-megabyte field from being used
/// to DoS the card UI. A no-op for benign input that is already short and free
/// of control/format chars. May return an empty string (e.g. a value that was
/// nothing but control chars); callers that treat empty as absent should check
/// for it.
String sanitizeDisplayText(String input, {int maxLen = 256}) {
  final stripped = input.replaceAll(_displayUnsafe, '');
  return stripped.length > maxLen ? stripped.substring(0, maxLen) : stripped;
}
