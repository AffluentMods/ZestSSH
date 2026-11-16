import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// The Team destination's pages (3.0). Owners and admins run the
/// Orchard from here instead of from dialogs off the space menu.
enum TeamPage { overview, members, roles, seats, crates, rules, signIn, setup, trust, activity, settings }

/// The Team page on screen; kept while the app runs.
final teamPageProvider = StateProvider<TeamPage>((_) => TeamPage.overview);

/// The member whose panel is open on an Orchard's Members page (by the
/// Orchard's id), so that the page's header ends where the list does while
/// the panel takes the right of the page. Kept only while that page is on
/// screen: another page, another team or the Members page closed, and it
/// starts again with no panel (it kept the member, whose panel came back
/// unasked, perhaps of someone no longer in the team).
final teamMemberPanelProvider = StateProvider.autoDispose.family<String?, String>((_, orchardId) => null);

/// The vault whose pane is open on an Orchard's Vaults page (by the
/// Orchard's id), so that the page's header ends where the list does while
/// the pane takes the right of the page. Kept only while that page is on
/// screen, as a member's panel is.
final teamVaultPanelProvider = StateProvider.autoDispose.family<String?, String>((_, orchardId) => null);

/// A vault another page asked the Vaults page to open (the Roles page's
/// "Change in Vaults"): read once, and cleared, when that page opens.
final teamVaultToOpenProvider = StateProvider<String?>((_) => null);

/// The invitation whose review (someone who used an invite code or accepted
/// an invitation, waiting to be let in) is open beside an Orchard's Members
/// list, by the Orchard's id: in place of a member's panel, kept as that
/// panel is.
final teamReviewPanelProvider = StateProvider.autoDispose.family<String?, String>((_, orchardId) => null);

/// An invitation another page asked the Members page to review (the
/// Overview's Review): read once, and cleared, when that page opens.
final teamReviewToOpenProvider = StateProvider<String?>((_) => null);

/// Opens the Team destination on [page] (desktop), leaving any session or
/// work tab. Returns false on phones and tablets, where the Orchard's
/// screens stay dialogs, so the caller opens its own.
bool openTeamPage(WidgetRef ref, TeamPage page) {
  if (!desktopShellInUse) return false;
  ref.read(teamPageProvider.notifier).state = page;
  ref.read(v3ActiveSessionTabProvider.notifier).state = null;
  ref.read(activeSidebarNavProvider.notifier).state = NavSection.team;
  ref.read(workTabsProvider.notifier).clearActiveTab();
  return true;
}

/// An Orchard's record as the Team page shows it, read from this device
/// alone: every change, oldest first; the address of everyone the record
/// names (members who left too); and its head, which a teammate who sees
/// the same history also sees.
class TeamRecord {
  const TeamRecord({
    required this.changes,
    required this.emails,
    required this.head,
    this.firstSeen = const {},
    this.entries = const [],
  });

  final List<TeamChange> changes;

  /// The entries themselves, oldest first, exactly as signed (the key log's
  /// details, its check and its export).
  final List<RecordEntry> entries;
  final Map<String, String?> emails;
  final Uint8List head;

  /// When this device first saw each entry, by its number; absent for
  /// entries kept before that was noted (3.0).
  final Map<int, DateTime> firstSeen;
}

final teamRecordProvider = FutureProvider.autoDispose.family<TeamRecord, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  final db = await ref.read(orchardDatabasesProvider.notifier).open(orchardId);
  final local = await LocalRecord.load(db, orchardId);
  final emails = {
    for (final r in await db.customSelect('SELECT uid, email FROM member_keys').get())
      r.read<String>('uid'): r.read<String?>('email'),
  };
  return TeamRecord(
    changes: await teamChanges(orchardId, local.entries),
    entries: local.entries,
    emails: emails,
    head: local.head,
    firstSeen: {
      for (var i = 0; i < local.entries.length; i++)
        if (local.firstSeen[i] case final s?) local.entries[i].seq: DateTime.fromMillisecondsSinceEpoch(s * 1000),
    },
  );
});

/// Team recovery as this device's copy of the record has it (3.0):
/// on or off, and how many owners the Orchard has. Offline too.
final teamRecoveryRuleProvider =
    FutureProvider.autoDispose.family<({bool on, int owners}), String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  final db = await ref.read(orchardDatabasesProvider.notifier).open(orchardId);
  final latest = (await LocalRecord.load(db, orchardId)).latest;
  return (on: latest.teamRecovery, owners: latest.owners.length);
});

/// What the team records (3.0) as this device's copy of the
/// record has it. Offline too.
final teamTrackingProvider = FutureProvider.autoDispose.family<RecordTracking, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  final db = await ref.read(orchardDatabasesProvider.notifier).open(orchardId);
  return (await LocalRecord.load(db, orchardId)).latest.tracking;
});

/// The Crates whose sessions are logged for their team (3.0), as
/// this device's copy of the record has it. Offline too.
final teamSessionLogCratesProvider = FutureProvider.autoDispose.family<Set<String>, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  final db = await ref.read(orchardDatabasesProvider.notifier).open(orchardId);
  final latest = (await LocalRecord.load(db, orchardId)).latest;
  return {
    for (final c in latest.crates.values)
      if (c.sessionLogs) c.id,
  };
});

/// The Crates whose sessions are watched (3.0), as this device's
/// copy of the record has it. Offline too.
final teamWatchedCratesProvider = FutureProvider.autoDispose.family<Set<String>, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  final db = await ref.read(orchardDatabasesProvider.notifier).open(orchardId);
  final latest = (await LocalRecord.load(db, orchardId)).latest;
  return {
    for (final c in latest.crates.values)
      if (c.watched) c.id,
  };
});

/// The Crates where everyone who may connect may also do so with nobody
/// watching while ZestSSH Cloud cannot be reached, and not owners alone
/// (3.0, the outage work), as this device's copy of the record has it.
/// Offline too.
final teamUnwatchedAwayCratesProvider =
    FutureProvider.autoDispose.family<Set<String>, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  final db = await ref.read(orchardDatabasesProvider.notifier).open(orchardId);
  final latest = (await LocalRecord.load(db, orchardId)).latest;
  return {
    for (final c in latest.crates.values)
      if (c.unwatchedAway) c.id,
  };
});

/// Reads what a member reported of a session that ran with nobody watching
/// out of its entry of an Orchard's record, as this device can read it
/// (orchard_unwatched.dart). A test stands in.
final unwatchedSessionReaderProvider =
    Provider<Future<UnwatchedSession?> Function(String orchardId, RecordEntry entry)>(
        (ref) => (orchardId, entry) => ref.read(orchardServiceProvider).unwatchedSessionOf(orchardId, entry));

/// The keys to change after people lost access (3.0), kept on
/// this device.
final teamChangeNextProvider = FutureProvider.autoDispose.family<List<ChangeNextItem>, String>((ref, orchardId) {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardServiceProvider).changeNext(orchardId);
});

/// What this device holds back of an Orchard's items ([CrateSyncEngine.heldBack]).
final teamHeldBackProvider = FutureProvider.autoDispose.family<List<HeldBackItem>, String>((ref, orchardId) {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardSyncProvider).heldBack(orchardId);
});

/// An Orchard's people for the Overview (its counts and what needs
/// attention). Reading them may ask the server which account is signed in,
/// at most every ten minutes.
final teamPeopleProvider = FutureProvider.autoDispose.family<OrchardPeople, String>((ref, orchardId) {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardServiceProvider).people(orchardId);
});
