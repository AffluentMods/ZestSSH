import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_held_back.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_attention.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/orchards/widgets/crate_authority_view.dart';
import 'package:zestssh/features/orchards/widgets/join_review.dart'
    show CodeUsedAttentionRow, InviteView, teamInvitesProvider, teamJoiningCount;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_access_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_device_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_directory_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_recovery_view.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// The Team page's Overview (3.0): where this account stands
/// (the status banner), a nudge towards a second owner, the Orchard at a
/// glance, what about its people needs this account, access for a set time
/// (who asks, what runs, and asking or giving), and the latest changes
/// to its record. Everything comes from this device's copy of the Orchard,
/// but the requests for access, which wait on ZestSSH Cloud.
/// What the Overview's Needs attention lists for [orchard], and so what the
/// Team page's Overview badge counts ([teamAttentionRowCount]): worked out
/// in one place, as the two had come apart (the badge left out team
/// recovery, the one owner and each used invite code).
///
({
  List<TeamAttention> attention,
  List<InviteView> codesUsed,
  int directoryWaiting,
  List<AccessRequestView> asking,
  List<DeviceRequestView> devices,
  bool soleOwner,
  List<RecoveryWait> recovery,
  List<HeldBackItem> heldBack,
}) teamAttentionRows(WidgetRef ref, OrchardSummary orchard, {required int nowSeconds}) {
  final people = ref.watch(teamPeopleProvider(orchard.id)).valueOrNull;
  // Who waits for team recovery, for owners.
  final recovery = orchard.isOwner
      ? ref.watch(teamRecoveryStatusProvider(orchard.id)).valueOrNull?.waiting ?? const <RecoveryWait>[]
      : const <RecoveryWait>[];
  // Certificate authorities that need a new key, for owners.
  final authorities = orchard.isOwner
      ? ref.watch(crateAuthoritiesProvider(orchard.id)).valueOrNull ?? const <String, CrateAuthorityView>{}
      : const <String, CrateAuthorityView>{};
  final allAttention = teamAttention(
      orchard: orchard, people: people, nowSeconds: nowSeconds, recovery: recovery, authorities: authorities);
  // Invite codes someone used, a row each, to review or turn away;
  // invitations to an address that
  // were accepted stay one row together.
  final codesUsed = orchard.canInvite && orchard.active
      ? [
          for (final v in ref.watch(teamInvitesProvider(orchard.id)).valueOrNull ?? const <InviteView>[])
            if (v.waiting && v.invite.byCode) v,
        ]
      : const <InviteView>[];
  final attention = [
    for (final a in allAttention)
      if (a.kind != TeamAttentionKind.invitesWaiting)
        a
      else if (a.count > codesUsed.length)
        TeamAttention(a.kind, count: a.count - codesUsed.length),
  ];
  // What the company's directory asks for, for owners and admins.
  final directoryWaiting =
      ref.watch(orchardDirectoryProvider(directoryReaderOf(orchard))).valueOrNull?.pending.length ?? 0;
  // Access for a set time: the requests this account can answer.
  final asking = people == null
      ? const <AccessRequestView>[]
      : ref.watch(accessRequestsProvider(orchard.id)).valueOrNull?.waiting ?? const <AccessRequestView>[];
  // Devices that ask to be approved, which this account could
  // approve from this device.
  final devices = people == null
      ? const <DeviceRequestView>[]
      : ref.watch(deviceRequestsProvider(orchard.id)).valueOrNull ?? const <DeviceRequestView>[];
  // Items a new device shows no copy of, for the owners and admins who may do
  // something about them, and nobody else.
  final heldBack = orchard.role == FixedRoles.owner || orchard.role == FixedRoles.admin
      ? [
          for (final item in ref.watch(teamHeldBackProvider(orchard.id)).valueOrNull ?? const <HeldBackItem>[])
            if (item.mayAct) item,
        ]
      : const <HeldBackItem>[];
  return (
    attention: attention,
    codesUsed: codesUsed,
    directoryWaiting: directoryWaiting,
    asking: asking,
    devices: devices,
    // The one owner: a row of its own among what needs this account (it was
    // a callout above the stats).
    soleOwner: people?.soleOwner ?? false,
    recovery: recovery,
    heldBack: heldBack,
  );
}

/// How many rows the Overview's Needs attention shows: the Team page's
/// Overview badge.
int teamAttentionRowCount(WidgetRef ref, OrchardSummary orchard) {
  final r = teamAttentionRows(ref, orchard, nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000);
  return r.attention.length +
      r.codesUsed.length +
      (r.directoryWaiting > 0 ? 1 : 0) +
      r.asking.length +
      r.devices.length +
      (r.soleOwner ? 1 : 0) +
      (r.heldBack.isNotEmpty ? 1 : 0);
}

class TeamOverview extends ConsumerWidget {
  const TeamOverview({super.key, required this.orchard, this.onOpen});

  final OrchardSummary orchard;

  /// Opens another Team page (a phone pushes it); by default the desktop's
  /// Team destination turns to it.
  final void Function(TeamPage page)? onOpen;

