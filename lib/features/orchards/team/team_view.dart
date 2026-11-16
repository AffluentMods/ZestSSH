import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_activity_view.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart';
import 'package:zestssh/features/orchards/team/team_settings.dart';
import 'package:zestssh/features/orchards/team/team_setup.dart';
import 'package:zestssh/features/orchards/team/team_trust.dart';
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart' show showPassFromOwner;
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_sso_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/join_review.dart' show teamJoiningCount;
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/features/orchards/widgets/roles_matrix.dart';
import 'package:zestssh/features/orchards/widgets/vaults_page.dart' show kVaultPaneWidth;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

/// How wide a Team page grows.
const kTeamPageWidth = 860.0;

/// How wide the Roles page grows: its table has a column for each vault.
const kTeamWidePageWidth = 1060.0;

/// How wide the Overview grows: what needs this account and what runs,
/// and At a glance beside them (4.0).
///
const kTeamOverviewWidth = 1084.0;

/// The pages [o] offers this account: the Overview, Members and the key log
/// always; Seats and Crates while it syncs; the rules while it syncs or
/// while a rule holds this account back; Roles, Sign-in and Activity for
/// owners; the setup file and Team settings (its name, and deleting
/// it, which only an owner does) for owners and admins.
List<TeamPage> teamPagesFor(OrchardSummary o) => [
      TeamPage.overview,
      TeamPage.members,
      if (o.active && o.isOwner) TeamPage.roles,
      if (o.active) TeamPage.seats,
      if (o.active) TeamPage.crates,
      if (o.active || o.status == 'rules') TeamPage.rules,
      if (o.active && o.isOwner) TeamPage.signIn,
      if (o.active && (o.isOwner || o.role == FixedRoles.admin)) TeamPage.setup,
      TeamPage.trust,
      if (o.active && o.isOwner) TeamPage.activity,
      if (o.active && (o.isOwner || o.role == FixedRoles.admin)) TeamPage.settings,
    ];

/// The Team destination (3.0): the Orchard on screen, its pages
/// on the left, the page on the right. In the rail while an Orchard is
/// open; built only while it is the section on screen, so nothing is read
/// for it otherwise.
class TeamView extends ConsumerWidget {
  const TeamView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(activeSidebarNavProvider) != NavSection.team) return const SizedBox.shrink();
    final active = ref.watch(activeOrchardProvider);
    final orchard = active.valueOrNull;
    if (orchard == null) {
      // The Orchard closed (the Tree is on screen, or it went away): back to
      // the Hosts page.
      if (active is AsyncData) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (ref.read(activeSidebarNavProvider) == NavSection.team &&
              ref.read(activeOrchardProvider).valueOrNull == null) {
            ref.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
          }
        });
      }
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    if (orchard.closedOffline) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.wifiOff, size: 28, color: ZestColors.textTertiary),
              const SizedBox(height: 12),
              Text(
                // (Said anew when it turns out that the service is the one
                // that cannot be reached, or that it can be again.)
                orchardClosedOfflineText(l10n, ref.watch(cloudReachStateProvider).valueOrNull?.reach),
                key: const ValueKey('team-closed-offline'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: ZestColors.textSecondary),
              ),
              // The way on without the internet: an owner signs a pass for
              // this device (rules/offline_pass.dart).
              const SizedBox(height: 12),
              TextButton.icon(
                key: const ValueKey('team-closed-pass'),
                onPressed: () => showPassFromOwner(context, orchardId: orchard.id),
                icon: const Icon(LucideIcons.qrCode, size: 14),
                label: Text(l10n.passAskButton),
              ),
            ],
          ),
        ),
      );
    }
    final pages = teamPagesFor(orchard);
    final chosen = ref.watch(teamPageProvider);
    final page = pages.contains(chosen) ? chosen : TeamPage.overview;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TeamNav(orchard: orchard, pages: pages, page: page),
        Expanded(
          child: _TeamPageBody(
            key: ValueKey('team-${orchard.id}-${page.name}'),
            orchard: orchard,
            page: page,
          ),
        ),
      ],
    );
  }
}

class _TeamNav extends ConsumerWidget {
  const _TeamNav({required this.orchard, required this.pages, required this.page});

