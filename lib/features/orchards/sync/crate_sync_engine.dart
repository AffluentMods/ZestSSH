import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show itemDisplayName;
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Who writes: the signed-in account and its keys, which sign every record.
class CrateAuthor {
  const CrateAuthor({required this.uid, required this.keys});

  final String uid;
  final AccountKeys keys;
}

/// What one sync of an Orchard did.
class CrateSyncReport {
  /// Versions from elsewhere written here.
  int received = 0;

  /// Versions of this device's changes the server took.
  int sent = 0;

  /// Conflicts where this device's version was newer and replaced the other.
  int conflictsWon = 0;

  /// Conflicts where a newer version from elsewhere replaced this device's;
  /// this device's version went to the item's history.
  int conflictsLost = 0;

  /// Records refused: they do not open, name another item, do not carry a
  /// valid signature by the author they name, or their author was not
  /// allowed to write them (as the Orchard's record stood when they did); or a
  /// copy in another Crate than the item's that does not count (see
  /// [CrateSyncEngine]); or held back, to be read again at the next sync,
  /// because opening or taking it threw. The log says so; nothing on screen
  /// does.
  int rejected = 0;

  /// Changes that could not be sent: no Crate this account can write to, or
  /// its access there does not include the change (adding, editing or
  /// deleting).
  int unsent = 0;

  /// Items too large for one record.
  int tooLarge = 0;

  /// Losing versions the server could not keep in history.
  int historyFailed = 0;

  /// A Crate key is missing or out of date: refresh the Orchard's keys and
  /// sync again.
  bool needsKeys = false;

  /// An item names an entry of the Orchard's record this device does not
  /// have yet: read the record and sync again.
  bool needsRecord = false;

  /// An item names an entry of the Orchard's record that is not the one this
  /// device holds under that number: the server is showing different
  /// records to different people. The item is refused.
  bool recordMismatch = false;

  /// Crates the server no longer shows this account.
  final Set<String> goneCrates = {};

  /// The account's keys were replaced and this device still signs with the
  /// old ones: nothing more was sent until it has the new keys.
  bool staleAccountKeys = false;

  /// The Orchard's rules hold this account or this device back:
  /// nothing was synced.
  bool held = false;

  /// The Orchard has more people than seats: new items wait on this
  /// device (counted in [unsent]) until an owner buys seats; changes and
  /// deletions went as usual.
  bool seatsNeeded = false;

  /// What [seatsNeeded] was about is what the team's vaults hold, not how many
  /// people it has (the server's 'seats-needed' with the reason 'storage'): its
  /// seats may be free, and more of them make room all the same.
  bool vaultsFull = false;

  @override
  String toString() => 'received $received, sent $sent, won $conflictsWon, '
      'lost $conflictsLost, rejected $rejected, unsent $unsent, '
      'too large $tooLarge, needs keys $needsKeys, needs record $needsRecord, '
      'record mismatch $recordMismatch, gone ${goneCrates.length}, '
      'stale account keys $staleAccountKeys, held $held, seats needed $seatsNeeded, vaults full $vaultsFull';
}

/// Syncs one Orchard's database with its Crates on ZestSSH Cloud (3.0),
/// item by item.
///
/// Pull: every Crate's changes since the last revision read, oldest first.
/// Each record is opened and checked (orchard_crypto.dart) before anything
/// is written, and written with the outbox triggers off.
///
/// Push: every change the triggers queued, as one record per item to the
/// item's Crate, based on the revision this device last saw. A stale base
/// comes back as a conflict carrying the current version: the newer version
/// wins everywhere, and the losing one is kept in the item's history.
///
/// Kinds this version does not know are skipped. A version that adds a kind
/// must read its Crates again from the start (reset `last_revision`).
///
/// The Orchard's record: every version this device writes names the
/// record's last entry here (its anchor). A version read is taken only when
/// the entry it names is the one this device holds under that number, and
/// its author could, as the record stood then, add or edit it (or delete
/// it, for a deletion). A change this account may not make in its Crate is
/// not sent.
///
/// Moves: an item moved to another Crate is written there, and its copy in
/// the old Crate is replaced by a deletion naming the new Crate, so other
/// devices follow it without deleting it. If two live copies meet (two
/// devices moved or edited it at once), the newer one decides where the item
/// lives, and the other copy is removed.
///
/// An item's key is one namespace across an Orchard's Crates, and a version's
/// signature and encryption bind it to the Crate it sits in, not to the item's.
/// So a copy in another Crate counts only as a move: only where its author
/// held the delete switch in the other Crate, at the entry the version names
/// (found in a security review: someone who could add in one Crate wrote a
/// copy naming another's item, with a later time, and every device reading
/// both rewrote the item and signed the real copy's deletion). The rule, the
/// same on every device, whichever it reads first ([_receive]): of two live
/// copies, the one whose author could have moved it out of the other's Crate
/// is the item; where both could, the newer; where neither could, nobody can
/// tell, so a device keeps the one it holds and takes no other, and a device
/// that has read nothing yet holds both out ([_holdOut]). Nothing is signed on
/// the strength of a copy refused.
///
/// Such a pair is noted with who wrote each copy and when ([heldBack]), since a
/// fresh device shows neither and later edits do not lift that: whoever holds the
/// rights settles it as the person they are, with a version of their own where the
/// copy stays and a deletion of the other ([keepHeldBack]), or a deletion alone
/// ([removeHeldBack]). Both are signed as any edit and deletion are, and the rule
/// then decides as it always does, on every device.
///
/// All of that is about a live item. A device that holds only a deletion has no
/// item for a copy to overwrite or take the place of, so it takes a later copy
/// from another Crate as one with nothing would, whoever wrote it (found in a review:
/// moved to a Crate this person could not open, a host stayed
/// deleted here, and the copy they met once they were given that Crate, or once
/// it moved on to one they had, was refused for good where its last editor could
/// not delete in the old Crate; a fresh device showed it). It reads the Crate the
/// deletion came from first, where the item may have come back ([_readThrough]),
/// and signs nothing. Where the deletion it holds names the Crate a copy is in,
/// that copy is the item, however old; a copy older than a deletion that says the
/// item went somewhere else stays out, and is not signed away.
///
/// What a copy from elsewhere took the place of was still the other Crate's item
/// (the same review: someone who may add in A wrote a later copy over a deletion
/// held for B, every device took it, and then refused the item's real restore in B,
/// even an owner's). So where a device takes a copy over a deletion that names no
/// Crate, by someone who could not have moved it from there, it notes that Crate and
/// the deletion's time. A live copy there no older than that deletion replaces
/// whatever such a copy put here, whatever time it says, and the note goes. Unless
/// the version held is by someone who could have moved it out of that Crate: then it
/// is a move like any other. A deletion that names a Crate leaves no note, so a host
/// moved to a Crate someone could not open comes back to them and no copy in the
/// Crate it left replaces it. A note stands until that Crate's copy comes: what is
/// taken meanwhile makes none of its own, so planting a copy and deleting it cannot
/// turn it to point the other way.
class CrateSyncEngine {
  CrateSyncEngine({
    required this.db,
    required this.orchardId,
    required this.server,
    required this.author,
    required this.signers,
    int Function()? nowMs,
    @visibleForTesting this.readsFormat = kItemRecordFormat,
  })  : _store = OrchardItemStore(db),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase db;
  final String orchardId;
  final CrateServer server;
  final CrateAuthor author;
  final SigningKeyLookup signers;

  /// The newest item record format this device reads ([kItemRecordFormat]);
  /// a test sets 1 to read as a version before 3.4 did, which refuses a
  /// version of an FTPS host as one that does not open.
  final int readsFormat;
  final OrchardItemStore _store;
  final int Function() _nowMs;

  /// The server takes 200 items and 8 MB per write; base64 makes 6 MB of
  /// records about 8 MB.
  static const maxBatchItems = 200;
  static const maxBatchBytes = 5 * 1024 * 1024;

  /// The server's limit for one record.
  static const maxRecordBytes = 256 * 1024;

  static const _maxPushRounds = 3;

  Future<CrateSyncReport>? _running;
  bool _again = false;

  /// A Crate showed that the server went back in time during this sync.
  bool _wentBack = false;
  final _idKeys = <String, Uint8List>{};

  /// The Orchard's record as it stood when this sync began.
  LocalRecord _record = LocalRecord.empty('');

  /// This device has not yet read every Crate to its end once
  /// ([_firstSyncState]): what it holds, it only just read.
  bool _firstSync = false;

  /// The Crates read to their end, or gone, since this call of [sync] began:
  /// a device that holds only a deletion believes it once it has read the Crate
  /// it came from ([_receive]).
  final _readThrough = <String>{};

  /// A copy waits to be read again once [_readThrough] holds its item's Crate:
  /// one more round, where this one read every Crate to its end. (Otherwise it
  /// waits for the next sync, kept: a Crate whose key is missing stops where it
  /// is, and rounds would only spin.)
  bool _copyWaits = false;

  /// The Crate being read, and whether a version of it was noted to be read
  /// again meanwhile: that note outlives this read.
  String? _reading;
  bool _readAgainHere = false;

