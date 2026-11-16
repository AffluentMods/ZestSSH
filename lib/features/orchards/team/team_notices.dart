import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/orchards/hostkeys/host_key_notices.dart';
import 'package:zestssh/features/orchards/orchard_service.dart'
    show AccessNotice, AccessNoticeKind, DeviceNotice, DeviceNoticeKind, goneCrateNames, kSessionLogsFullState;
import 'package:zestssh/features/orchards/sync/crate_server.dart' show MyInvite;
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_words.dart' show levelWords;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Changes to an Orchard's record that every member is told of (3.0):
/// team recovery turned on or off, and each time two owners give a
/// member their access back; and what the team records about its members,
/// whenever an owner changes it. And two the member they are about is
/// told of, and nobody else: a Crate given to them until a set time, and
/// that ended early by someone else.
enum TeamNoticeKind {
  recoveryOn,
  recoveryOff,
  memberRecovered,
  trackingMore,
  trackingLess,
  trackingNow,

  /// A Crate's session logs turned on or off: told to those who can
  /// open it.
  sessionLogsOn,
  sessionLogsOff,

  /// A Crate, or more in one, given to this account until a set time,
  /// and that ended early by someone else.
  accessGiven,
  accessEnded,

  /// The team's events are sent on to a system of its own from now on, or
  /// no longer (event export): every member is told.
  exportOn,
  exportOff,

  /// A Crate's sessions are watched from now on, or no longer (session
  /// moderation): told to those who can open it.
  watchedOn,
  watchedOff,

  /// Who connects to a watched Crate's hosts with nobody watching while
  /// ZestSSH Cloud cannot be reached (3.0, the outage work): everyone who
  /// may connect there, or owners only again. Told to those who can open
  /// it.
  unwatchedAwayOn,
  unwatchedAwayOff,

  /// A session ran so, as the member who connected reports: told to those
  /// who manage the Crate, as every owner does.
  sessionUnwatched,

  /// This account's access to a vault set apart from its role by someone
  /// else: a level, the vault taken away, or put back to the
  /// role. Told to the member alone.
  vaultSet,
  vaultTaken,
  vaultBack,

  /// The team is being deleted: every member is told when the
  /// owner's signed entry arrives, and again each day until it goes (the
  /// one who asked too), counting down; and told when an owner undid it.
  teamDeleting,
  teamDeletingSoon,
  teamKept,
}

class TeamNotice {
  const TeamNotice(this.kind,
      {required this.seq,
      required this.by,
      this.member,
      this.approver,
      this.tracking,
      this.crateId,
      this.until,
      this.switches});

  final TeamNoticeKind kind;

  /// The record entry it comes from.
  final int seq;

  /// Who made the change: for a recovery, the owner who completed it.
  final String by;

  /// For a recovery: the member, and the other owner, who approved.
  final String? member;
  final String? approver;

  /// For what the team records: what is on now.
  final RecordTracking? tracking;

  /// For session logs, and for access given until a set time: the Crate.
  final String? crateId;

  /// For access given until a set time: when it ends, in seconds since the
  /// epoch.
  final int? until;

  /// For a level set for this account in a vault: what it is held to there.
  final Set<String>? switches;

  /// Told to [member] alone, whether or not they can open the Crate.
  bool get forMemberOnly =>
      kind == TeamNoticeKind.accessGiven ||
      kind == TeamNoticeKind.accessEnded ||
      kind == TeamNoticeKind.vaultSet ||
      kind == TeamNoticeKind.vaultTaken ||
      kind == TeamNoticeKind.vaultBack;

  /// Told to those who manage the Crate (every owner does), and to nobody
  /// else who can open it.
  bool get forThoseWhoAnswer => kind == TeamNoticeKind.sessionUnwatched;

  /// Told to everyone, the one who made the change too: the countdown to a
  /// team's deletion.
  bool get forEveryone => kind == TeamNoticeKind.teamDeletingSoon;
}

/// Where the Orchard's own database (on this device only) keeps the last
/// entry its person was told about.
const _toldKey = 'orchards.told_seq';

/// Where it keeps the day the countdown to the team's deletion was last
/// told, as yyyymmdd on this device's clock.
const _deletingToldKey = 'orchards.deleting_told_day';