  final OrchardSummary orchard;
  final List<TeamPage> pages;
  final TeamPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // What needs this account, what the company's directory asks for
    // and who asks for access it could give, as the Overview lists
    // them.
    // (Counted by the Overview's own rows, so the badge and the list agree.)
    final attention = teamAttentionRowCount(ref, orchard);
    // Who waits to join (invitations and used invite codes), on Members.
    final joining = teamJoiningCount(ref, orchard);
    // Rules changed and not saved, on Rules.
    final rulesUnsaved = unsavedRuleCount(ref.watch(orchardRulesDraftProvider(orchard.id)), orchard);
    Widget? item(TeamPage p) {
      if (!pages.contains(p)) return null;
      final (icon, label, count) = switch (p) {
        TeamPage.overview => (LucideIcons.layoutDashboard, l10n.teamPageOverview, attention),
        TeamPage.members => (LucideIcons.users, l10n.orchardMembers, joining),
        TeamPage.roles => (LucideIcons.crown, l10n.orchardRoles, 0),
        TeamPage.seats => (LucideIcons.armchair, l10n.teamPageSeats, 0),
        TeamPage.crates => (LucideIcons.package, l10n.orchardCrates, 0),
        TeamPage.rules => (LucideIcons.scrollText, l10n.orchardRules, rulesUnsaved),
        TeamPage.signIn => (LucideIcons.globe, l10n.teamPageSignIn, 0),
        TeamPage.setup => (LucideIcons.fileJson, l10n.teamPageSetup, 0),
        TeamPage.trust => (LucideIcons.fingerprint, l10n.teamPageTrust, 0),
        TeamPage.activity => (LucideIcons.activity, l10n.teamPageActivity, 0),
        TeamPage.settings => (LucideIcons.settings, l10n.teamPageSettings, 0),
      };
      return _TeamNavItem(
        key: ValueKey('team-nav-${p.name}'),
        icon: icon,
        label: label,
        count: count,
        on: p == page,
        onTap: () async {
          // Unsaved rules ask before Rules goes.
          if (p != page && page == TeamPage.rules && !await mayLeaveOrchardRules()) return;
          ref.read(teamPageProvider.notifier).state = p;
        },
      );
    }

    List<Widget> group(String id, String label, List<TeamPage> of) {
      final items = [for (final p in of) ?item(p)];
      return items.isEmpty ? const [] : [_Group(label, key: ValueKey('team-nav-group-$id')), ...items];
    }

    // The Overview alone at the top,
    // then who is in (People), what they get at (Access) and what was done
    // (Records); Team settings and the setup file at the foot.
    final setup = item(TeamPage.setup);
    final settings = item(TeamPage.settings);
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(right: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 18, 10, 18),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: RedactedText(
                    Redactable.account(orchardDisplayName(orchard.name, l10n)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: ZestColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    teamRoleLine(orchard, l10n),
                    style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary),
                  ),
                ),
                const SizedBox(height: 14),
                ?item(TeamPage.overview),
                ...group('people', l10n.teamGroupPeople, const [TeamPage.members, TeamPage.roles, TeamPage.seats]),
                ...group('access', l10n.teamGroupAccess, const [TeamPage.crates, TeamPage.rules, TeamPage.signIn]),
                ...group('records', l10n.teamGroupRecords, const [TeamPage.activity, TeamPage.trust]),
              ],
            ),
          ),
          if (setup != null || settings != null)
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestColors.borderSubtle))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [?settings, ?setup],
              ),
            ),
        ],
      ),
    );
  }
}

/// "You're an Owner", "You're an Admin", or "You're a member".
String teamRoleLine(OrchardSummary o, AppLocalizations l10n) => switch (o.role) {
      FixedRoles.owner => l10n.teamYouAreOwner,
      FixedRoles.admin => l10n.teamYouAreAdmin,
      _ => l10n.teamYouAreMember,
    };

class _Group extends StatelessWidget {
  const _Group(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.9,
          color: ZestColors.textMuted,
        ),
      ),
    );
  }
}

class _TeamNavItem extends StatefulWidget {
  const _TeamNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
    this.count = 0,
  });

  final IconData icon;
  final String label;
  final bool on;
  final int count;
  final VoidCallback onTap;

  @override
  State<_TeamNavItem> createState() => _TeamNavItemState();
}

class _TeamNavItemState extends State<_TeamNavItem> {
  bool _hover = false;
  bool _focusRing = false; // keyboard focus only