  /// Pulls every Crate, then pushes this device's changes. A call while a
  /// sync runs makes that sync run once more, so no change waits for the
  /// next call, and returns its report.
  Future<CrateSyncReport> sync() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final run = _loop();
    _running = run;
    return run;
  }

  Future<CrateSyncReport> _loop() async {
    try {
      CrateSyncReport report;
      _readThrough.clear();
      do {
        _again = false;
        report = await _once();
      } while (_again);
      return report;
    } finally {
      _running = null;
    }
  }

  Future<CrateSyncReport> _once() async {
    final report = CrateSyncReport();
    _record = await LocalRecord.load(db, orchardId);
    // The server went back in time (a restore from an older backup), as this
    // device's record or one of its Crates showed: every Crate is read again
    // from the start, and what the server lacks is sent again.
    final rereading = await LocalStateStore(db).read(kServerWentBackState) != null;
    var reread = rereading;
    final crates = await _crates();
    await _readAgainInNewFormat(crates);
    await _noteFirstSync(crates, rereading: rereading);
    var whole = true;
    _copyWaits = false;
    for (final crate in crates.values) {
      try {
        if (!await _pullCrate(crate, report, reread: rereading)) {
          reread = false;
          whole = false;
        }
      } on OrchardServerException catch (e) {
        if (!e.notFound) rethrow;
        report.goneCrates.add(crate.id);
        _readThrough.add(crate.id);
      }
      if (!rereading && _wentBack) break;
    }
    _reading = null;
    if (!rereading && _wentBack) {
      // Found just now: every Crate is read again before anything is sent.
      _wentBack = false;
      _again = true;
      return report;
    }
    if (_copyWaits && whole) _again = true;
    if (_firstSync && whole) {
      _firstSync = false;
      await LocalStateStore(db).remove(_firstSyncState);
    }
    if (rereading && reread) {
      await LocalStateStore(db).remove(kServerWentBackState);
      AppLogger.info('Orchard sync: every Crate was read again after the server went back in time');
    }
    await _push(crates, report);
    if (report.rejected > 0 ||
        report.needsKeys ||
        report.needsRecord ||
        report.goneCrates.isNotEmpty ||
        report.staleAccountKeys) {
      AppLogger.warning('Orchard sync: $report');
    }
    return report;
  }

  // ── Placing and moving items ──────────────────────────────────────────

  /// Puts an item that has not reached the server yet into [crateId]; see
  /// [CratePlacement.place].
  Future<void> place(String kind, String key, String crateId) =>
      CratePlacement(db, nowMs: _nowMs).place(kind, key, crateId);

  /// Moves an item to another Crate of this Orchard; see
  /// [CratePlacement.moveItem].
  Future<void> moveItem(String kind, String key, String toCrateId) =>
      CratePlacement(db, nowMs: _nowMs).moveItem(kind, key, toCrateId);

  /// The Crate an item is in on this device.
  Future<String?> crateOf(String kind, String key) =>
      CratePlacement(db, nowMs: _nowMs).crateOf(kind, key);

  // ── Copies held back ──────────────────────────────────────────────────

  /// The items of which this device knows two live copies, neither by someone
  /// who could have moved it out of the other's Crate: a fresh device shows
  /// neither ([_holdOut]; a device that held one for longer keeps it, [_refuse]).
  /// Each copy comes with its Crate, who wrote it and when, and what this account
  /// may do about it. What someone who could have moved it wrote since is settled,
  /// and not listed.
  Future<List<HeldBackItem>> heldBack() async {
    final crates = await _crates();
    final record = await LocalRecord.load(db, orchardId);
    final items = <HeldBackItem>[];
    for (final state in await LocalStateStore(db).keysWithPrefix(_refusedPrefix)) {
      final id = state.substring(_refusedPrefix.length);
      final bar = id.indexOf('|');
      if (bar < 0) continue;
      final kind = id.substring(0, bar);
      final key = id.substring(bar + 1);
      final noted = await _refused(kind, key);
      final back = noted == null ? null : await _heldBack(kind, key, noted, record);
      if (back == null) continue;
      final ids = back.copies.keys.toList()..sort();
      items.add(HeldBackItem(kind: kind, key: key, copies: [
        for (final c in ids)
          HeldBackCopy(
            crateId: c,
            author: back.copies[c]!.author,
            editedAt: back.copies[c]!.editedAt,
            name: back.copies[c]!.name,
            here: c == back.here,
            mayKeep: _mayKeep(crates, c, {...ids}..remove(c)),
            mayRemove: c != back.here && (crates[c]?.allows(CrateSwitches.delete) ?? false),
          ),
      ]));
    }
    return items;
  }

  /// Keeps the copy in [crateId] of an item held back ([heldBack]), as this
  /// account: where this device holds it, it goes again as this account's edit;
  /// otherwise it is read again first ([_keepCopy]). Every other copy goes, as a
  /// deletion naming that Crate. Takes edit there and delete in each of the others,
  /// or does nothing and says false. The next sync sends it.
  Future<bool> keepHeldBack(String kind, String key, String crateId) => _applying(() async {
        final noted = await _refused(kind, key);
        final back = noted == null ? null : await _heldBack(kind, key, noted, await LocalRecord.load(db, orchardId));
        if (back == null || !back.copies.containsKey(crateId)) return false;
        final others = {...back.copies.keys}..remove(crateId);
        if (!_mayKeep(await _crates(), crateId, others)) return false;
        if (back.here == crateId) {
          final at = _laterThan(back.copies.values);
          for (final other in others) {
            await _addLeftover(kind, key, other, noted!.copies[other]!, editedAt: at);
            await _forgetRefused(kind, key, other);
          }
          await _queueAgain(kind, key, at);
          return true;
        }
        noted!.keep = crateId;
        await _keepRefused(kind, key, noted);
        await _readAgain(crateId, noted.copies[crateId]!);
        return true;
      });

  /// Deletes the copy in [crateId] of an item held back ([heldBack]), as this
  /// account: what is left is then the item, as the rule says of a copy gone.
  /// Takes delete there, or does nothing and says false. (A device that holds that
  /// copy keeps the other instead.) The next sync sends it.
  Future<bool> removeHeldBack(String kind, String key, String crateId) => _applying(() async {
        final noted = await _refused(kind, key);
        final back = noted == null ? null : await _heldBack(kind, key, noted, await LocalRecord.load(db, orchardId));
        if (back == null || !back.copies.containsKey(crateId) || back.here == crateId) return false;
        if (!((await _crates())[crateId]?.allows(CrateSwitches.delete) ?? false)) return false;
        await _addLeftover(kind, key, crateId, noted!.copies[crateId]!, editedAt: _laterThan(back.copies.values));
        return true;
      });

  /// The copies held back that [noted] speaks of, by Crate, and the one of them
  /// this device holds; null where this is not two copies nobody can tell apart.
  Future<({Map<String, _Noted> copies, String? here})?> _heldBack(
    String kind,
    String key,
    _Refused noted,
    LocalRecord record,
  ) async {
    if (noted.heldOut) {
      if (noted.copies.length < 2) return null;
      return (
        copies: {for (final c in noted.copies.keys) c: noted.who[c] ?? const _Noted(null, null, null)},
        here: null,
      );
    }
    final meta = await _meta(kind, key);
    if (meta == null || meta.serverRevision == null || meta.serverDeleted) return null;
    final by = meta.author;
    final others = {
      for (final e in noted.who.entries)
        if (noted.copies.containsKey(e.key) &&
            e.key != meta.crateId &&
            !(by != null && record.latest.switchesAt(by, e.key, 0).contains(CrateSwitches.delete)))
          e.key: e.value,
    };
    if (others.isEmpty) return null;
    final name = _Noted.nameOf(kind, await _store.read(kind, key));
    return (copies: {meta.crateId: _Noted(by, meta.editedAt, name), ...others}, here: meta.crateId);
  }

  /// Whether this account may keep the copy in [crateId]: edit it there, and
  /// delete the copy in each of [others], which is what the rule asks of a version
  /// to be the item.
  bool _mayKeep(Map<String, _Crate> crates, String crateId, Set<String> others) =>
      (crates[crateId]?.allows(CrateSwitches.edit) ?? false) &&
      others.every((other) => crates[other]?.allows(CrateSwitches.delete) ?? false);

  /// Now, or later than any of [copies] says it was written: a time its author
  /// chose holds nothing off (and none past the latest a record may say,
  /// [itemEditedAfter]).
  int _laterThan(Iterable<_Noted> copies) {
    var at = _nowMs();
    for (final copy in copies) {
      final was = copy.editedAt;
      if (was != null) at = itemEditedAfter(was, at);
    }
    return at;
  }

  /// [rec] is the copy someone chose ([keepHeldBack]), read again: it is taken and
  /// goes again as this account's edit, and every other copy goes. Should the rights
  /// have gone since, the choice goes instead and false is said.
  Future<bool> _keepCopy(
    String c,
    ItemRecord rec,
    int revision,
    _Refused noted,
    List<_Loser> losers,
    CrateSyncReport report, {
    required _Meta? meta,
    required _Pending? pending,
  }) async {
    noted
      ..keep = null
      ..copies[c] = revision
      ..who[c] = _Noted.of(rec);
    final back = await _heldBack(rec.kind, rec.key, noted, _record);
    final others = {...?back?.copies.keys}..remove(c);
    if (back == null || !back.copies.containsKey(c) || !_mayKeep(await _crates(), c, others)) {
      await _keepRefused(rec.kind, rec.key, noted);
      return false;
    }
    if (pending != null) {
      losers.add(_Loser(back.here ?? c, await _localVersion(rec.kind, rec.key, pending.editedAt)));
      await _clearPending(pending);
      report.conflictsLost++;
    }
    final at = _laterThan(back.copies.values);
    for (final other in others) {
      final base = other == back.here ? meta!.serverRevision! : noted.copies[other]!;
      await _addLeftover(rec.kind, rec.key, other, base, editedAt: at);
      await _forgetRefused(rec.kind, rec.key, other);
    }
    await _forgetRefused(rec.kind, rec.key, c);
    await _take(rec, c, revision);
    await _queueAgain(rec.kind, rec.key, at);
    report.received++;
    return true;
  }

  // ── Pull ──────────────────────────────────────────────────────────────

  /// Reads [crate]'s changes since this device last read it, or, with
  /// [reread], every item from the start: what the server lacks of what this
  /// device holds is then queued to go again (see [_receive] and
  /// [_sendAgainWhatTheServerLost]). True when the Crate was read to its end.
  ///
  /// A server restored from an older backup is found here too: the Crate's
  /// newest revision is below what this device read, or the newest version
  /// this device holds of any of its items is not on the server any more
  /// ([ItemCheck]). Revisions are never handed out twice, so what others
  /// wrote since the restore is above what this device read and comes in as
  /// usual; what the server lost is what this device must send. It is noted
  /// for the whole Orchard ([kServerWentBackState]), and every Crate is read
  /// again before anything is sent.
  ///
  /// A copy refused here that turned out to be the item (it followed a move:
  /// [_readAgain]) is read again from where it was.
  Future<bool> _pullCrate(_Crate crate, CrateSyncReport report, {bool reread = false}) async {
    var since = reread ? 0 : crate.lastRevision;
    if (reread) {
      await db.customStatement('UPDATE orchard_crates SET last_revision = 0 WHERE crate_id = ?', [crate.id]);
    }
    final firstRead = !reread && await _neverRead(crate);
    final witness = reread ? null : await _witness(crate.id);
    final read = witness == null || witness.revision < since ? since : witness.revision;
    final again = await _readAgainFrom(crate.id);
    if (again != null && again < since) since = again;
    _reading = crate.id;
    _readAgainHere = false;
    final seen = <String>{};
    var first = true;
    while (true) {
      final page = await server.changes(crate.id, since: since, check: first ? witness : null);
      if (first && !reread) {
        final head = page.head;
        if ((head != null && head < read) || page.check == false) {
          AppLogger.warning('Orchard sync: a Crate on the server is behind what this device read; '
              'the server went back in time, so every Crate is read again');
          await LocalStateStore(db).write(kServerWentBackState, '1');
          _wentBack = true;
          return false;
        }
      }
      first = false;
      if (page.keyGeneration > crate.keyGeneration) report.needsKeys = true;
      for (final (itemId, remote) in page.items) {
        final Object? opened;
        try {
          opened = await _open(crate.id, itemId, remote.item, report);
        } catch (e) {
          await _holdBack(crate.id, remote.revision, e, report);
          since = remote.revision;
          continue;
        }
        if (opened is _MissingKey || opened is _MissingRecord) {
          // Stop before it: it is read again once the key, or the record,
          // is here.
          await _saveProgress(crate.id, since);
          return false;
        }
        if (opened is ItemRecord) {
          final rec = opened;
          seen.add('${rec.kind}|${rec.key}');
          final losers = <_Loser>[];
          try {
            await _applying(() =>
                _receive(crate.id, rec, remote.revision, losers, report, reread: reread, firstRead: firstRead));
          } on FormatException catch (e) {
            // A version this device cannot take, or will not (RecordRefused):
            // what it held stays, and nothing of it lost. It stopped here for
            // good: read again at each sync, one member's record held up every
            // later item of the Crate for everyone.
            AppLogger.warning('Orchard sync: a version of an item was not taken (${e.message})');
            report.rejected++;
            losers.clear();
          } catch (e) {
            losers.clear();
            await _holdBack(crate.id, remote.revision, e, report);
          }
          await _keepLosers(losers, report);
        }
        since = remote.revision;
      }
      since = page.latest > since ? page.latest : since;
      await _saveProgress(crate.id, since);
      if (!page.more) break;
    }
    if (again != null && !_readAgainHere) await LocalStateStore(db).remove(_readAgainState(crate.id));
    if (firstRead) await LocalStateStore(db).write(_readOnceState(crate.id), '1');
    if (reread) await _sendAgainWhatTheServerLost(crate, seen);
    _readThrough.add(crate.id);
    return true;
  }

  /// Once this device reads a newer item record format than it read its
  /// Crates in, every Crate it has read is read again from its start
  /// ([_noteReadAgain]: its progress stays, and what it holds is the same
  /// version coming back, passed over): what it refused before, as a version
  /// before 3.4 refuses an FTPS host ([kItemRecordFormat]), comes in now. Kept
  /// for each Crate until it was read to its end, through a sync that stopped
  /// part way.
  Future<void> _readAgainInNewFormat(Map<String, _Crate> crates) async {
    final store = LocalStateStore(db);
    final read = int.tryParse(await store.read(_readFormatState) ?? '') ?? 1;
    if (read >= readsFormat) return;
    for (final crate in crates.values) {
      if (crate.lastRevision > 0) await _noteReadAgain(crate.id, 1);
    }
    await store.write(_readFormatState, '$readsFormat');
    AppLogger.info('Orchard sync: this version reads more kinds of item; every vault is read again once');
  }

  /// Whether this device never read [crate] to its end. (Its progress alone
  /// does not say: one with nothing in it stays at the start.)
  Future<bool> _neverRead(_Crate crate) async =>
      crate.lastRevision == 0 && await LocalStateStore(db).read(_readOnceState(crate.id)) == null;

  /// Notes that this device starts reading the Orchard with nothing read yet
  /// ([_firstSyncState]): every Crate never read, and not because the server
  /// went back. Kept until every Crate was read to its end, through a sync
  /// that stopped part way.
  Future<void> _noteFirstSync(Map<String, _Crate> crates, {required bool rereading}) async {
    final store = LocalStateStore(db);
    _firstSync = await store.read(_firstSyncState) != null;
    if (_firstSync || rereading || crates.isEmpty) return;
    for (final crate in crates.values) {
      if (!await _neverRead(crate)) return;
    }
    await store.write(_firstSyncState, '1');
    _firstSync = true;
  }

  /// The newest version this device holds of an item of [crateId], to ask
  /// the server whether it still holds it; null for none (or no key to name
  /// the item by).
  Future<ItemCheck?> _witness(String crateId) async {
    final row = await db.customSelect(
      'SELECT kind, item_key, server_revision FROM crate_items_meta '
      'WHERE crate_id = ? AND server_revision IS NOT NULL ORDER BY server_revision DESC LIMIT 1',
      variables: [Variable(crateId)],
    ).getSingleOrNull();
    if (row == null) return null;
    final idKey = await _idKey(crateId);
    if (idKey == null) return null;
    return ItemCheck(crateItemId(idKey, kind: row.read<String>('kind'), key: row.read<String>('item_key')),
        row.read<int>('server_revision'));
  }

  /// After [crate] was read again from the start ([seen]: every item the
  /// server holds there): an item this device holds in it, based on a copy
  /// the server no longer has, goes again as new; one it holds no row of
  /// (deleted here, and that deletion lost) is nothing to send, and its
  /// bookkeeping goes.
  Future<void> _sendAgainWhatTheServerLost(_Crate crate, Set<String> seen) async {
    final rows = await db.customSelect(
      'SELECT kind, item_key, edited_at FROM crate_items_meta WHERE crate_id = ? AND server_revision IS NOT NULL',
      variables: [Variable(crate.id)],
    ).get();
    var queued = 0;
    for (final r in rows) {
      final kind = r.read<String>('kind');
      final key = r.read<String>('item_key');
      if (seen.contains('$kind|$key') || !OrchardItemStore.isKind(kind)) continue;
      if (await _store.read(kind, key) == null) {
        await db.customStatement('DELETE FROM crate_items_meta WHERE kind = ? AND item_key = ?', [kind, key]);
        continue;
      }
      await db.customStatement(
        'UPDATE crate_items_meta SET server_revision = NULL, server_deleted = 0 WHERE kind = ? AND item_key = ?',
        [kind, key],
      );
      if (crate.allows(kind == kHostKeyKind ? CrateSwitches.edit : CrateSwitches.add)) {
        await _queueAgain(kind, key, r.read<int?>('edited_at') ?? 0);
        queued++;
      }
    }
    if (queued > 0) AppLogger.info('Orchard sync: $queued item(s) the server lost go to it again');
  }

  /// Queues [kind]/[key] to be sent again as this device holds it, with its
  /// edit time [editedAt]; a change already waiting keeps its own.
  Future<void> _queueAgain(String kind, String key, int editedAt) async {
    await db.customStatement('UPDATE orchard_sync_control SET change_seq = change_seq + 1 WHERE id = 1');
    await db.customStatement(
      'INSERT OR IGNORE INTO crate_outbox (kind, item_key, change_seq, edited_at) '
      'SELECT ?, ?, change_seq, ? FROM orchard_sync_control WHERE id = 1',
      [kind, key, editedAt],
    );
  }

  /// The version at [revision] in [crateId] threw [error] as it was opened or
  /// taken, as no version should: it is held back, and read again at the next
  /// sync ([_noteReadAgain]), while every other item of every Crate syncs.
  /// What this device held of it stays, as the transaction that took it rolls
  /// back. One member's version used to stop every member's team sync, in every
  /// vault, at every sync, until the data was mended by hand (found in a security
  /// review); and something that failed only this once, read
  /// again, is not lost. Counted as refused, and the log says so.
  Future<void> _holdBack(String crateId, int revision, Object error, CrateSyncReport report) async {
    AppLogger.warning('Orchard sync: a version of an item was held back, to be read again (${errorKind(error)})');
    report.rejected++;
    await _noteReadAgain(crateId, revision);
  }

  Future<void> _saveProgress(String crateId, int revision) => db.customStatement(
        'UPDATE orchard_crates SET last_revision = ? WHERE crate_id = ? AND last_revision < ?',
        [revision, crateId, revision],
      );

  /// Opens a record: the [ItemRecord], [_MissingKey], [_MissingRecord], or
  /// null when refused.
  Future<Object?> _open(
    String crateId,
    String itemId,
    SealedItem? item,
    CrateSyncReport report,
  ) async {
    if (item == null) {
      report.rejected++;
      return null;
    }
    final crateKey = await _crateKey(crateId, item.keyGeneration);
    final idKey = await _idKey(crateId);
    if (crateKey == null || idKey == null) {
      report.needsKeys = true;
      return const _MissingKey();
    }
    final ItemRecord rec;
    try {
      rec = await openItem(item,
          orchardId: orchardId,
          crateId: crateId,
          crateKey: crateKey,
          idKey: idKey,
          signers: signers,
          readsFormat: readsFormat);
    } on ItemRejected catch (e) {
      AppLogger.warning('Orchard sync: an item in a Crate was refused (${e.reason})');
      report.rejected++;
      return null;
    }
    return _checkAnchor(rec, crateId, report);
  }

  /// Checks a version against the Orchard's record ([checkVersionAnchor]).
  Future<Object?> _checkAnchor(ItemRecord rec, String crateId, CrateSyncReport report) async {
    switch (await checkVersionAnchor(_record, rec, crateId)) {
      case VersionStanding.allowed:
        if (!await writtenWhileAllowed(_record, rec, crateId, _nowMs() ~/ 1000)) {
          AppLogger.warning('Orchard sync: an item was written after its author lost access');
          report.rejected++;
          return null;
        }
        return rec;
      case VersionStanding.recordBehind:
        report.needsRecord = true;
        return const _MissingRecord();
      case VersionStanding.otherRecord:
        AppLogger.warning('Orchard sync: an item names a record entry this device does not have');
        report.recordMismatch = true;
        report.rejected++;
        return null;
      case VersionStanding.notAllowed:
        AppLogger.warning('Orchard sync: an item was written by someone not allowed to');
        report.rejected++;
        return null;
    }
  }

  /// [rec] naming the record's last entry here, as every version this
  /// device writes does.
  ItemRecord _anchored(ItemRecord rec) => _record.seq == 0
      ? rec
      : ItemRecord(
          kind: rec.kind,
          key: rec.key,
          author: rec.author,
          authorKeyVersion: rec.authorKeyVersion,
          editedAt: rec.editedAt,
          deleted: rec.deleted,
          movedTo: rec.movedTo,
          data: rec.data,
          extra: rec.extra,
          recordSeq: _record.seq,
          recordHead: _record.head,
        );

  /// Takes one version from Crate [c] at [revision], against what this
  /// device has. Runs with the outbox triggers off, in one transaction.
  /// Versions of this device's that lose go to [losers], for the history.
  Future<void> _receive(
    String c,
    ItemRecord rec,
    int revision,
    List<_Loser> losers,
    CrateSyncReport report, {
    bool reread = false,
    bool firstRead = false,
  }) async {
    if (!OrchardItemStore.isKind(rec.kind)) return;
    final meta = await _meta(rec.kind, rec.key);
    if (meta != null &&
        meta.crateId == c &&
        meta.serverRevision == revision &&
        (!reread || meta.editedAt == rec.editedAt)) {
      return; // this device's own write, coming back
    }
    // A pin's key names its Crate, and a pin counts for that Crate's hosts
    // alone (team_host_keys.dart): one in another Crate is no pin of anything,
    // and no device gives the real one's place to it.
    if (rec.kind == kHostKeyKind && !rec.deleted && _namesAnotherCrate(rec.key, c)) {
      AppLogger.warning('Orchard sync: a pinned host key in one Crate names another');
      report.rejected++;
      return;
    }
    final pending = await _pending(rec.kind, rec.key);
    // Someone who holds the rights chose this copy ([keepHeldBack]).
    final chosen = await _refused(rec.kind, rec.key);
    if (chosen?.keep == c &&
        !rec.deleted &&
        await _keepCopy(c, rec, revision, chosen!, losers, report, meta: meta, pending: pending)) {
      return;
    }
    if (meta == null && pending == null) {
      final refused = await _refused(rec.kind, rec.key);
      if (refused != null && refused.heldOut) return _receiveHeldOut(c, rec, revision, refused, report);
    }
    final home = meta?.crateId ?? (pending != null ? await _defaultCrateId(await _crates()) : null);

    if (home == null) {
      // New to this device. A deletion of something it never had is nothing.
      if (rec.deleted) return;
      await _take(rec, c, revision);
      report.received++;
      return;
    }

    final local = pending == null ? null : await _localVersion(rec.kind, rec.key, pending.editedAt);

    if (home == c) {
      // A version older than the one this device holds, where it has no
      // change of its own: every change is later than the version it
      // replaced (the outbox stamps it so), so this is a server sending an
      // old version again, to roll the item back or to bring back what was
      // deleted (a team's pinned host key among them). The device keeps what
      // it holds, and bases its next change on the revision the server
      // shows (found in a client security review).
      final held = meta?.editedAt;
      final heldRevision = meta?.serverRevision;
      // Older: an earlier time, or the same time and an earlier write to the
      // server. Below the latest time a record may say, a change is later than
      // what it replaced, so one time is one version; at it, every change has
      // that time ([itemEditedAfter], V-2), and only the server's order tells
      // them apart (where it went back, the version it lost is the later write).
      final older = held != null &&
          heldRevision != null &&
          (rec.editedAt < held || (rec.editedAt == held && revision < heldRevision));
      if (local == null && older && reread) {
        // The server was restored from an older backup and lost the version
        // this device holds: it goes again, based on the copy there now.
        await _setMeta(rec.kind, rec.key, crateId: c, serverRevision: revision, serverDeleted: rec.deleted, editedAt: held);
        final need = await _store.read(rec.kind, rec.key) == null
            ? CrateSwitches.delete
            : rec.deleted && rec.kind != kHostKeyKind
                ? CrateSwitches.add
                : CrateSwitches.edit;
        if ((await _crates())[c]?.allows(need) ?? false) await _queueAgain(rec.kind, rec.key, held);
        return;
      }
      if (local == null && older) {
        AppLogger.warning('Orchard sync: an older version of an item was refused');
        await _setMeta(rec.kind, rec.key,
            crateId: c, serverRevision: revision, serverDeleted: meta!.serverDeleted, editedAt: held);
        report.rejected++;
        return;
      }
      final movedTo = rec.movedTo;
      if (local != null && versionWins(local, rec) && (movedTo == null || await _mayMoveOutOf(movedTo))) {
        // This device's change is newer: the next push replaces that version,
        // and the server keeps it in the item's history.
        await _setMeta(rec.kind, rec.key,
            crateId: c, serverRevision: revision, serverDeleted: rec.deleted, editedAt: meta?.editedAt);
        report.conflictsWon++;
        return;
      }
      // (A change newer than a move, by an account that could not have moved
      // the item out of where it went, loses to it: every device that followed
      // the move would refuse the copy it brought back here, and others would
      // keep it. It goes to the history.)
      if (local != null) {
        losers.add(_Loser(c, local));
        await _clearPending(pending!);
        report.conflictsLost++;
      }
      if (rec.deleted && movedTo != null && (await _crates()).containsKey(movedTo)) {
        // It moved to a Crate this account can open and lives on there: keep
        // its rows (and what is yours alone on them) and follow it. A copy
        // there refused so far (read first, by someone who could not have
        // moved it: an edit since the move) is the item now.
        await _setMeta(rec.kind, rec.key,
            crateId: movedTo, serverRevision: null, serverDeleted: false, editedAt: rec.editedAt);
        final refused = (await _refused(rec.kind, rec.key))?.copies[movedTo];
        if (refused != null) {
          await _forgetRefused(rec.kind, rec.key, movedTo);
          await _readAgain(movedTo, refused);
        }
        return;
      }
      await _take(rec, c, revision);
      report.received++;
      if (rec.deleted) await _tookDeletion(rec, revision);
      return;
    }

    // The item lives in another Crate on this device. A copy here this
    // device already means to remove (it moved the item away) is known.
    final leftover = await db.customSelect(
      'SELECT revision, edited_at FROM crate_leftovers WHERE kind = ? AND item_key = ? AND crate_id = ?',
      variables: [Variable(rec.kind), Variable(rec.key), Variable(c)],
    ).getSingleOrNull();
    if (leftover != null && leftover.read<int>('revision') >= revision) return;
    final over = await _tookOver(rec.kind, rec.key);
    if (rec.deleted) {
      // The Crate a copy took a deletion's place of deleted it again: a copy to
      // replace that one is no older than this.
      if (over != null && over.crate == c && rec.editedAt > over.at) {
        await _noteTookOver(rec.kind, rec.key, c, rec.editedAt);
      }
      // A deletion in a Crate the item has left: that copy is gone. Where it
      // says the item went on from there to a third Crate, it is noted: this
      // device may yet follow a move to here, and then it is read again.
      await _dropLeftover(rec.kind, rec.key, c);
      final onward = rec.movedTo;
      if (onward != null && onward != home) {
        final passed = await _refused(rec.kind, rec.key) ?? _Refused({});
        passed.copies[c] = revision;
        passed.who.remove(c);
        await _keepRefused(rec.kind, rec.key, passed);
      } else {
        await _forgetRefused(rec.kind, rec.key, c);
      }
      return;
    }
    final mine = local ?? await _localVersion(rec.kind, rec.key, meta?.editedAt ?? 0);
    final mineWins = versionWins(mine, rec);
    final firstLook = firstRead || _firstSync;

    // What is held took a deletion's place in this Crate, and is no item of its
    // own: this copy, no older than that deletion, is what comes back. Not over a
    // version by someone who could have moved it out of here: that made it a move
    // like any other, and the note is done with either way.
    if (over != null && over.crate == c && leftover == null && rec.editedAt >= over.at) {
      final authorOfHeld = local != null ? author.uid : meta?.author;
      final movedOut = !mine.deleted &&
          authorOfHeld != null &&
          _record.latest.switchesAt(authorOfHeld, c, 0).contains(CrateSwitches.delete);
      await _forgetTookOver(rec.kind, rec.key);
      if (!movedOut) {
        return _takeCopy(c, rec, revision, losers, report,
            home: home, meta: meta, local: local, pending: pending, leaves: false);
      }
    }

    // All this device holds of the item is a deletion, so a live copy here
    // overwrites nothing and takes no item's place: as on a device that holds
    // nothing, it is taken where it is no older than that deletion (a move
    // leaves both with one time), or where that deletion names this Crate.
    // Nothing is signed. First the Crate the deletion came from is read, where
    // the item may have come back: a copy read before that would take the place
    // of the real one, on nothing but which Crate sorts first.
    if (local == null && leftover == null && meta != null && meta.serverDeleted && mine.deleted) {
      final leftFor = await _leftFor(rec.kind, rec.key, meta);
      if (leftFor == c || rec.editedAt >= (meta.editedAt ?? 0)) {
        if ((await _crates()).containsKey(home) && !_readThrough.contains(home)) {
          await _noteReadAgain(c, revision);
          _copyWaits = true;
          return;
        }
        await LocalStateStore(db).remove(_leftForState(rec.kind, rec.key));
        // A copy from elsewhere: the item's own Crate keeps its say ([_tookOver]).
        if (leftFor == null && over == null && !await _couldMove(rec, from: home, to: c)) {
          await _noteTookOver(rec.kind, rec.key, home, meta.editedAt ?? 0);
        }
        return _takeCopy(c, rec, revision, losers, report,
            home: home, meta: meta, local: null, pending: null, leaves: false);
      }
      // Older than a deletion that says the item went on to another Crate: it
      // stays out until it is edited, and is not signed away, since the item
      // lives on and this device cannot tell this copy is not on its way.
      if (leftFor != null) return _refuse(c, rec, revision, report);
    }

    // A live copy here and one in its Crate. This device moved the item out
    // of here, and the Crate it goes to holds no copy yet: this is still where
    // the item is, so it is a change like any other, and the newer one decides.
    final stillHere = leftover != null && meta?.serverRevision == null;
    // Otherwise a copy counts only as a move: one by someone who could not
    // have moved it out of where the item lives is not the item, whatever
    // time it says.
    final moved = stillHere || await _couldMove(rec, from: home, to: c);
    // And what this device holds, as the record stands (it does not keep which
    // entry that version named).
    final heldAuthor = local != null ? author.uid : meta?.author;
    final heldCouldMove = stillHere ||
        (heldAuthor != null && _record.latest.switchesAt(heldAuthor, c, 0).contains(CrateSwitches.delete));

    if (moved && !mineWins) {
      // The newer version decides where the item lives, and the other copy
      // goes: its author could remove it. Not on a first look at a copy of
      // someone who could not have moved it here: nothing is signed for what
      // this device only just read.
      return _takeCopy(c, rec, revision, losers, report,
          home: home, meta: meta, local: local, pending: pending, leaves: heldCouldMove || !firstLook);
    }
    if (mineWins && heldCouldMove && (moved || (reread && !_keepFirst(rec.kind)))) {
      // Older than what this device holds, by someone who could have moved it
      // (or, where the server went back, the copy its deletion was lost over):
      // it is never taken, and the other copy goes.
      if (local == null && !stillHere && !reread && rec.editedAt < (meta?.editedAt ?? 0)) {
        AppLogger.warning('Orchard sync: an older version of an item, in another Crate, was refused');
        report.rejected++;
      }
      await _addLeftover(rec.kind, rec.key, c, revision, editedAt: mine.editedAt);
      return;
    }
    if (leftover != null) {
      // This device already means to remove that copy, by a right of its own.
      // It goes, with what someone changed in it since, and later than that
      // change, so that those who hold it take the deletion.
      final was = leftover.read<int>('edited_at');
      await _addLeftover(rec.kind, rec.key, c, revision, editedAt: itemEditedAfter(rec.editedAt, was));
      if (!moved) report.rejected++;
      return;
    }
    if (moved && firstLook && local == null) {
      // Older than a copy this device read just now, by someone who could not
      // have moved that one here: its time, which its author chose, holds
      // nothing off. (Older than one held for longer, it is a server sending
      // it again: refused below.)
      return _takeCopy(c, rec, revision, losers, report,
          home: home, meta: meta, local: local, pending: pending, leaves: false);
    }
    if (!moved && !heldCouldMove && _firstSync && local == null && meta?.serverRevision != null && !_keepFirst(rec.kind)) {
      return _holdOut(c, rec, revision, meta!, report);
    }
    await _refuse(c, rec, revision, report,
        neither: !moved && !heldCouldMove && meta?.serverRevision != null && !_keepFirst(rec.kind));
  }

  /// Takes [rec], a copy in [c], over the one this device holds in [home]:
  /// the item lives in [c] from now on. With [leaves], the copy in [home] goes
  /// too (a device that may delete there signs its deletion).
  Future<void> _takeCopy(
    String c,
    ItemRecord rec,
    int revision,
    List<_Loser> losers,
    CrateSyncReport report, {
    required String home,
    required _Meta? meta,
    required ItemRecord? local,
    required _Pending? pending,
    required bool leaves,
  }) async {
    if (local != null) {
      losers.add(_Loser(home, local));
      await _clearPending(pending!);
      report.conflictsLost++;
    }
    if (leaves && meta?.serverRevision != null) {
      await _addLeftover(rec.kind, rec.key, home, meta!.serverRevision!, editedAt: rec.editedAt);
    }
    await _dropLeftover(rec.kind, rec.key, c);
    await _forgetRefused(rec.kind, rec.key, c);
    await _take(rec, c, revision);
    report.received++;
  }

  /// [rec], a deletion at [revision], is what this device holds of its item now.
  /// Where it says the item went on, that is kept, for the day this device can
  /// open where it went ([_leftFor]). A copy passed over while the item was live
  /// here may be the item now: read again.
  Future<void> _tookDeletion(ItemRecord rec, int revision) async {
    final movedTo = rec.movedTo;
    if (movedTo != null) await LocalStateStore(db).write(_leftForState(rec.kind, rec.key), '$revision $movedTo');
    final passed = await _refused(rec.kind, rec.key);
    if (passed == null || passed.heldOut) return;
    await _forgetAllRefused(rec.kind, rec.key);
    for (final copy in passed.copies.entries) {
      await _readAgain(copy.key, copy.value);
    }
  }

  /// The Crate the deletion this device holds ([meta]) says its item went to, or
  /// null where it says none. (A note kept of an earlier deletion says nothing.)
  Future<String?> _leftFor(String kind, String key, _Meta meta) async {
    final note = await LocalStateStore(db).read(_leftForState(kind, key));
    final held = '${meta.serverRevision} ';
    return note != null && note.startsWith(held) ? note.substring(held.length) : null;
  }

  /// The Crate whose deletion a copy from elsewhere took the place of on this
  /// device, and that deletion's time; null where none did.
  Future<({String crate, int at})?> _tookOver(String kind, String key) async {
    final note = await LocalStateStore(db).read(_tookOverState(kind, key));
    if (note == null) return null;
    final space = note.indexOf(' ');
    final at = space < 0 ? null : int.tryParse(note.substring(0, space));
    return at == null ? null : (crate: note.substring(space + 1), at: at);
  }

  Future<void> _noteTookOver(String kind, String key, String crate, int at) =>
      LocalStateStore(db).write(_tookOverState(kind, key), '$at $crate');

  Future<void> _forgetTookOver(String kind, String key) => LocalStateStore(db).remove(_tookOverState(kind, key));

  /// Whether [rec], a live copy in the Crate [to], was written by someone who
  /// could have moved it out of the Crate [from]: judged as the deletion a move
  /// leaves there would be, at the record's entry the version names, and as
  /// written while they still could ([writtenWhileAllowed]: otherwise someone
  /// who once held that switch could name an entry from then). A move's other
  /// half, adding to [to], is what [_checkAnchor] asked of it already.
  Future<bool> _couldMove(ItemRecord rec, {required String from, required String to}) async {
    final deletion = ItemRecord(
      kind: rec.kind,
      key: rec.key,
      author: rec.author,
      authorKeyVersion: rec.authorKeyVersion,
      editedAt: rec.editedAt,
      deleted: true,
      movedTo: to,
      recordSeq: rec.recordSeq,
      recordHead: rec.recordHead,
    );
    if (await checkVersionAnchor(_record, deletion, from) != VersionStanding.allowed) return false;
    return writtenWhileAllowed(_record, deletion, from, _nowMs() ~/ 1000);
  }

  /// Whether this account could move an item out of [crateId].
  Future<bool> _mayMoveOutOf(String crateId) async =>
      (await _crates())[crateId]?.allows(CrateSwitches.delete) ?? false;

  /// Refuses [rec], a copy in [c] that does not count: what this device holds
  /// stays, and nothing is signed on its strength. Noted, for the day the
  /// item's own copy moves to [c] after all; with [neither] (nobody can tell
  /// which of the two is the item) with who wrote it as well ([heldBack]).
  Future<void> _refuse(String c, ItemRecord rec, int revision, CrateSyncReport report, {bool neither = false}) async {
    AppLogger.warning('Orchard sync: a copy of an item in another Crate was refused: it is older, '
        'or its author could not have moved it there');
    final refused = await _refused(rec.kind, rec.key) ?? _Refused({});
    refused.copies[c] = revision;
    if (neither) {
      refused.who[c] = _Noted.of(rec);
    } else {
      refused.who.remove(c);
    }
    await _keepRefused(rec.kind, rec.key, refused);
    report.rejected++;
  }

  /// Two Crates hold live copies of an item, neither author could have moved
  /// it out of the other's, and this device only just read them: nobody can
  /// tell which is the item, and a copy written to take it over would be as
  /// good as the real one. It takes neither, until one of them goes, or one is
  /// written by someone who could move it ([_receiveHeldOut]). Nothing is
  /// signed. What a device that held one for longer does is keep it.
  Future<void> _holdOut(String c, ItemRecord rec, int revision, _Meta meta, CrateSyncReport report) async {
    AppLogger.warning('Orchard sync: two Crates hold an item under one key, and neither copy can be told '
        'for the item: it is held out of this device');
    final held = _Noted(meta.author, meta.editedAt, _Noted.nameOf(rec.kind, await _store.read(rec.kind, rec.key)));
    await _store.write(rec.kind, rec.key, data: null, editedAt: rec.editedAt);
    await db.customStatement('DELETE FROM crate_items_meta WHERE kind = ? AND item_key = ?', [rec.kind, rec.key]);
    await db.customStatement('DELETE FROM crate_leftovers WHERE kind = ? AND item_key = ?', [rec.kind, rec.key]);
    await _keepRefused(
      rec.kind,
      rec.key,
      _Refused({meta.crateId: meta.serverRevision!, c: revision},
          heldOut: true, who: {meta.crateId: held, c: _Noted.of(rec)}),
    );
    report.rejected++;
  }

  /// A version from [c] of an item held out of this device ([_holdOut]). A
  /// copy gone leaves what is left to be the item, read again. A live one
  /// counts only if its author could have moved it out of every other Crate
  /// that holds one. A removal of it waiting here ([removeHeldBack]) goes with
  /// what someone changed in it since, and later than that change.
  Future<void> _receiveHeldOut(String c, ItemRecord rec, int revision, _Refused out, CrateSyncReport report) async {
    final going = await db.customSelect(
      'SELECT edited_at FROM crate_leftovers WHERE kind = ? AND item_key = ? AND crate_id = ?',
      variables: [Variable(rec.kind), Variable(rec.key), Variable(c)],
    ).getSingleOrNull();
    if (rec.deleted) {
      if (going != null) await _dropLeftover(rec.kind, rec.key, c);
      out.copies.remove(c);
      if (out.copies.length > 1) return _keepRefused(rec.kind, rec.key, out);
      for (final left in out.copies.entries) {
        await _readAgain(left.key, left.value);
      }
      return _forgetAllRefused(rec.kind, rec.key);
    }
    out.copies[c] = revision;
    out.who[c] = _Noted.of(rec);
    for (final other in out.copies.keys) {
      if (other != c && !await _couldMove(rec, from: other, to: c)) {
        if (going != null) {
          final was = going.read<int>('edited_at');
          await _addLeftover(rec.kind, rec.key, c, revision, editedAt: itemEditedAfter(rec.editedAt, was));
        }
        await _keepRefused(rec.kind, rec.key, out);
        report.rejected++;
        return;
      }
    }
    if (going != null) await _dropLeftover(rec.kind, rec.key, c);
    await _forgetAllRefused(rec.kind, rec.key);
    await _take(rec, c, revision);
    report.received++;
  }

  /// Kinds whose key is a name, so that two Crates hold the same one in all
  /// honesty (a snippet category, or a pin from before a pin's key named its
  /// Crate), and whose copy hurts nobody whichever it is (a category's looks;
  /// a pin counts only for its own Crate's hosts): on a first look the first
  /// read stays, as on a device that held it for longer.
  static bool _keepFirst(String kind) => kind == 'category' || kind == kHostKeyKind;

  /// The Crate at the end of a pin's key where it is another than [crateId]
  /// ([teamHostKeyId]; a key from before pins carried their Crate names none).
  static bool _namesAnotherCrate(String key, String crateId) {
    final last = key.substring(key.lastIndexOf('|') + 1);
    return _crateIdShape.hasMatch(last) && last != crateId;
  }

  static final _crateIdShape = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  // ── Copies refused, and Crates to read again ──────────────────────────

  /// Set while this device has not yet read every Crate to its end once.
  static const _firstSyncState = 'crate.first_sync';

  static const _refusedPrefix = 'crate.refused.';

  static String _refusedState(String kind, String key) => '$_refusedPrefix$kind|$key';

  static String _readAgainState(String crateId) => 'crate.read_again.$crateId';

  static String _readOnceState(String crateId) => 'crate.read_once.$crateId';

  /// The newest item record format this device has read its Crates in.
  static const _readFormatState = 'crate.read_format';

  static String _leftForState(String kind, String key) => 'crate.left_for.$kind|$key';

  static String _tookOverState(String kind, String key) => 'crate.took_over.$kind|$key';

  /// The copies of an item this device refused, or null for none.
  Future<_Refused?> _refused(String kind, String key) async {
    final raw = await LocalStateStore(db).read(_refusedState(kind, key));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return _Refused(
        {
          for (final e in (json['copies'] as Map<String, dynamic>).entries) e.key: e.value as int,
        },
        heldOut: json['out'] == true,
        who: {
          for (final e in ((json['who'] as Map<String, dynamic>?) ?? const <String, dynamic>{}).entries)
            e.key: _Noted.fromJson(e.value as Map<String, dynamic>),
        },
        keep: json['keep'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _keepRefused(String kind, String key, _Refused refused) => LocalStateStore(db).write(
        _refusedState(kind, key),
        jsonEncode({
          'copies': refused.copies,
          if (refused.heldOut) 'out': true,
          'who': {
            for (final e in refused.who.entries)
              if (refused.copies.containsKey(e.key)) e.key: e.value.toJson(),
          },
          if (refused.copies.containsKey(refused.keep)) 'keep': refused.keep,
        }),
      );

  /// [crateId]'s copy of an item is no longer one refused.
  Future<void> _forgetRefused(String kind, String key, String crateId) async {
    final refused = await _refused(kind, key);
    if (refused == null || !refused.copies.containsKey(crateId)) return;
    refused.copies.remove(crateId);
    if (refused.copies.isEmpty) return _forgetAllRefused(kind, key);
    await _keepRefused(kind, key, refused);
  }

  Future<void> _forgetAllRefused(String kind, String key) => LocalStateStore(db).remove(_refusedState(kind, key));

  /// Where [crateId] is to be read again from, as [_readAgain] noted it.
  Future<int?> _readAgainFrom(String crateId) async =>
      int.tryParse(await LocalStateStore(db).read(_readAgainState(crateId)) ?? '');

  /// [crateId] is read again from its version at [revision] (this device's
  /// progress there stays), starting with one more round of this sync: kept,
  /// so that a sync that stops part way does not lose it.
  Future<void> _readAgain(String crateId, int revision) async {
    await _noteReadAgain(crateId, revision);
    _again = true;
  }

  /// [crateId] is read again from its version at [revision], next time it is
  /// read.
  Future<void> _noteReadAgain(String crateId, int revision) async {
    final from = revision - 1;
    final known = await _readAgainFrom(crateId);
    if (known == null || from < known) await LocalStateStore(db).write(_readAgainState(crateId), '$from');
    if (crateId == _reading) _readAgainHere = true;
  }

  /// Writes a version from Crate [crateId] here and records where it lives
  /// and who wrote it, keeping what a newer app put in it that this one does
  /// not know.
  Future<void> _take(ItemRecord rec, String crateId, int revision) async {
    await _store.write(rec.kind, rec.key, data: rec.deleted ? null : rec.data, editedAt: rec.editedAt);
    await _setMeta(rec.kind, rec.key,
        crateId: crateId,
        serverRevision: revision,
        serverDeleted: rec.deleted,
        editedAt: rec.editedAt,
        author: rec.author);
    final extras = rec.deleted
        ? ItemExtras.none
        : _store.extrasOf(rec.kind, rec.data!, record: rec.extra);
    await db.customStatement(
      'UPDATE crate_items_meta SET extra = ? WHERE kind = ? AND item_key = ?',
      [extras.encode(), rec.kind, rec.key],
    );
  }

  /// This device's version of an item, with what a newer app put in the last
  /// version received (and this one does not know) carried along.
  Future<ItemRecord> _localVersion(String kind, String key, int editedAt) async {
    final data = await _store.read(kind, key);
    final extras = ItemExtras.decode((await _meta(kind, key))?.extra);
    return ItemRecord(
      kind: kind,
      key: key,
      author: author.uid,
      authorKeyVersion: author.keys.version,
      editedAt: editedAt,
      deleted: data == null,
      data: data == null ? null : _store.withExtras(kind, data, extras),
      extra: data == null ? const {} : extras.record,
    );
  }

  /// Runs [body] in one transaction with the outbox triggers off, then lets
  /// the screens showing this Orchard read again.
  Future<T> _applying<T>(Future<T> Function() body) async {
    final result = await db.transaction(() async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      try {
        return await body();
      } finally {
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      }
    });
    db.notifyOrchardItemsChanged();
    return result;
  }

  /// Queues every item this account wrote last, in a Crate where it may
  /// still edit, to go again as it is, with its edit time: the next sync
  /// encrypts each one with its Crate's current key and signs it with the
  /// account's current keys. After a key replacement this takes the
  /// Orchard off the old keys, so they can be distrusted everywhere. Other
  /// members' items keep their author. Returns how many went into the
  /// queue ([queued]) and how many of this account's items sit in Crates
  /// where it can no longer edit ([stranded]): those stay signed with the
  /// old keys until someone who may edit them saves them again. A change
  /// already waiting keeps its own edit time.
  Future<({int queued, int stranded})> queueRewrite() async {
    return db.transaction(() async {
      await db.customStatement(
          'UPDATE orchard_sync_control SET change_seq = change_seq + 1 WHERE id = 1');
      final before = await _outboxCount();
      await db.customStatement(
        'INSERT OR IGNORE INTO crate_outbox (kind, item_key, change_seq, edited_at) '
        'SELECT m.kind, m.item_key, '
        '(SELECT change_seq FROM orchard_sync_control WHERE id = 1), COALESCE(m.edited_at, 0) '
        'FROM crate_items_meta m JOIN orchard_crates c ON c.crate_id = m.crate_id '
        "WHERE c.switches LIKE '%\"edit\"%' AND m.server_revision IS NOT NULL AND m.author = ?",
        [author.uid],
      );
      final stranded = await db.customSelect(
        'SELECT COUNT(*) AS n FROM crate_items_meta m JOIN orchard_crates c ON c.crate_id = m.crate_id '
        "WHERE c.switches NOT LIKE '%\"edit\"%' AND m.server_revision IS NOT NULL AND m.author = ?",
        variables: [Variable(author.uid)],
      ).getSingle();
      return (queued: await _outboxCount() - before, stranded: stranded.read<int>('n'));
    });
  }

  Future<int> _outboxCount() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle()).read<int>('n');

  // ── Push ──────────────────────────────────────────────────────────────

  Future<void> _push(Map<String, _Crate> crates, CrateSyncReport report) async {
    for (var round = 0; round < _maxPushRounds; round++) {
      final writes = await _collect(crates, report);
      if (writes.isEmpty) return;
      var again = false;
      for (final entry in writes.entries) {
        final crate = crates[entry.key]!;
        batches:
        for (final batch in _batches(entry.value)) {
          // One that lost to a newer version while this round went (its move
          // met an edit where the item was) is not sent after all: written
          // anyway, it would leave a second copy behind.
          var sending = [
            for (final w in batch)
              if (w.seq == null || (await _pending(w.record.kind, w.record.key))?.seq == w.seq) w,
          ];
          List<WriteResult>? results;
          while (results == null) {
            // More people in the Orchard than seats: new items wait on
            // this device until an owner buys seats; changes and deletions go.
            if (report.seatsNeeded) {
              final changes = [for (final w in sending) if (w.base != null) w];
              report.unsent += sending.length - changes.length;
              sending = changes;
            }
            if (sending.isEmpty) continue batches;
            try {
              results = await server.write(
                  crate.id, [for (final w in sending) ItemWrite(w.sealed, w.base)],
                  keyVersion: author.keys.version);
            } on StaleCrateKey {
              report.needsKeys = true;
              break batches;
            } on OrchardServerException catch (e) {
              if (e.staleAccountKeys) {
                // Signed with keys the account replaced: members no longer
                // trust them, so nothing more goes until the new ones are here.
                report.staleAccountKeys = true;
                return;
              }
              if (e.notFound) {
                report.goneCrates.add(crate.id);
                break batches;
              }
              if (e.code == 'read-only') {
                report.unsent += sending.length;
                break batches;
              }
              if (e.code == 'seats-needed') {
                if (e.reason == 'storage') report.vaultsFull = true;
                if (!report.seatsNeeded) {
                  // Once more, without the new items.
                  report.seatsNeeded = true;
                  continue;
                }
                // A deleted item brought back is new again: this batch waits.
                report.unsent += sending.length;
                continue batches;
              }
              rethrow;
            }
          }
          final byId = {for (final w in sending) w.sealed.itemId: w};
          for (final result in results) {
            final w = byId[result.itemId];
            if (w == null) continue;
            try {
              if (await _afterWrite(crate, w, result, report)) again = true;
            } catch (e) {
              // One answer that could not be handled here (the version a
              // conflict brought threw as it was taken, V-1): that change waits
              // as it is, and the next sync reads the version there (holding it
              // back if it throws again). Nothing is replaced on the strength of
              // a version not read, and every other answer is handled.
              AppLogger.warning('Orchard sync: the answer to a change was not handled; it waits (${errorKind(e)})');
              report.rejected++;
            }
          }
        }
      }
      if (!again) return;
    }
  }

  /// Everything waiting to be sent, by Crate: deletions of copies left in
  /// Crates items moved out of, then this device's changes.
  Future<Map<String, List<_Write>>> _collect(
    Map<String, _Crate> crates,
    CrateSyncReport report,
  ) async {
    final out = <String, List<_Write>>{};
    // Each round counts what cannot go afresh.
    report
      ..unsent = 0
      ..tooLarge = 0;
    final leftovers = await db
        .customSelect('SELECT kind, item_key, crate_id, revision, edited_at FROM crate_leftovers')
        .get();
    for (final row in leftovers) {
      final kind = row.read<String>('kind');
      final key = row.read<String>('item_key');
      final crate = crates[row.read<String>('crate_id')];
      if (crate == null || !crate.allows(CrateSwitches.delete)) {
        // Not this account's to remove any more.
        await _dropLeftover(kind, key, row.read<String>('crate_id'));
        continue;
      }
      final record = _anchored(ItemRecord(
        kind: kind,
        key: key,
        author: author.uid,
        authorKeyVersion: author.keys.version,
        editedAt: row.read<int>('edited_at'),
        deleted: true,
        movedTo: (await _meta(kind, key))?.crateId,
      ));
      final sealed = await _seal(crate, record, report);
      if (sealed == null) continue;
      out.putIfAbsent(crate.id, () => []).add(
          _Write(record, sealed, base: row.read<int>('revision'), leftover: true));
    }

    final queued = await db
        .customSelect(
            'SELECT kind, item_key, change_seq, edited_at FROM crate_outbox ORDER BY change_seq')
        .get();
    for (final row in queued) {
      final pending = _Pending(
        row.read<String>('kind'),
        row.read<String>('item_key'),
        row.read<int>('change_seq'),
        row.read<int>('edited_at'),
      );
      if (!OrchardItemStore.isKind(pending.kind)) {
        await _clearPending(pending);
        continue;
      }
      final meta = await _meta(pending.kind, pending.key);
      final homeId = meta?.crateId ?? await _defaultCrateId(crates);
      final home = homeId == null ? null : crates[homeId];
      if (home == null) {
        report.unsent++;
        continue;
      }
      final record = _anchored(await _localVersion(pending.kind, pending.key, pending.editedAt));
      if (record.deleted && meta?.serverRevision == null) {
        // Made and deleted again before it reached its Crate.
        await _clearPending(pending);
        continue;
      }
      // Adding, editing and deleting are each a switch of their own; a
      // team-pinned host key needs edit, new or not. Bringing back an
      // item the Crate holds a deletion of is adding it.
      final need = record.deleted
          ? CrateSwitches.delete
          : (meta?.serverRevision == null || meta!.serverDeleted) && record.kind != kHostKeyKind
              ? CrateSwitches.add
              : CrateSwitches.edit;
      if (!home.allows(need)) {
        report.unsent++;
        continue;
      }
      final sealed = await _seal(home, record, report);
      if (sealed == null) continue;
      if (sealed.record.length > maxRecordBytes) {
        report.tooLarge++;
        continue;
      }
      out.putIfAbsent(home.id, () => []).add(
          _Write(record, sealed, base: meta?.serverRevision, seq: pending.seq));
    }
    return out;
  }

  /// Handles one write's result. True when something must be sent again.
  Future<bool> _afterWrite(
    _Crate crate,
    _Write w,
    WriteResult result,
    CrateSyncReport report,
  ) async {
    final kind = w.record.kind;
    final key = w.record.key;
    switch (result) {
      case WriteOk(:final revision):
        if (w.leftover) {
          await _dropLeftover(kind, key, crate.id);
          // A copy held back is gone: its deletion is read now, and what it
          // leaves with it.
          if (await _refused(kind, key) != null) _again = true;
          return false;
        }
        await db.transaction(() async {
          await _setMeta(kind, key,
              crateId: crate.id,
              serverRevision: revision,
              serverDeleted: w.record.deleted,
              editedAt: w.record.editedAt,
              author: author.uid);
          await _clearPending(_Pending(kind, key, w.seq!, w.record.editedAt));
        });
        report.sent++;
        return false;

      case WriteConflict(:final current):
        if (current == null) {
          // Not there after all: send it as new.
          if (w.leftover) {
            await _dropLeftover(kind, key, crate.id);
            return false;
          }
          await _rebase(kind, key, crate.id, null, deleted: false);
          return true;
        }
        final opened = await _open(crate.id, w.sealed.itemId, current.item, report);
        if (opened is _MissingKey) return false;
        if (opened is! ItemRecord) {
          // What is there does not open or verify: replace it.
          if (w.leftover) {
            await _addLeftover(kind, key, crate.id, current.revision, editedAt: w.record.editedAt);
          } else {
            await _rebase(kind, key, crate.id, current.revision, deleted: current.item?.deleted ?? false);
          }
          return true;
        }
        if (w.leftover) {
          if (opened.deleted) {
            await _dropLeftover(kind, key, crate.id);
            return false;
          }
          if (versionWins(w.record, opened)) {
            await _addLeftover(kind, key, crate.id, current.revision, editedAt: w.record.editedAt);
            return true;
          }
        }
        // A newer version than the one this write was based on: take it as
        // if it had been pulled. Either this device's change wins and goes
        // again on the new base, or it goes to the history.
        final losers = <_Loser>[];
        try {
          await _applying(() => _receive(crate.id, opened, current.revision, losers, report));
        } on FormatException catch (e) {
          // What is there cannot be taken here (RecordRefused among it), as
          // what does not open: replace it.
          AppLogger.warning('Orchard sync: a version of an item was not taken (${e.message})');
          report.rejected++;
          await _rebase(kind, key, crate.id, current.revision, deleted: current.item?.deleted ?? false);
          return true;
        }
        await _keepLosers(losers, report);
        return true;
    }
  }

  /// Bases the next write of an item in its Crate on [revision], a deletion
  /// when [deleted].
  Future<void> _rebase(String kind, String key, String crateId, int? revision, {required bool deleted}) async {
    final meta = await _meta(kind, key);
    await _setMeta(kind, key,
        crateId: crateId, serverRevision: revision, serverDeleted: deleted, editedAt: meta?.editedAt);
  }

  Future<SealedItem?> _seal(_Crate crate, ItemRecord record, CrateSyncReport report) async {
    final crateKey = await _crateKey(crate.id, crate.keyGeneration);
    final idKey = await _idKey(crate.id);
    if (crateKey == null || idKey == null) {
      report.needsKeys = true;
      return null;
    }
    return sealItem(
      record,
      place: ItemPlace(
        orchardId: orchardId,
        crateId: crate.id,
        itemId: crateItemId(idKey, kind: record.kind, key: record.key),
        generation: crate.keyGeneration,
      ),
      crateKey: crateKey,
      signer: author.keys,
    );
  }

  Iterable<List<_Write>> _batches(List<_Write> writes) sync* {
    var batch = <_Write>[];
    var bytes = 0;
    for (final w in writes) {
      final size = w.sealed.record.length + w.sealed.signature.length;
      if (batch.isNotEmpty &&
          (batch.length >= maxBatchItems || bytes + size > maxBatchBytes)) {
        yield batch;
        batch = <_Write>[];
        bytes = 0;
      }
      batch.add(w);
      bytes += size;
    }
    if (batch.isNotEmpty) yield batch;
  }

  /// Keeps versions of this device's that lost in their items' history, so
  /// nothing is lost. Best effort: a failure is counted, not retried.
  Future<void> _keepLosers(List<_Loser> losers, CrateSyncReport report) async {
    if (losers.isEmpty) return;
    final crates = await _crates();
    for (final loser in losers) {
      final crate = crates[loser.crateId];
      if (crate == null || !crate.canWrite) continue;
      try {
        final sealed = await _seal(crate, _anchored(loser.record), report);
        if (sealed == null || sealed.record.length > maxRecordBytes) continue;
        await server.keepInHistory(crate.id, sealed);
      } catch (e) {
        report.historyFailed++;
        AppLogger.warning('Orchard sync: a replaced version could not be kept ($e)');
      }
    }
  }

  // ── Bookkeeping ───────────────────────────────────────────────────────

  Future<Map<String, _Crate>> _crates() async {
    final rows = await db
        .customSelect(
            'SELECT crate_id, switches, key_generation, last_revision FROM orchard_crates ORDER BY crate_id')
        .get();
    return {
      for (final r in rows)
        r.read<String>('crate_id'): _Crate(
          r.read<String>('crate_id'),
          _switchSet(r.read<String>('switches')),
          r.read<int>('key_generation'),
          r.read<int>('last_revision'),
        ),
    };
  }

  static Set<String> _switchSet(String json) {
    try {
      return {
        for (final s in jsonDecode(json) as List)
          if (s is String) s,
      };
    } catch (_) {
      return const {};
    }
  }

  /// The Crate new items go into: the one picked on this device, else the
  /// first this account can add to.
  Future<String?> _defaultCrateId(Map<String, _Crate> crates) async {
    final row = await db
        .customSelect('SELECT default_crate_id FROM orchard_info WHERE id = 1')
        .getSingleOrNull();
    final picked = row?.read<String?>('default_crate_id');
    if (picked != null && (crates[picked]?.allows(CrateSwitches.add) ?? false)) return picked;
    for (final crate in crates.values) {
      if (crate.allows(CrateSwitches.add)) return crate.id;
    }
    return null;
  }

  Future<_Meta?> _meta(String kind, String key) async {
    final row = await db.customSelect(
      'SELECT crate_id, server_revision, server_deleted, edited_at, extra, author FROM crate_items_meta '
      'WHERE kind = ? AND item_key = ?',
      variables: [Variable(kind), Variable(key)],
    ).getSingleOrNull();
    if (row == null) return null;
    return _Meta(
      row.read<String>('crate_id'),
      row.read<int?>('server_revision'),
      row.read<int?>('edited_at'),
      row.read<String?>('extra'),
      serverDeleted: row.read<bool>('server_deleted'),
      author: row.read<String?>('author'),
    );
  }

  /// Records where an item lives and what it is based on ([serverDeleted]:
  /// a deletion); [author], when given, is who wrote the version this device
  /// now holds.
  Future<void> _setMeta(
    String kind,
    String key, {
    required String crateId,
    required int? serverRevision,
    required bool serverDeleted,
    required int? editedAt,
    String? author,
  }) =>
      db.customStatement(
        'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, server_deleted, edited_at, author) '
        'VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(kind, item_key) DO UPDATE SET '
        'crate_id = excluded.crate_id, server_revision = excluded.server_revision, '
        'server_deleted = excluded.server_deleted, '
        'edited_at = excluded.edited_at, author = COALESCE(excluded.author, crate_items_meta.author)',
        [kind, key, crateId, serverRevision, serverRevision != null && serverDeleted ? 1 : 0, editedAt, author],
      );

  Future<_Pending?> _pending(String kind, String key) async {
    final row = await db.customSelect(
      'SELECT change_seq, edited_at FROM crate_outbox WHERE kind = ? AND item_key = ?',
      variables: [Variable(kind), Variable(key)],
    ).getSingleOrNull();
    if (row == null) return null;
    return _Pending(kind, key, row.read<int>('change_seq'), row.read<int>('edited_at'));
  }

  /// Clears a queued change, unless the item changed again since it was read.
  Future<void> _clearPending(_Pending pending) => db.customStatement(
        'DELETE FROM crate_outbox WHERE kind = ? AND item_key = ? AND change_seq = ?',
        [pending.kind, pending.key, pending.seq],
      );


  Future<void> _addLeftover(String kind, String key, String crateId, int revision,
          {required int editedAt}) =>
      db.customStatement(
        'INSERT OR REPLACE INTO crate_leftovers (kind, item_key, crate_id, revision, edited_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [kind, key, crateId, revision, editedAt],
      );

  Future<void> _dropLeftover(String kind, String key, String crateId) => db.customStatement(
        'DELETE FROM crate_leftovers WHERE kind = ? AND item_key = ? AND crate_id = ?',
        [kind, key, crateId],
      );

  Future<Uint8List?> _crateKey(String crateId, int generation) async {
    final row = await db.customSelect(
      "SELECT secret FROM space_keys WHERE scope = 'crate' AND scope_id = ? AND generation = ?",
      variables: [Variable(crateId), Variable(generation)],
    ).getSingleOrNull();
    return row?.read<Uint8List>('secret');
  }

  /// The key a Crate's item ids are derived under, from its first key.
  Future<Uint8List?> _idKey(String crateId) async {
    final known = _idKeys[crateId];
    if (known != null) return known;
    final first = await _crateKey(crateId, 1);
    if (first == null) return null;
    return _idKeys[crateId] =
        await crateItemIdKey(first, orchardId: orchardId, crateId: crateId);
  }
}

