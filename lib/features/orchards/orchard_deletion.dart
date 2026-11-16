part of 'orchard_service.dart';

// Deleting a team. An
// owner asks, with a sign-in from the last ten minutes and two-step where
// the team's rules want it, by signing a team.delete entry. ZestSSH Cloud
// then holds every member back, owners too, for seven days, and purges the
// team after them unless an owner undoes it first (team.restore). Meanwhile
// this device keeps what it holds of the team and syncs nothing of it; it
// reads the record (any member may, while the team is being deleted), so
// that it holds the signed deletion, and keeps to the device rules the
// server says are in force.
//
// Once the team is gone, the server no longer lists it and answers, for 90
// days, that it holds this device's last entry and that the team was
// deleted. This device removes the team without asking only when its own
// record ends in the signed deletion and it saw that entry at least seven
// days earlier by its own clock: a server that hid a later undo can make a
// device ask, never wipe it unasked. Otherwise it asks its person, and keeps
// the team, held back, until they answer.

/// The standing (orchard_info.status) of a team being deleted.
const String kDeletingStatus = 'deleting';

/// The standing of a team ZestSSH Cloud says was deleted, which this device
/// did not see being deleted long enough ago to remove it unasked: it stays,
/// held back, until its person answers ([OrchardDeletion.removeDeletedTeam]).
const String kDeletedStatus = 'deleted';

/// Days from the request to the purge, as the server counts them.
const int kTeamDeleteDays = 7;

/// A deleted team that left this device: its name as it was
/// here, and who deleted it, for the notice that says so.
class TeamGone {
  const TeamGone({required this.orchardId, this.name, this.byName, this.byMe = false});

  final String orchardId;

  /// Null where its key never opened on this device.
  final String? name;

  /// The owner who deleted it, as this device last knew them (their name,
  /// else their address); null when it does not know, or it was [byMe].
  final String? byName;

  /// This account deleted it.
  final bool byMe;
}

/// Whether this device may remove a deleted team unasked: its
/// own record [local] ends in the signed deletion (nothing undid it), and it
/// saw that entry at least [kTeamDeleteDays] days before [nowSeconds], by
/// its own clock.
bool deletionSeenLongEnough(LocalRecord local, {required int nowSeconds}) {
  final d = local.latest.deleting;
  if (d == null) return false;
  final seen = d.seq >= 1 && d.seq <= local.firstSeen.length ? local.firstSeen[d.seq - 1] : null;
  return seen != null && nowSeconds - seen >= kTeamDeleteDays * Duration.secondsPerDay;
}

/// What the team's own database says of its deletion: who asked and the day
/// it goes ([kDeletingStatus], as the server last listed it), and when the
/// server said it was deleted ([kDeletedStatus]).
({TeamDeletion? deleting, DateTime? deletedAt}) deletionHeldIn(Object? held) {
  if (held is! Map) return (deleting: null, deletedAt: null);
  final at = held['deleted_at'];
  return (
    deleting: TeamDeletion.fromJson(held['deleting']),
    deletedAt: at is String ? DateTime.tryParse(at)?.toUtc() : null,
  );
}

/// The team is being deleted since the list of teams was read ([e], a hold
/// met on the way): noted in its own database, until the next refresh says
/// more.
Future<void> _noteBeingDeleted(AppDatabase db, OrchardServerException e) async {
  final row = await db.customSelect('SELECT held FROM orchard_info WHERE id = 1').getSingleOrNull();
  final before = _decodedHeld(row?.read<String?>('held'));
  await db.customStatement('UPDATE orchard_info SET status = ?, held = ? WHERE id = 1', [
    kDeletingStatus,
    jsonEncode({
      ...before,
      if (e.deleting != null) 'deleting': e.deleting!.toJson(),
    }),
  ]);
}

Map<String, Object?> _decodedHeld(String? raw) {
  if (raw == null) return {};
  try {
    final m = jsonDecode(raw);
    return m is Map<String, dynamic> ? m : {};
  } catch (_) {
    return {};
  }
}