/// Where the Orchard's own database keeps when its session logs being full was
/// last told, in seconds since the epoch.
const _logsFullToldKey = 'orchards.session_logs_full_told';

/// Logs run out after 30 days: a team that is full again after that hears again.
const _logsFullToldFor = Duration(days: 30);

/// Whether [me] is to be told now that the session logs of the Orchard (its
/// database [db]) are full: an owner, once. A sync of a member
/// who is no owner lets the note go, as there is nothing for them to do.
Future<bool> takeSessionLogsFull(AppDatabase db, String orchardId, {required String? me, DateTime? now}) async {
  final store = LocalStateStore(db);
  if (await store.read(kSessionLogsFullState) == null) return false;
  await store.remove(kSessionLogsFullState);
  if (me == null || (await LocalRecord.load(db, orchardId)).latest.members[me]?.role != FixedRoles.owner) return false;
  final at = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final told = int.tryParse(await store.read(_logsFullToldKey) ?? '');
  if (told != null && at - told < _logsFullToldFor.inSeconds) return false;
  await store.write(_logsFullToldKey, '$at');
  return true;
}

/// The changes in [orchardId]'s record (its database [db]) this device has
/// not told its person about yet, oldest first, counted as told from now
/// on. The first time on a device nothing is new (what came before is on
/// the Trust page), except what the team records: when it records
/// anything, that is said once, whatever an invitation said, and likewise
/// that its events are sent on.
///
/// While the team is being deleted, the countdown is told once a
/// day on top ([TeamNoticeKind.teamDeletingSoon]), but on the day the
/// deletion itself was told; [now] is this device's clock.
Future<List<TeamNotice>> takeTeamNotices(AppDatabase db, String orchardId, {DateTime? now}) async {
  final store = LocalStateStore(db);
  final record = await LocalRecord.load(db, orchardId);
  final told = await store.readInt(_toldKey);
  final notices = told == record.seq ? const <TeamNotice>[] : await _noticesSince(store, record, told);
  final deleting = record.latest.deleting;
  if (deleting == null) return notices;
  final at = now ?? DateTime.now();
  final today = '${at.year * 10000 + at.month * 100 + at.day}';
  if (await store.read(_deletingToldKey) == today) return notices;
  await store.write(_deletingToldKey, today);
  if (notices.any((n) => n.kind == TeamNoticeKind.teamDeleting)) return notices;
  return [...notices, TeamNotice(TeamNoticeKind.teamDeletingSoon, seq: deleting.seq, by: deleting.by)];
}

