import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart' show AppDatabase, kHostKeyKind;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show shortMemberId;
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart' show CompareCodes;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart' show BusinessServicesState;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/sign_in_ways.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

// Deleting a team, on screen:
// the confirmation that names everything that goes, built from
// what this device holds of the team; the banner while it is being deleted,
// with Undo for owners and Leave for everyone; the question a device asks
// once ZestSSH Cloud says the team was deleted; and a team's only owner who
// chooses Leave, offered Make someone owner or Delete the team.

/// How many names of each kind the confirmation shows before "and N more".
const int kTeamDeleteNamesShown = 6;

/// How many people the confirmation names before "+ N more".
const int kTeamDeletePeopleShown = 6;

/// The kinds of item a vault holds, in the order the confirmation lists them.
const List<String> kTeamDeleteKinds = ['host', 'key', 'snippet', 'forward', 'group', 'network', 'trigger', kHostKeyKind];

/// For each kind: the table, its id column and its name, for the names shown.
const Map<String, (String, String, String)> _kindNames = {
  'host': ('connections', 'id', 'label'),
  'key': ('identities', 'id', 'label'),
  'snippet': ('snippets', 'id', 'label'),
  'forward': ('port_forward_rules', 'id', 'label'),
  'group': ('connection_groups', 'id', 'name'),
  'network': ('networks', 'id', 'name'),
  'trigger': ('terminal_triggers', 'id', 'name'),
  kHostKeyKind: ('team_host_keys', 'id', "host || ':' || port"),
};

/// One vault of a team about to be deleted, as this device holds it: how
/// many of each kind of item, and the first names of each.
class TeamDeletionVault {
  const TeamDeletionVault({required this.id, required this.name, required this.counts, required this.names});

  final String id;
  final String name;

  /// Kind of item (see [kTeamDeleteKinds]) to how many.
  final Map<String, int> counts;

  /// Kind of item to its first names, as kept (masked where they are shown).
  final Map<String, List<String>> names;

  int get items => counts.values.fold(0, (a, b) => a + b);
}

/// What deleting a team takes with it: built from what this
/// device holds of it, its record, and what ZestSSH Cloud says of its
/// invitations, seats and company sign-in. What cannot be read now is left
/// out, never guessed.
class TeamDeletionPreview {
  const TeamDeletionPreview({
    required this.vaults,
    required this.people,
    this.invitations,
    this.codes,
    this.recordedVaults = const [],
    this.history = false,
    this.activity = false,
    this.authorities = const [],
    this.companySignIn,
    this.directory = false,
    this.eventExport = false,
    this.seats,
    this.businessRenews,
    this.business = false,
    this.onlyCompanySignIn = false,
    this.firstNewKind = false,
  });

  final List<TeamDeletionVault> vaults;

  /// Everyone who loses access, this account first: as shown (masked while
  /// recording), with whether it is this account.
  final List<({String name, bool me})> people;

  /// Invitations to an address, and team codes, still waiting; null where
  /// they could not be read.
  final int? invitations;
  final int? codes;

  /// The vaults whose sessions are recorded, by name.
  final List<String> recordedVaults;

  /// Version history and the trash, and activity.
  final bool history;
  final bool activity;

  /// Each vault's certificate authority: its name, and the latest a
  /// certificate it signed may last until.
  final List<({String vault, DateTime latest})> authorities;

  /// The company sign-in's name as an owner gave it, where one is set up.
  final String? companySignIn;
  final bool directory;
  final bool eventExport;

  /// The team's seats, and Business with the day it renews (or works until).
  final int? seats;
  final bool business;
  final DateTime? businessRenews;

  /// This account signs in to ZestSSH only through the team's company
  /// sign-in, which goes with the team.
  final bool onlyCompanySignIn;

  /// No entry of a new kind is in the record yet: deleting is the first.
  final bool firstNewKind;

  int get hosts => vaults.fold(0, (n, v) => n + (v.counts['host'] ?? 0));
}

