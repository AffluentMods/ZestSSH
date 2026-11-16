import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// One member as this device shows them.
class MemberView {
  const MemberView({
    required this.uid,
    required this.role,
    required this.isMe,
    this.status = 'active',
    this.endsAt,
    this.email,
    this.keyVersion,
    this.fingerprint,
    this.verifiedByMe = false,
    this.verifiedBy = const [],
    this.replacedSinceCompared = false,
    this.pending,
    this.accountDeleted = false,
    this.name,
    this.picture,
  });

  final String uid;

  /// Their name and picture as the server last listed them.
  final String? name;
  final String? picture;

  /// 'owner', 'admin' or the id of a role the owners made.
  final String role;
  final bool isMe;

  /// 'active' or 'suspended'.
  final String status;

  /// When their access ends, in seconds since the epoch; null for never.
  final int? endsAt;
  final String? email;
  final int? keyVersion;

  /// The pinned keys' fingerprint, null for a member with no keys yet.
  final Uint8List? fingerprint;
  final bool verifiedByMe;

  /// Members whose checked statements cover the pinned keys.
  final List<String> verifiedBy;

  /// This device's person compared an earlier version of their keys, and
  /// nobody here has compared the ones they replaced them with.
  final bool replacedSinceCompared;

  /// Keys waiting after a hard stop.
  final PublishedAccountKeys? pending;

  /// The server says the account was deleted since the record added it.
  final bool accountDeleted;

  bool get hardStop => pending != null;
}

/// An Orchard's members and the keys this device trusts for each, in the
/// Orchard's own database (3.0). Who the members are, their
/// roles and standing come from the Orchard's record; their addresses and
/// the signed checks of their keys from the server's member list. What the
/// sync engine asks when it checks who signed an item or sealed a key, and
/// what the members screen shows. Members who left keep their pinned keys,
/// so what they signed while they were in still checks out.
/// The members' names and pictures as the server last listed them (to-do
/// 59), in the team database's own store: shown, never trusted for anything.
const kMemberFacesState = 'member_faces_v1';

class MemberDirectory {
  MemberDirectory(this.db);

  final AppDatabase db;

  Future<PinnedMember?> pin(String uid) async {
    final row = await db
        .customSelect('SELECT * FROM member_keys WHERE uid = ?', variables: [Variable(uid)])
        .getSingleOrNull();
    return row == null ? null : _pin(row.data);
  }

  Future<Map<String, PinnedMember>> pins() async {
    final out = <String, PinnedMember>{};
    for (final r in await db.customSelect('SELECT * FROM member_keys').get()) {
      final p = _pin(r.data);
      if (p != null) out[p.uid] = p;
    }
    return out;
  }

  /// The members the server says were deleted since the record added them
  /// (no key is sealed to them any more).
  Future<Set<String>> deletedAccounts() async => {
        for (final r in await db.customSelect('SELECT uid FROM member_keys WHERE account_deleted = 1').get())
          r.read<String>('uid'),
      };

  /// The signing key trusted for [uid] at [version], or null: an item signed
  /// with anything else is refused (after a hard stop, the new key too).
  Future<Uint8List?> signingKey(String uid, int version) async {
    final p = await pin(uid);
    return p != null && p.keyVersion == version ? p.signingKey : null;
  }