class _Crate {
  const _Crate(this.id, this.switches, this.keyGeneration, this.lastRevision);

  final String id;

  /// What this account may do in it, from the record.
  final Set<String> switches;
  final int keyGeneration;
  final int lastRevision;

  bool allows(String s) => switches.contains(s);

  /// Adds, edits or deletes anything at all.
  bool get canWrite => allows(CrateSwitches.add) || allows(CrateSwitches.edit) || allows(CrateSwitches.delete);
}

class _Meta {
  const _Meta(this.crateId, this.serverRevision, this.editedAt, this.extra, {this.serverDeleted = false, this.author});

  final String crateId;
  final int? serverRevision;
  final int? editedAt;

  /// Whether the copy [serverRevision] names is a deletion.
  final bool serverDeleted;

  /// See [CrateItemsMeta.extra].
  final String? extra;

  /// Who wrote the version this device holds; null while not known.
  final String? author;
}

class _Pending {
  const _Pending(this.kind, this.key, this.seq, this.editedAt);

  final String kind;
  final String key;
  final int seq;
  final int editedAt;
}

class _Write {
  const _Write(this.record, this.sealed, {required this.base, this.seq, this.leftover = false});

  final ItemRecord record;
  final SealedItem sealed;
  final int? base;

  /// The queued change this write sends; null for a leftover's deletion.
  final int? seq;
  final bool leftover;
}