/// [at] as a day the person reads: "5 November 2026".
String teamDeletionDay(DateTime at, AppLocalizations l10n) {
  final local = at.toLocal();
  try {
    return DateFormat.yMMMMd(l10n.localeName).format(local);
  } catch (_) {
    // This language's dates are loaded with the first screen.
    return DateFormat.yMMMMd('en_US').format(local);
  }
}

/// Reads [orchard]'s [TeamDeletionPreview].
Future<TeamDeletionPreview> readTeamDeletionPreview(WidgetRef ref, OrchardSummary orchard, AppLocalizations l10n) async {
  final service = ref.read(orchardServiceProvider);
  final db = await service.databases.open(orchard.id);
  final record = (await LocalRecord.load(db, orchard.id)).latest;
  final vaults = await _vaultsIn(db, orchard, l10n);

  final people = <({String name, bool me})>[];
  try {
    final team = await service.people(orchard.id);
    for (final m in team.members) {
      if (m.status == MemberStatus.removed) continue;
      people.add((name: Redactable.account(m.name ?? m.email ?? shortMemberId(m.uid)).displayIn(ref), me: m.isMe));
    }
  } catch (e) {
    AppLogger.info('Delete team: the members could not be read ($e)');
  }

  int? invitations, codes;
  try {
    final open = (await service.invites(orchard.id)).where((i) => !i.expired).toList();
    codes = open.where((i) => i.code != null).length;
    invitations = open.length - codes;
  } catch (e) {
    AppLogger.info('Delete team: the invitations could not be read ($e)');
  }

  String? companySignIn;
  try {
    final sso = await ref.read(orchardSsoApiProvider).get(orchard.id);
    if (sso.isSetUp) {
      companySignIn = sso.displayName?.trim().isNotEmpty == true ? sso.displayName!.trim() : l10n.teamDeleteSignInUnnamed;
    }
  } catch (e) {
    AppLogger.info('Delete team: company sign-in could not be read ($e)');
  }
  var directory = false;
  try {
    directory = (await ref.read(orchardDirectoryApiProvider).get(orchard.id)).enabled;
  } catch (e) {
    AppLogger.info('Delete team: directory sync could not be read ($e)');
  }

  int? seats;
  var business = false;
  DateTime? renews;
  try {
    final billing = await ref.read(orchardBillingApiProvider).get(orchard.id);
    seats = billing.seats.total;
    final services = billing.services;
    business = services.subscribed && services.state != BusinessServicesState.off;
    renews = services.endsAtPeriodEnd ? null : services.paidThrough;
  } catch (e) {
    AppLogger.info('Delete team: the seats could not be read ($e)');
  }

  var onlyCompany = false;
  try {
    // As the Account page reads them: this device's sign-in where it is
    // Firebase's, else ZestSSH Cloud's answer.
    final user = AuthService.currentUser;
    final ways = user != null
        ? SignInWays.fromProviders(user.email ?? '', user.providerData.map((p) => p.providerId))
        : await SignInWaysApi(bearer: accountBearer).load();
    onlyCompany = ways.ways.length == 1 && ways.ways.single == SignInWay.company;
  } catch (e) {
    AppLogger.info('Delete team: how this account signs in could not be read ($e)');
  }

  final now = DateTime.now();
  String vaultName(String id) => vaults.where((v) => v.id == id).firstOrNull?.name ?? l10n.crateUnnamed;
  return TeamDeletionPreview(
    vaults: vaults,
    people: [...people.where((p) => p.me), ...people.where((p) => !p.me)],
    invitations: invitations,
    codes: codes,
    recordedVaults: [
      for (final c in record.crates.values)
        if (c.sessionLogs) vaultName(c.id),
    ],
    history: record.tracking.history,
    activity: record.tracking.activity,
    authorities: [
      for (final c in record.crates.values)
        if (c.ca != null) (vault: vaultName(c.id), latest: now.add(Duration(minutes: c.ca!.ttlMinutes))),
    ],
    companySignIn: companySignIn,
    directory: directory,
    eventExport: record.eventExport != null,
    seats: seats,
    business: business,
    businessRenews: renews,
    onlyCompanySignIn: onlyCompany,
    firstNewKind: !record.newKindsUsed,
  );
}

