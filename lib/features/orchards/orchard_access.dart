part of 'orchard_service.dart';

// Access on request (3.0): a member asks for a Crate, or for more in
// one they open, for a set time; someone who manages that Crate gives it with
// an entry in the Orchard's record that names the time it ends (access.grant),
// or declines. Nothing has to be taken back: every device, and the server,
// stop counting what was given the second its time comes. A member cannot
// read the name of a Crate they do not open, so a request for one says which
// in a note (encrypted with the Orchard's key), and whoever answers picks it.

/// The shortest and the longest time access is given for. The server holds
/// to the longest as well; the record has no clock.
const Duration kMinAccessDuration = Duration(minutes: 5);
const Duration kMaxAccessDuration = Duration(days: 30);

/// A request for access as this device shows it.
class AccessRequestView {
  const AccessRequestView({
    required this.id,
    required this.crateId,
    required this.level,
    required this.duration,
    required this.expiresAt,
    this.uid,
    this.note,
    this.noteUnread = false,
  });

  final String id;

  /// Who asks; null for this account's own request.
  final String? uid;

  /// The Crate asked for, or null when they could not name it.
  final String? crateId;

  final CrateLevel level;

  /// For how long, from the moment it is given.
  final Duration duration;

  /// What they say they need, when they said anything and it opened here.
  final String? note;

  /// A note came with it that this device could not open.
  final bool noteUnread;

  /// When the request lapses unanswered, in seconds since the epoch.
  final int expiresAt;
}

/// The requests for access in an Orchard that concern this account: its own,
/// and those of others it could answer.
typedef AccessRequestViews = ({List<AccessRequestView> mine, List<AccessRequestView> waiting});

/// A Crate, or more in one, that a member holds until a set time: as the
/// record has it, while it runs and adds to what they have for good.
class TimedAccess {
  const TimedAccess({
    required this.uid,
    required this.crateId,
    required this.adds,
    required this.level,
    required this.until,
    required this.wholeCrate,
    required this.canEnd,
  });

  final String uid;
  final String crateId;

  /// What it adds to what the member has for good in the Crate.
  final Set<String> adds;

  /// How far they may go in the Crate while it runs, with what they have
  /// for good.
  final CrateLevel level;

  /// When it ends, in seconds since the epoch.
  final int until;

  /// Nothing else gives them the Crate: when this ends they no longer open
  /// it at all.
  final bool wholeCrate;

  /// This account may end it now: it manages the Crate, or it is its own.
  final bool canEnd;
}

/// Something about access on request this device tells its person once.
enum AccessNoticeKind {
  /// Someone asks for access this account could give.
  asked,

  /// This account's request was declined.
  declined,

  /// This account's request lapsed without an answer.
  lapsed,

  /// What this account was given until a set time has ended by itself.
  over,
}

class AccessNotice {
  const AccessNotice(this.kind, {this.uid, this.crateId, this.crateName, this.count = 1});

  final AccessNoticeKind kind;

  /// For [AccessNoticeKind.asked]: who asks, when it is one person.
  final String? uid;

  /// The Crate it is about, when it names one.
  final String? crateId;

  /// For [AccessNoticeKind.over]: the Crate's name as this device had it
  /// while it was here, when it had one.
  final String? crateName;

  /// For [AccessNoticeKind.asked]: how many new requests.
  final int count;
}

/// Where an Orchard's own database (on this device only) keeps what it
/// already told its person about access: the requests this account made
/// that still waited at the last look, those of others it has seen, and the
/// ends it has spoken of.
const _accessAskedKey = 'access.asked';
const _accessSeenKey = 'access.seen';
const _accessOverKey = 'access.over';

/// The names of the Crates this account opens only until a set time, kept
/// while that runs so that the end can still name one after it left the
/// device, and forgotten then.
const _accessNamesKey = 'access.names';

/// An end this old is no longer worth a notice.
const _accessOverNoticeSeconds = 24 * 60 * 60;

