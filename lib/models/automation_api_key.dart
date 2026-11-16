import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A single automation API key with metadata.
///
/// The key itself is shown once, when it is made (
/// show-once, only a hash kept, as GitHub and Stripe tokens are). What is kept
/// is [hash], the lowercase hex SHA-256 of the key's UTF-8 bytes, and [hint],
/// its last 4 characters, so a row can say which key it is. A request's key is
/// checked by hashing it and comparing hashes; nothing can show the key again.
class AutomationApiKey {
  final String id;
  final String label;

  /// Lowercase hex SHA-256 of the key's UTF-8 bytes.
  final String hash;

  /// The key's last 4 characters, to tell keys apart in a list.
  final String hint;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;

  /// Connection this key is restricted to. `null` = ALL connections (the
  /// legacy behaviour - every key created before scoping existed decodes to
  /// null and stays unrestricted). When set, the automation dispatcher rejects
  /// any request that resolves to a different connection. See the enforcement
  /// in [AutomationNotifier.handleAutomation].
  final String? scopeConnectionId;

  /// Whether this key was read from a store that still held the key itself
  /// (before show-once). Its store is written again at once, without it.
  final bool readFromRawKey;

  const AutomationApiKey({
    required this.id,
    required this.label,
    required this.hash,
    required this.hint,
    required this.createdAt,
    this.lastUsedAt,
    this.expiresAt,
    this.scopeConnectionId,
    this.readFromRawKey = false,
  });

  /// A key's record made from the key itself: its [hashOf] and [hintOf]. The
  /// key is not kept.
  factory AutomationApiKey.fromSecret({
    required String id,
    required String label,
    required String secret,
    required DateTime createdAt,
    DateTime? lastUsedAt,
    DateTime? expiresAt,
    String? scopeConnectionId,
  }) =>
      AutomationApiKey(
        id: id,
        label: label,
        hash: hashOf(secret),
        hint: hintOf(secret),
        createdAt: createdAt,
        lastUsedAt: lastUsedAt,
        expiresAt: expiresAt,
        scopeConnectionId: scopeConnectionId,
      );

  /// Lowercase hex SHA-256 of [secret]'s UTF-8 bytes.
  static String hashOf(String secret) =>
      sha256.convert(utf8.encode(secret)).toString();

  /// The last 4 characters of [secret] (all of it when shorter).
  static String hintOf(String secret) =>
      secret.length <= 4 ? secret : secret.substring(secret.length - 4);

  /// Whether this key has expired.
  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Days until expiration, or null if no expiration.
  int? get daysUntilExpiry {
    if (expiresAt == null) return null;
    final diff = expiresAt!.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// What a row shows of the key: its last 4 characters after dots.
  String get displayHint => '•••• $hint';

  /// Generate a new 48-character cryptographically secure key (~285 bits entropy).
  ///
  /// Uses [Random.secure()] which is backed by the OS CSPRNG (/dev/urandom)
  /// on all platforms.
  static String generateKey() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    return List.generate(48, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  AutomationApiKey copyWith({DateTime? lastUsedAt, String? label}) =>
      AutomationApiKey(
        id: id,
        label: label ?? this.label,
        hash: hash,
        hint: hint,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        expiresAt: expiresAt,
        scopeConnectionId: scopeConnectionId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hash': hash,
        'hint': hint,
        'createdAt': createdAt.toIso8601String(),
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        if (scopeConnectionId != null) 'scopeConnectionId': scopeConnectionId,
      };

  /// Reads a stored key. A store from before show-once has the key itself
  /// ('key'): its hash and hint are made from it here and the key is dropped
  /// ([readFromRawKey] says so, and the store is written again without it).
  factory AutomationApiKey.fromJson(Map<String, dynamic> json) {
    final raw = json['key'] as String?;
    final hash = raw != null ? hashOf(raw) : json['hash'] as String;
    final hint = raw != null ? hintOf(raw) : (json['hint'] as String? ?? '');
    return AutomationApiKey(
      id: json['id'] as String,
      label: json['label'] as String,
      hash: hash.toLowerCase(),
      hint: hint,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastUsedAt: json['lastUsedAt'] != null
          ? DateTime.parse(json['lastUsedAt'] as String)
          : null,
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      scopeConnectionId: json['scopeConnectionId'] as String?,
      readFromRawKey: raw != null,
    );
  }

  /// Encode a list of keys to a JSON string for secure storage.
  static String encodeList(List<AutomationApiKey> keys) =>
      jsonEncode(keys.map((k) => k.toJson()).toList());

  /// Decode a JSON string to a list of keys.
  static List<AutomationApiKey> decodeList(String json) {
    final list = jsonDecode(json) as List;
    return list
        .map((e) => AutomationApiKey.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
