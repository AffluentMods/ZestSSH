import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/utils/type_name.dart';

/// The keys of an invite code's maker, as this device checked them against the
/// code before it joined, kept until it first reads the team's record.
///
/// A joining device takes the record it is first shown, and the code's tag is
/// checked before joining, over the keys the server hands out with the offer:
/// nothing held the record to those keys (found in a cryptography
/// review). Now that first record must hold them, under the same account and
/// version: a server that shows another team's record, or one made for this
/// person, has to name the real maker's real keys in it. Public keys: nothing
/// here is secret, and nothing is sealed.
class InviteMakerChecks {
  InviteMakerChecks(this._storage);

  final FlutterSecureStorage _storage;

  static String _slot(String orchardId) => 'orchard_join_maker_v1.$orchardId';

  /// [joiner] joined [orchardId] by a code whose tag held over [maker].
  Future<void> remember(String orchardId, {required String joiner, required PublishedAccountKeys maker}) =>
      _storage.write(
        key: _slot(orchardId),
        value: jsonEncode({
          'joiner': joiner,
          'uid': maker.uid,
          'version': maker.version,
          'signing': base64Encode(maker.signingKey),
          'encryption': base64Encode(maker.encryptionKey),
        }),
      );

  /// Whether [record], as this device first reads it for the account [joiner],
  /// holds what was kept for [orchardId]; null where nothing was kept (no code,
  /// another account's, or read long ago). Throws [InviteMakerCheckUnread]
  /// where the storage does not answer: the record is then not taken unchecked,
  /// and it is looked at again at the next refresh (found in a security
  /// review: it read as "nothing kept").
  Future<bool?> holds(String orchardId, OrchardRecord record, {required String joiner}) async {
    final String? raw;
    try {
      raw = await _storage.read(key: _slot(orchardId));
    } catch (e) {
      throw InviteMakerCheckUnread(e);
    }
    if (raw == null) return null;
    try {
      final kept = jsonDecode(raw) as Map<String, dynamic>;
      if (kept['joiner'] != joiner) return null;
      final keys = record.keysOf(kept['uid'] as String, kept['version'] as int);
      return keys != null &&
          base64Encode(keys.signingKey) == kept['signing'] &&
          base64Encode(keys.encryptionKey) == kept['encryption'];
    } catch (_) {
      // Kept by hand (what is on this device is its person's): never why a
      // team does not sync.
      return null;
    }
  }

  /// What is kept for [orchardId] now, as stored (null for nothing), to put
  /// back with [putBack] where a code turns out not to have been used.
  /// Throws where the storage does not answer: a code is then not used
  /// (OrchardService.acceptInviteCode keeps the maker's keys first).
  Future<String?> keptNow(String orchardId) => _storage.read(key: _slot(orchardId));

  /// Puts back [raw], as [keptNow] gave it, for [orchardId]; null takes away
  /// what is kept.
  Future<void> putBack(String orchardId, String? raw) async {
    try {
      if (raw == null) {
        await _storage.delete(key: _slot(orchardId));
      } else {
        await _storage.write(key: _slot(orchardId), value: raw);
      }
    } catch (_) {/* what stays holds for the real maker's keys */}
  }

  /// The record held them: done with.
  Future<void> forget(String orchardId) async {
    try {
      await _storage.delete(key: _slot(orchardId));
    } catch (_) {/* looked at again at the next refresh */}
  }
}

/// The kept keys of an invite code's maker could not be read now: the team's
/// record is not taken unchecked this time ([InviteMakerChecks.holds]).
class InviteMakerCheckUnread implements Exception, HasTypeName {
  const InviteMakerCheckUnread(this.cause);

  final Object cause;

  @override
  String toString() => 'InviteMakerCheckUnread';

  @override
  String get typeName => 'InviteMakerCheckUnread';
}