  @override
  Widget build(BuildContext context) {
    final on = widget.on;
    final fg = on ? ZestColors.textPrimary : ZestColors.textSecondary;
    // A button that Tab reaches and Enter or Space presses, with a ring, and
    // to a screen reader a button that says whether its page is the one
    // shown. It was a bare GestureDetector: with nothing waiting on Overview
    // no key led to Members, so a person without a mouse could not change a
    // member's role or leave the team.
    return Semantics(
      button: true,
      selected: on,
      child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (h) => setState(() => _hover = h),
      onShowFocusHighlight: (f) => setState(() => _focusRing = f),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 34,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: on
                ? ZestColors.bgSurface
                : _hover
                    ? ZestColors.surfaceRaisedAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: _focusRing ? ZestColors.accentInk : Colors.transparent, width: 1.5),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 15, color: on ? ZestColors.accentInk : fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    color: fg,
                  ),
                ),
              ),
              if (widget.count > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: ZestColors.accentPrimary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${widget.count}',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: ZestColors.accentInk,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// The app's feature id whose guide the "?" by Team page [page]'s title
/// opens (Help > Guides; the guides' frontmatter lists these ids).
String teamGuideFeature(TeamPage page) => switch (page) {
      TeamPage.overview => 'team_overview',
      TeamPage.members => 'team_members',
      TeamPage.seats => 'team_seats',
      TeamPage.roles => 'team_roles',
      TeamPage.crates => 'team_vaults',
      TeamPage.rules => 'team_rules',
      TeamPage.signIn => 'team_sign_in',
      TeamPage.trust => 'team_trust',
      TeamPage.setup || TeamPage.activity || TeamPage.settings => 'team',
    };

/// What Team page [page] of [orchard] shows: its title, the line under it
/// (null for the Overview, which names the Orchard instead), and the page.
/// On a [phone], Members is one list with the actions in each row's menu,
/// and a link to another page goes through [onOpen]. [onLeft] runs when
/// this account left the Orchard from Members.
({String title, String? subtitle, Widget body}) teamPageContent(
  BuildContext context,
  WidgetRef ref,
  OrchardSummary orchard,
  TeamPage page, {
  bool phone = false,
  void Function(TeamPage page)? onOpen,
  required VoidCallback onLeft,
}) {
  final l10n = AppLocalizations.of(context)!;
  return switch (page) {
    TeamPage.overview => (title: l10n.teamPageOverview, subtitle: null, body: TeamOverview(orchard: orchard, onOpen: onOpen)),
    TeamPage.members => (
        title: l10n.orchardMembers,
        // On a computer the page speaks for itself;
        // a phone keeps the line.
        subtitle: phone ? l10n.teamMembersSubtitle : null,
        body: OrchardMembersView(
          orchardId: orchard.id,
          inviteInHeader: !phone,
          pageLayout: !phone,
          onLeft: onLeft,
          onOpenRules: () =>
              onOpen != null ? onOpen(TeamPage.rules) : ref.read(teamPageProvider.notifier).state = TeamPage.rules,
        ),
      ),
    // On a computer one table of every role and vault; on a phone a list.
    TeamPage.roles => (
        title: l10n.orchardRoles,
        subtitle: l10n.teamRolesPageSubtitle,
        body: phone ? OrchardRolesView(orchardId: orchard.id) : OrchardRolesMatrix(orchardId: orchard.id),
      ),
    TeamPage.seats => (
        title: l10n.teamPageSeats,
        subtitle: l10n.teamSeatsSubtitle,
        body: TeamSeatsView(
          orchard: orchard,
          // On a computer Buy seats and Redeem a code are in the header.
          actionsInHeader: !phone,
          onOpenMembers: () =>
              onOpen != null ? onOpen(TeamPage.members) : ref.read(teamPageProvider.notifier).state = TeamPage.members,
          // On a computer the review opens beside the Members list, as the
          // Overview's Review does; a phone opens Members, where the person
          // waits at the top with Review.
          onOpenReview: (inviteId) {
            if (onOpen != null) {
              onOpen(TeamPage.members);
              return;
            }
            ref.read(teamReviewToOpenProvider.notifier).state = inviteId;
            ref.read(teamPageProvider.notifier).state = TeamPage.members;
          },
        ),
      ),
    TeamPage.crates => (
        title: l10n.orchardCrates,
        subtitle: l10n.teamCratesSubtitle,
        body: OrchardCratesView(orchardId: orchard.id, pageLayout: !phone),
      ),
    // Rules scrolls itself, its Save bar under it in sight (on a phone the
    // line under the title goes in its scroll).
    TeamPage.rules => (
        title: l10n.orchardRules,
        subtitle: phone ? null : l10n.teamRulesSubtitle,
        body: OrchardRulesView(
          orchardId: orchard.id,
          onSaved: () {},
          scrollPadding: phone ? const EdgeInsets.fromLTRB(16, 12, 16, 28) : const EdgeInsets.fromLTRB(28, 4, 28, 28),
          maxWidth: phone ? null : kTeamPageWidth,
          leading: phone
              ? Text(l10n.teamRulesSubtitle, style: TextStyle(fontSize: 13, height: 1.45, color: ZestColors.textSecondary))
              : null,
          onOpenMembers: () =>
              onOpen != null ? onOpen(TeamPage.members) : ref.read(teamPageProvider.notifier).state = TeamPage.members,
          onOpenSignIn: () =>
              onOpen != null ? onOpen(TeamPage.signIn) : ref.read(teamPageProvider.notifier).state = TeamPage.signIn,
        ),
      ),
    TeamPage.signIn => (
        title: l10n.teamPageSignIn,
        subtitle: l10n.teamSignInSubtitle,
        body: OrchardSignInView(
          orchard: orchard,
          onOpenBusiness: () =>
              onOpen != null ? onOpen(TeamPage.seats) : ref.read(teamPageProvider.notifier).state = TeamPage.seats,
        ),
      ),
    TeamPage.setup => (title: l10n.teamPageSetup, subtitle: l10n.teamSetupSubtitle, body: TeamSetup(orchard: orchard)),
    // The team's name and deleting it (4.0: they were on the Overview).
    TeamPage.settings => (
        title: l10n.teamPageSettings,
        subtitle: l10n.teamSettingsSubtitle,
        body: TeamSettingsView(orchard: orchard, onOpen: onOpen),
      ),
    TeamPage.trust => (title: l10n.teamPageTrust, subtitle: l10n.teamTrustSubtitle, body: TeamTrust(orchard: orchard)),
    TeamPage.activity => (
        title: l10n.teamPageActivity,
        subtitle: l10n.teamActivitySubtitle,
        body: TeamActivityView(
          orchard: orchard,
          onOpenRules: () =>
              onOpen != null ? onOpen(TeamPage.rules) : ref.read(teamPageProvider.notifier).state = TeamPage.rules,
        ),
      ),
  };
}

class _TeamPageBody extends ConsumerWidget {
  const _TeamPageBody({super.key, required this.orchard, required this.page});

  final OrchardSummary orchard;
  final TeamPage page;

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    if (await showInviteDialog(context, ref, orchard)) {
      ref.read(orchardInvitesVersionProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final (:title, :subtitle, :body) = teamPageContent(
      context,
      ref,
      orchard,
      page,
      // Leaving took this account out: back to the Hosts page.
      onLeft: () => ref.read(activeSidebarNavProvider.notifier).state = NavSection.hosts,
    );
    final actions = <Widget>[
      // The theme's buttons, as everywhere on the team's pages: Team
      // settings quiet (Rename and Delete team are there now), Invite the one
      // filled, the page's one orange.
      if (page == TeamPage.overview && teamPagesFor(orchard).contains(TeamPage.settings))
        teamButton(
          key: const ValueKey('team-settings-open'),
          label: l10n.teamPageSettings,
          icon: LucideIcons.settings,
          kind: TeamButtonKind.ghost,
          onPressed: () => ref.read(teamPageProvider.notifier).state = TeamPage.settings,
        ),
      if ((page == TeamPage.overview || page == TeamPage.members) && orchard.active && orchard.canInvite)
        teamButton(
          key: const ValueKey('team-invite'),
          label: l10n.teamInvitePeople,
          icon: LucideIcons.userPlus,
          kind: TeamButtonKind.primary,
          onPressed: () => _invite(context, ref),
        ),
      // Seats are bought and codes redeemed by owners on a computer.
      if (page == TeamPage.seats && orchard.isOwner && ref.watch(billingOnThisDeviceProvider)) ...[
        teamButton(
          key: const ValueKey('team-seats-redeem'),
          label: l10n.settingsMobRedeemCode,
          icon: LucideIcons.gift,
          onPressed: () => redeemSeatCode(context, ref, orchard),
        ),
        teamButton(
          key: const ValueKey('team-seats-buy'),
          label: l10n.teamSeatsBuy,
          icon: LucideIcons.armchair,
          kind: TeamButtonKind.primary,
          onPressed: () => openSeatsSheet(context, ref, orchard.id),
        ),
      ],
      // Only owners change roles.
      if (page == TeamPage.roles && orchard.isOwner && orchard.active)
        teamButton(
          key: const ValueKey('role-new'),
          label: l10n.orchardRoleNew,
          icon: LucideIcons.plus,
          kind: TeamButtonKind.primary,
          onPressed: () => newOrchardRole(context, ref, orchard),
        ),
      if (page == TeamPage.crates && orchard.canAddCrates && orchard.active)
        teamButton(
          key: const ValueKey('crate-new'),
          label: l10n.crateNewAction,
          icon: LucideIcons.plus,
          kind: TeamButtonKind.primary,
          onPressed: () => showNewCrateDialog(context, ref, orchard.id),
        ),
    ];
    // While a member's panel (or a vault's pane) takes the right of the
    // page, the header ends where the list does (its button stood over it).
    final panelOpen = (page == TeamPage.members &&
            (ref.watch(teamMemberPanelProvider(orchard.id)) != null ||
                ref.watch(teamReviewPanelProvider(orchard.id)) != null)) ||
        (page == TeamPage.crates && ref.watch(teamVaultPanelProvider(orchard.id)) != null);
    // The Roles table has a column for each vault: it takes more room.
    final width = switch (page) {
      TeamPage.roles => kTeamWidePageWidth,
      TeamPage.overview => kTeamOverviewWidth,
      _ => kTeamPageWidth,
    };
    final panelWidth = page == TeamPage.crates ? kVaultPaneWidth : kMemberPanelWidth;
    return LayoutBuilder(builder: (context, box) {
    // A panel beside the list (not in its place, on a narrow page).
    final panel = panelOpen && teamPanelBeside(box.maxWidth, panelWidth);
    final heading = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GuideTitle(
                      feature: teamGuideFeature(page),
                      title: Text(
                        title,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          color: ZestColors.textPrimary,
                        ),
                      ),
                    ),
                    // The Overview and Members say no more under their
                    // title: the team and this account's role head the list
                    // on the left.
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(subtitle, style: TextStyle(fontSize: 13, color: ZestColors.textSecondary)),
                    ],
                  ],
                );
    return _HeaderOverScroll(
        header: Padding(
          padding: EdgeInsets.fromLTRB(28, 24, panel ? 28 + panelWidth : 28, 14),
          // As wide as the page below it, so its buttons end where it does.
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              // The buttons beside the title where it keeps its room, under
              // it where it would not (on a narrow page the title and the
              // line under it were left a letter a line).
              child: actions.isEmpty
                  ? Align(alignment: AlignmentDirectional.centerStart, child: heading)
                  : BesideOrUnder(
                      minWordsWidth: 240,
                      gap: 16,
                      underGap: 12,
                      words: heading,
                      control: Wrap(spacing: 8, runSpacing: 8, children: actions),
                    ),
            ),
          ),
        ),
        // Members and Vaults scroll their lists themselves, beside their
        // panes; Rules, over its Save bar.
        body: page == TeamPage.members || page == TeamPage.crates || page == TeamPage.rules
            ? body
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: width),
                    child: body,
                  ),
                ),
              ),
    );
    });
  }
}