/// Every vault of [orchard] on this device, with what is in it.
Future<List<TeamDeletionVault>> _vaultsIn(AppDatabase db, OrchardSummary orchard, AppLocalizations l10n) async {
  // An item not placed in a vault yet (made here, not sent) is in this
  // device's default vault, as everywhere in the app (CratePlacement.crateOf).
  final info = await db.customSelect('SELECT default_crate_id FROM orchard_info WHERE id = 1').getSingleOrNull();
  final fallback = info?.read<String?>('default_crate_id');
  final counts = <String, Map<String, int>>{};
  final names = <String, Map<String, List<String>>>{};
  for (final kind in kTeamDeleteKinds) {
    final (table, id, name) = _kindNames[kind]!;
    try {
      for (final r in await db.customSelect(
        'SELECT COALESCE(m.crate_id, ?) AS c, $name AS n FROM $table t '
        'LEFT JOIN crate_items_meta m ON m.kind = ? AND m.item_key = t.$id '
        'WHERE COALESCE(m.server_deleted, 0) = 0',
        variables: [Variable(fallback), Variable(kind)],
      ).get()) {
        final crate = r.read<String?>('c');
        if (crate == null) continue;
        final byKind = counts.putIfAbsent(crate, () => {});
        byKind[kind] = (byKind[kind] ?? 0) + 1;
        final shown = r.read<String?>('n')?.trim();
        if (shown != null && shown.isNotEmpty) names.putIfAbsent(crate, () => {}).putIfAbsent(kind, () => []).add(shown);
      }
    } catch (e) {
      // A kind this database does not hold: nothing of it to name.
      AppLogger.info('Delete team: items of one kind could not be read ($e)');
    }
  }
  return [
    for (final crate in orchard.crates)
      TeamDeletionVault(
        id: crate.id,
        name: crateDisplayName(crate, l10n),
        counts: {...?counts[crate.id]},
        names: {
          for (final MapEntry(key: kind, value: all) in (names[crate.id] ?? const <String, List<String>>{}).entries)
            kind: (all..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))).take(kTeamDeleteNamesShown).toList(),
        },
      ),
  ];
}

/// [kind]'s count in words: "42 hosts".
String teamDeleteCountText(String kind, int n, AppLocalizations l10n) => switch (kind) {
      'host' => l10n.teamDeleteHosts(n),
      'key' => l10n.teamDeleteKeys(n),
      'snippet' => l10n.teamDeleteSnippets(n),
      'forward' => l10n.teamDeleteForwards(n),
      'group' => l10n.teamDeleteGroups(n),
      'network' => l10n.teamDeleteNetworks(n),
      'trigger' => l10n.teamDeleteTriggers(n),
      _ => l10n.teamDeleteHostKeys(n),
    };

/// A name of [kind] as the confirmation shows it, masked while recording.
String _shownName(String kind, String name, WidgetRef ref) => switch (kind) {
      'host' => Redactable.host(name).displayIn(ref),
      'key' => Redactable.keyName(name).displayIn(ref),
      kHostKeyKind => Redactable.address(name).displayIn(ref),
      _ => Redactable.freeText(name).displayIn(ref),
    };