/// The changes since [told] (see [takeTeamNotices]), counted as told now.
Future<List<TeamNotice>> _noticesSince(LocalStateStore store, LocalRecord record, int? told) async {
  await store.write(_toldKey, '${record.seq}');
  if (told == null) {
    final now = record.latest.tracking;
    if (now.isNone) return const [];
    final set = record.entries.where((e) => e.type == RecordTypes.trackingSet).lastOrNull;
    if (set == null) return const [];
    final export = record.latest.eventExport;
    final turnedOn = record.entries.where((e) => e.type == RecordTypes.exportSet).lastOrNull;
    return [
      TeamNotice(TeamNoticeKind.trackingNow, seq: set.seq, by: set.by, tracking: now),
      if (export != null && turnedOn != null) TeamNotice(TeamNoticeKind.exportOn, seq: turnedOn.seq, by: export.by),
    ];
  }
  final out = <TeamNotice>[];
  // Whether the team's events were sent on just before each new entry
  // (event export): that ends with other entries too (activity no longer recorded,
  // the owner who set it up no longer one), so the record itself is asked.
  var exporting = told >= 1 && (await record.stateAt(told)).eventExport != null;
  // What the team recorded before each tracking.set: the one before it
  // (every entry kept here was checked when it arrived).
  var tracking = RecordTracking.none;
  for (final e in record.entries) {
    if (e.type == RecordTypes.trackingSet) {
      final before = tracking;
      tracking = RecordTracking.fromBody(_bodyOf(e));
      if (e.seq > told && tracking != before) {
        out.add(TeamNotice(
          tracking.recordsMoreThan(before) ? TeamNoticeKind.trackingMore : TeamNoticeKind.trackingLess,
          seq: e.seq,
          by: e.by,
          tracking: tracking,
        ));
      }
    } else if (e.seq > told) {
      final notice = teamNoticeOf(e);
      if (notice != null) out.add(notice);
      // Whether a Crate's sessions are watched, when that changed: the
      // record before and after the entry is asked, so an entry that says
      // what was so already tells nobody anything.
      final crate = e.type == RecordTypes.crateSet ? (_bodyOf(e) ?? const <String, Object?>{})['id'] : null;
      if (crate is String && e.seq > 1) {
        final before = (await record.stateAt(e.seq - 1)).crates[crate];
        final after = (await record.stateAt(e.seq)).crates[crate];
        final was = before?.watched ?? false;
        final now = after?.watched ?? false;
        if (was != now) {
          out.add(TeamNotice(now ? TeamNoticeKind.watchedOn : TeamNoticeKind.watchedOff,
              seq: e.seq, by: e.by, crateId: crate));
        }
        // Who connects there with nobody watching while ZestSSH Cloud
        // cannot be reached, when that changed: said of a Crate whose
        // sessions are watched, since it means nothing for any other. One
        // whose sessions become watched with everyone let in already says
        // so then.
        final wasAway = was && (before?.unwatchedAway ?? false);
        final nowAway = after?.unwatchedAway ?? false;
        if (now && wasAway != nowAway) {
          out.add(TeamNotice(nowAway ? TeamNoticeKind.unwatchedAwayOn : TeamNoticeKind.unwatchedAwayOff,
              seq: e.seq, by: e.by, crateId: crate));
        }
      }
    }
    if (e.seq > told) {
      final export = (await record.stateAt(e.seq)).eventExport;
      if ((export != null) != exporting) {
        exporting = export != null;
        out.add(TeamNotice(
          exporting ? TeamNoticeKind.exportOn : TeamNoticeKind.exportOff,
          seq: e.seq,
          by: export?.by ?? e.by,
        ));
      }
    }
  }
  return out;
}

Map<String, Object?>? _bodyOf(RecordEntry e) {
  try {
    return e.body;
  } catch (_) {
    return null;
  }
}

/// [e] as a notice, when it is one every member is told of.
TeamNotice? teamNoticeOf(RecordEntry e) {
  Map<String, Object?> body;
  try {
    body = e.body;
  } catch (_) {
    return null;
  }
  String? str(String k) => body[k] is String ? body[k] as String : null;
  return switch (e.type) {
    RecordTypes.recoverySet => TeamNotice(
        body['on'] == true ? TeamNoticeKind.recoveryOn : TeamNoticeKind.recoveryOff,
        seq: e.seq,
        by: e.by,
      ),
    RecordTypes.crateSet when body['session_logs'] is bool && str('id') != null => TeamNotice(
        body['session_logs'] == true ? TeamNoticeKind.sessionLogsOn : TeamNoticeKind.sessionLogsOff,
        seq: e.seq,
        by: e.by,
        crateId: str('id'),
      ),
    RecordTypes.memberRecover => TeamNotice(
        TeamNoticeKind.memberRecovered,
        seq: e.seq,
        by: e.by,
        member: str('uid'),
        approver: str('approver'),
      ),
    RecordTypes.accessGrant when body['until'] is int && str('uid') != null && str('crate') != null => TeamNotice(
        body['until'] == 0 ? TeamNoticeKind.accessEnded : TeamNoticeKind.accessGiven,
        seq: e.seq,
        by: e.by,
        member: str('uid'),
        crateId: str('crate'),
        until: body['until'] == 0 ? null : body['until'] as int,
      ),
    RecordTypes.sessionUnwatched when str('crate') != null => TeamNotice(
        TeamNoticeKind.sessionUnwatched,
        seq: e.seq,
        by: e.by,
        crateId: str('crate'),
      ),
    // Deleting the team, and undoing it: every member is told.
    RecordTypes.teamDelete => TeamNotice(TeamNoticeKind.teamDeleting, seq: e.seq, by: e.by),
    RecordTypes.teamRestore => TeamNotice(TeamNoticeKind.teamKept, seq: e.seq, by: e.by),
    RecordTypes.memberLimit
        when str('uid') != null && str('crate') != null && (body['switches'] == null || body['switches'] is List) =>
      TeamNotice(
        switch (body['switches']) {
          null => TeamNoticeKind.vaultBack,
          List(isEmpty: true) => TeamNoticeKind.vaultTaken,
          _ => TeamNoticeKind.vaultSet,
        },
        seq: e.seq,
        by: e.by,
        member: str('uid'),
        crateId: str('crate'),
        switches: body['switches'] is List ? {...(body['switches'] as List).whereType<String>()} : null,
      ),
    _ => null,
  };
}