  /// How many of the record's changes the Overview lists.
  static const recentCount = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final peopleAsync = ref.watch(teamPeopleProvider(orchard.id));
    final people = peopleAsync.valueOrNull;
    final recordAsync = ref.watch(teamRecordProvider(orchard.id));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final (:attention, :codesUsed, :directoryWaiting, :asking, :devices, :soleOwner, :recovery, :heldBack) =
        teamAttentionRows(ref, orchard, nowSeconds: now);
    // Access for a set time: this account's own requests, and what
    // runs, are listed below.
    final requests = ref.watch(accessRequestsProvider(orchard.id)).valueOrNull;
    void go(TeamPage page) => onOpen != null ? onOpen!(page) : ref.read(teamPageProvider.notifier).state = page;

    String nameOf(String? uid) {
      if (uid == null) return '';
      final email = recordAsync.valueOrNull?.emails[uid] ??
          people?.members.where((m) => m.uid == uid).firstOrNull?.email;
      return Redactable.account(email ?? shortMemberId(uid)).displayIn(ref);
    }

    final nothing =
        attention.isEmpty && codesUsed.isEmpty && directoryWaiting == 0 && asking.isEmpty && devices.isEmpty && !soleOwner && heldBack.isEmpty;

    final attentionCount = attention.length +
        codesUsed.length +
        (directoryWaiting > 0 ? 1 : 0) +
        asking.length +
        devices.length +
        (soleOwner ? 1 : 0) +
        (heldBack.isNotEmpty ? 1 : 0);
    // Needs attention first, with its actions (4.0):
    // the only part that asks for
    // something.
    final needsAttention = <Widget>[
      _SectionTitle(
        l10n.teamAttentionTitle,
        key: const ValueKey('team-attention-title'),
        first: true,
        count: attentionCount,
      ),
      _Panel(
        key: const ValueKey('team-attention'),
        children: [
          for (final v in codesUsed)
            CodeUsedAttentionRow(
              key: ValueKey('team-attn-code-${v.invite.id}'),
              orchard: orchard,
              view: v,
              // On a computer the review opens beside the Members list; a
              // phone keeps its sheet.
              onReview: onOpen != null
                  ? null
                  : () {
                      ref.read(teamReviewToOpenProvider.notifier).state = v.invite.id;
                      go(TeamPage.members);
                    },
            ),
          if (directoryWaiting > 0)
            _Row(
              key: const ValueKey('team-attn-directory'),
              icon: LucideIcons.building2,
              tone: TeamTone.info,
              title: l10n.directoryAttention(directoryWaiting),
              action: (label: l10n.directoryReview, onPressed: () => showOrchardDirectoryQueue(context, ref, orchard)),
            ),
          if (heldBack.isNotEmpty)
            _Row(
              key: const ValueKey('team-attn-held-back'),
              icon: LucideIcons.copy,
              tone: TeamTone.info,
              quiet: true,
              title: l10n.teamAttnHeldBack(heldBack.length),
              action: (label: l10n.teamReview, onPressed: () => showHeldBackItems(context, ref, orchard)),
            ),
          for (final r in asking)
            _Row(
              key: ValueKey('team-attn-access-${r.id}'),
              icon: LucideIcons.keyRound,
              tone: TeamTone.info,
              person: nameOf(r.uid),
              title: l10n.accessRequestTitle(nameOf(r.uid)),
              body: [
                accessRequestSummary(r, orchard, l10n),
                if (r.note != null) r.note! else if (r.noteUnread) l10n.accessRequestNoteUnread,
              ].join('\n'),
              action: (
                label: l10n.accessAnswer,
                onPressed: () => showGiveAccess(context, ref, orchard, people!, request: r),
              ),
            ),
          for (final r in devices)
            _Row(
              key: ValueKey('team-attn-device-${r.id}'),
              icon: LucideIcons.monitorSmartphone,
              tone: TeamTone.info,
              title: r.uid == people!.me ? l10n.deviceRequestTitleOwn : l10n.deviceRequestTitle(nameOf(r.uid)),
              body: l10n.deviceRequestRowBody,
              action: (
                label: l10n.teamReview,
                onPressed: () =>
                    showDeviceRequest(context, ref, orchard, r, name: nameOf(r.uid), own: r.uid == people.me),
              ),
            ),
          // The members could not be read: said with why and its code,
          // Retry and Copy details, never as "nothing needs you" (it was
          // the success row with the words of the failure).
          if (peopleAsync.hasError && people == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: TeamLoadProblem(
                title: l10n.orchardMembersLoadFailed,
                error: peopleAsync.error!,
                stack: peopleAsync.stackTrace,
                where: 'Team overview: reading the members',
                onRetry: peopleAsync.isLoading ? null : () => ref.invalidate(teamPeopleProvider(orchard.id)),
              ),
            )
          else if (nothing)
            _Row(
              icon: LucideIcons.checkCircle2,
              tone: TeamTone.success,
              title: l10n.teamAttentionNone,
            )
          else
            for (final a in attention)
              _attentionRow(context, a, nameOf, go,
                  me: people?.me,
                  onRecovery: (uid) {
                    final wait = recovery.where((w) => w.uid == uid).firstOrNull;
                    if (wait != null) showRecoveryReview(context, ref, orchard, wait);
                  },
                  crateName: (id) {
                    final c = orchard.crates.where((c) => c.id == id).firstOrNull;
                    return c == null ? l10n.crateUnnamed : crateDisplayName(c, l10n);
                  },
                  onAuthority: (crateId) => showCrateAuthority(context, ref, orchard.id, crateId)),
          if (soleOwner)
            _Row(
              key: const ValueKey('team-sole-owner'),
              icon: LucideIcons.crown,
              tone: TeamTone.warning,
              title: l10n.teamAttnSoleOwner,
              body: l10n.teamAttnSoleOwnerBody,
              actionKey: const ValueKey('team-callout-action'),
              action: (label: l10n.teamAddSecondOwner, onPressed: () => go(TeamPage.members)),
            ),
        ],
      ),
    ];
    // The counts, quiet, each saying something and opening its page.
    Widget glance({required bool first}) => Column(
          key: const ValueKey('team-glance'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionTitle(l10n.teamAtAGlance, key: const ValueKey('team-glance-title'), first: first),
            _Glance(
              orchard: orchard,
              people: people,
              onOpen: (page) => page == null
                  ? ref.read(activeSidebarNavProvider.notifier).state = NavSection.hosts
                  : go(page),
            ),
          ],
        );
    final rest = <Widget>[
      _AccessSection(orchard: orchard, people: people, mine: requests?.mine ?? const [], nameOf: nameOf),
      _ChangeNext(orchard: orchard, nameOf: nameOf),
      // "See all in Trust"; on a phone, where the title leaves less room,
      // "See all".
      LayoutBuilder(
        builder: (context, box) => _SectionTitle(
          l10n.teamRecentTitle,
          trailing: _SectionLink(
            key: const ValueKey('team-see-all'),
            label: box.maxWidth < kTeamNarrowWidth ? l10n.teamSeeAll : l10n.teamSeeAllInTrust,
            trailingIcon: LucideIcons.chevronRight,
            onPressed: () => go(TeamPage.trust),
          ),
        ),
      ),
      switch (recordAsync) {
        // A plain list, a hairline between its rows (it was one more box).
        AsyncData(:final value) => Container(
            key: const ValueKey('team-recent'),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestColors.borderSubtle))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final c in value.changes.reversed.take(recentCount))
                  _ChangeRow(
                    change: c,
                    seen: teamSeenLabel(value.firstSeen[c.seq], l10n,
                        Localizations.localeOf(context).toLanguageTag(), DateTime.now()),
                    text: teamChangeText(c, l10n, nameOf: nameOf, crateName: (id) => teamCrateName(orchard, id, l10n),
                        roleName: (id) => orchardRoleLabel(id, l10n, names: orchardRoleNames(ref, orchard.id))),
                    by: c.by == people?.me ? l10n.teamYou : nameOf(c.by),
                  ),
              ],
            ),
          ),
        AsyncError() => _Panel(children: [
            _Row(icon: LucideIcons.alertCircle, tone: TeamTone.critical, title: l10n.teamRecordLoadFailed),
          ]),
        _ => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))),
          ),
      },
      // Rename and Delete team are on Team settings (the link at the top),
      // not on the everyday Overview.
    ];

    return LayoutBuilder(builder: (context, box) {
      // Two columns where there is room: what needs this account and what
      // runs on the left, the counts on the right; one column on a phone,
      // the counts under what needs this account.
      final wide = box.maxWidth >= kTeamOverviewTwoColumns;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OrchardStatusBanner(padding: EdgeInsets.only(bottom: 14)),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [...needsAttention, ...rest],
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(width: kTeamGlanceWidth, child: glance(first: true)),
              ],
            )
          else ...[
            ...needsAttention,
            glance(first: false),
            ...rest,
          ],
        ],
      );
    });
  }

  Widget _attentionRow(
    BuildContext context,
    TeamAttention a,
    String Function(String?) nameOf,
    void Function(TeamPage) go, {
    required String? me,
    required void Function(String uid) onRecovery,
    required String Function(String crateId) crateName,
    required void Function(String crateId) onAuthority,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final name = nameOf(a.uid);
    final review = (label: l10n.teamReview, onPressed: () => go(TeamPage.members));
    return switch (a.kind) {
      TeamAttentionKind.keysChanged => _Row(
          key: ValueKey('team-attn-keys-${a.uid}'),
          icon: LucideIcons.shieldAlert,
          tone: TeamTone.critical,
          title: l10n.teamAttnKeysChanged(name),
          body: l10n.teamAttnKeysChangedBody(name),
          action: review,
        ),
      TeamAttentionKind.authorityNewKey => _Row(
          key: ValueKey('team-attn-authority-${a.crateId}'),
          icon: LucideIcons.badgeAlert,
          tone: TeamTone.critical,
          title: l10n.teamAttnAuthorityNewKey(crateName(a.crateId!)),
          body: l10n.teamAttnAuthorityNewKeyBody,
          action: (label: l10n.teamReview, onPressed: () => onAuthority(a.crateId!)),
        ),
      TeamAttentionKind.recoveryWaiting => _Row(
          key: ValueKey('team-attn-recovery-${a.uid}'),
          icon: LucideIcons.lifeBuoy,
          tone: TeamTone.warning,
          title: l10n.teamAttnRecoveryWaiting(name),
          body: a.approvedBy.isEmpty
              ? l10n.teamAttnRecoveryWaitingBody
              : a.approvedBy.contains(me)
                  ? l10n.teamAttnRecoveryApprovedByYou
                  : l10n.teamAttnRecoveryApprovedByOther(nameOf(a.approvedBy.first)),
          action: (label: l10n.teamReview, onPressed: () => onRecovery(a.uid!)),
        ),
      TeamAttentionKind.invitesWaiting => _Row(
          key: const ValueKey('team-attn-invites'),
          icon: LucideIcons.mailCheck,
          tone: TeamTone.info,
          title: l10n.teamAttnInvites(a.count),
          body: l10n.teamAttnInvitesBody,
          action: review,
        ),
      TeamAttentionKind.accountDeleted => _Row(
          key: ValueKey('team-attn-deleted-${a.uid}'),
          icon: LucideIcons.userX,
          tone: TeamTone.warning,
          title: l10n.teamAttnAccountDeleted(name),
          body: l10n.teamAttnAccountDeletedBody,
          action: review,
        ),
      TeamAttentionKind.accessEnding => _Row(
          key: ValueKey('team-attn-ending-${a.uid}'),
          icon: LucideIcons.calendarClock,
          tone: TeamTone.info,
          title: l10n.teamAttnAccessEnding(name, accessThrough(a.endsAt!, context)),
          action: (label: l10n.teamChangeDate, onPressed: () => go(TeamPage.members)),
        ),
      TeamAttentionKind.keysReplaced => _Row(
          key: const ValueKey('team-attn-replaced'),
          icon: LucideIcons.refreshCw,
          tone: TeamTone.warning,
          title: l10n.teamAttnKeysReplaced(a.count),
          body: l10n.teamAttnKeysReplacedBody,
          action: (label: l10n.teamCompare, onPressed: () => go(TeamPage.members)),
        ),
      TeamAttentionKind.notVerified => _Row(
          key: const ValueKey('team-attn-unverified'),
          icon: LucideIcons.fingerprint,
          tone: TeamTone.warning,
          title: l10n.teamAttnNotVerified(a.count),
          body: l10n.teamAttnNotVerifiedBody,
          action: (label: l10n.teamCompare, onPressed: () => go(TeamPage.members)),
        ),
    };
  }
}