extension OrchardDeletion on OrchardService {
  /// Deletes [orchardId] (owners): the signed team.delete, next in
  /// the record as it stands on the server. Every member is held back from
  /// then on, this device too, and the team goes seven days on unless an
  /// owner undoes it. Returns what the server says of it. Throws
  /// [OrchardRecordRefused] when the record refuses it here (not an owner),
  /// and an [OrchardServerException] as [CrateServer.deleteTeam] does.
  Future<TeamDeletion> deleteTeam(String orchardId) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    return _serial(orchardId, () async {
      final deletion = await _namingDevice(() async {
        for (var attempt = 0;; attempt++) {
          final record = await pullRecord(db, orchardId, server);
          final entry = await signRecordEntry(me.keys,
              orchardId: orchardId,
              seq: record.seq + 1,
              prev: record.head,
              type: RecordTypes.teamDelete,
              body: const {},
              by: me.uid);
          await OrchardService._probeOn(record.latest, entry);
          final TeamDeletion asked;
          try {
            asked = await server.deleteTeam(orchardId, entry);
          } on OrchardServerException catch (e) {
            if (e.recordMoved && attempt < 2) continue;
            rethrow;
          }
          await record.extend(db, [entry]);
          return asked;
        }
      });
      _standing[orchardId] = kDeletingStatus;
      try {
        await _refreshOrchard(orchardId, me);
      } catch (e) {
        // The deletion stands; the next refresh says the rest.
        AppLogger.info('Orchards: a team just deleted was not read again (${errorKind(e)})');
        await _noteBeingDeleted(db, OrchardServerException(403, 'team-being-deleted', deleting: deletion));
      }
      // Where this device sends the team's events on, the deletion goes
      // now, while it can.
      await _flushEvents(orchardId);
      return deletion;
    });
  }

  /// Undoes deleting [orchardId] before its day (owners): the
  /// signed team.restore. Everyone is let back in, this device first.
  /// Throws as [CrateServer.restoreTeam] does ('undo-too-late' once the day
  /// came).
  Future<void> restoreTeam(String orchardId) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    await _serial(orchardId, () async {
      await _namingDevice(() async {
        for (var attempt = 0;; attempt++) {
          final record = await pullRecord(db, orchardId, server);
          final entry = await signRecordEntry(me.keys,
              orchardId: orchardId,
              seq: record.seq + 1,
              prev: record.head,
              type: RecordTypes.teamRestore,
              body: const {},
              by: me.uid);
          await OrchardService._probeOn(record.latest, entry);
          try {
            await server.restoreTeam(orchardId, entry);
          } on OrchardServerException catch (e) {
            if (e.recordMoved && attempt < 2) continue;
            rethrow;
          }
          await record.extend(db, [entry]);
          return;
        }
      });
      await _refreshOrchard(orchardId, me);
    });
  }

  /// Takes the deleted team [orchardId] off this device: what
  /// this device has left to send of its events goes first, then its
  /// database, its key, its owner entry and the cloud import accounts that
  /// brought hosts into it ([OrchardDatabasesNotifier.forget]); the notice
  /// says so ([OrchardService.onTeamDeleted]). At once where this device
  /// saw the deletion long enough ago ([deletionSeenLongEnough]), else when
  /// its person answers the question.
  Future<void> removeDeletedTeam(String orchardId) async {
    final db = await databases.open(orchardId);
    final gone = await _goneOf(db, orchardId);
    await _flushEvents(orchardId);
    _standing.remove(orchardId);
    _listed.remove(orchardId);
    _invitesWaiting.remove(orchardId);
    await databases.forget(orchardId);
    AppLogger.info('Orchards: a deleted team left this device');
    onTeamDeleted?.call(gone);
  }

  /// A team being deleted, as the list says it: what is here stays and
  /// nothing syncs; the deletion and the device rules in force are noted,
  /// and the record is read, so that this device holds the signed deletion.
  /// Never one to sync.
  Future<bool> _refreshDeleting(AppDatabase db, RemoteOrchard orchard) async {
    final device = orchard.heldDeviceRules;
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, role, key_generation, status, held) '
      'VALUES (1, ?, ?, 0, ?, ?) ON CONFLICT(id) DO UPDATE SET status = excluded.status, held = excluded.held',
      [
        orchard.id,
        orchard.role,
        kDeletingStatus,
        jsonEncode({
          if (orchard.deleting != null) 'deleting': orchard.deleting!.toJson(),
          if (device != null) 'device_rules': device.toBody(),
        }),
      ],
    );
    try {
      final record = await pullRecord(db, orchard.id, server);
      await db.customStatement(
          'UPDATE orchard_info SET rules = ? WHERE id = 1', [jsonEncode(record.latest.rules.toBody())]);
    } on RecordProblem catch (e) {
      AppLogger.warning('Orchards: stopped following the record of a team being deleted ($e)');
      await db.customStatement('UPDATE orchard_info SET record_problem = ? WHERE id = 1', [e.reason]);
    } catch (e) {
      AppLogger.warning('Orchards: could not read the record of a team being deleted (${errorKind(e)})');
    }
    return false;
  }

  /// [orchardId], which ZestSSH Cloud says was deleted at [deletedAt]:
  /// removed at once where this device may ([deletionSeenLongEnough]),
  /// otherwise held back, asking its person ([kDeletedStatus]).
  Future<void> _teamDeleted(String orchardId, DateTime deletedAt) async {
    final db = await databases.open(orchardId);
    final local = await LocalRecord.load(db, orchardId);
    if (deletionSeenLongEnough(local, nowSeconds: OrchardService._nowSeconds())) {
      await removeDeletedTeam(orchardId);
      return;
    }
    final row = await db.customSelect('SELECT held FROM orchard_info WHERE id = 1').getSingleOrNull();
    await db.customStatement('UPDATE orchard_info SET status = ?, held = ? WHERE id = 1', [
      kDeletedStatus,
      jsonEncode({..._decodedHeld(row?.read<String?>('held')), 'deleted_at': deletedAt.toUtc().toIso8601String()}),
    ]);
    _standing[orchardId] = kDeletedStatus;
    AppLogger.info('Orchards: ZestSSH Cloud says a team on this device was deleted; its person is asked');
  }

  /// The name [db]'s team had here and who deleted it, for the notice.
  Future<TeamGone> _goneOf(AppDatabase db, String orchardId) async {
    final info = await db.customSelect('SELECT name, held FROM orchard_info WHERE id = 1').getSingleOrNull();
    String? by;
    try {
      by = (await LocalRecord.load(db, orchardId)).latest.deleting?.by;
    } catch (_) {
      // A record this device stopped following: what the server listed.
    }
    by ??= deletionHeldIn(_decodedHeld(info?.read<String?>('held'))).deleting?.by;
    String? byName;
    var byMe = false;
    final me = await author();
    if (by != null && me != null) {
      byMe = by == me.uid;
      final who = (await MemberDirectory(db).view(me.uid)).where((m) => m.uid == by).firstOrNull;
      if (!byMe) byName = who?.name ?? who?.email;
    }
    return TeamGone(orchardId: orchardId, name: info?.read<String?>('name'), byName: byName, byMe: byMe);
  }
}
