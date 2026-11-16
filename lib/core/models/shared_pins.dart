import 'dart:convert';

// A team host's shared SFTP bookmarks (4.0, connections.shared_pins): the
// folders a team keeps for one server, which travel in the host's record
// to every member who can see it. The list has the format of a member's own
// pins (`[{"label": ..., "path": ...}]`), held to tighter bounds, because a
// record is written by anyone who may edit the host and is read by every
// member, and a team's record has a size limit of its own.

/// The most bookmarks a team host shares.
const int kMaxSharedPins = 50;

/// The longest folder path a shared bookmark holds. A longer one is not
/// shortened (it would point at another folder): it is left out.
const int kMaxSharedPinPathChars = 1024;

/// The longest name a shared bookmark is shown with; a longer one is cut.
const int kMaxSharedPinLabelChars = 128;

/// The longest text read as a list at all: far past [kMaxSharedPins] whole
/// bookmarks, so nothing longer is parsed.
const int _maxSharedPinsJsonChars = 262144;

/// [s] without the characters a bookmark's name or path may not hold:
/// controls (line breaks and tabs among them) and the marks that turn text
/// around or hide in it (bidi embeddings, overrides and isolates, zero-width
/// marks), so a name in the rail never reads as something it is not. Done by
/// code point, so the source stays plain ASCII.
String cleanPinText(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r <= 0x1f) continue; // C0 controls (tab, CR, LF among them)
    if (r >= 0x7f && r <= 0x9f) continue; // DEL and the C1 controls
    if (r == 0x061c) continue; // Arabic Letter Mark
    if (r >= 0x200b && r <= 0x200f) continue; // zero-width marks, LRM, RLM
    if (r >= 0x202a && r <= 0x202e) continue; // bidi embeddings, overrides
    if (r == 0x2060 || r == 0xfeff) continue; // word joiner, BOM
    if (r >= 0x2066 && r <= 0x2069) continue; // bidi isolates
    buf.writeCharCode(r);
  }
  return buf.toString();
}

/// [s] cut to at most [max] UTF-16 units on a whole character.
String _cut(String s, int max) {
  if (s.length <= max) return s;
  final last = s.codeUnitAt(max - 1);
  final end = last >= 0xd800 && last <= 0xdbff ? max - 1 : max;
  return s.substring(0, end);
}

/// A team host's shared bookmarks as the column holds them, from whatever a
/// record or a screen gives ([v]): a JSON list of `{"label", "path"}`, at
/// most [kMaxSharedPins], each path cleaned, absolute and at most
/// [kMaxSharedPinPathChars] (one that is not is left out), each name cleaned
/// and cut to [kMaxSharedPinLabelChars] (the path when it has none), and no
/// path twice (the first one stays). Null for none, and for anything that is
/// not such a list: a bad value never stops the host from being written.
String? sanitizeSharedPinsJson(Object? v) {
  if (v is! String || v.isEmpty || v.length > _maxSharedPinsJsonChars) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(v);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  final out = <Map<String, String>>[];
  final seen = <String>{};
  for (final e in decoded) {
    if (out.length >= kMaxSharedPins) break;
    if (e is! Map) continue;
    final rawPath = e['path'];
    if (rawPath is! String) continue;
    final path = cleanPinText(rawPath).trim();
    if (path.isEmpty || path.length > kMaxSharedPinPathChars || !path.startsWith('/')) continue;
    if (!seen.add(path)) continue;
    final rawLabel = e['label'];
    final label = _cut(cleanPinText(rawLabel is String ? rawLabel : '').trim(), kMaxSharedPinLabelChars);
    out.add({'label': label.isEmpty ? path : label, 'path': path});
  }
  return out.isEmpty ? null : jsonEncode(out);
}

/// Whether [path] can be shared with the team: absolute, and short enough
/// to be kept whole ([sanitizeSharedPinsJson] leaves anything else out).
bool canSharePinPath(String path) {
  final clean = cleanPinText(path).trim();
  return clean.startsWith('/') && clean.length <= kMaxSharedPinPathChars;
}
