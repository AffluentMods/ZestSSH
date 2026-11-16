/// Catalog of every key the terminal soft-keyboard can render. Used by
/// both the legacy two-row layout (which picks specific keys per slot)
/// and the new scrollable single-row layout (which renders every key
/// in [allSoftKeys] order, minus user-disabled ids).
///
/// Each entry has a stable `id` used in the disabled-keys set persisted
/// to SharedPreferences - so renaming `label` is safe but renaming `id`
/// is a breaking change.
library;

import 'package:xterm/xterm.dart';

/// The keys of the row that a terminal sends in another form once a program
/// has asked for it (the arrows, Home and End), by the code the row hands
/// over for each, which is their form until then.
const softKeyTerminalKeys = <String, TerminalKey>{
  '\x1B[A': TerminalKey.arrowUp,
  '\x1B[B': TerminalKey.arrowDown,
  '\x1B[C': TerminalKey.arrowRight,
  '\x1B[D': TerminalKey.arrowLeft,
  '\x1B[H': TerminalKey.home,
  '\x1B[F': TerminalKey.end,
};

/// Types [key], which the row handed over, into [terminal]. An arrow, Home
/// or End goes as the key it is, so that it is sent in the form the program
/// at the other end asked for: an editor or a pager asks for `ESC O A`, and
/// the row's own `ESC [ A` is no arrow then to less, man, anything under
/// screen and others (the row's arrows did nothing in them). Everything else
/// goes as it is.
void typeSoftKey(Terminal terminal, String key) {
  final asKey = softKeyTerminalKeys[key];
  if (asKey == null) {
    terminal.textInput(key);
  } else {
    terminal.keyInput(asKey);
  }
}

/// How the key row looks (Settings > Terminal > Keyboard row). Since 3.2.1
/// only a look: every key is as wide as the next in both, and both layouts
/// have it.
enum SoftKeyRowStyle {
  /// An outline round the arrows with Home and End.
  grouped,

  /// Plain keys, nothing outlined.
  flat;

  /// The stored value's style; an unknown one is [grouped], and so is 3.1's
  /// Compact, whose small keys are [SoftKeySize.small] now.
  static SoftKeyRowStyle fromId(String? id) =>
      values.where((s) => s.name == id).firstOrNull ?? grouped;
}

/// How big the row's keys are, in either layout (3.2.1:
/// the scrollable row's keys were too big, and only the
/// two rows had smaller ones, as their Compact style).
enum SoftKeySize {
  small,
  medium,
  large;

  /// The stored value's size; none is [medium], the size before 3.2.1.
  static SoftKeySize fromId(String? id) =>
      values.where((s) => s.name == id).firstOrNull ?? medium;
}

/// What the row does while a hardware keyboard is typed on (3.2.1).
enum HardwareKeysRow {
  /// It hides, and comes back with the on-screen keyboard.
  hide,

  /// It stays as it is.
  always,

  /// It keeps only the keys a laptop-style keyboard lacks
  /// ([hardwareMissingKeyIds]).
  missingOnly;

  /// The stored choice; null where none was made.
  static HardwareKeysRow? fromId(String? id) =>
      values.where((v) => v.name == id).firstOrNull;

  /// Unchosen, a tablet (often in a keyboard case) keeps the keys its
  /// keyboard lacks and a phone hides the row.
  static HardwareKeysRow defaultFor({required bool tablet}) =>
      tablet ? missingOnly : hide;
}