  /// Every member as this device shows them, the signed-in account first.
  /// Members who left are not shown.
  Future<List<MemberView>> view(String myUid) async {
    final faces = await _faces();
    final rows = await db
        .customSelect("SELECT * FROM member_keys WHERE status <> 'removed' ORDER BY email, uid")
        .get();
    final out = <MemberView>[];
    for (final r in rows) {
      final d = r.data;
      final pinned = _pin(d);
      final checkedBy = [
        for (final v in jsonDecode(d['verified_by'] as String? ?? '[]') as List)
          if (v is String) v,
      ];
      final byMe = (pinned?.verifiedByMe ?? false) || checkedBy.contains(myUid);
      out.add(MemberView(
        uid: d['uid'] as String,
        role: d['role'] as String,
        isMe: d['uid'] == myUid,
        status: d['status'] as String? ?? 'active',
        endsAt: d['ends_at'] as int?,
        email: d['email'] as String?,
        name: faces[d['uid']]?.name,
        picture: faces[d['uid']]?.picture,
        keyVersion: pinned?.keyVersion,
        fingerprint: pinned?.fingerprint,
        // A check this account signed, on this device or another of its own.
        verifiedByMe: byMe,
        verifiedBy: [
          for (final v in checkedBy)
            if (v != myUid) v,
        ],
        replacedSinceCompared: (pinned?.replacedSinceCompared ?? false) && !byMe,
        pending: pinned?.pending,
        accountDeleted: (d['account_deleted'] as int? ?? 0) == 1,
      ));
    }
    out.sort((a, b) => a.isMe == b.isMe ? 0 : (a.isMe ? -1 : 1));
    return out;
  }

  /// Applies the Orchard's [record]: pins, follows or stops on each member's
  /// keys ([applyRecordKeys]), and keeps each member's role and standing.
  /// From the server's [listings] come their addresses, the checks of their
  /// keys, counted only when this device can verify them, and which accounts
  /// were deleted since; null [listings] keeps the ones it has. The
  /// signed-in account is shown with its own keys. Returns what changed for
  /// each member.
  Future<Map<String, MemberKeyChange>> apply({
    required String orchardId,
    required LocalRecord record,
    required MemberList? listings,
    required CrateAuthor me,
  }) async {
    final before = await pins();
    final rows = {
      for (final r in await db.customSelect('SELECT uid, email, verified_by, account_deleted FROM member_keys').get())
        r.read<String>('uid'): r.data,
    };
    final byUid = {for (final l in listings?.members ?? const <MemberListing>[]) l.uid: l};
    if (listings != null) {
      await LocalStateStore(db).write(kMemberFacesState, jsonEncode({
        for (final l in listings.members)
          if (l.name != null || l.picture != null) l.uid: {'n': ?l.name, 'p': ?l.picture},
      }));
    }
    final after = <String, PinnedMember>{};
    final changes = <String, MemberKeyChange>{};
    for (final m in record.latest.members.values) {
      if (m.uid == me.uid) continue;
      final (pin, change) = applyRecordKeys(before[m.uid], m);
      if (pin != null) after[m.uid] = pin;
      changes[m.uid] = change;
    }
    final mine = PinnedMember.fromKeys(await me.keys.publish(me.uid));
    await db.transaction(() async {
      for (final m in record.latest.members.values) {
        final listing = byUid[m.uid];
        final pin = m.uid == me.uid ? mine : after[m.uid];
        final List<String> checked;
        if (listings == null) {
          checked = [
            for (final v in jsonDecode(rows[m.uid]?['verified_by'] as String? ?? '[]') as List)
              if (v is String) v,
          ];
        } else {
          checked = pin == null
              ? const <String>[]
              : await verifiedBy(
                  orchardId: orchardId,
                  subject: pin,
                  checks: listing?.checks ?? const [],
                  pins: after,
                  myUid: me.uid,
                  myKeys: me.keys,
                );
        }
        final deleted = m.uid != me.uid &&
            (listings == null ? (rows[m.uid]?['account_deleted'] as int? ?? 0) == 1 : listings.deleted.contains(m.uid));
        await db.customStatement(
          'INSERT INTO member_keys (uid, email, role, status, ends_at, key_version, signing_key, '
          'encryption_key, verified_by_me, verified_by, pending_keys, account_deleted, replaced_since_compared) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(uid) DO UPDATE SET email = excluded.email, role = excluded.role, '
          'status = excluded.status, ends_at = excluded.ends_at, '
          'key_version = excluded.key_version, signing_key = excluded.signing_key, '
          'encryption_key = excluded.encryption_key, verified_by_me = excluded.verified_by_me, '
          'verified_by = excluded.verified_by, pending_keys = excluded.pending_keys, '
          'account_deleted = excluded.account_deleted, '
          'replaced_since_compared = excluded.replaced_since_compared',
          [
            m.uid,
            listing?.email ?? rows[m.uid]?['email'],
            m.role,
            m.status.name,
            m.endsAt,
            pin?.keyVersion,
            pin?.signingKey,
            pin?.encryptionKey,
            (pin?.verifiedByMe ?? false) ? 1 : 0,
            jsonEncode(checked),
            pin?.pending == null ? null : jsonEncode(_published(pin!.pending!)),
            deleted ? 1 : 0,
            (pin?.replacedSinceCompared ?? false) ? 1 : 0,
          ],
        );
      }
      // Someone the record never had is no member.
      for (final uid in rows.keys) {
        if (!record.latest.members.containsKey(uid)) {
          await db.customStatement('DELETE FROM member_keys WHERE uid = ?', [uid]);
        }
      }
    });
    return changes;
  }

