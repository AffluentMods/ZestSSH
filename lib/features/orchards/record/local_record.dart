import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// An Orchard's record as this device holds it (3.0): the entries
/// it checked when they arrived, read back from the Orchard's own database,
/// and the state they describe.
class LocalRecord {
  LocalRecord._(this.orchardId, this.entries, this._hashes, this.firstSeen, this.latest);

  /// An Orchard with no entries here yet.
  LocalRecord.empty(this.orchardId)
      : entries = const [],
        _hashes = const [],
        firstSeen = const [],
        latest = OrchardRecord(orchardId);

  final String orchardId;
  final List<RecordEntry> entries;
  final List<Uint8List> _hashes;

  /// When this device first saw each entry, in seconds since the epoch, in
  /// step with [entries] (3.0): entries carry no time, so this is the
  /// only date there is, and it stays on this device. Null for entries kept
  /// before it was noted.
  final List<int?> firstSeen;

  /// What the whole record says.
  final OrchardRecord latest;

  int get seq => latest.seq;
  Uint8List get head => latest.head;

  /// The hash of entry [seq], or null when this device does not have it.
  Uint8List? hashAt(int seq) => seq >= 1 && seq <= _hashes.length ? _hashes[seq - 1] : null;

  static const _maxStates = 32;
  /// States already worked out, oldest first (a map literal keeps order).
  final _states = <int, OrchardRecord>{};

  /// What the record said just after entry [seq]. Throws [RangeError] for an
  /// entry this device does not have.
  Future<OrchardRecord> stateAt(int seq) async {
    if (seq < 1 || seq > this.seq) throw RangeError.range(seq, 1, this.seq, 'seq');
    if (seq == this.seq) return latest;
    final known = _states[seq];
    if (known != null) return known;
    var from = 0;
    for (final s in _states.keys) {
      if (s < seq && s > from) from = s;
    }
    final state = from == 0 ? OrchardRecord(orchardId) : _states[from]!.copy();
    for (var i = from; i < seq; i++) {
      await state.append(entries[i], trusted: true);
    }
    if (_states.length >= _maxStates) _states.remove(_states.keys.first);
    _states[seq] = state;
    return state;
  }

  /// The record kept in [db].
  static Future<LocalRecord> load(AppDatabase db, String orchardId) async {
    final rows = await db
        .customSelect(
            'SELECT seq, prev, type, body, by_uid, by_key_version, signature, hash, first_seen '
            'FROM orchard_record_entries ORDER BY seq')
        .get();
    final entries = [
      for (final r in rows)
        RecordEntry(
          seq: r.read<int>('seq'),
          prev: r.read<Uint8List>('prev'),
          type: r.read<String>('type'),
          bodyJson: r.read<String>('body'),
          by: r.read<String>('by_uid'),
          byKeyVersion: r.read<int>('by_key_version'),
          signature: r.read<Uint8List>('signature'),
        ),
    ];
    final latest = await OrchardRecord.replay(orchardId, entries, trusted: true);
    return LocalRecord._(
      orchardId,
      entries,
      [for (final r in rows) r.read<Uint8List>('hash')],
      [for (final r in rows) r.read<int?>('first_seen')],
      latest,
    );
  }

  /// This record with [more] after it, each checked against the rules and
  /// the entry before it, then kept in [db] with the time this device first
  /// saw it ([now], this device's clock by default). Throws [RecordRejected]
  /// at the first that fails; nothing is kept then.
  Future<LocalRecord> extend(AppDatabase db, List<RecordEntry> more, {DateTime? now}) async {
    if (more.isEmpty) return this;
    final seen = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final state = latest.copy();
    final hashes = <Uint8List>[];
    for (final e in more) {
      await state.append(e);
      hashes.add(state.head);
    }
    await db.transaction(() async {
      for (var i = 0; i < more.length; i++) {
        final e = more[i];
        await db.customStatement(
          'INSERT INTO orchard_record_entries (seq, prev, type, body, by_uid, by_key_version, signature, hash, '
          'first_seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [e.seq, e.prev, e.type, e.bodyJson, e.by, e.byKeyVersion, e.signature, hashes[i], seen],
        );
      }
    });
    return LocalRecord._(
      orchardId,
      [...entries, ...more],
      [..._hashes, ...hashes],
      [...firstSeen, for (var i = 0; i < more.length; i++) seen],
      state,
    );
  }
}