class _Loser {
  const _Loser(this.crateId, this.record);

  final String crateId;
  final ItemRecord record;
}

/// The copies of an item this device passed over, each by its Crate and
/// revision: refused, or a deletion naming a Crate it had not followed the item
/// to; [heldOut] where it holds no copy at all for now.
class _Refused {
  _Refused(this.copies, {this.heldOut = false, Map<String, _Noted>? who, this.keep}) : who = who ?? {};

  final Map<String, int> copies;
  final bool heldOut;

  /// Who wrote the copies nobody can tell for the item, by Crate ([heldBack]).
  final Map<String, _Noted> who;

  /// The Crate whose copy someone chose, until it is read again ([_keepCopy]).
  String? keep;
}

/// Who wrote a copy held back, when, and the name it shows under, as a version
/// said; nulls where this device did not note it.
class _Noted {
  const _Noted(this.author, this.editedAt, this.name);

  factory _Noted.of(ItemRecord rec) => _Noted(rec.author, rec.editedAt, nameOf(rec.kind, rec.data));

  factory _Noted.fromJson(Map<String, dynamic> json) =>
      _Noted(json['by'] as String?, json['at'] as int?, json['name'] as String?);

  final String? author;
  final int? editedAt;
  final String? name;

  /// The name [data] shows under, cut short: this is a note, not the item.
  static String? nameOf(String kind, Map<String, Object?>? data) {
    final name = itemDisplayName(kind, data);
    if (name.isEmpty) return null;
    return name.length > 120 ? name.substring(0, 120) : name;
  }