/// The keys a laptop-style keyboard (a tablet's case) has none of, as the
/// row shows them while one is typed on: in landscape one row, upright two
/// with Insert, Home and Page Up over Delete, End and Page Down, as on a
/// desktop keyboard.
const List<String> hardwareMissingKeyIds = [
  'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
  'ins', 'del', 'home', 'end', 'pgup', 'pgdn',
];
const List<String> hardwareMissingRow1 = ['f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'ins', 'home', 'pgup'];
const List<String> hardwareMissingRow2 = ['f7', 'f8', 'f9', 'f10', 'f11', 'f12', 'del', 'end', 'pgdn'];

/// The keys the two-row layout keeps on its FN page, wherever the rows have
/// them; the scrollable layout shows them in its rows.
const Set<String> fnPageSoftKeyIds = {
  'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
  'pgup', 'pgdn', 'ins',
};

/// The arrows with Home and End, which the Grouped style outlines.
const Set<String> softKeyClusterIds = {'home', 'end', 'up', 'down', 'left', 'right'};

/// Kind of action a key triggers.
enum SoftKeyKind {
  /// Sends [SoftKey.sequence] verbatim to the terminal.
  send,

  /// Sticky modifier (Ctrl / Alt) - toggles state, doesn't send anything
  /// on its own. The next regular key applies the modifier and clears it.
  modifier,

  /// Microphone / voice-to-text - handled by the parent via callback,
  /// not by sending a sequence.
  mic,
}

/// A single key in the soft-keyboard catalog.
class SoftKey {
  const SoftKey({
    required this.id,
    required this.label,
    this.sequence,
    this.kind = SoftKeyKind.send,
    this.semanticLabel,
    this.repeatable = false,
  });

  /// Stable identifier (lowercase, no spaces). Used in the disabled set.
  final String id;

  /// Visible label on the key. Free to use unicode glyphs (↑, ←, etc.).
  final String label;

  /// Bytes sent to the terminal for [SoftKeyKind.send] keys. Null for
  /// non-send kinds (modifiers, mic).
  final String? sequence;

  /// Action class - determines how the key behaves on tap.
  final SoftKeyKind kind;

  /// Accessibility label for VoiceOver / TalkBack. Defaults to
  /// `'$label key'` when null.
  final String? semanticLabel;

  /// True when long-pressing the key should auto-repeat the sequence
  /// (e.g. arrow keys for cursor movement).
  final bool repeatable;
}

/// All keys the catalog knows about, in display order for the
/// scrollable layout. The legacy two-row layout picks specific keys by
/// id - this list is just the source of truth for what *exists*.
const List<SoftKey> allSoftKeys = [
  // Navigation / movement (front of the row - most-used).
  SoftKey(id: 'esc', label: 'ESC', sequence: '\x1B'),
  SoftKey(id: 'tab', label: 'TAB', sequence: '\t', semanticLabel: 'Tab key'),
  SoftKey(id: 'ctrl', label: 'CTRL', kind: SoftKeyKind.modifier,
      semanticLabel: 'Control modifier key'),
  SoftKey(id: 'alt', label: 'ALT', kind: SoftKeyKind.modifier,
      semanticLabel: 'Alt modifier key'),

  // Arrow keys.
  SoftKey(id: 'up', label: '↑', sequence: '\x1B[A',
      semanticLabel: 'Up arrow key', repeatable: true),
  SoftKey(id: 'down', label: '↓', sequence: '\x1B[B',
      semanticLabel: 'Down arrow key', repeatable: true),
  SoftKey(id: 'left', label: '←', sequence: '\x1B[D',
      semanticLabel: 'Left arrow key', repeatable: true),
  SoftKey(id: 'right', label: '→', sequence: '\x1B[C',
      semanticLabel: 'Right arrow key', repeatable: true),

  // Common shell punctuation.
  SoftKey(id: 'slash', label: '/', sequence: '/'),
  SoftKey(id: 'pipe', label: '|', sequence: '|'),
  SoftKey(id: 'minus', label: '-', sequence: '-'),
  SoftKey(id: 'tilde', label: '~', sequence: '~'),

  // Editor-style navigation.
  SoftKey(id: 'home', label: 'HOME', sequence: '\x1B[H',
      semanticLabel: 'Home key'),
  SoftKey(id: 'end', label: 'END', sequence: '\x1B[F',
      semanticLabel: 'End key'),
  SoftKey(id: 'pgup', label: 'PgUp', sequence: '\x1B[5~',
      semanticLabel: 'Page Up key'),
  SoftKey(id: 'pgdn', label: 'PgDn', sequence: '\x1B[6~',
      semanticLabel: 'Page Down key'),
  SoftKey(id: 'ins', label: 'INS', sequence: '\x1B[2~',
      semanticLabel: 'Insert key'),
  SoftKey(id: 'del', label: 'DEL', sequence: '\x1B[3~',
      semanticLabel: 'Delete key'),

  // Function keys (less commonly needed - most users will disable some).
  SoftKey(id: 'f1', label: 'F1', sequence: '\x1BOP'),
  SoftKey(id: 'f2', label: 'F2', sequence: '\x1BOQ'),
  SoftKey(id: 'f3', label: 'F3', sequence: '\x1BOR'),
  SoftKey(id: 'f4', label: 'F4', sequence: '\x1BOS'),
  SoftKey(id: 'f5', label: 'F5', sequence: '\x1B[15~'),
  SoftKey(id: 'f6', label: 'F6', sequence: '\x1B[17~'),
  SoftKey(id: 'f7', label: 'F7', sequence: '\x1B[18~'),
  SoftKey(id: 'f8', label: 'F8', sequence: '\x1B[19~'),
  SoftKey(id: 'f9', label: 'F9', sequence: '\x1B[20~'),
  SoftKey(id: 'f10', label: 'F10', sequence: '\x1B[21~'),
  SoftKey(id: 'f11', label: 'F11', sequence: '\x1B[23~'),
  SoftKey(id: 'f12', label: 'F12', sequence: '\x1B[24~'),

  // Voice input - always last.
  SoftKey(id: 'mic', label: '🎤', kind: SoftKeyKind.mic,
      semanticLabel: 'Voice input'),
];

/// Default id order for row 1 of the row, before any user reordering, in
/// both layouts (3.2.1: the two rows read them too). HOME ↑ END stand over
/// ← ↓ → (row 2), the arrows an inverted T. Reordering is persisted
/// separately; this is the fallback + the "reset to defaults" target.
const List<String> defaultSoftRow1 = [
  'esc', 'slash', 'pipe', 'minus', 'home', 'up', 'end', 'tilde',
  'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8',
];

/// Default id order for row 2.
const List<String> defaultSoftRow2 = [
  'tab', 'ctrl', 'alt', 'del', 'left', 'down', 'right', 'mic',
  'f9', 'f10', 'f11', 'f12', 'pgup', 'pgdn', 'ins',
];

/// Every non-modifier, non-mic key id - the set a user is allowed to
/// reorder / hide. `ctrl`, `alt`, `mic` are pinned (always present) so the
/// keyboard always has its essential controls.
const Set<String> pinnedSoftKeyIds = {'ctrl', 'alt', 'mic'};

/// Look up a key by id, or null if no such key exists.
SoftKey? findSoftKey(String id) {
  for (final k in allSoftKeys) {
    if (k.id == id) return k;
  }
  return null;
}

/// Reconcile a saved (row1, row2) order against the current [allSoftKeys]
/// catalog: drops ids that no longer exist and appends any catalog keys
/// missing from BOTH rows (so a newly-added key still shows up for users
/// who saved an order before it existed). Returns the effective rows.
({List<String> row1, List<String> row2}) reconcileSoftRows(
  List<String> savedRow1,
  List<String> savedRow2,
) {
  final valid = {for (final k in allSoftKeys) k.id};
  final r1 = savedRow1.where(valid.contains).toList();
  final r2 = savedRow2.where(valid.contains).toList();
  final present = {...r1, ...r2};
  // Append catalog keys missing from both rows, honouring their default row.
  for (final id in defaultSoftRow1) {
    if (valid.contains(id) && !present.contains(id)) r1.add(id);
  }
  for (final id in defaultSoftRow2) {
    if (valid.contains(id) && !present.contains(id)) r2.add(id);
  }
  return (row1: r1, row2: r2);
}
