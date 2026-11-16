/// Where a host's password comes from when it lives in the person's password
/// manager (3.0): only this reference is kept on the host (and
/// synced with it); the password itself is fetched when connecting, used
/// once and never kept.
///
/// References are data other people can edit (a host in an Orchard), so
/// every part is checked here before it reaches a command line: nothing may
/// start with `-` (it would be read as an option), hold a control character,
/// or run past [kPasswordRefMaxLength].
///
/// Pure Dart, no Flutter or app imports, so it is testable on its own.
library;

import 'dart:convert';

/// The password managers ZestSSH fetches from.
enum PasswordManagerKind {
  /// 1Password, through its `op` command line tool.
  onePassword('op'),

  /// Bitwarden, through its `bw` command line tool.
  bitwarden('bw'),

  /// KeePassXC, through its `keepassxc-cli` command line tool.
  keePassXc('kpx');

  const PasswordManagerKind(this.code);

  /// How the kind is written in a stored reference.
  final String code;

  static PasswordManagerKind? fromCode(Object? code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// The longest reference, or part of one, that is accepted.
const int kPasswordRefMaxLength = 512;

final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');
final RegExp _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// A 1Password secret reference: `op://vault/item/field` or
/// `op://vault/item/section/field`, no query (`?attribute=...` would fetch
/// something other than a password).
final RegExp _opRef = RegExp(r'^op://([^/?]+)/([^/?]+)/(?:([^/?]+)/)?([^/?]+)$');

/// A reference to one password in one password manager.
class PasswordRef {
  const PasswordRef._(this.kind, this.target, {this.field});

  /// A 1Password secret reference (`op://vault/item/[section/]field`).
  static PasswordRef? onePassword(String reference) {
    final r = reference.trim();
    final m = _safe(r) ? _opRef.firstMatch(r) : null;
    if (m == null) return null;
    // No part may read as an option, or be only spaces.
    for (var g = 1; g <= 4; g++) {
      final part = m.group(g);
      if (part != null && (part.startsWith('-') || part.trim().isEmpty)) return null;
    }
    return PasswordRef._(PasswordManagerKind.onePassword, r);
  }

  /// A Bitwarden item, by its id: its login password.
  static PasswordRef? bitwarden(String itemId) {
    final id = itemId.trim().toLowerCase();
    if (!_uuid.hasMatch(id)) return null;
    return PasswordRef._(PasswordManagerKind.bitwarden, id);
  }

  /// A KeePassXC entry, by its path in the database this device is set to
  /// use (`Servers/web1`), and the attribute that holds the password.
  static PasswordRef? keePassXc(String entry, {String attribute = 'Password'}) {
    final e = entry.trim();
    final a = attribute.trim();
    if (!_safe(e) || !_safe(a)) return null;
    return PasswordRef._(PasswordManagerKind.keePassXc, e, field: a == 'Password' ? null : a);
  }

  final PasswordManagerKind kind;

  /// The 1Password reference, the Bitwarden item id, or the KeePassXC entry
  /// path.
  final String target;

  /// The KeePassXC attribute when it is not `Password`.
  final String? field;

  /// For KeePassXC: the attribute to read.
  String get attribute => field ?? 'Password';

  static bool _safe(String s) =>
      s.isNotEmpty && s.length <= kPasswordRefMaxLength && !s.startsWith('-') && !_control.hasMatch(s);

  /// The stored form (a host's `password_ref`).
  String encode() => jsonEncode({'v': 1, 'm': kind.code, 't': target, 'f': ?field});

  /// Reads [encode]'s form back; null for anything that is not a valid
  /// reference (so a bad value synced from elsewhere is never used).
  static PasswordRef? decode(String? stored) {
    if (stored == null || stored.isEmpty || stored.length > kPasswordRefMaxLength * 2 + 64) return null;
    final Object? json;
    try {
      json = jsonDecode(stored);
    } on FormatException {
      return null;
    }
    if (json is! Map || json['v'] != 1) return null;
    final target = json['t'];
    final field = json['f'];
    if (target is! String || (field != null && field is! String)) return null;
    return switch (PasswordManagerKind.fromCode(json['m'])) {
      PasswordManagerKind.onePassword => field == null ? onePassword(target) : null,
      PasswordManagerKind.bitwarden => field == null ? bitwarden(target) : null,
      PasswordManagerKind.keePassXc => keePassXc(target, attribute: (field as String?) ?? 'Password'),
      null => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is PasswordRef && other.kind == kind && other.target == target && other.field == field;

  @override
  int get hashCode => Object.hash(kind, target, field);

  @override
  String toString() => 'PasswordRef(${kind.code}, $target${field == null ? '' : ', $field'})';
}