  Map<String, Object?> toJson() => {'by': author, 'at': editedAt, 'name': name};
}

/// An item of which a device knows two live copies, neither by someone who could
/// have moved it out of the other's Crate ([CrateSyncEngine.heldBack]).
class HeldBackItem {
  const HeldBackItem({required this.kind, required this.key, required this.copies});

  final String kind;
  final String key;
  final List<HeldBackCopy> copies;

  /// Whether this account may do anything about it.
  bool get mayAct => copies.any((copy) => copy.mayKeep || copy.mayRemove);
}

/// One copy of a [HeldBackItem].
class HeldBackCopy {
  const HeldBackCopy({
    required this.crateId,
    required this.mayKeep,
    required this.mayRemove,
    this.author,
    this.editedAt,
    this.name,
    this.here = false,
  });

  final String crateId;

  /// Who wrote it, and when in milliseconds; null where this device did not note it.
  final String? author;
  final int? editedAt;

  /// The name it shows under; null for none.
  final String? name;

  /// Whether this device shows it (it held it for longer).
  final bool here;

  final bool mayKeep;
  final bool mayRemove;
}

class _MissingKey {
  const _MissingKey();
}

class _MissingRecord {
  const _MissingRecord();
}

/// How a version read from a Crate stands against this device's copy of
/// the Orchard's record ([checkVersionAnchor]).
enum VersionStanding {
  /// Its author was allowed to write it.
  allowed,