/// When this device first saw a record entry, short: today, yesterday, a
/// weekday within the week, else the date (with its year when not this
/// one); "Earlier" for entries kept before dates were noted.
String teamSeenLabel(DateTime? seen, AppLocalizations l10n, String locale, DateTime now) {
  if (seen == null) return l10n.teamSeenEarlier;
  // Whole days between the two dates, whatever the clocks did in between.
  final days = DateTime.utc(now.year, now.month, now.day)
      .difference(DateTime.utc(seen.year, seen.month, seen.day))
      .inDays;
  if (days <= 0) return l10n.teamSeenToday;
  if (days == 1) return l10n.teamSeenYesterday;
  if (days < 7) return DateFormat.EEEE(locale).format(seen);
  if (seen.year == now.year) return DateFormat.MMMd(locale).format(seen);
  return DateFormat.yMMMd(locale).format(seen);
}

/// A member's id, short, for someone whose address this device never saw.
String shortMemberId(String uid) => uid.length > 10 ? '${uid.substring(0, 10)}…' : uid;

/// A Crate's name, or "a Crate you can't open" for one this account cannot.
String teamCrateName(OrchardSummary orchard, String? id, AppLocalizations l10n) {
  final crate = orchard.crates.where((c) => c.id == id).firstOrNull;
  return crate == null ? l10n.teamCrateClosed : crateDisplayName(crate, l10n);
}

