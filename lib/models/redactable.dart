import 'package:zestssh/utils/redactor.dart';

/// What kind of identifying value a [Redactable] holds. The kind picks the
/// masking rule (see [Redactor]); the caller never chooses a rule directly.
enum RedactKind {
  /// A saved host's display name ("db-primary").
  host,

  /// A connection group name ("Nodes").
  group,

  /// A workspace name ("Main").
  workspace,

  /// Account identity: the signed-in display name, the tree/crate name.
  account,

  /// A host address: IPv4, IPv6, DNS name, optionally with `:port`.
  address,

  /// A login username.
  username,

  /// A key / identity display name ("Alex").
  keyName,

  /// A key comment, which usually holds `user@host` (free text rule).
  keyComment,

  /// A key fingerprint ("SHA256:...").
  fingerprint,

  /// Free text that may embed addresses, `user@host`, or host names.
  freeText,

  /// A secret value that is shown only as bullets.
  password,

  /// A network profile name or a Wi-Fi SSID ("Office-WiFi"): names the
  /// user's environment as surely as a host does. Name rule.
  network,

  /// A filesystem path (e.g. an OSC 7 working directory). Masks each segment so
  /// a screenshot never leaks the OS username or directory names, keeping the
  /// path's shape at the layout level and replacing it with words at strict.
  path,

  /// A shell command the user ran (Command history). A command can embed
  /// anything (hosts, paths, secrets in flags, what the setup does), so it is
  /// not scanned but REPLACED by a harmless stand-in command, chosen by hash
  /// so the same real command shows the same fake everywhere.
  command,
}

/// A value with a real form and a display form. Screens get [display]; only
/// the connection layer, the SSH core boundary and export paths take [raw].
///
/// `toString()` returns the display form on purpose, so an accidental
/// `'$host'` in a tooltip is still safe. The redaction source gate
/// (`test/redaction/no_raw_in_ui_test.dart`) fails the build if `.raw` is
/// used under the UI directories without an explicit
/// `// redaction: raw ok` annotation on that line.
class Redactable {
  const Redactable._(this.raw, this.kind);

  /// The real value. UI code must not read this; use [display].
  final String raw;
  final RedactKind kind;

  factory Redactable.host(String v) => Redactable._(v, RedactKind.host);
  factory Redactable.group(String v) => Redactable._(v, RedactKind.group);
  factory Redactable.workspace(String v) =>
      Redactable._(v, RedactKind.workspace);
  factory Redactable.account(String v) => Redactable._(v, RedactKind.account);
  factory Redactable.address(String v) => Redactable._(v, RedactKind.address);
  factory Redactable.username(String v) =>
      Redactable._(v, RedactKind.username);
  factory Redactable.keyName(String v) => Redactable._(v, RedactKind.keyName);
  factory Redactable.keyComment(String v) =>
      Redactable._(v, RedactKind.keyComment);
  /// A key's fingerprint, shown as ssh-keygen -l shows it: an SHA256 one
  /// without base64's padding (one kept by an import before 3.0 ended in
  /// "=").
  factory Redactable.fingerprint(String v) =>
      Redactable._(fingerprintAsShown(v), RedactKind.fingerprint);
  factory Redactable.freeText(String v) =>
      Redactable._(v, RedactKind.freeText);
  factory Redactable.password(String v) =>
      Redactable._(v, RedactKind.password);
  factory Redactable.network(String v) => Redactable._(v, RedactKind.network);
  factory Redactable.path(String v) => Redactable._(v, RedactKind.path);
  factory Redactable.command(String v) => Redactable._(v, RedactKind.command);

  /// The form safe to render: the real value when recording mode is off, the
  /// masked value when it is on.
  String get display => Redactor.instance.apply(raw, kind);

  bool get isEmpty => raw.isEmpty;
  bool get isNotEmpty => raw.isNotEmpty;

  @override
  String toString() => display;

  @override
  bool operator ==(Object other) =>
      other is Redactable && other.raw == raw && other.kind == kind;

  @override
  int get hashCode => Object.hash(raw, kind);
}

/// [fingerprint] as ssh-keygen -l writes it: an SHA256 fingerprint without
/// base64's padding; any other as it is.
String fingerprintAsShown(String fingerprint) =>
    fingerprint.startsWith('SHA256:') ? fingerprint.replaceFirst(RegExp(r'=+$'), '') : fingerprint;