  /// Its author was not allowed to write it then.
  notAllowed,

  /// It names a record entry this device holds differently.
  otherRecord,

  /// It names a record entry this device does not have yet.
  recordBehind,
}

/// Checks a version read from [crateId] against [record]: the entry it
/// names must be the one this device holds under that number, and its
/// author must have been allowed to write it then (add or edit; delete for a
/// deletion). A version written before the record is judged by the record as
/// it stands. The sync engine, the trash and the version history all
/// judge versions this way.
Future<VersionStanding> checkVersionAnchor(LocalRecord record, ItemRecord rec, String crateId) async {
  final seq = rec.recordSeq;
  final OrchardRecord state;
  if (seq == null) {
    state = record.latest;
  } else {
    if (seq > record.seq) return VersionStanding.recordBehind;
    if (!_same(record.hashAt(seq)!, rec.recordHead!)) return VersionStanding.otherRecord;
    state = await record.stateAt(seq);
  }
  // What its author could do under that state of the record, counting what
  // they held until a set time: a version says which state it was
  // written under and nothing says when, so whether that time had come is
  // the server's to hold to (it refuses the write), not something a reader
  // can tell.
  final switches = state.switchesAt(rec.author, crateId, 0);
  return _mayWrite(switches, rec) ? VersionStanding.allowed : VersionStanding.notAllowed;
}