/// How many of [rules] are on.
int rulesOn(RecordRules rules) => [
      rules.require2fa,
      rules.emailDomains.isNotEmpty,
      rules.reauthSeconds > 0,
      rules.requireAppLock,
      rules.noExport,
      rules.offlineHours > 0,
      rules.requireSso,
      rules.trustedDevices,
      rules.screensSshOnly,
      rules.screensLockRedirections,
    ].where((on) => on).length;

// ── Pieces ──────────────────────────────────────────────────────────────

/// "Access for a set time" (3.0): this account's own requests that
/// wait, what it or others hold until a set time (those it could end), and
/// the way in: asking, for someone below admin, and giving, for someone who
/// manages a Crate, beside the section's title. Nothing shows for an account
/// with none of these.
class _AccessSection extends ConsumerWidget {
  const _AccessSection({required this.orchard, required this.people, required this.mine, required this.nameOf});

  final OrchardSummary orchard;
  final OrchardPeople? people;
  final List<AccessRequestView> mine;
  final String Function(String? uid) nameOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final people = this.people;
    final timed = [
      for (final t in ref.watch(timedAccessProvider(orchard.id)).valueOrNull ?? const <TimedAccess>[])
        if (t.canEnd) t,
    ];
    final canAsk = orchard.role != FixedRoles.owner && orchard.role != FixedRoles.admin;
    final canGive = people != null && OrchardAccess.accessCratesFor(people.record, people.me).isNotEmpty;
    if (!canAsk && !canGive && mine.isEmpty && timed.isEmpty) return const SizedBox.shrink();
    final me = people?.me;
    final now = DateTime.now();
    // On a computer asking and giving are links beside the title; on a
    // phone, rows of their own with the words of what they do.
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < kTeamNarrowWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(
            l10n.accessSectionTitle,
            count: mine.length + timed.length,
            trailing: !narrow && (canAsk || canGive)
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (canAsk)
                        _SectionLink(
                          key: const ValueKey('team-access-ask'),
                          icon: LucideIcons.plus,
                          label: l10n.accessAskAction,
                          onPressed: () => showAskAccess(context, ref, orchard),
                        ),
                      if (canGive)
                        _SectionLink(
                          key: const ValueKey('team-access-give'),
                          icon: LucideIcons.plus,
                          label: l10n.accessGiveAction,
                          onPressed: () => showGiveAccess(context, ref, orchard, people),
                        ),
                    ],
                  )
                : null,
          ),
          _Panel(
            key: const ValueKey('team-access'),
            children: [
              for (final r in mine)
                _Row(
                  key: ValueKey('team-access-mine-${r.id}'),
                  icon: LucideIcons.hourglass,
                  tone: TeamTone.info,
                  title: l10n.accessMineTitle,
                  body: '${accessRequestSummary(r, orchard, l10n)}\n${l10n.accessMineWaiting}',
                  action: (
                    label: l10n.accessWithdraw,
                    onPressed: () => withdrawAccessRequest(context, ref, orchard, r.id),
                  ),
                ),
              for (final t in timed)
                if (!narrow)
                  // One line (4.0): who and where, how far and until
                  // when, the time left and the button.
                  _TimedLine(
                    key: ValueKey('team-access-timed-${t.uid}-${t.crateId}'),
                    person: t.uid == me ? l10n.teamYou : nameOf(t.uid),
                    title: '${t.uid == me ? l10n.teamYou : nameOf(t.uid)} · ${teamAccessCrateName(orchard, t.crateId, l10n)}',
                    sub: [
                      crateLevelName(t.level, l10n),
                      l10n.accessUntil(accessTimeText(t.until, l10n, now: now)),
                    ].join(' · '),
                    left: accessLeftText(t.until, l10n, now: now),
                    action: (
                      label: t.uid == me ? l10n.accessGiveUp : l10n.accessEndNow,
                      onPressed: () =>
                          endTimedAccess(context, ref, orchard, t, name: nameOf(t.uid), mine: t.uid == me),
                    ),
                  )
                else
                _Row(
                  key: ValueKey('team-access-timed-${t.uid}-${t.crateId}'),
                  icon: LucideIcons.timer,
                  tone: TeamTone.info,
                  person: t.uid == me ? l10n.teamYou : nameOf(t.uid),
                  // Who, in which vault; how far (where it is more than they
                  // have there for good) and until when; the time left.
                  title: '${t.uid == me ? l10n.teamYou : nameOf(t.uid)} · ${teamAccessCrateName(orchard, t.crateId, l10n)}',
                  body: [
                    crateLevelName(t.level, l10n),
                    l10n.accessUntil(accessTimeText(t.until, l10n, now: now)),
                  ].join(' · '),
                  left: accessLeftText(t.until, l10n, now: now),
                  action: (
                    label: t.uid == me ? l10n.accessGiveUp : l10n.accessEndNow,
                    onPressed: () =>
                        endTimedAccess(context, ref, orchard, t, name: nameOf(t.uid), mine: t.uid == me),
                  ),
                ),
              if (narrow && canAsk)
                _Row(
                  key: const ValueKey('team-access-ask'),
                  icon: LucideIcons.keyRound,
                  tone: TeamTone.info,
                  title: l10n.accessAskHint,
                  quiet: true,
                  action: (label: l10n.accessAskAction, onPressed: () => showAskAccess(context, ref, orchard)),
                ),
              if (narrow && canGive)
                _Row(
                  key: const ValueKey('team-access-give'),
                  icon: LucideIcons.keyRound,
                  tone: TeamTone.info,
                  title: l10n.accessGiveHint,
                  quiet: true,
                  action: (label: l10n.accessGiveAction, onPressed: () => showGiveAccess(context, ref, orchard, people)),
                ),
              // Nothing runs or waits: what the links above do, in a line.
              if (!narrow && mine.isEmpty && timed.isEmpty)
                _Row(
                  key: const ValueKey('team-access-none'),
                  icon: LucideIcons.timer,
                  tone: TeamTone.info,
                  title: canGive ? l10n.accessGiveHint : l10n.accessAskHint,
                  quiet: true,
                ),
            ],
          ),
        ],
      );
    });
  }
}

