part of 'orchard_service.dart';

// What a device reports of a session to a watched Crate's host that went on
// with nobody watching (3.0, the outage work; watch/unwatched.dart says
// when that may be). The report is sealed with the Crate's key and kept in
// the Orchard's own database before the session starts, each under a name
// of its own, and put into the Orchard's record once the server can be
// reached: as an entry of its own kind, signed by this account like every
// other entry. The server reads the Crate and the time; the host, the
// reason and how the service stood are for those who hold the Crate's key.
// A report is not sent before its session is known to run, and is taken
// back where it never does: what the record holds is a session that ran
// with nobody watching.

/// Where an Orchard's database keeps a report this device has not sent:
/// this, then an id of the report's own.
const String kUnwatchedState = 'unwatched.';

/// The reports kept in this run whose session is not known to run yet, by
/// the name each is kept under. Such a report is not sent before its
/// session runs ([OrchardUnwatched.unwatchedRan]), and is taken back where
/// it never does ([OrchardUnwatched.forgetUnwatchedReport]). Kept in memory
/// on purpose and nowhere else: an app that ended without saying what
/// became of a session finds its report when it starts again, and sends it.
final _unwatchedNotYet = <String>{};

/// As if the app had been started again: every report kept is one to send.
@visibleForTesting
void debugUnwatchedNewRun() => _unwatchedNotYet.clear();

/// A change of profile: every session has ended, and a team opens only for its own
/// account, as at a new start. Every report kept is one to send when it does.
void forgetUnwatchedNotYet() => _unwatchedNotYet.clear();

/// A report could not be kept on this device (no key of the Crate's here,
/// nothing to say as the reason): the session it is about must not start
/// with nobody watching.
class UnwatchedNotKept implements Exception, HasTypeName {
  const UnwatchedNotKept(this.why);

  final String why;

  @override
  String toString() => 'Orchards: the report of a session with nobody watching could not be kept ($why)';

  @override
  String get typeName => 'UnwatchedNotKept';
}

/// A session the record says went on with nobody watching, as this device
/// reads it.
class UnwatchedSession {
  const UnwatchedSession({required this.seq, required this.by, required this.crateId, required this.at, this.report});

  /// Where the report stands in the record.
  final int seq;

  /// Who connected: the entry's author.
  final String by;
  final String crateId;

  /// When the session went on with nobody watching, by their device's
  /// clock (seconds since the epoch).
  final int at;

  /// What only holders of the Crate's key read; null where this device
  /// does not hold the key it was sealed with, or it does not open.
  final UnwatchedReport? report;
}