/// Whether [switches] let someone write [rec]. A team-pinned host key
/// is trust for everyone in the Crate: only someone who could edit it wrote
/// one that counts.
bool _mayWrite(Set<String> switches, ItemRecord rec) => rec.deleted
    ? switches.contains(CrateSwitches.delete)
    : rec.kind == kHostKeyKind
        ? switches.contains(CrateSwitches.edit)
        : switches.contains(CrateSwitches.add) || switches.contains(CrateSwitches.edit);

/// Whether [rec], allowed under the state of the record it names
/// ([checkVersionAnchor]), was written while its author still could write
/// it, as this device can tell (found in a client security
/// review). A version names the state it was written under, and
/// nothing says when it was written: someone removed, suspended, or whose
/// access was taken away or ended could go on writing, naming a state from
/// before, and a server could hand that to the team. A version by someone
/// who may write it at [nowSeconds] counts. One by someone who may not
/// counts only when it was edited before they lost that: their end date, or
/// the end of what they were given until a set time, or when this device
/// first saw the entry that took it from them. One backdated to before the
/// loss cannot be told from one written then; it still loses to every
/// version edited since (CrateSyncEngine._receive refuses older versions).
Future<bool> writtenWhileAllowed(LocalRecord record, ItemRecord rec, String crateId, int nowSeconds) async {
  if (_mayWrite(record.latest.switchesAt(rec.author, crateId, nowSeconds), rec)) return true;
  return rec.editedAt <= await _writeLostAt(record, rec, crateId) * 1000;
}