/// Delete [orchard] for everyone (owners): the confirmation that
/// names what goes, then the signed team.delete, with a sign-in from the
/// last ten minutes and two-step where the team's rules want it. [onOpenSetup]
/// opens the Setup page, to save the team as a file first. True when it was
/// asked.
Future<bool> deleteTeamFlow(BuildContext context, WidgetRef ref, OrchardSummary orchard,
    {VoidCallback? onOpenSetup}) async {
  final l10n = AppLocalizations.of(context)!;
  final name = orchardDisplayName(orchard.name, l10n);
  final go = await showZestModal<_DeleteChoice>(
    context: context,
    size: ZestModalSize.large,
    child: _TeamDeleteDialog(orchard: orchard, name: name),
  );
  if (go == _DeleteChoice.openSetup) {
    onOpenSetup?.call();
    return false;
  }
  if (go != _DeleteChoice.delete || !context.mounted) return false;
  final service = ref.read(orchardServiceProvider);
  TeamDeletion? asked;
  try {
    final ran = await withRecentSignIn(
      context,
      ref,
      () async => asked = await service.deleteTeam(orchard.id),
      summary: (what: l10n.stepUpDeleteTeam(name), effects: [l10n.teamDeleteIntro]),
      window: StepUpWindow.account,
    );
    if (!ran || asked == null) return false;
  } catch (e) {
    AppLogger.warning('Delete team: not asked ($e)');
    if (context.mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    return false;
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
  if (context.mounted) {
    showTopSnackBar(context, l10n.teamDeletedToast(name, teamDeletionDay(asked!.purgeAt, l10n)), isWarning: true);
  }
  return true;
}

/// Undo deleting [orchard] before its day (owners and admins): everyone is let back in.
Future<void> undoTeamDeletion(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final name = orchardDisplayName(orchard.name, l10n);
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.info,
    title: l10n.teamUndoTitle(name),
    body: l10n.teamUndoBody,
    confirmLabel: l10n.teamUndoConfirm,
  );
  if (go != true || !context.mounted) return;
  try {
    final ran = await withRecentSignIn(
      context,
      ref,
      () => ref.read(orchardServiceProvider).restoreTeam(orchard.id),
      summary: (what: l10n.stepUpUndoDelete(name), effects: const []),
    );
    if (ran && context.mounted) showTopSnackBar(context, l10n.teamKeptToast(name), isSuccess: true);
  } catch (e) {
    AppLogger.warning('Delete team: not undone ($e)');
    if (context.mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
}

/// Leaves [orchard] from its banner while it is being deleted: the Tree comes
/// on screen first, since the team's database closes and leaves this device.
Future<void> leaveTeamBeingDeleted(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final name = orchardDisplayName(orchard.name, l10n);
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.orchardLeaveTitle(name),
    body: l10n.orchardLeaveBody,
    confirmLabel: l10n.orchardLeaveConfirm,
  );
  if (go != true || !context.mounted) return;
  try {
    final space = ref.read(activeSpaceProvider);
    if (space is OrchardSpace && space.orchardId == orchard.id) {
      await ref.read(spaceControllerProvider).switchTo(const TreeSpace());
    }
    await ref.read(orchardServiceProvider).leaveOrchard(orchard.id);
    if (context.mounted) showTopSnackBar(context, l10n.orchardLeftToast(name), isSuccess: true);
  } catch (e) {
    AppLogger.warning('Delete team: leaving did not go through ($e)');
    if (context.mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
}

/// Removes [orchard], which ZestSSH Cloud says was deleted, from this device,
/// once its person says so: the question a device asks when it did not see
/// the deletion long enough ago to do it unasked.
Future<void> removeDeletedTeamFlow(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final name = orchardDisplayName(orchard.name, l10n);
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.teamRemoveDeletedTitle(name),
    body: l10n.teamRemoveDeletedBody,
    confirmLabel: l10n.teamRemoveDeletedConfirm,
  );
  if (go != true || !context.mounted) return;
  try {
    final space = ref.read(activeSpaceProvider);
    if (space is OrchardSpace && space.orchardId == orchard.id) {
      await ref.read(spaceControllerProvider).switchTo(const TreeSpace());
    }
    await ref.read(orchardServiceProvider).removeDeletedTeam(orchard.id);
  } catch (e) {
    AppLogger.warning('Delete team: the deleted team was not removed ($e)');
    if (context.mounted) showTopSnackBar(context, orchardErrorMessage(e, l10n), isError: true, details: '$e');
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
}

/// Removes [orchard], which ZestSSH Cloud no longer lists for this account
/// while the team's signed record here still has it in, from this
/// device, once its person says so: changes not yet sent go with it.
Future<void> removeUnlistedTeamFlow(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final name = orchardDisplayName(orchard.name, l10n);
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.teamRemoveDeletedTitle(name),
    body: l10n.teamRemoveUnlistedBody,
    confirmLabel: l10n.teamRemoveDeletedConfirm,
  );
  if (go != true || !context.mounted) return;
  try {
    final space = ref.read(activeSpaceProvider);
    if (space is OrchardSpace && space.orchardId == orchard.id) {
      await ref.read(spaceControllerProvider).switchTo(const TreeSpace());
    }
    await ref.read(orchardServiceProvider).removeUnlistedTeam(orchard.id);
  } catch (e) {
    AppLogger.warning('Orchards: a team ZestSSH Cloud no longer lists was not removed (${errorKind(e)})');
    if (context.mounted) showTopSnackBar(context, orchardErrorMessage(e, l10n), isError: true, details: '$e');
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
}

/// A team's only owner chose Leave: a team needs an owner, so
/// they are offered Make someone owner (then they leave, in one go) or
/// Delete the team. [onLeft] runs once they left; [onOpenSetup] as for
/// [deleteTeamFlow].
Future<void> soleOwnerLeave(BuildContext context, WidgetRef ref, OrchardSummary orchard, OrchardPeople people,
    {VoidCallback? onLeft, VoidCallback? onOpenSetup}) async {
  final l10n = AppLocalizations.of(context)!;
  final others = [
    for (final m in people.members)
      if (!m.isMe && m.status == MemberStatus.active && !m.accountDeleted) m,
  ];
  final deleteOn = newRecordKindsOn.value;
  final choice = await ZestDialogShell.showModal<String>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.crown,
    title: l10n.teamSoleOwnerLeaveTitle,
    body: Column(
      key: const ValueKey('sole-owner-leave'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.teamSoleOwnerLeaveBody, style: TextStyle(fontSize: 13.5, height: 1.45, color: ZestTokens.textSecondary)),
        const SizedBox(height: 12),
        if (others.isNotEmpty)
          _ChoiceRow(
            key: const ValueKey('sole-owner-make-owner'),
            icon: LucideIcons.crown,
            title: l10n.teamSoleOwnerMakeOwner,
            body: l10n.teamSoleOwnerMakeOwnerBody,
            onTap: () => Navigator.of(context).pop('owner'),
          ),
        if (deleteOn)
          _ChoiceRow(
            key: const ValueKey('sole-owner-delete'),
            icon: LucideIcons.trash2,
            tone: TeamTone.critical,
            title: l10n.teamSoleOwnerDelete,
            body: l10n.teamSoleOwnerDeleteBody,
            onTap: () => Navigator.of(context).pop('delete'),
          ),
        if (others.isEmpty && !deleteOn)
          Text(l10n.orchardErrorFeatureNotYet(kNewRecordKindsVersion),
              style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
      ],
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
  );
  if (!context.mounted) return;
  if (choice == 'delete') {
    await deleteTeamFlow(context, ref, orchard, onOpenSetup: onOpenSetup);
    return;
  }
  if (choice != 'owner') return;
  final uid = await ZestDialogShell.showModal<String>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.crown,
    title: l10n.teamSoleOwnerPickTitle,
    body: Column(
      key: const ValueKey('sole-owner-pick'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in others)
          _ChoiceRow(
            key: ValueKey('sole-owner-pick-${m.uid}'),
            icon: LucideIcons.user,
            title: Redactable.account(m.name ?? m.email ?? shortMemberId(m.uid)).displayIn(ref),
            body: m.name != null && m.email != null ? Redactable.account(m.email!).displayIn(ref) : null,
            onTap: () => Navigator.of(context).pop(m.uid),
          ),
      ],
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
  );
  if (uid == null || !context.mounted) return;
  final service = ref.read(orchardServiceProvider);
  final name = orchardDisplayName(orchard.name, l10n);
  // Only a member this person has compared safety words with can be made an
  // owner. Compared first, here: the change used to go to the sign-in
  // from the last ten minutes and only then fail with "compare first", with
  // nothing changed.
  final picked = others.firstWhere((m) => m.uid == uid);
  if (!_comparedByMe(picked) && !await _compareBeforeOwner(context, ref, orchard, people, picked)) return;
  if (!context.mounted) return;
  try {
    final ran = await withRecentSignIn(
      context,
      ref,
      () => service.makeOwner(orchard.id, uid, stepDown: true),
      summary: (what: l10n.stepUpMakeOwnerAndLeave, effects: const []),
    );
    if (!ran || !context.mounted) return;
    final space = ref.read(activeSpaceProvider);
    if (space is OrchardSpace && space.orchardId == orchard.id) {
      await ref.read(spaceControllerProvider).switchTo(const TreeSpace());
    }
    await service.leaveOrchard(orchard.id);
    if (context.mounted) showTopSnackBar(context, l10n.orchardLeftToast(name), isSuccess: true);
    onLeft?.call();
  } catch (e) {
    AppLogger.warning('Sole owner: making an owner and leaving did not go through ($e)');
    if (context.mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
}

/// Whether this person has compared safety words with [p] for the keys
/// they have now (what Members goes by too).
bool _comparedByMe(OrchardPerson p) =>
    p.trust != null && p.trust!.verifiedByMe && !p.trust!.hardStop && p.trust!.fingerprint != null;

/// Asks the only owner, who picked [p] to become the owner, to compare
/// safety words with them first, as Members does before Make owner, and
/// saves the check. True when [p] is compared now.
Future<bool> _compareBeforeOwner(
    BuildContext context, WidgetRef ref, OrchardSummary orchard, OrchardPeople people, OrchardPerson p) async {
  final l10n = AppLocalizations.of(context)!;
  final name = Redactable.account(p.name ?? p.email ?? shortMemberId(p.uid)).displayIn(ref);
  final trust = p.trust;
  final fingerprint = trust?.pending?.fingerprint ?? trust?.fingerprint;
  if (trust == null || fingerprint == null) {
    // No keys of theirs on this device to compare: say so, before any sign-in.
    showTopSnackBar(context, l10n.orchardPromoteCompareTitle(name), isError: true, details: 'MemberNotCompared');
    return false;
  }
  final matched = await ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.standard,
    tone: trust.hardStop ? ZestDialogTone.warning : ZestDialogTone.info,
    icon: trust.hardStop ? LucideIcons.shieldAlert : LucideIcons.fingerprint,
    title: l10n.orchardPromoteCompareTitle(name),
    body: Column(
      key: const ValueKey('sole-owner-compare'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (trust.hardStop) ...[
          ZestCallout(l10n.orchardKeyChangedBody(name), icon: LucideIcons.shieldAlert),
          const SizedBox(height: 12),
        ],
        Text(l10n.orchardPromoteCompareBody,
            style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
        const SizedBox(height: 14),
        CompareCodes(
          theirs: fingerprint,
          name: name,
          mine: people.members.where((m) => m.isMe).firstOrNull?.trust?.fingerprint,
          onScanMatch: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
    primaryAction: (
      label: l10n.orchardVerifyMatch,
      onPressed: () => Navigator.of(context).pop(true),
      icon: LucideIcons.check,
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
  );
  if (matched != true || !context.mounted) return false;
  try {
    await ref.read(orchardServiceProvider).verifyMember(orchard.id, p.uid);
    return true;
  } catch (e) {
    AppLogger.warning('Sole owner: the check was not saved ($e)');
    if (context.mounted) showTopSnackBar(context, l10n.orchardVerifyFailed, isError: true, details: '$e');
    return false;
  }
}

enum _DeleteChoice { delete, openSetup }

class _TeamDeleteDialog extends ConsumerStatefulWidget {
  const _TeamDeleteDialog({required this.orchard, required this.name});

  final OrchardSummary orchard;
  final String name;

  @override
  ConsumerState<_TeamDeleteDialog> createState() => _TeamDeleteDialogState();
}

class _TeamDeleteDialogState extends ConsumerState<_TeamDeleteDialog> {
  final _typed = TextEditingController();
  late final Future<TeamDeletionPreview> _preview =
      readTeamDeletionPreview(ref, widget.orchard, AppLocalizations.of(context)!);
  final _open = <String>{};

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  /// What the owner types to confirm: the team's name, or for a team whose
  /// name does not read on this device, the words it is shown by ("Unnamed
  /// team"). With no name, nothing typed could match and the team could
  /// never be deleted from this device.
  String _confirmWord(AppLocalizations l10n) {
    final name = (widget.orchard.name ?? '').trim();
    return name.isEmpty ? l10n.orchardUnnamed : name;
  }

  bool _named(AppLocalizations l10n) => _typed.text.trim() == _confirmWord(l10n);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<TeamDeletionPreview>(
      future: _preview,
      builder: (context, snap) {
        final preview = snap.data;
        return ZestDialogShell(
          size: ZestModalSize.large,
          tone: ZestDialogTone.destructive,
          icon: LucideIcons.trash2,
          title: l10n.teamDeleteTitle(widget.name),
          subtitle: l10n.teamDeleteIntro,
          onClose: () => Navigator.of(context).pop(),
          body: switch (snap) {
            AsyncSnapshot(hasError: true) => TeamLoadProblem(
                title: l10n.teamDeleteReadFailed,
                error: snap.error!,
                stack: snap.stackTrace,
                where: 'Delete team: reading what the team holds',
              ),
            _ when preview == null => Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.textSecondary)),
              ),
            _ => _body(context, preview, l10n),
          },
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
          primaryAction: (
            label: l10n.teamDeleteConfirm(widget.name),
            onPressed: preview != null && _named(l10n) ? () => Navigator.of(context).pop(_DeleteChoice.delete) : null,
            icon: LucideIcons.trash2,
          ),
          primaryDanger: true,
        );
      },
    );
  }

  Widget _body(BuildContext context, TeamDeletionPreview p, AppLocalizations l10n) {
    final muted = TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary);
    final strong = TextStyle(fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary);
    Widget section(String title, List<Widget> children, {Key? key}) => Padding(
          key: key,
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Text(title, style: strong), const SizedBox(height: 8), ...children],
          ),
        );
    Widget row(IconData icon, String title, String? body, {Key? key}) => Padding(
          key: key,
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TeamIconTile(icon: icon, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                    if (body != null) Text(body, style: muted),
                  ],
                ),
              ),
            ],
          ),
        );
    final shownPeople = p.people.take(kTeamDeletePeopleShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Every vault, and what is in it by name.
        section(l10n.teamDeleteVaults(p.vaults.length), [
          for (final v in p.vaults) _vault(v, l10n, muted),
        ], key: const ValueKey('team-delete-vaults')),
        section(l10n.teamDeletePeople(p.people.length), [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final person in shownPeople)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(person.me ? l10n.teamDeleteYouName(person.name) : person.name,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              if (p.people.length > shownPeople.length)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(l10n.teamDeletePeopleMore(p.people.length - shownPeople.length),
                      style: const TextStyle(fontSize: 12.5)),
                ),
            ],
          ),
          if ((p.invitations ?? 0) > 0) ...[const SizedBox(height: 6), Text(l10n.teamDeleteInvitesWaiting(p.invitations!), style: muted)],
          if ((p.codes ?? 0) > 0) ...[const SizedBox(height: 4), Text(l10n.teamDeleteCodesWaiting(p.codes!), style: muted)],
        ], key: const ValueKey('team-delete-people')),
        section(l10n.teamDeleteCloudTitle, [
          if (p.recordedVaults.isNotEmpty)
            row(LucideIcons.video, l10n.teamDeleteSessionLogs,
                l10n.teamDeleteSessionLogsBody(p.recordedVaults.join(l10n.listSeparator))),
          if (p.history) row(LucideIcons.history, l10n.teamDeleteHistory, l10n.teamDeleteHistoryBody),
          if (p.activity) row(LucideIcons.activity, l10n.teamDeleteActivity, l10n.teamDeleteActivityBody),
          for (final a in p.authorities)
            row(LucideIcons.badgeCheck, l10n.teamDeleteAuthority(a.vault),
                l10n.teamDeleteAuthorityBody(teamDeletionDay(a.latest, l10n)),
                key: ValueKey('team-delete-ca-${a.vault}')),
          if (p.companySignIn != null)
            row(LucideIcons.building2, l10n.teamDeleteSignIn, l10n.teamDeleteSignInBody(p.companySignIn!),
                key: const ValueKey('team-delete-sso')),
          if (p.directory) row(LucideIcons.users, l10n.teamDeleteDirectory, l10n.teamDeleteDirectoryBody),
          if (p.eventExport) row(LucideIcons.send, l10n.teamDeleteExport, l10n.teamDeleteExportBody),
          row(LucideIcons.scrollText, l10n.teamDeleteRecord, l10n.teamDeleteRecordBody),
        ], key: const ValueKey('team-delete-cloud')),
        section(l10n.teamDeleteSeatsTitle, [
          if (p.seats != null) Text(l10n.teamDeleteSeatsBody(p.seats!), style: muted),
          if (p.business)
            Text(
                p.businessRenews == null
                    ? l10n.teamDeleteBusinessBody
                    : l10n.teamDeleteBusinessRenewsBody(teamDeletionDay(p.businessRenews!, l10n)),
                style: muted),
          const SizedBox(height: 4),
          Text(l10n.teamDeleteNoRefund, key: const ValueKey('team-delete-no-refund'), style: muted),
        ], key: const ValueKey('team-delete-seats')),
        if (p.onlyCompanySignIn || p.companySignIn != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TeamCallout(
              key: const ValueKey('team-delete-sso-warning'),
              tone: TeamTone.warning,
              icon: LucideIcons.logIn,
              title: p.onlyCompanySignIn ? l10n.teamDeleteOnlySso : l10n.teamDeleteSsoOthers,
            ),
          ),
        section(l10n.teamDeleteKeptTitle, [
          Text(l10n.teamDeleteKeptPersonal, style: muted),
          const SizedBox(height: 4),
          Text(l10n.teamDeleteKeptFiles, style: muted),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('team-delete-save-file'),
              icon: const Icon(LucideIcons.fileDown, size: 16),
              label: Text(l10n.teamDeleteSaveFile),
              onPressed: () => Navigator.of(context).pop(_DeleteChoice.openSetup),
            ),
          ),
        ], key: const ValueKey('team-delete-kept')),
        if (p.firstNewKind)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(l10n.teamDeleteOlderVersions(kNewRecordKindsVersion),
                key: const ValueKey('team-delete-older'), style: muted),
          ),
        const SizedBox(height: 16),
        Text(l10n.teamDeleteTypeName(_confirmWord(l10n)), style: strong),
        const SizedBox(height: 6),
        TeamField(
          key: const ValueKey('team-delete-name'),
          fieldKey: const ValueKey('team-delete-name-field'),
          controller: _typed,
          hint: _confirmWord(l10n),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _vault(TeamDeletionVault v, AppLocalizations l10n, TextStyle muted) {
    final open = _open.contains(v.id);
    final summary = v.items == 0
        ? l10n.teamDeleteVaultEmpty
        : [for (final k in kTeamDeleteKinds) if ((v.counts[k] ?? 0) > 0) teamDeleteCountText(k, v.counts[k]!, l10n)]
            .join(l10n.listSeparator);
    return Container(
      key: ValueKey('team-delete-vault-${v.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: v.items == 0 ? null : () => setState(() => open ? _open.remove(v.id) : _open.add(v.id)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(open ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                      size: 16, color: v.items == 0 ? ZestTokens.textTertiary : ZestTokens.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(v.name,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                        Text(summary, style: muted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final k in kTeamDeleteKinds)
                    if ((v.names[k] ?? const []).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(teamDeleteCountText(k, v.counts[k] ?? 0, l10n),
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary)),
                      for (final n in v.names[k]!) Text(_shownName(k, n, ref), style: muted),
                      if ((v.counts[k] ?? 0) > v.names[k]!.length)
                        Text(l10n.teamDeleteMore((v.counts[k] ?? 0) - v.names[k]!.length), style: muted),
                    ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A choice in a short list: an icon, what it does and a line on it.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({super.key, required this.icon, required this.title, this.body, required this.onTap, this.tone = TeamTone.info});

  final IconData icon;
  final String title;
  final String? body;
  final VoidCallback onTap;
  final TeamTone tone;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TeamIconTile(icon: icon, tone: tone),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                        if (body != null)
                          Text(body!, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary)),
                      ],
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: 16, color: ZestTokens.textTertiary),
                ],
              ),
            ),
          ),
        ),
      );
}