/// Why this device stopped following an Orchard's record: the server showed
/// a record that does not follow the one here (fewer entries, or entries
/// that do not chain on from the last one here), or an entry that breaks
/// the rules. A newer app version's entries can also be one this version
/// cannot read.
/// Whether [reason], a [RecordProblem]'s, is an entry this version does not
/// know: a newer version's. Said as that, with the update, and
/// logins with the team's certificates go on with the record the device has.
bool recordProblemIsNewer(String reason) => reason.endsWith(': unknown type');

class RecordProblem implements Exception, HasTypeName {
  const RecordProblem(this.reason);

  final String reason;

  @override
  String toString() => 'Orchard record: $reason';

  @override
  String get typeName => 'RecordProblem';
}

class _Kept {
  const _Kept(this.seq, this.record);

  final int seq;
  final OrchardRecord record;
}

/// What each Orchard database's record said when it was last read here.
final _kept = Expando<_Kept>('the record as last read');

/// What the Orchard's record in [db] says now: null for your Tree's
/// database, and for an Orchard's that holds no entry yet. Worked out again
/// only when the record has grown (it only ever grows), so asking is cheap.
/// What comes back is shared: read it, never change it.
Future<OrchardRecord?> latestRecordIn(AppDatabase db) async {
  if (!db.isOrchard) return null;
  final row = await db
      .customSelect('SELECT orchard_id, (SELECT MAX(seq) FROM orchard_record_entries) AS last FROM orchard_info '
          'WHERE id = 1')
      .getSingleOrNull();
  final orchardId = row?.read<String?>('orchard_id');
  final last = row?.read<int?>('last');
  if (orchardId == null || last == null) return null;
  final kept = _kept[db];
  if (kept != null && kept.seq == last && kept.record.orchardId == orchardId) return kept.record;
  final record = (await LocalRecord.load(db, orchardId)).latest;
  _kept[db] = _Kept(record.seq, record);
  return record;
}

/// Where this device keeps the server's receipt for the record as it last
/// read it whole ([RecordPage.receipt]): JSON {"seq": n, "receipt": "..."}.
const String kRecordReceiptState = 'record.receipt';

/// Set once this device found the server behind its record and sent the
/// lost entries back (the restore work): the server was restored from an
/// older backup, so the Crates are read again from the start and key copies
/// the server lost are sealed again. Cleared by whoever has done that.
const String kServerWentBackState = 'record.server_went_back';

/// The standing (orchard_info.status) of an Orchard the server no longer
/// lists for this account although the record here has it in, and whose
/// record the server does not hold all of: the server was restored from an
/// older backup that lost the entry that put this account in. What is here
/// stays and nothing syncs, until a member's device has sent the lost
/// entries back and the server lists the Orchard again.
const String kServerBehindStatus = 'server-behind';

/// The standing of an Orchard the server no longer lists for this account,
/// says it holds this device's last entry of (so it took the account out),
/// and whose record, as this device holds and checks it, still has this
/// account active: ZestSSH Cloud's word alone. What is here stays, held back,
/// and nothing syncs, until the server lists it again, a record this device
/// checks shows the account out, or its person removes it from the device
/// (found in a security review: the server alone wiped a team's
/// data, changes not yet sent included).
const String kUnlistedStatus = 'unlisted';