/// The notifications waiting in the Orchards on this device ([databases]:
/// each Orchard's id and its database) for the signed-in account [me], in
/// words from [l10n], with people named by their address and each Orchard by
/// [orchardName] (its name as this device has it, or none). Changes [me] made
/// itself are counted as told without being shown: its person just saw
/// them happen. One Orchard that cannot be read keeps nothing from the rest.
Future<List<AppNotification>> takeTeamNotifications(
  Map<String, AppDatabase> databases, {
  required String? me,
  required AppLocalizations l10n,
  required String Function(String? name) orchardName,
}) async {
  final out = <AppNotification>[];
  for (final entry in databases.entries) {
    try {
      final db = entry.value;
      final taken = await takeTeamNotices(db, entry.key);
      // Session logs are told to those who can open the Crate.
      final record = taken.any((n) => n.crateId != null) ? (await LocalRecord.load(db, entry.key)).latest : null;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final notices = [
        for (final n in taken)
          if ((n.by != me || n.forEveryone) &&
              (n.forMemberOnly
                  ? n.member == me
                  : n.forThoseWhoAnswer
                      // A session that ran with nobody watching: those who
                      // manage the Crate, as every owner does, and nobody
                      // else.
                      ? me != null && record!.switchesAt(me, n.crateId!, now).contains(CrateSwitches.manage)
                      : n.crateId == null || (me != null && record!.switchesAt(me, n.crateId!, now).isNotEmpty)))
            n,
      ];
      // Team-pinned host keys replaced or removed by someone else.
      final hostKeys = await takeHostKeyNotices(db, me: me);
      final logsFull = await takeSessionLogsFull(db, entry.key, me: me);
      if (notices.isEmpty && hostKeys.isEmpty && !logsFull) continue;
      final emails = {
        for (final r in await db.customSelect('SELECT uid, email FROM member_keys').get())
          r.read<String>('uid'): r.read<String?>('email'),
      };
      final info = await db.customSelect('SELECT name, held FROM orchard_info WHERE id = 1').getSingleOrNull();
      final orchard = orchardName(info?.read<String?>('name'));
      // What a team being deleted takes with it, and who can undo it (design
      // 55), for its notices.
      final deletion = notices.any((n) => n.kind == TeamNoticeKind.teamDeleting || n.kind == TeamNoticeKind.teamDeletingSoon)
          ? await _deletionWords(db, entry.key, info?.read<String?>('held'), me: me, l10n: l10n, nameOf: (uid) => emails[uid] ?? uid)
          : null;
      final crateNames = {
        // A vault that already left this device named as it was (for
        // a member told it was taken away from them).
        if (notices.any((n) => n.crateId != null)) ...await goneCrateNames(db),
        if (notices.any((n) => n.crateId != null))
          for (final r in await db.customSelect('SELECT crate_id, name FROM orchard_crates').get())
            r.read<String>('crate_id'): r.read<String?>('name'),
      };
      for (final n in notices) {
        out.add(teamNoticeNotification(
          n,
          orchardId: entry.key,
          orchard: orchard,
          crateName: (id) => crateNames[id] ?? '',
          nameOf: (uid) => uid == null ? '' : emails[uid] ?? uid,
          me: me,
          l10n: l10n,
          deletion: deletion,
        ));
      }
      for (final h in hostKeys) {
        out.add(hostKeyNoticeNotification(
          h,
          orchardId: entry.key,
          orchard: orchard,
          nameOf: (uid) => uid == null ? '' : emails[uid] ?? uid,
          l10n: l10n,
        ));
      }
      if (logsFull) {
        out.add(AppNotification(
          id: 'team-session-logs-full-${entry.key}',
          title: l10n.orchardSessionLogsFullTitle(orchard),
          body: l10n.orchardSessionLogsFullBody,
          severity: NotificationSeverity.warning,
        ));
      }
    } catch (e) {
      AppLogger.info('Orchards: what changed in an Orchard could not be read ($e)');
    }
  }
  return out;
}

