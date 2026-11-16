import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart' show showPassFromOwner;
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

/// The Team on a phone (3.0): More, then the Orchard on screen,
/// lists its pages; each opens full screen. The same pages as the desktop's
/// Team destination, in one column.
class TeamPhoneScreen extends ConsumerWidget {
  const TeamPhoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = ref.watch(activeOrchardProvider).valueOrNull;
    if (orchard == null || orchard.closedOffline) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.orchardTeam)),
        body: _Closed(closedOrchardId: orchard?.id),
      );
    }
    final pages = teamPagesFor(orchard);
    // Who asks for access this account could give: the Overview lists
    // them.
    // Likewise the devices that ask to be approved.
    final asking = (ref.watch(accessRequestsProvider(orchard.id)).valueOrNull?.waiting.length ?? 0) +
        (ref.watch(deviceRequestsProvider(orchard.id)).valueOrNull?.length ?? 0);
    Widget row(TeamPage p, IconData icon, String label, {int count = 0}) => ListTile(
          key: ValueKey('team-phone-${p.name}'),
          leading: Icon(icon, size: 20, color: ZestColors.textSecondary),
          title: Text(label, style: TextStyle(fontSize: 15, color: ZestColors.textPrimary)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (count > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: ZestColors.statusWarning.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZestColors.statusWarning),
                  ),
                ),
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronRight, size: 18, color: ZestColors.textTertiary),
            ],
          ),
          onTap: () => context.push('${Routes.team}/${p.name}'),
        );
    List<Widget> group(String label, List<(TeamPage, IconData, String, int)> of) {
      final items = [
        for (final (p, icon, text, count) in of)
          if (pages.contains(p)) row(p, icon, text, count: count),
      ];
      if (items.isEmpty) return const [];
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: ZestSectionHeader(label: label),
        ),
        ...items,
      ];
    }

    return Scaffold(
      appBar: AppBar(
        title: RedactedText(
          Redactable.account(orchardDisplayName(orchard.name, l10n)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        key: const ValueKey('team-phone'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(teamRoleLine(orchard, l10n), style: TextStyle(fontSize: 13, color: ZestColors.textSecondary)),
          ),
          // As on a computer: the
          // Overview alone, then People, Access and Records; the setup file
          // last.
          const SizedBox(height: 8),
          if (pages.contains(TeamPage.overview))
            row(TeamPage.overview, LucideIcons.layoutDashboard, l10n.teamPageOverview, count: asking),
          ...group(l10n.teamGroupPeople, [
            (TeamPage.members, LucideIcons.users, l10n.orchardMembers, orchard.invitesWaiting),
            (TeamPage.roles, LucideIcons.crown, l10n.orchardRoles, 0),
            (TeamPage.seats, LucideIcons.armchair, l10n.teamPageSeats, 0),
          ]),
          ...group(l10n.teamGroupAccess, [
            (TeamPage.crates, LucideIcons.package, l10n.orchardCrates, 0),
            (TeamPage.rules, LucideIcons.scrollText, l10n.orchardRules, 0),
            (TeamPage.signIn, LucideIcons.globe, l10n.teamPageSignIn, 0),
          ]),
          ...group(l10n.teamGroupRecords, [
            (TeamPage.activity, LucideIcons.activity, l10n.teamPageActivity, 0),
            (TeamPage.trust, LucideIcons.fingerprint, l10n.teamPageTrust, 0),
          ]),
          if (pages.contains(TeamPage.settings) || pages.contains(TeamPage.setup)) const SizedBox(height: 12),
          if (pages.contains(TeamPage.settings)) row(TeamPage.settings, LucideIcons.settings, l10n.teamPageSettings),
          if (pages.contains(TeamPage.setup)) row(TeamPage.setup, LucideIcons.fileJson, l10n.teamPageSetup),
        ],
      ),
    );
  }
}

/// One Team page, full screen on a phone.
class TeamPhonePageScreen extends ConsumerWidget {
  const TeamPhonePageScreen({super.key, required this.page});

  final TeamPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = ref.watch(activeOrchardProvider).valueOrNull;
    if (orchard == null || orchard.closedOffline || !teamPagesFor(orchard).contains(page)) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.orchardTeam)),
        body: _Closed(closedOrchardId: orchard != null && orchard.closedOffline ? orchard.id : null),
      );
    }
    final (:title, :subtitle, :body) = teamPageContent(
      context,
      ref,
      orchard,
      page,
      phone: true,
      onOpen: (p) => context.push('${Routes.team}/${p.name}'),
      // Leaving took this account out: back to where the Team was opened.
      onLeft: () {
        if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      },
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          GuideHelpButton(feature: teamGuideFeature(page), size: 20),
          // Team settings (Rename and Delete team are there now).
          if (page == TeamPage.overview && teamPagesFor(orchard).contains(TeamPage.settings))
            IconButton(
              key: const ValueKey('team-settings-open'),
              tooltip: l10n.teamPageSettings,
              icon: const Icon(LucideIcons.settings, size: 20),
              onPressed: () => context.push('${Routes.team}/${TeamPage.settings.name}'),
            ),
          if (page == TeamPage.overview && orchard.active && orchard.canInvite)
            IconButton(
              key: const ValueKey('team-invite'),
              tooltip: l10n.teamInvitePeople,
              icon: const Icon(LucideIcons.userPlus, size: 20),
              onPressed: () async {
                if (await showInviteDialog(context, ref, orchard)) {
                  ref.read(orchardInvitesVersionProvider.notifier).state++;
                }
              },
            ),
        ],
      ),
      // Every page scrolls here, Members too (its phone list is a column of
      // its own, which ran over the screen's foot); Rules scrolls itself,
      // over its Save bar.
      body: page == TeamPage.rules
          ? body
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (subtitle != null) ...[
                    Text(subtitle, style: TextStyle(fontSize: 13, height: 1.45, color: ZestColors.textSecondary)),
                    const SizedBox(height: 14),
                  ],
                  body,
                ],
              ),
            ),
    );
  }
}

class _Closed extends ConsumerWidget {
  const _Closed({this.closedOrchardId});

  /// The Orchard that its offline limit closed on this device, where that
  /// is why nothing is shown: it is said, and a pass is asked for it from
  /// here. Null where there is no Orchard to show, or the page is not this
  /// account's to see.
  final String? closedOrchardId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final closed = closedOrchardId;
    final offline = closed != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(offline ? LucideIcons.wifiOff : LucideIcons.users, size: 28, color: ZestColors.textTertiary),
            const SizedBox(height: 12),
            Text(
              offline
                  ? orchardClosedOfflineText(l10n, ref.watch(cloudReachStateProvider).valueOrNull?.reach)
                  : l10n.teamPhoneNoOrchard,
              key: offline ? const ValueKey('team-phone-closed-offline') : null,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.5, color: ZestColors.textSecondary),
            ),
            // The way on without the internet: an owner signs a pass for
            // this device.
            if (closed != null) ...[
              const SizedBox(height: 12),
              TextButton.icon(
                key: const ValueKey('team-phone-closed-pass'),
                onPressed: () => showPassFromOwner(context, orchardId: closed),
                icon: const Icon(LucideIcons.qrCode, size: 14),
                label: Text(l10n.passAskButton),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