/// How long is left of access that ends at [until] (seconds since the
/// epoch), in the shared compact words ("1h 59m left", not "1 h 59 min left"):
/// days past a day, hours and minutes
/// past an hour, else minutes.
String accessLeftText(int until, AppLocalizations l10n, {DateTime? now}) =>
    timeLeftWords(l10n, Duration(seconds: until - (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000));

/// "Change these next": for each person who lost access, the keys they
/// could use, first to change first, until each is marked changed.
class _ChangeNext extends ConsumerWidget {
  const _ChangeNext({required this.orchard, required this.nameOf});

  final OrchardSummary orchard;
  final String Function(String? uid) nameOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final items = ref.watch(teamChangeNextProvider(orchard.id)).valueOrNull ?? const <ChangeNextItem>[];
    final groups = <(String, int), List<ChangeNextItem>>{};
    for (final i in items) {
      groups.putIfAbsent((i.subjectUid, i.entrySeq), () => []).add(i);
    }
    final open = [
      for (final g in groups.entries)
        if (g.value.any((i) => !i.done)) g,
    ];
    if (open.isEmpty) return const SizedBox.shrink();
    Future<void> mark(ChangeNextItem item) async {
      await ref.read(orchardServiceProvider).markChanged(orchard.id, item);
      ref.invalidate(teamChangeNextProvider(orchard.id));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in open) ...[
          _SectionTitle(
            l10n.teamChangeNextTitle,
            trailing: Text(
              '${l10n.teamChangeNextFrom(nameOf(g.key.$1))} · '
              '${l10n.teamChangeNextLeft(g.value.where((i) => !i.done).length, g.value.length)}',
              style: TextStyle(fontSize: 12, color: ZestColors.textTertiary),
            ),
          ),
          _Panel(
            key: ValueKey('team-change-next-${g.key.$1}-${g.key.$2}'),
            children: [
              for (final i in g.value)
                if (!i.done)
                  _Row(
                    key: ValueKey('team-change-next-item-${i.keyId}'),
                    icon: i.couldReveal ? LucideIcons.eye : LucideIcons.plug,
                    tone: i.couldReveal ? TeamTone.warning : TeamTone.info,
                    title: '${i.rank}. ${Redactable.keyName(i.label).displayIn(ref)} · '
                        '${teamCrateName(orchard, i.crateId, l10n)}',
                    body: '${i.couldReveal ? l10n.teamChangeNextReveal(nameOf(i.subjectUid)) : l10n.teamChangeNextConnect(nameOf(i.subjectUid))}'
                        ' ${l10n.teamChangeNextHosts(i.hosts)}',
                    action: (label: l10n.teamMarkChanged, onPressed: () => mark(i)),
                  ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The names of the rules on in [rules], in the order the Rules page lists
/// them (as many as [rulesOn] counts).
List<String> rulesOnNames(RecordRules rules, AppLocalizations l10n) => [
      if (rules.require2fa) l10n.orchardRulesTwoStep,
      if (rules.emailDomains.isNotEmpty) l10n.orchardRulesDomains,
      if (rules.reauthSeconds > 0) l10n.orchardRulesReauth,
      if (rules.requireAppLock) l10n.orchardRulesAppLock,
      if (rules.noExport) l10n.orchardRulesNoExport,
      if (rules.offlineHours > 0) l10n.orchardRulesOffline,
      if (rules.requireSso) l10n.orchardRulesRequireSso,
      if (rules.trustedDevices) l10n.orchardRulesDevices,
      if (rules.screensSshOnly) l10n.orchardRulesScreensSshOnly,
      if (rules.screensLockRedirections) l10n.orchardRulesScreensNoSharing,
    ];

/// Below this width the Overview stacks: a row's button goes under its
/// words, and the stats go two by two (a phone's Team page).
const kTeamNarrowWidth = 520.0;

/// From this width the Overview is two columns: what needs this account on
/// the left, At a glance on the right.
const kTeamOverviewTwoColumns = 760.0;

/// How wide At a glance is beside the rest.
const kTeamGlanceWidth = 312.0;

/// [words] with [button] beside them, or under them when narrow.
Widget _wordsAndButton({required Widget icon, required Widget words, Widget? button}) {
  return LayoutBuilder(builder: (context, constraints) {
    if (button == null || constraints.maxWidth >= kTeamNarrowWidth) {
      return Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Expanded(child: words),
          if (button != null) ...[const SizedBox(width: 12), button],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [words, const SizedBox(height: 8), button],
          ),
        ),
      ],
    );
  });
}

/// "At a glance" (4.0): the
/// members and who waits to join, the vaults and how many only owners open,
/// the hosts in each vault, the rules on and which. Quiet rows, each a
/// number, what it counts and one line that says something, opening its
/// page. (It was four large cards across the top, the hosts' line cut.)
class _Glance extends ConsumerWidget {
  const _Glance({required this.orchard, required this.people, required this.onOpen});

  final OrchardSummary orchard;
  final OrchardPeople? people;

  /// The page a row opens; null for the Hosts page.
  final void Function(TeamPage? page) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final record = people?.record;
    final crates = record?.crates.length ?? orchard.crates.length;
    final ownersOnly = orchard.crates.where((c) => c.ownersOnly).length;
    final rules = record?.rules ?? orchard.rules;
    final ruleNames = rulesOnNames(rules, l10n);
    final joining = teamJoiningCount(ref, orchard);
    final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull;
    // How many of the hosts are in each vault this device opens: the team's
    // first vault first, then by name.
    final placed = ref.watch(hostCratesProvider).valueOrNull ?? const <String, String>{};
    final perCrate = <String, int>{};
    for (final h in hosts ?? const <ConnectionWithDetails>[]) {
      final crate = placed[h.connection.id];
      if (crate != null) perCrate[crate] = (perCrate[crate] ?? 0) + 1;
    }
    final vaults = [...orchard.crates]..sort((a, b) {
        if (a.id == orchard.defaultCrateId) return -1;
        if (b.id == orchard.defaultCrateId) return 1;
        return crateDisplayName(a, l10n).toLowerCase().compareTo(crateDisplayName(b, l10n).toLowerCase());
      });
    final hostsSub = [
      for (final c in vaults)
        // A vault's name and its count kept together where the line wraps.
        if ((perCrate[c.id] ?? 0) > 0) '${Redactable.group(crateDisplayName(c, l10n)).displayIn(ref)}\u00a0${perCrate[c.id]}',
    ];
    final rows = [
      _GlanceRow(
        key: const ValueKey('team-stat-members'),
        label: l10n.orchardMembers,
        value: people == null ? null : '${people!.members.length}',
        sub: joining > 0 ? l10n.teamStatJoining(joining) : null,
        onTap: () => onOpen(TeamPage.members),
      ),
      _GlanceRow(
        key: const ValueKey('team-stat-crates'),
        label: l10n.orchardCrates,
        value: '$crates',
        sub: ownersOnly > 0 ? l10n.teamStatOwnersOnly(ownersOnly) : null,
        onTap: orchard.active ? () => onOpen(TeamPage.crates) : null,
      ),
      _GlanceRow(
        key: const ValueKey('team-stat-hosts'),
        label: l10n.teamStatHosts,
        value: hosts == null ? null : '${hosts.length}',
        // Every vault's, whole: the line wraps where it must (it was cut
        // to "Shared 6 · Production 4 · +1").
        sub: hostsSub.isEmpty ? null : hostsSub.join(OneLineParts.gap),
        onTap: () => onOpen(null),
      ),
      _GlanceRow(
        key: const ValueKey('team-stat-rules'),
        label: l10n.orchardRules,
        value: '${ruleNames.length}',
        sub: ruleNames.isEmpty ? l10n.teamStatRulesNone : ruleNames.join(l10n.listSeparator),
        onTap: () => onOpen(TeamPage.rules),
      ),
    ];
    return _Panel(children: rows);
  }
}

/// One row of At a glance: the number, what it counts and its line, and a
/// chevron where it opens a page. A button to the keyboard and to a screen
/// reader, its whole row the target.
class _GlanceRow extends StatefulWidget {
  const _GlanceRow({super.key, required this.label, required this.value, this.sub, this.onTap});

  final String label;

  /// Null while it is being read.
  final String? value;
  final String? sub;
  final VoidCallback? onTap;

  @override
  State<_GlanceRow> createState() => _GlanceRowState();
}

class _GlanceRowState extends State<_GlanceRow> {
  bool _hover = false;
  bool _focusRing = false; // keyboard focus only

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    final sub = widget.sub;
    final subKey = widget.key is ValueKey<String> ? ValueKey('${(widget.key! as ValueKey<String>).value}-sub') : null;
    final touch = isTouchLayout;
    return Semantics(
      button: tappable,
      child: FocusableActionDetector(
        enabled: tappable,
        mouseCursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focusRing = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap?.call();
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            // 48 high at least on a phone and a tablet.
            constraints: BoxConstraints(minHeight: touch ? 56 : 52),
            padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 12, 10),
            decoration: BoxDecoration(
              color: _hover && tappable ? ZestColors.surfaceRaisedAlt : Colors.transparent,
              border: Border.all(color: _focusRing ? ZestColors.accentInk : Colors.transparent, width: 1.5),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    widget.value ?? '…',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1,
                      color: ZestColors.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.label,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3, color: ZestColors.textPrimary)),
                      if (sub != null) ...[
                        const SizedBox(height: 1),
                        Text(sub,
                            key: subKey,
                            style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestColors.textFaint)),
                      ],
                    ],
                  ),
                ),
                if (tappable) ...[
                  const SizedBox(width: 8),
                  Icon(LucideIcons.chevronRight, size: 16, color: ZestColors.textTertiary),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [parts] on one line, as many whole ones as fit, then "+N" for the ones
/// that do not ("Production 4 · +2"). A line cut at its end lost a vault's
/// name halfway ("Recove…"), and one that wrapped made its card taller than
/// the three beside it. Where even the
/// first does not fit, the first is cut and the "+N" still stands.
class OneLineParts extends StatelessWidget {
  const OneLineParts({super.key, required this.parts, required this.style});

  final List<String> parts;
  final TextStyle style;

  /// What stands between two parts.
  static const gap = ' · ';

  /// The line with the first [shown] of [parts], and "+N" for the rest.
  static String line(List<String> parts, int shown) =>
      [...parts.take(shown), if (shown < parts.length) '+${parts.length - shown}'].join(gap);

  @override
  Widget build(BuildContext context) {
    Text one(String text, {bool cut = false}) => Text(text,
        maxLines: 1, softWrap: false, overflow: cut ? TextOverflow.ellipsis : TextOverflow.clip, style: style);
    // Measured in the face it is drawn in.
    final face = DefaultTextStyle.of(context).style.merge(style);
    final behavior = DefaultTextStyle.of(context).textHeightBehavior;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    ({double width, double height}) measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: face),
        maxLines: 1,
        textDirection: direction,
        textScaler: scaler,
        textHeightBehavior: behavior,
      )..layout();
      final size = (width: painter.width, height: painter.height);
      painter.dispose();
      return size;
    }

    // One line high, said before it is laid out: the four cards are made as
    // tall as the tallest (IntrinsicHeight), which asks each how tall it is,
    // and a LayoutBuilder cannot answer that.
    return SizedBox(
      height: measure(line(parts, parts.length)).height,
      child: LayoutBuilder(builder: (context, box) {
        bool fits(String text) => measure(text).width <= box.maxWidth;
        var shown = parts.length;
        while (shown > 1 && !fits(line(parts, shown))) {
          shown--;
        }
        if (shown == parts.length || fits(line(parts, shown))) return one(line(parts, shown), cut: true);
        return Row(
          children: [
            Flexible(child: one(parts.first, cut: true)),
            one('$gap+${parts.length - 1}'),
          ],
        );
      }),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label, {super.key, this.count, this.trailing, this.first = false});

  final String label;
  final int? count;
  final Widget? trailing;

  /// The first section of its column: no room above it.
  final bool first;

  // A plain label (4.0): no orange bar and no rule,
  // so nothing on the page leads but what needs this account.
  @override
  Widget build(BuildContext context) {
    final count = this.count;
    final trailing = this.trailing;
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 26, bottom: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 22),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
            Flexible(
              child: Semantics(
                header: true,
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                    height: 1,
                    color: ZestColors.textFaint,
                  ),
                ),
              ),
            ),
            if (count != null && count > 0) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: ZestColors.surfaceChip, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w500,
                    color: ZestColors.textFaint,
                  ),
                ),
              ),
            ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A link at the end of a section's title ("See all in Trust", "Give