/// [n] as the notification this device shows: in [orchard] (its name), with
/// people named by [nameOf], [me] the signed-in account. A security change,
/// so it stays in the bell until read.
AppNotification teamNoticeNotification(
  TeamNotice n, {
  required String orchardId,
  required String orchard,
  String Function(String? crateId)? crateName,
  required String Function(String? uid) nameOf,
  required String? me,
  required AppLocalizations l10n,
  TeamDeletionWords? deletion,
  DateTime? now,
}) {
  final (title, body) = switch (n.kind) {
    TeamNoticeKind.recoveryOn => (l10n.noticeRecoveryOnTitle(orchard), l10n.noticeRecoveryOnBody),
    TeamNoticeKind.recoveryOff => (l10n.noticeRecoveryOffTitle(orchard), l10n.noticeRecoveryOffBody),
    TeamNoticeKind.memberRecovered when n.member != null && n.member == me => (
        l10n.noticeYouRecoveredTitle(orchard),
        l10n.noticeYouRecoveredBody(nameOf(n.by), nameOf(n.approver)),
      ),
    TeamNoticeKind.memberRecovered => (
        l10n.noticeMemberRecoveredTitle(nameOf(n.member), orchard),
        l10n.noticeMemberRecoveredBody(nameOf(n.by), nameOf(n.approver)),
      ),
    TeamNoticeKind.sessionLogsOn => (
        l10n.noticeSessionLogsOnTitle((crateName ?? (_) => '')(n.crateId)),
        l10n.noticeSessionLogsOnBody(nameOf(n.by), orchard),
      ),
    TeamNoticeKind.sessionLogsOff => (
        l10n.noticeSessionLogsOffTitle((crateName ?? (_) => '')(n.crateId)),
        l10n.noticeSessionLogsOffBody(nameOf(n.by), orchard),
      ),
    TeamNoticeKind.accessGiven => (
        l10n.noticeAccessGivenTitle(orchard),
        l10n.noticeAccessGivenBody(
          nameOf(n.by),
          _crateOr((crateName ?? (_) => '')(n.crateId), l10n),
          accessTimeText(n.until ?? 0, l10n),
        ),
      ),
    TeamNoticeKind.accessEnded => (l10n.noticeAccessEndedTitle(orchard), l10n.noticeAccessEndedBody(nameOf(n.by))),
    TeamNoticeKind.trackingNow => (
        l10n.noticeTrackingNowTitle(orchard),
        l10n.noticeTrackingNowBody(trackingOnNames(n.tracking ?? RecordTracking.none, l10n).join(l10n.listSeparator)),
      ),
    TeamNoticeKind.trackingMore || TeamNoticeKind.trackingLess => (
        n.kind == TeamNoticeKind.trackingMore
            ? l10n.noticeTrackingMoreTitle(orchard)
            : l10n.noticeTrackingLessTitle(orchard),
        trackingNoticeBody(n.tracking ?? RecordTracking.none, by: nameOf(n.by), l10n: l10n),
      ),
    TeamNoticeKind.exportOn => (l10n.noticeExportOnTitle(orchard), l10n.noticeExportOnBody(nameOf(n.by))),
    TeamNoticeKind.exportOff => (l10n.noticeExportOffTitle(orchard), l10n.noticeExportOffBody),
    TeamNoticeKind.watchedOn => (
        l10n.noticeWatchedOnTitle((crateName ?? (_) => '')(n.crateId)),
        l10n.noticeWatchedOnBody(nameOf(n.by), orchard),
      ),
    TeamNoticeKind.watchedOff => (
        l10n.noticeWatchedOffTitle((crateName ?? (_) => '')(n.crateId)),
        l10n.noticeWatchedOffBody(nameOf(n.by), orchard),
      ),
    TeamNoticeKind.unwatchedAwayOn => (
        l10n.noticeUnwatchedAwayOnTitle((crateName ?? (_) => '')(n.crateId)),
        l10n.noticeUnwatchedAwayOnBody(nameOf(n.by), orchard),
      ),
    TeamNoticeKind.unwatchedAwayOff => (
        l10n.noticeUnwatchedAwayOffTitle((crateName ?? (_) => '')(n.crateId)),
        l10n.noticeUnwatchedAwayOffBody(nameOf(n.by), orchard),
      ),
    // Nothing of the host or the reason: the bell keeps what it showed
    // outside the Orchard's own database. It says where they are.
    TeamNoticeKind.sessionUnwatched => (
        l10n.noticeSessionUnwatchedTitle(_crateOr((crateName ?? (_) => '')(n.crateId), l10n)),
        l10n.noticeSessionUnwatchedBody(nameOf(n.by), orchard, l10n.teamPageTrust),
      ),
    TeamNoticeKind.vaultSet => (
        l10n.noticeVaultAccessTitle(orchard),
        l10n.noticeVaultSetBody(
          _crateOr((crateName ?? (_) => '')(n.crateId), l10n),
          levelWords(n.switches ?? const {}, l10n),
          nameOf(n.by),
        ),
      ),
    TeamNoticeKind.vaultTaken => (
        l10n.noticeVaultAccessTitle(orchard),
        l10n.noticeVaultTakenBody(nameOf(n.by), _crateOr((crateName ?? (_) => '')(n.crateId), l10n)),
      ),
    TeamNoticeKind.vaultBack => (
        l10n.noticeVaultAccessTitle(orchard),
        l10n.noticeVaultBackBody(nameOf(n.by), _crateOr((crateName ?? (_) => '')(n.crateId), l10n)),
      ),
    TeamNoticeKind.teamDeleting || TeamNoticeKind.teamDeletingSoon => (
        _deletingTitle(n, orchard, deletion, l10n, now ?? DateTime.now()),
        _deletingBody(n, deletion, nameOf, me, l10n),
      ),
    TeamNoticeKind.teamKept => (l10n.noticeTeamKeptTitle(orchard), l10n.noticeTeamKeptBody(nameOf(n.by))),
  };
  // (An entry that changes what is recorded can end the sending on as
  // well, and one entry can change a Crate's session logs and whether its
  // sessions are watched: two notices from one entry, each with an id of
  // its own.)
  final export = n.kind == TeamNoticeKind.exportOn || n.kind == TeamNoticeKind.exportOff;
  final watched = n.kind == TeamNoticeKind.watchedOn || n.kind == TeamNoticeKind.watchedOff;
  final away = n.kind == TeamNoticeKind.unwatchedAwayOn || n.kind == TeamNoticeKind.unwatchedAwayOff;
  // The countdown, a notice of its own each day it is told.
  final soon = n.kind == TeamNoticeKind.teamDeletingSoon;
  final day = now ?? DateTime.now();
  return AppNotification(
    id: 'orchard-notice-$orchardId-${n.seq}${export ? '-export' : watched ? '-watched' : away ? '-away' : soon ? '-soon-${day.year * 10000 + day.month * 100 + day.day}' : ''}',
    title: title,
    body: body,
    severity: NotificationSeverity.warning,
  );
}