/// Brings the record of [orchardId] on this device up to date with the
/// server, page by page. Every new entry is checked (its signature, the
/// rules, and that it follows the one before), then kept, with the server's
/// receipt for the whole. Throws [RecordProblem]; nothing new is kept then.
///
/// A server that holds fewer entries than this device was restored from an
/// older backup (or hides entries, a removal say). When the entries it holds
/// are this device's own first ones, this device sends it the rest, exactly
/// as signed, up to the entry its receipt is for ([CrateServer.mendRecord]),
/// and reads again; the server checks each as it did the first time. A
/// server whose record parts ways with this device's is not followed: that
/// is a [RecordProblem] as before.
Future<LocalRecord> pullRecord(AppDatabase db, String orchardId, CrateServer server) async {
  var local = await LocalRecord.load(db, orchardId);
  for (var attempt = 0;; attempt++) {
    final fresh = <RecordEntry>[];
    var after = local.seq;
    int? behind;
    String? receipt;
    while (true) {
      final page = await server.record(orchardId, after: after);
      if (page.seq < local.seq) {
        behind = page.seq;
        break;
      }
      for (final e in page.entries) {
        if (e.seq != after + 1) throw RecordProblem('entry ${e.seq} came out of order');
        fresh.add(e);
        after = e.seq;
      }
      if (!page.more) {
        receipt = page.seq == after ? page.receipt : null;
        break;
      }
      if (page.entries.isEmpty) throw const RecordProblem('the server said there was more and sent none');
    }
    if (behind != null) {
      if (attempt >= 3) {
        throw RecordProblem(ErrorCodes.withCode(
            'the server holds $behind entries and this device ${local.seq}', ErrorCodes.teamRecordParted));
      }
      await _sendBack(db, local, server, behind);
      continue;
    }
    try {
      local = await local.extend(db, fresh);
    } on RecordRejected catch (e) {
      throw RecordProblem('entry ${e.seq}: ${e.reason}');
    }
    if (receipt != null && after == local.seq) {
      // As long as this device's: a receipt for the same number that is not
      // the one kept is for another last entry (one written in its place on
      // a server restored from an older backup), or made with another key;
      // the server says which.
      final kept = await _receipt(db);
      if (fresh.isEmpty &&
          kept != null &&
          kept.seq == local.seq &&
          kept.receipt != receipt &&
          !(await server.recordHolds(orchardId, local.seq, local.head)).holds) {
        throw RecordProblem(ErrorCodes.withCode(
            'the server shows another entry ${local.seq} than this device holds', ErrorCodes.teamRecordParted));
      }
      await LocalStateStore(db).write(kRecordReceiptState, jsonEncode({'seq': after, 'receipt': receipt}));
    }
    return local;
  }
}

/// The server holds [serverSeq] entries of [local]'s record, fewer than this
/// device: sends the rest back when the server's are this device's own
/// first ones. Returns once the server took them, or another device was
/// first (the caller reads again); throws [RecordProblem] when they cannot
/// go back.
Future<void> _sendBack(AppDatabase db, LocalRecord local, CrateServer server, int serverSeq) async {
  final orchardId = local.orchardId;
  String parted(String why) => ErrorCodes.withCode(why, ErrorCodes.teamRecordParted);
  if (serverSeq < 1) {
    throw RecordProblem(parted('the server holds none of the record and this device ${local.seq} entries'));
  }
  // The server's last entry must be the one this device holds under that
  // number: the same entry chains the same record before it.
  final page = await server.record(orchardId, after: serverSeq - 1);
  final theirs = page.entries.isEmpty ? null : page.entries.first;
  final ours = local.entries[serverSeq - 1];
  if (theirs == null || theirs.seq != serverSeq || !_sameEntry(theirs, ours)) {
    throw RecordProblem(parted('the server\'s record parts ways with this device\'s at entry $serverSeq'));
  }
  final kept = await _receipt(db);
  if (kept == null || kept.seq <= serverSeq || kept.seq > local.seq) {
    throw RecordProblem(parted('the server holds $serverSeq entries and this device ${local.seq}, '
        'and this device holds no receipt of the server for the ones after'));
  }
  final entries = local.entries.sublist(serverSeq, kept.seq);
  final state = await local.stateAt(kept.seq);
  try {
    await server.mendRecord(orchardId,
        after: serverSeq, entries: entries, receipt: kept.receipt, names: await _namesFor(db, entries, state));
  } on OrchardServerException catch (e) {
    if (e.recordMoved) return;
    if (e.routeMissing) {
      // A server a deploy behind this app (one host of a deploy not yet
      // done, say) cannot take entries back: as before the restore work.
      throw RecordProblem(parted('the server holds $serverSeq entries and this device ${local.seq}'));
    }
    if (e.code == 'record-fork') {
      throw RecordProblem(parted('the server\'s record parts ways with this device\'s after entry $serverSeq'));
    }
    if (e.code == 'record-unproven') {
      throw RecordProblem(parted('the server gave no receipt for the entries this device sent back'));
    }
    if (e.code == 'record-refused') {
      throw RecordProblem(parted('the server refused an entry this device sent back: ${e.reason ?? 'no reason given'}'));
    }
    rethrow;
  }
  AppLogger.info('Orchards: the server was behind a team\'s record; this device sent back '
      '${entries.length} entries');
  await LocalStateStore(db).write(kServerWentBackState, '1');
}