extension OrchardAccess on OrchardService {
  /// Asks for [crateId] at [level] for [duration]; with no [crateId], for a
  /// Crate this account cannot name, which [note] describes. Throws
  /// [ArgumentError] for a time out of range or a missing note, and an
  /// [OrchardServerException] ('request-limit', 'access-not-needed').
  Future<void> requestAccess(
    String orchardId, {
    String? crateId,
    required CrateLevel level,
    required Duration duration,
    String? note,
  }) async {
    if (level == CrateLevel.manage) throw ArgumentError('Manage is never given until a set time');
    if (duration < kMinAccessDuration || duration > kMaxAccessDuration) {
      throw ArgumentError('Access is asked for five minutes to thirty days');
    }
    final words = note?.trim() ?? '';
    if (crateId == null && words.isEmpty) throw ArgumentError('Say which Crate');
    final me = await _me();
    final db = await databases.open(orchardId);
    Uint8List? noteEnc;
    int? generation;
    if (words.isNotEmpty) {
      generation = (await LocalRecord.load(db, orchardId)).latest.generationOf(kOrchardScope);
      final key = await OrchardService._secret(db, orchardId, null, generation);
      if (key == null) throw const OrchardInviteError(OrchardInviteProblem.missingKeys);
      noteEnc = await encryptAccessNote(words, key, orchardId: orchardId, uid: me.uid, generation: generation);
    }
    final made = await server.requestAccess(orchardId,
        crateId: crateId, level: level, seconds: duration.inSeconds, noteEnc: noteEnc, noteGeneration: generation);
    final store = LocalStateStore(db);
    final asked = await _accessMap(store, _accessAskedKey);
    asked[made.id] = made.expiresAt;
    await store.write(_accessAskedKey, jsonEncode(asked));
  }

  /// This account's requests in [orchardId] and those of others it can
  /// answer, with their notes opened. A request the server lists that the
  /// record does not let this account answer (it does not manage the Crate
  /// for good, or does not rank above whoever asks) is left out: the server
  /// is not taken at its word for who may give what.
  Future<AccessRequestViews> accessRequests(String orchardId) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final record = (await LocalRecord.load(db, orchardId)).latest;
    final listed = await server.accessRequests(orchardId);
    Future<AccessRequestView> view(AccessRequest r, String asker) async {
      String? note;
      var unread = false;
      final enc = r.noteEnc;
      final generation = r.noteGeneration;
      if (enc != null && generation != null) {
        try {
          final key = await OrchardService._secret(db, orchardId, null, generation);
          note = key == null
              ? null
              : await decryptAccessNote(enc, key, orchardId: orchardId, uid: asker, generation: generation);
        } catch (_) {
          // Not this member's note, or not a note at all.
        }
        unread = note == null;
      }
      return AccessRequestView(
        id: r.id,
        uid: asker == me.uid ? null : asker,
        crateId: r.crateId,
        level: r.level,
        duration: Duration(seconds: r.seconds),
        expiresAt: r.expiresAt,
        note: note,
        noteUnread: unread,
      );
    }