/// What a team being deleted takes with it, for its notices:
/// the day it goes, its vaults by name with how many hosts they hold, and
/// the owners and admins who can undo it (this account aside), each as shown.
class TeamDeletionWords {
  const TeamDeletionWords({this.purgeAt, required this.vaults, required this.hosts, required this.owners, required this.meMayUndo});

  final DateTime? purgeAt;
  final String vaults;
  final int hosts;
  final String owners;
  final bool meMayUndo;
}

/// [TeamDeletionWords] for the team [orchardId] (its database [db]), with
/// [held] its orchard_info.held, as the list of teams last said it.
Future<TeamDeletionWords> _deletionWords(AppDatabase db, String orchardId, String? held,
    {required String? me, required AppLocalizations l10n, required String Function(String uid) nameOf}) async {
  DateTime? purgeAt;
  try {
    final h = held == null ? null : jsonDecode(held);
    final at = h is Map && h['deleting'] is Map ? (h['deleting'] as Map)['purge_at'] : null;
    purgeAt = at is String ? DateTime.tryParse(at) : null;
  } catch (_) {
    // Said without the day.
  }
  final names = [
    for (final r in await db.customSelect('SELECT name FROM orchard_crates ORDER BY name COLLATE NOCASE').get())
      r.read<String?>('name')?.trim().isNotEmpty == true ? r.read<String>('name') : l10n.crateUnnamed,
  ];
  final hosts = (await db
          .customSelect("SELECT COUNT(*) AS n FROM crate_items_meta WHERE kind = 'host' AND server_deleted = 0")
          .getSingle())
      .read<int>('n');
  final record = (await LocalRecord.load(db, orchardId)).latest;
  // Who can undo it: the owners and the admins.
  final owners = [for (final uid in [...record.owners, ...record.admins]) if (uid != me) nameOf(uid)];
  return TeamDeletionWords(
    purgeAt: purgeAt,
    vaults: names.join(l10n.listSeparator),
    hosts: hosts,
    owners: owners.join(l10n.listSeparator),
    meMayUndo: me != null && (record.isOwner(me) || record.isAdmin(me)),
  );
}