/// The receipt this device keeps, or null.
Future<({int seq, String receipt})?> _receipt(AppDatabase db) async {
  final raw = await LocalStateStore(db).read(kRecordReceiptState);
  if (raw == null) return null;
  try {
    final j = jsonDecode(raw);
    if (j is Map && j['seq'] is int && j['receipt'] is String) {
      return (seq: j['seq'] as int, receipt: j['receipt'] as String);
    }
  } on FormatException {
    // Kept by hand, or cut short: none.
  }
  return null;
}

/// The names of the Crates [entries] add and of the keys they replace, as
/// [state] has their generations, sealed under those keys where this device
/// holds them: so that the server, which lost them, shows them again.
Future<List<MendName>> _namesFor(AppDatabase db, List<RecordEntry> entries, OrchardRecord state) async {
  final scopes = <String>{};
  for (final e in entries) {
    try {
      final body = jsonDecode(e.bodyJson);
      if (body is! Map) continue;
      if (e.type == RecordTypes.crateAdd && body['id'] is String) scopes.add(body['id'] as String);
      if (e.type == RecordTypes.keyRotate) {
        scopes.add(body['crate'] is String ? body['crate'] as String : kOrchardScope);
      }
    } on FormatException {
      continue;
    }
  }
  final out = <MendName>[];
  for (final scope in scopes) {
    final generation = state.generationOf(scope);
    if (generation < 1) continue;
    final orchard = scope == kOrchardScope;
    final key = await db.customSelect(
      'SELECT secret FROM space_keys WHERE scope = ? AND scope_id = ? AND generation = ?',
      variables: [Variable(orchard ? 'orchard' : 'crate'), Variable(orchard ? state.orchardId : scope), Variable(generation)],
    ).getSingleOrNull();
    final name = orchard
        ? (await db.customSelect('SELECT name FROM orchard_info WHERE id = 1').getSingleOrNull())?.read<String?>('name')
        : (await db.customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?', variables: [Variable(scope)])
                .getSingleOrNull())
            ?.read<String?>('name');
    if (key == null || name == null) continue;
    final secret = key.read<Uint8List>('secret');
    out.add(MendName(
      crateId: orchard ? null : scope,
      generation: generation,
      nameEnc: orchard
          ? await encryptOrchardName(name, secret, orchardId: state.orchardId, generation: generation)
          : await encryptCrateName(name, secret, orchardId: state.orchardId, crateId: scope, generation: generation),
    ));
  }
  return out;
}

bool _sameEntry(RecordEntry a, RecordEntry b) =>
    a.seq == b.seq &&
    a.type == b.type &&
    a.bodyJson == b.bodyJson &&
    a.by == b.by &&
    a.byKeyVersion == b.byKeyVersion &&
    _sameBytes(a.prev, b.prev) &&
    _sameBytes(a.signature, b.signature);

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