    return (
      mine: [for (final r in listed.mine) await view(r, me.uid)],
      waiting: [
        for (final r in listed.waiting)
          if (r.uid != null && r.uid != me.uid && _mayAnswer(record, me.uid, r.uid!, r.crateId)) await view(r, r.uid!),
      ],
    );
  }

  /// Whether the record lets [me] give [asker] the Crate [crateId] (any
  /// Crate, when null) until a set time.
  static bool _mayAnswer(OrchardRecord record, String me, String asker, String? crateId) {
    final target = record.members[asker];
    if (target == null || target.status != MemberStatus.active) return false;
    if (target.role == FixedRoles.owner || target.role == FixedRoles.admin) return false;
    if (record.rankOf(me) <= record.rankOfRole(target.role)) return false;
    return accessCratesFor(record, me, crateId: crateId).isNotEmpty;
  }

  /// The Crates [me] could give someone until a set time: those it manages
  /// for good that are not owners-only ([crateId] alone, when given).
  static List<String> accessCratesFor(OrchardRecord record, String me, {String? crateId}) => [
        for (final c in record.crates.values)
          if ((crateId == null || c.id == crateId) &&
              !c.ownersOnly &&
              record.switchesOf(me, c.id).contains(CrateSwitches.manage))
            c.id,
      ];

  /// Withdraws this account's own request.
  Future<void> withdrawAccessRequest(String orchardId, String requestId) async {
    await server.deleteAccessRequest(orchardId, requestId);
    final store = LocalStateStore(await databases.open(orchardId));
    final asked = await _accessMap(store, _accessAskedKey);
    if (asked.remove(requestId) != null) await store.write(_accessAskedKey, jsonEncode(asked));
  }

  /// Declines someone's request. Nothing is kept of it.
  Future<void> declineAccessRequest(String orchardId, String requestId) =>
      server.deleteAccessRequest(orchardId, requestId);

  /// Gives [uid] the Crate [crateId] at [level] for [duration] from now: an
  /// access.grant entry, with the Crate's key sealed to them when they do
  /// not hold it yet. [requestId] is the request it answers, which goes with
  /// it. What it hands out is what [level] stands for and this account has
  /// there itself. Throws as [change] does, and an [OrchardServerException]
  /// ('access-until-passed' when this device's clock is far behind,
  /// 'access-too-long').
  Future<void> giveAccess(
    String orchardId, {
    required String uid,
    required String crateId,
    required CrateLevel level,
    required Duration duration,
    String? requestId,
  }) {
    if (level == CrateLevel.manage) throw ArgumentError('Manage is never given until a set time');
    if (duration < kMinAccessDuration || duration > kMaxAccessDuration) {
      throw ArgumentError('Access is given for five minutes to thirty days');
    }
    final until = OrchardService._nowSeconds() + duration.inSeconds;
    return _changeWith(orchardId, (latest) async {
      final mine = latest.switchesOf((await _me()).uid, crateId);
      return [
        (
          type: RecordTypes.accessGrant,
          body: {
            'uid': uid,
            'crate': crateId,
            'switches': switchList(levelSwitches(level).where(mine.contains)),
            'until': until,
            'req': ?requestId,
          },
        ),
      ];
    });
  }

  /// Ends what [uid] was given in [crateId] until a set time, now: by
  /// whoever manages the Crate, or by the member themselves.
  Future<void> endAccess(String orchardId, {required String uid, required String crateId}) =>
      change(orchardId, RecordTypes.accessGrant, {'uid': uid, 'crate': crateId, 'until': 0});

  /// What members of [orchardId] hold until a set time, as this device's
  /// copy of the record has it now: only what still runs and adds to what
  /// they have for good, soonest to end first.
  Future<List<TimedAccess>> timedAccess(String orchardId) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final record = (await LocalRecord.load(db, orchardId)).latest;
    final now = OrchardService._nowSeconds();
    final out = <TimedAccess>[];
    for (final m in record.members.values) {
      for (final t in m.timed.entries) {
        final forGood = record.switchesOf(m.uid, t.key);
        final all = record.switchesAt(m.uid, t.key, now);
        final adds = all.difference(forGood);
        if (adds.isEmpty) continue;
        out.add(TimedAccess(
          uid: m.uid,
          crateId: t.key,
          adds: adds,
          level: levelOf(all) ?? CrateLevel.connect,
          until: t.value.until,
          wholeCrate: forGood.isEmpty,
          canEnd: m.uid == me.uid || record.switchesOf(me.uid, t.key).contains(CrateSwitches.manage),
        ));
      }
    }
    out.sort((a, b) {
      final byEnd = a.until.compareTo(b.until);
      if (byEnd != 0) return byEnd;
      final byUid = a.uid.compareTo(b.uid);
      return byUid != 0 ? byUid : a.crateId.compareTo(b.crateId);
    });
    return out;
  }

  /// When what this account may do next becomes less by itself, in any
  /// Orchard on this device (what it was given until a set time, or its own
  /// time in an Orchard), in seconds since the epoch; null when nothing
  /// does. The Orchards are brought up to date then.
  Future<int?> nextAccessEnd() async {
    final me = await author();
    if (me == null) return null;
    final now = OrchardService._nowSeconds();
    int? next;
    for (final orchardId in await databases.onDevice()) {
      try {
        final db = await databases.open(orchardId);
        final record = (await LocalRecord.load(db, orchardId)).latest;
        for (final crateId in record.crates.keys) {
          final ends = record.accessEndsAt(me.uid, crateId, now);
          if (ends != null && (next == null || ends < next)) next = ends;
        }
      } catch (e) {
        AppLogger.info('Orchards: an Orchard could not be read for when access ends ($e)');
      }
    }
    return next;
  }

  /// What this device has not told its person yet about access in
  /// [orchardId], counted as told from now on: requests of others it could
  /// answer that are new, its own requests that were declined or lapsed,
  /// and what it was given that has ended by itself. [requests] is the
  /// list as just read ([accessRequests]); without one, only what ended.
  Future<List<AccessNotice>> takeAccessNotices(String orchardId, {AccessRequestViews? requests}) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final store = LocalStateStore(db);
    final local = await LocalRecord.load(db, orchardId);
    final now = OrchardService._nowSeconds();
    final out = <AccessNotice>[];

    // What ended by itself: each end once, and only while it is news.
    final told = await _accessMap(store, _accessOverKey);
    final timed = local.latest.members[me.uid]?.timed ?? const <String, RecordTimedGrant>{};
    final names = await _accessNames(store);
    final namesWere = jsonEncode(names);
    // The Crates this account opens only until a time still to come: their
    // names are kept for the moment they leave, to say which one it was.
    // (Every name here is taken up first; the ones that are not needed go
    // again below, before anything is kept.)
    bool leavesLater(String crateId) =>
        (timed[crateId]?.until ?? 0) > now && local.latest.switchesOf(me.uid, crateId).isEmpty;
    for (final row in await db.customSelect('SELECT crate_id, name FROM orchard_crates').get()) {
      final name = row.read<String?>('name');
      if (name != null) names[row.read<String>('crate_id')] = name;
    }
    final ended = {
      for (final t in timed.entries)
        if (t.value.until <= now) t.key: t.value.until,
    };
    var changed = false;
    for (final e in ended.entries) {
      if (told[e.key] == e.value) continue;
      told[e.key] = e.value;
      changed = true;
      // (A Crate they open for good stays: more in it ended, and nothing left.)
      if (now - e.value < _accessOverNoticeSeconds && local.latest.switchesOf(me.uid, e.key).isEmpty) {
        out.add(AccessNotice(AccessNoticeKind.over, crateId: e.key, crateName: names[e.key]));
      }
    }
    // (A grant that was replaced or ended early is no longer one to remember.)
    final before = told.length;
    told.removeWhere((crateId, until) => timed[crateId]?.until != until);
    if (changed || told.length != before) await store.write(_accessOverKey, jsonEncode(told));
    // Once its time has come (and was told above), or it was ended early,
    // nothing of the Crate stays here: not its name either.
    names.removeWhere((crateId, _) => !leavesLater(crateId));
    if (jsonEncode(names) != namesWere) await store.write(_accessNamesKey, jsonEncode(names));

    if (requests == null) return out;

    // This account's own requests that no longer wait: answered with access
    // (the record says so, and its own notice tells of it), declined, or
    // lapsed.
    final asked = await _accessMap(store, _accessAskedKey);
    final waiting = {for (final r in requests.mine) r.id: r.expiresAt};
    Set<String> answeredIn(LocalRecord record) => {
          for (final e in record.entries)
            if (e.type == RecordTypes.accessGrant) ?_requestOf(e),
        };
    var record = local;
    var answered = answeredIn(record);
    final gone = [
      for (final id in asked.keys)
        if (!waiting.containsKey(id)) id,
    ];
    var recordRead = true;
    if (gone.any((id) => !answered.contains(id))) {
      // Word that a request moved reaches a device before its next sync
      // does, so the entry that answered one may not be here yet: the record
      // is read up to now before a request is called declined. ([requests]
      // was read before this, and an answer takes the request away in the
      // same step that records it, so the entry is in the record by now.)
      try {
        record = await pullRecord(db, orchardId, server);
        answered = answeredIn(record);
      } catch (e) {
        // Not now: such a request is decided at the next look.
        AppLogger.info('Orchards: the record could not be read to see how a request ended ($e)');
        recordRead = false;
      }
    }
    // An owner or admin is never given a Crate until a set time: what they
    // asked for before they became one is not waited for any more, and was
    // not declined either (an admin opens what the Admin role opens).
    final role = record.latest.members[me.uid]?.role;
    final opensAll = role == FixedRoles.owner || role == FixedRoles.admin;
    for (final id in gone) {
      if (!answered.contains(id)) {
        if (!recordRead) continue;
        if (!opensAll) {
          out.add(AccessNotice(asked[id]! <= now ? AccessNoticeKind.lapsed : AccessNoticeKind.declined));
        }
      }
      asked.remove(id);
    }
    // (One made on another device of this account is followed from here on.)
    asked.addAll(waiting);
    await store.write(_accessAskedKey, jsonEncode(asked));

    // Requests of others that are new here.
    final seen = await _accessMap(store, _accessSeenKey);
    final fresh = [
      for (final r in requests.waiting)
        if (!seen.containsKey(r.id)) r,
    ];
    if (fresh.isNotEmpty) {
      final askers = {for (final r in fresh) r.uid};
      out.add(AccessNotice(AccessNoticeKind.asked,
          uid: askers.length == 1 ? askers.single : null, count: fresh.length));
    }
    await store.write(_accessSeenKey, jsonEncode({for (final r in requests.waiting) r.id: r.expiresAt}));
    return out;
  }

  /// What this account held until a set time that has come, by this
  /// device's clock, ends on this device now, in every Orchard that is open
  /// on it, with no word from the server (which may not be reachable): a
  /// Crate held only until then leaves the device with its items and its
  /// keys, as it does when the Orchard is brought up to date, and in one
  /// this account opens for good what was added for the time falls away.
  /// Where this account's own time in an Orchard has come, the Orchard says
  /// so and what is on the device stays, as when the server says it.
  /// Returns the Orchards in which something ended. Never throws; an
  /// Orchard whose database is closed is not opened for it.
  Future<Set<String>> endAccessByClock() async {
    final ended = <String>{};
    final CrateAuthor? me;
    try {
      me = await author();
    } catch (e) {
      AppLogger.info('Orchards: who this is could not be read to see what has ended ($e)');
      return ended;
    }
    if (me == null) return ended;
    final mine = me;
    for (final orchardId in await databases.onDevice()) {
      try {
        if (await _serial(orchardId, () => _endAccessByClockIn(orchardId, mine))) ended.add(orchardId);
      } catch (e) {
        AppLogger.info('Orchards: what has ended by itself could not be taken off this device ($e)');
      }
    }
    return ended;
  }

  Future<bool> _endAccessByClockIn(String orchardId, CrateAuthor me) async {
    final db = databases.opened(orchardId);
    if (db == null) return false;
    // Only where this account's membership counts, as far as this device
    // knows: suspended, ended or held back, what is here stays as it is,
    // as when the server says so.
    final standing = (await db.customSelect('SELECT status FROM orchard_info WHERE id = 1').getSingleOrNull())
        ?.read<String>('status');
    if (standing != 'active') return false;
    // (As last read: asking again costs nothing until the record grows.)
    final record = await latestRecordIn(db);
    final mine = record?.members[me.uid];
    if (record == null || mine == null) return false;
    final now = OrchardService._nowSeconds();
    final own = mine.endsAt;
    if (own != null && own <= now) {
      // Their own time in the Orchard: it says so; what is here stays.
      await db.customStatement("UPDATE orchard_info SET status = 'ended' WHERE id = 1");
      return true;
    }
    final over = [
      for (final t in mine.timed.entries)
        if (t.value.until <= now) t.key,
    ];
    if (over.isEmpty) return false;
    var any = false;
    await db.transaction(() async {
      for (final crateId in over) {
        final row = await db
            .customSelect('SELECT switches FROM orchard_crates WHERE crate_id = ?', variables: [Variable(crateId)])
            .getSingleOrNull();
        if (row == null) continue;
        final left = record.switchesAt(me.uid, crateId, now);
        if (left.isEmpty) {
          await _dropCrate(db, crateId);
          any = true;
        } else {
          final switches = jsonEncode(switchList(left));
          if (switches == row.read<String>('switches')) continue;
          await db.customStatement('UPDATE orchard_crates SET level = ?, switches = ? WHERE crate_id = ?',
              [(levelOf(left) ?? CrateLevel.connect).name, switches, crateId]);
          any = true;
        }
      }
      if (!any) return;
      // New items go into a Crate this account may still add to.
      final addable = [
        for (final r in await db.customSelect('SELECT crate_id, switches FROM orchard_crates').get())
          if (OrchardService._switches(r.read<String>('switches')).contains(CrateSwitches.add))
            r.read<String>('crate_id'),
      ]..sort();
      final home = (await db.customSelect('SELECT default_crate_id FROM orchard_info WHERE id = 1').getSingleOrNull())
          ?.read<String?>('default_crate_id');
      if (home == null || !addable.contains(home)) {
        await db.customStatement(
            'UPDATE orchard_info SET default_crate_id = ? WHERE id = 1', [addable.isEmpty ? null : addable.first]);
      }
      // What is still held only until a time to come.
      await OrchardService._keepAccessUntil(db, {
        for (final t in mine.timed.entries)
          if (t.value.until > now && record.switchesOf(me.uid, t.key).isEmpty) t.key: t.value.until,
      });
    });
    if (any) db.notifyOrchardItemsChanged();
    return any;
  }

  /// How long until [nextAccessEnd], by this device's clock; null when
  /// nothing ends by itself.
  Future<Duration?> timeToNextAccessEnd() async {
    final next = await nextAccessEnd();
    // As far as a Duration can say: an end further off would come round as a
    // moment long past, and the device would bring itself up to date each second.
    return next == null
        ? null
        : Duration(seconds: (next - OrchardService._nowSeconds()).clamp(-kMaxDateSeconds, kMaxDateSeconds));
  }

  static Future<Map<String, String>> _accessNames(LocalStateStore store) async {
    final raw = await store.read(_accessNamesKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } on FormatException {
      return {};
    }
  }

  static String? _requestOf(RecordEntry e) {
    try {
      final req = e.body['req'];
      return req is String ? req : null;
    } catch (_) {
      return null;
    }
  }

  /// A map of ids to numbers kept under [key]; empty when none is kept or
  /// it cannot be read.
  static Future<Map<String, int>> _accessMap(LocalStateStore store, String key) async {
    final raw = await store.read(key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is int) e.key as String: e.value as int,
      };
    } on FormatException {
      return {};
    }
  }
}