String _deletingTitle(TeamNotice n, String orchard, TeamDeletionWords? d, AppLocalizations l10n, DateTime now) {
  final at = d?.purgeAt;
  if (at == null) return l10n.noticeTeamDeletingNoDayTitle(orchard);
  if (n.kind == TeamNoticeKind.teamDeleting) return l10n.noticeTeamDeletingTitle(orchard, _day(at, l10n));
  final local = at.toLocal();
  final days = DateTime(local.year, local.month, local.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days <= 0) return l10n.noticeTeamDeletingTodayTitle(orchard);
  if (days == 1) return l10n.noticeTeamDeletingTomorrowTitle(orchard);
  return l10n.noticeTeamDeletingInDaysTitle(orchard, days);
}

String _deletingBody(
    TeamNotice n, TeamDeletionWords? d, String Function(String? uid) nameOf, String? me, AppLocalizations l10n) {
  if (d == null) return n.by == me ? l10n.noticeTeamDeletingYouShortBody : l10n.noticeTeamDeletingShortBody(nameOf(n.by));
  final hosts = l10n.teamDeleteHosts(d.hosts);
  if (n.by == me) return l10n.noticeTeamDeletingYouBody(d.vaults, hosts);
  if (d.meMayUndo) return l10n.noticeTeamDeletingOwnerBody(d.vaults, hosts, nameOf(n.by));
  return d.owners.isEmpty
      ? l10n.noticeTeamDeletingNoOwnersBody(d.vaults, hosts, nameOf(n.by))
      : l10n.noticeTeamDeletingBody(d.vaults, hosts, nameOf(n.by), d.owners);
}

String _day(DateTime at, AppLocalizations l10n) {
  try {
    return DateFormat.yMMMMd(l10n.localeName).format(at.toLocal());
  } catch (_) {
    return DateFormat.yMMMMd('en_US').format(at.toLocal());
  }
}

/// [n] (about access on request) as the notification this device shows:
/// in [orchard] (its name), with people named by [nameOf]. It stays in the
/// bell until read.
AppNotification accessNoticeNotification(
  AccessNotice n, {
  required String orchardId,
  required String orchard,
  required String Function(String? uid) nameOf,
  required AppLocalizations l10n,
  DateTime? now,
}) {
  final (title, body) = switch (n.kind) {
    AccessNoticeKind.asked => (
        l10n.noticeAccessAskedTitle(orchard),
        n.uid != null ? l10n.noticeAccessAskedBody(nameOf(n.uid)) : l10n.noticeAccessAskedManyBody(n.count),
      ),
    AccessNoticeKind.declined => (l10n.noticeAccessDeclinedTitle(orchard), l10n.noticeAccessDeclinedBody),
    AccessNoticeKind.lapsed => (l10n.noticeAccessLapsedTitle(orchard), l10n.noticeAccessLapsedBody),
    AccessNoticeKind.over => (
        l10n.noticeAccessOverTitle(orchard),
        n.crateName == null ? l10n.noticeAccessOverBodyUnnamed : l10n.noticeAccessOverBody(n.crateName!),
      ),
  };
  final at = now ?? DateTime.now();
  return AppNotification(
    id: 'orchard-access-$orchardId-${n.kind.name}-${n.crateId ?? ''}-${at.microsecondsSinceEpoch}',
    title: title,
    body: body,
    severity: NotificationSeverity.warning,
    createdAt: at,
  );
}