/// What [_writeLostAt] worked out, by record (each a new one per extend).
final _writeLostCache = Expando<Map<String, int>>();

/// When [rec]'s author lost what writing it in [crateId] needs, in seconds
/// since the epoch; 0 when this device cannot tell (an entry kept before
/// first_seen was noted).
Future<int> _writeLostAt(LocalRecord record, ItemRecord rec, String crateId) async {
  final from = rec.recordSeq ?? record.seq;
  final cache = _writeLostCache[record] ??= <String, int>{};
  final what = rec.deleted ? 'delete' : (rec.kind == kHostKeyKind ? 'pin' : 'write');
  final key = '${rec.author}|$crateId|$what|$from';
  final known = cache[key];
  if (known != null) return known;
  var lost = 0;
  if (_mayWrite(record.latest.switchesAt(rec.author, crateId, 0), rec)) {
    // Lost by the clock alone.
    lost = _writeEndsAt(record.latest, rec, crateId) ?? 0;
  } else {
    // Lost by an entry after the state the version names: the last that
    // took it, and the clock, when that ended it first.
    var state = from == 0 ? OrchardRecord(record.orchardId) : await record.stateAt(from);
    for (var i = from; i < record.seq; i++) {
      final next = state.copy();
      await next.append(record.entries[i], trusted: true);
      if (_mayWrite(state.switchesAt(rec.author, crateId, 0), rec) &&
          !_mayWrite(next.switchesAt(rec.author, crateId, 0), rec)) {
        final seen = record.firstSeen[i] ?? 0;
        final ended = _writeEndsAt(state, rec, crateId);
        lost = ended != null && ended < seen ? ended : seen;
      }
      state = next;
    }
  }
  cache[key] = lost;
  return lost;
}

/// When writing [rec] in [crateId] ends by the clock for its author under
/// [state], in seconds: their end date, and where only what they were given
/// until a set time lets them, that time if earlier. Null when nothing ends.
int? _writeEndsAt(OrchardRecord state, ItemRecord rec, String crateId) {
  final m = state.members[rec.author];
  if (m == null) return null;
  final ends = m.endsAt;
  if (_mayWrite(state.switchesOf(rec.author, crateId), rec)) return ends;
  final until = m.timed[crateId]?.until;
  if (until == null) return ends;
  return ends != null && ends < until ? ends : until;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