  /// The names and pictures kept from the last listing, by member.
  Future<Map<String, ({String? name, String? picture})>> _faces() async {
    try {
      final raw = jsonDecode(await LocalStateStore(db).read(kMemberFacesState) ?? '{}');
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          if (e.key is String && e.value is Map)
            e.key as String: (
              name: (e.value as Map)['n'] is String ? (e.value as Map)['n'] as String : null,
              picture: (e.value as Map)['p'] is String ? (e.value as Map)['p'] as String : null,
            ),
      };
    } on FormatException {
      return const {};
    }
  }

  /// Someone this device's person compared and then confirmed into the
  /// Orchard: the keys they compared become the pin, verified here,
  /// whatever was pinned for the account before.
  Future<void> pinConfirmed(PublishedAccountKeys keys, {String? email, required String role}) =>
      db.customStatement(
        'INSERT INTO member_keys (uid, email, role, key_version, signing_key, encryption_key, '
        'verified_by_me, verified_by, pending_keys, replaced_since_compared) '
        "VALUES (?, ?, ?, ?, ?, ?, 1, '[]', NULL, 0) "
        'ON CONFLICT(uid) DO UPDATE SET email = excluded.email, role = excluded.role, '
        "status = 'active', key_version = excluded.key_version, signing_key = excluded.signing_key, "
        'encryption_key = excluded.encryption_key, verified_by_me = 1, pending_keys = NULL, '
        'replaced_since_compared = 0',
        [keys.uid, email, role, keys.version, keys.signingKey, keys.encryptionKey],
      );

  /// This device's person compared [uid]'s fingerprint: the keys waiting
  /// after a hard stop become the pin, and the pin counts as verified here.
  Future<PinnedMember?> markVerified(String uid) async {
    final p = await pin(uid);
    if (p == null) return null;
    final next = p.hardStop ? acceptPending(p) : p.copyWith(verifiedByMe: true, replacedSinceCompared: false);
    await db.customStatement(
      'UPDATE member_keys SET key_version = ?, signing_key = ?, encryption_key = ?, '
      'verified_by_me = 1, pending_keys = NULL, replaced_since_compared = 0 WHERE uid = ?',
      [next.keyVersion, next.signingKey, next.encryptionKey, uid],
    );
    return next;
  }

  static Map<String, dynamic> _published(PublishedAccountKeys k) => {
        ...k.toJson(),
        'endorsement': k.endorsement == null ? null : base64Encode(k.endorsement!),
      };

  static PinnedMember? _pin(Map<String, Object?> d) {
    final uid = d['uid'] as String;
    final version = d['key_version'] as int?;
    final signing = d['signing_key'];
    final encryption = d['encryption_key'];
    if (version == null || signing is! Uint8List || encryption is! Uint8List) return null;
    PublishedAccountKeys? pending;
    final raw = d['pending_keys'] as String?;
    if (raw != null) {
      try {
        pending = PublishedAccountKeys.fromJson(uid, jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        pending = null;
      }
    }
    return PinnedMember(
      uid: uid,
      keyVersion: version,
      signingKey: signing,
      encryptionKey: encryption,
      verifiedByMe: (d['verified_by_me'] as int? ?? 0) == 1,
      replacedSinceCompared: (d['replaced_since_compared'] as int? ?? 0) == 1,
      pending: pending,
    );
  }
}