/// access"): quiet words, never orange (the page's one orange is Invite
/// people).
class _SectionLink extends StatelessWidget {
  const _SectionLink({super.key, required this.label, required this.onPressed, this.icon, this.trailingIcon});

  final String label;
  final IconData? icon;

  /// After the words ("See all in Trust >").
  final IconData? trailingIcon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      // 32 high to a mouse at least (it was 28), 44 to a finger.
      minimumSize: Size(0, isTouchLayout ? 44 : 32),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: ZestColors.textSecondary,
      textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 13, fontWeight: FontWeight.w500),
    );
    final icon = this.icon;
    final trailingIcon = this.trailingIcon;
    return TextButton(
      onPressed: onPressed,
      style: style,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 15, color: ZestColors.textFaint), const SizedBox(width: 6)],
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (trailingIcon != null) ...[
            const SizedBox(width: 6),
            Icon(trailingIcon, size: 15, color: ZestColors.textFaint),
          ],
        ],
      ),
    );
  }
}

/// Rows in one bordered block, split by hairlines.
class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: ZestColors.borderSubtle),
            children[i],
          ],
        ],
      ),
    );
  }
}

typedef _Action = ({String label, VoidCallback onPressed});

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    this.body,
    this.action,
    this.actionKey,
    this.person,
    this.left,
    this.quiet = false,
  });

  final IconData icon;
  final TeamTone tone;
  final String title;
  final String? body;
  final _Action? action;
  final Key? actionKey;

  /// The person the row is about, as shown: their initials in place of the
  /// icon.
  final String? person;

  /// How long is left, with a clock, before the button.
  final String? left;

  /// A line that only says what something does: not bold.
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    final left = this.left;
    final button = action == null ? null : teamButton(key: actionKey, label: action.label, onPressed: action.onPressed);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: _wordsAndButton(
        icon: person == null ? TeamIconTile(icon: icon, tone: tone) : TeamInitials(name: person!),
        words: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: quiet ? FontWeight.w400 : FontWeight.w600,
                height: 1.4,
                color: quiet ? ZestColors.textSecondary : ZestColors.textPrimary,
              ),
            ),
            if (body != null) ...[
              const SizedBox(height: 2),
              Text(body!, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary)),
            ],
          ],
        ),
        // The time left, then the button; on a phone the button goes under
        // it where the line has no room for both.
        button: left == null || button == null
            ? button
            : Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.clock, size: 13, color: ZestColors.textTertiary),
                      const SizedBox(width: 6),
                      Text(left, style: TextStyle(fontSize: 12.5, color: ZestColors.textSecondary)),
                    ],
                  ),
                  button,
                ],
              ),
      ),
    );
  }
}