/// [n] (about devices) as the notification this device shows: in
/// [orchard] (its name), with people named by [nameOf]. It stays in the
/// bell until read.
AppNotification deviceNoticeNotification(
  DeviceNotice n, {
  required String orchardId,
  required String orchard,
  required String Function(String? uid) nameOf,
  required AppLocalizations l10n,
  DateTime? now,
}) {
  final (title, body) = switch (n.kind) {
    DeviceNoticeKind.asked => (
        l10n.noticeDeviceAskedTitle(orchard),
        n.uid == null
            ? l10n.noticeDeviceAskedManyBody(n.count)
            : n.own
                ? l10n.noticeDeviceAskedOwnBody
                : l10n.noticeDeviceAskedBody(nameOf(n.uid)),
      ),
    DeviceNoticeKind.removed => (l10n.noticeDeviceRemovedTitle(orchard), l10n.noticeDeviceRemovedBody),
  };
  final at = now ?? DateTime.now();
  return AppNotification(
    id: 'orchard-device-$orchardId-${n.kind.name}-${at.microsecondsSinceEpoch}',
    title: title,
    body: body,
    severity: NotificationSeverity.warning,
    createdAt: at,
  );
}

/// An invitation to this account as the notification this device
/// shows, once for each invitation: who sent it, where it says. The team's
/// name is encrypted for its members, so it is not known before they join.
/// It stays in the bell until read.
AppNotification invitationNotification(MyInvite invite, {required AppLocalizations l10n}) => AppNotification(
      id: 'orchard-invite-${invite.id}',
      title: l10n.noticeInvitedTitle,
      body: invite.invitedBy == null ? l10n.noticeInvitedBodySomeone : l10n.noticeInvitedBody(invite.invitedBy!),
      severity: NotificationSeverity.warning,
    );

/// A Crate's name, or "a Crate you can't open" when this device has none
/// for it (it is not here yet, or no longer).
String _crateOr(String name, AppLocalizations l10n) => name.isEmpty ? l10n.teamCrateClosed : name;

/// The moment [seconds] (since the epoch) on this device's clock, in words:
/// the time alone when it is today, with the day otherwise.
String accessTimeText(int seconds, AppLocalizations l10n, {DateTime? now}) {
  final at = secondsAsDate(seconds);
  final today = now ?? DateTime.now();
  final sameDay = at.year == today.year && at.month == today.month && at.day == today.day;
  String written(String locale) => (sameDay ? DateFormat.jm(locale) : DateFormat.MMMd(locale).add_jm()).formatPlain(at);
  try {
    return written(l10n.localeName);
  } catch (_) {
    // This language's dates are loaded with the first screen. A notice that
    // comes before that is not lost for it: the one way of writing a time
    // that is always there.
    return written('en_US');
  }
}

/// What [tracking] turns on, in words from [l10n], in the order the Team
/// page lists them; empty for nothing.
List<String> trackingOnNames(RecordTracking tracking, AppLocalizations l10n) => [
      if (tracking.history) l10n.trackingListHistory,
      if (tracking.activity) l10n.trackingListActivity,
      if (tracking.devices) l10n.trackingListDevices,
      if (tracking.ips) l10n.trackingListIps,
    ];

/// A tracking notice's body: who changed it ([by]) and what is on now.
String trackingNoticeBody(RecordTracking tracking, {required String by, required AppLocalizations l10n}) {
  final on = trackingOnNames(tracking, l10n);
  return on.isEmpty ? l10n.noticeTrackingNoneBody(by) : l10n.noticeTrackingOnBody(by, on.join(l10n.listSeparator));
}