/// A team page's header over its body: a hairline under the header while
/// the body (or a pane of it) is scrolled, so what slides under the header
/// is cut by a line, not by nothing. At
/// the top of the page there is none, as before.
class _HeaderOverScroll extends StatefulWidget {
  const _HeaderOverScroll({required this.header, required this.body});

  final Widget header;
  final Widget body;

  @override
  State<_HeaderOverScroll> createState() => _HeaderOverScrollState();
}

class _HeaderOverScrollState extends State<_HeaderOverScroll> {
  /// The lists of the body scrolled away from their top.
  final _scrolled = <BuildContext>{};

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n.context == null) return false;
    final away = n.metrics.pixels > n.metrics.minScrollExtent + 0.5;
    final changed = away ? _scrolled.add(n.context!) : _scrolled.remove(n.context);
    if (!changed) return false;
    // A list laid out anew can say it moved while the frame is being laid
    // out: the rule follows in the next frame then.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    _scrolled.removeWhere((c) => !c.mounted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header,
        // Its room is kept while it is not drawn: the page does not jump.
        Container(
          key: const ValueKey('team-header-rule'),
          height: 1,
          color: _scrolled.isEmpty ? Colors.transparent : ZestColors.borderSubtle,
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.body),
        ),
      ],
    );
  }
}