/// Access for a set time on a computer, one line (4.0):
/// who and in which vault, how far and until when, the time
/// left, and the button that ends it.
class _TimedLine extends StatelessWidget {
  const _TimedLine({
    super.key,
    required this.person,
    required this.title,
    required this.sub,
    required this.left,
    required this.action,
  });

  final String person;
  final String title;
  final String sub;
  final String left;
  final _Action action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 10, 9),
      child: Row(
        children: [
          TeamInitials(name: person, size: 28),
          const SizedBox(width: 12),
          Flexible(
            flex: 3,
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: ZestColors.textFaint)),
          ),
          const SizedBox(width: 12),
          Icon(LucideIcons.clock, size: 14, color: ZestColors.textTertiary),
          const SizedBox(width: 6),
          Text(left, style: TextStyle(fontSize: 12.5, color: ZestColors.textSecondary)),
          const SizedBox(width: 10),
          teamButton(label: action.label, onPressed: action.onPressed),
        ],
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change, required this.text, required this.by, required this.seen});

  final TeamChange change;
  final String text;
  final String by;

  /// When this device first saw it.
  final String seen;

  @override
  Widget build(BuildContext context) {
    final number = Text(
      '#${change.seq}',
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 11.5,
        height: 1.6,
        color: ZestColors.textMuted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return Container(
      key: ValueKey('team-change-${change.seq}'),
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZestColors.borderSubtle))),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < kTeamNarrowWidth - 28
            // A phone: the change, then who and when under it.
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 38, child: number),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(text, style: TextStyle(fontSize: 13, height: 1.35, color: ZestColors.textPrimary)),
                        const SizedBox(height: 3),
                        Text(
                          '$by · $seen',
                          style: TextStyle(fontSize: 12, height: 1.35, color: ZestColors.textTertiary),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : _wide(),
      ),
    );
  }

  /// A computer: the number, the change, then who and when at the end of
  /// the line, quiet.
  Widget _wide() {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            '#${change.seq}',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11.5,
              // A number that is read: muted, not the placeholder's dim.
              color: ZestColors.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, height: 1.35, color: ZestColors.textSecondary)),
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            '$by · $seen',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, color: ZestColors.textTertiary),
          ),
        ),
      ],
    );
  }

}