extension OrchardUnwatched on OrchardService {
  /// Seals what this device reports of a session to [hostLabel], a host of
  /// the watched Crate [crateId], that is about to go on with nobody
  /// watching, and keeps it until the Orchard's record takes it
  /// ([unwatchedRound]). [reason] is what the person gave; [reach] how
  /// ZestSSH Cloud stood (the name of a CloudReach value). Throws
  /// [UnwatchedNotKept] when it cannot be kept: nothing starts then.
  ///
  /// Answers with the name the report is kept under. It is kept now, so
  /// that nothing reaches the host before it is, and is not sent until
  /// [unwatchedRan] says the session runs with nobody watching. Where it
  /// never does, [forgetUnwatchedReport] takes it back.
  Future<String> keepUnwatchedReport(
    String orchardId, {
    required String crateId,
    required String hostLabel,
    required String reason,
    required String reach,
  }) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final crate = (await LocalRecord.load(db, orchardId)).latest.crates[crateId];
    if (crate == null) throw const UnwatchedNotKept('no such Crate');
    final generation = crate.generation;
    final key = await OrchardService._secret(db, orchardId, crateId, generation);
    if (key == null) throw const UnwatchedNotKept("the Crate's key is not on this device");
    var said = unwatchedReason(reason);
    if (said == null) throw const UnwatchedNotKept('no reason');
    final at = OrchardService._nowSeconds();
    final host = unwatchedHost(hostLabel);
    Uint8List sealed;
    while (true) {
      sealed = await sealUnwatchedReport(
        UnwatchedReport(host: host, reason: said!, reach: reach).toJson(),
        key,
        orchardId: orchardId,
        crateId: crateId,
        uid: me.uid,
        at: at,
        generation: generation,
      );
      if (sealed.length <= kMaxUnwatchedSealed) break;
      // Longer than an entry takes (a reason in a script of four bytes to
      // the character): the end of the reason goes, the host stays whole.
      final shorter = said.runes.length * 3 ~/ 4;
      if (shorter < 1) throw const UnwatchedNotKept('too long to seal');
      said = String.fromCharCodes(said.runes.take(shorter));
    }
    final name = '$kUnwatchedState${const Uuid().v4()}';
    // Held back before it is written: no sync finds it in between.
    _unwatchedNotYet.add(name);
    await LocalStateStore(db)
        .write(name, jsonEncode({'crate': crateId, 'at': at, 'gen': generation, 'sealed': base64Encode(sealed)}));
    AppLogger.info('Orchards: a session goes on with nobody watching; its report is kept until it can be sent');
    return name;
  }

  /// The session the report kept under [name] is about runs with nobody
  /// watching: the report goes with the next sync that reaches the server.
  void unwatchedRan(String name) => _unwatchedNotYet.remove(name);

  /// The session the report kept under [name] in [orchardId] is about never
  /// ran with nobody watching (its connection was not made, or someone
  /// watched it from its start): nothing is reported. Leaves alone whatever
  /// else the Orchard's database keeps.
  Future<void> forgetUnwatchedReport(String orchardId, String name) async {
    if (!name.startsWith(kUnwatchedState)) return;
    await LocalStateStore(await databases.open(orchardId)).remove(name);
    _unwatchedNotYet.remove(name);
  }

  /// The reports that wait on this device, oldest first, each with where it
  /// is kept. What is kept there and is no report is left out.
  Future<List<({String key, Map<String, Object?> body})>> _unwatchedWaiting(LocalStateStore store) async {
    final out = <({String key, Map<String, Object?> body})>[];
    for (final key in await store.keysWithPrefix(kUnwatchedState)) {
      try {
        final body = jsonDecode(await store.read(key) ?? '');
        if (body is Map<String, Object?> && body['at'] is int && body['sealed'] is String) {
          out.add((key: key, body: body));
        }
      } on FormatException {
        // Not a report: nothing to send.
      }
    }
    out.sort((a, b) {
      final byTime = (a.body['at'] as int).compareTo(b.body['at'] as int);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return out;
  }

  /// How many reports this device keeps for [orchardId]'s record: those
  /// that wait to be sent, and those whose session is not known to run yet.
  Future<int> unwatchedWaiting(String orchardId) async =>
      (await _unwatchedWaiting(LocalStateStore(await databases.open(orchardId)))).length;

  /// Puts the reports that wait into [orchardId]'s record, oldest first,
  /// and returns how many it took. One the record already holds (its answer
  /// to an earlier try never arrived) is not sent again. One the record
  /// refuses is dropped: it would be refused for ever (its Crate is gone).
  /// What cannot be sent now, because the server cannot be reached or holds
  /// this account back, waits for the next sync and is thrown on. One whose
  /// session is not known to run yet is left where it is.
  Future<int> unwatchedRound(String orchardId) async {
    final db = await databases.open(orchardId);
    final store = LocalStateStore(db);
    final waiting = [
      for (final w in await _unwatchedWaiting(store))
        if (!_unwatchedNotYet.contains(w.key)) w,
    ];
    if (waiting.isEmpty) return 0;
    final me = await _me();
    var sent = 0;
    for (final w in waiting) {
      final there = (await pullRecord(db, orchardId, server)).entries.any((e) =>
          e.type == RecordTypes.sessionUnwatched && e.by == me.uid && e.body['sealed'] == w.body['sealed']);
      if (!there) {
        try {
          await _changeWith(orchardId, (_) async => [(type: RecordTypes.sessionUnwatched, body: w.body)],
              refresh: false);
          sent++;
        } on OrchardRecordRefused catch (e) {
          AppLogger.warning('Orchards: the record refuses a report of a session with nobody watching, which is '
              'dropped (${e.reason})');
        } on OrchardServerException catch (e) {
          if (e.code != 'record-refused') rethrow;
          AppLogger.warning('Orchards: the server refuses a report of a session with nobody watching, which is '
              'dropped (${e.reason})');
        }
      }
      await store.remove(w.key);
    }
    return sent;
  }

  /// The report in the record entry [e] of [orchardId] (one of
  /// [RecordTypes.sessionUnwatched]), as this device reads it: who, which
  /// Crate and when from the entry, and the sealed part where this device
  /// holds the Crate's key it was sealed with. Null for an entry that is no
  /// such report.
  Future<UnwatchedSession?> unwatchedSessionOf(String orchardId, RecordEntry e) async {
    if (e.type != RecordTypes.sessionUnwatched) return null;
    final Map<String, Object?> body;
    try {
      body = e.body;
    } catch (_) {
      return null;
    }
    final crateId = body['crate'], at = body['at'], generation = body['gen'], sealed = body['sealed'];
    if (crateId is! String || at is! int || generation is! int || sealed is! String) return null;
    UnwatchedReport? report;
    try {
      final db = await databases.open(orchardId);
      final key = await OrchardService._secret(db, orchardId, crateId, generation);
      if (key != null) {
        report = UnwatchedReport.fromJson(await openUnwatchedReport(base64Decode(sealed), key,
            orchardId: orchardId, crateId: crateId, uid: e.by, at: at, generation: generation));
      }
    } catch (err) {
      AppLogger.info('Orchards: a report of a session with nobody watching does not open here ($err)');
    }
    return UnwatchedSession(seq: e.seq, by: e.by, crateId: crateId, at: at, report: report);
  }
}
