import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/team/team_view.dart' show teamRoleLine;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show signInFromAnywhere;
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart' show accountSetupNeedsAttentionProvider;
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/profile_avatar.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_bottom_nav.dart';
import 'package:zestssh/utils/line_breaks.dart';

/// The phone's More tab (3.0 UI): the team, when an Orchard is on
/// screen, then what the desktop rail keeps under Manage and Utilities, then
/// Settings, Account and help. Each row opens its full screen. Keys and Port
/// forwarding are in the Manage tab, not here (3.1), and Snippets here, with
/// Networks among the utilities. (A tablet's 3.0 rows went with its tabs:
/// 4.0.)
class MoreTab extends ConsumerWidget {
  const MoreTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = kOrchardsEnabled ? ref.watch(activeOrchardProvider).valueOrNull : null;
    final isPro = ref.watch(isProProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);
    final accountAttention = ref.watch(accountSetupNeedsAttentionProvider).valueOrNull ?? false;
    // An answer from support that has not been read.
    final ticketReply = ref.watch(ticketUnreadCountProvider) > 0;
    // Sessions teammates share with this account (3.0).
    final shared = kOrchardsEnabled ? ref.watch(shareInvitationsProvider).length : 0;
    final networks = PhoneListRow(
      key: const ValueKey('more-networks'),
      icon: LucideIcons.network,
      title: Text(l10n.narrowSidebarNetworks, style: PhoneListRow.titleStyle),
      // Its last two words on one line ("away" was alone on a phone's: a
      // design audit).
      subtitle: noOrphan(l10n.phoneMoreNetworksDesc),
      onTap: () => context.push(Routes.networks),
    );
    return ListView(
      key: const ValueKey('phone-more'),
      padding: EdgeInsets.fromLTRB(16, 12, 16, ZestBottomNav.contentBottomPadding(context, hasFab: false)),
      children: [
        // A guest sees how to sign in first.
        // (Where the build has accounts at all, and plans to buy.)
        if (zestHasCloud && ref.watch(currentUserProvider) == null) ...[
          const _GuestCard(),
          const SizedBox(height: 8),
        ],
        if (zestHasPlans && (!isPro || !isCloudSync)) ...[
          _UpgradeCard(isPro: isPro, isCloudSync: isCloudSync),
          const SizedBox(height: 8),
        ],
        if (orchard != null) ...[
          PhoneListGroup(l10n.orchardTeam),
          PhoneListCard(children: [
              PhoneListRow(
              key: const ValueKey('more-team'),
              icon: LucideIcons.users,
              title: RedactedText(
                Redactable.account(orchardDisplayName(orchard.name, l10n)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PhoneListRow.titleStyle,
              ),
              subtitle: teamRoleLine(orchard, l10n),
              // People wait to be added, or keys to be replaced (as the
              // desktop rail's Team item).
              attention: orchard.invitesWaiting > 0 || orchard.keysWaiting,
              onTap: () => context.push(Routes.team),
            ),
          ]),
        ],
        if (kOrchardsEnabled && (orchard != null || shared > 0))
          PhoneListRow(
            key: const ValueKey('more-shared'),
            icon: LucideIcons.monitorUp,
            title: Text(l10n.shareInvitesTitle, style: PhoneListRow.titleStyle),
            subtitle: shared > 0 ? l10n.shareInvitesPill(shared) : l10n.shareInvitesRowDesc,
            attention: shared > 0,
            onTap: () => showShareInvitations(context),
          ),
        PhoneListGroup(l10n.narrowSidebarGroupUtilities),
        PhoneListCard(children: [
          networks,
          PhoneListRow(
            key: const ValueKey('more-snippets'),
            icon: LucideIcons.braces,
            title: Text(l10n.narrowSidebarSnippets, style: PhoneListRow.titleStyle),
            subtitle: l10n.utilitiesSnippetsDesc,
            onTap: () => context.push(Routes.snippets),
          ),
            PhoneListRow(
            key: const ValueKey('more-triggers'),
            icon: LucideIcons.bellRing,
            title: Text(l10n.narrowSidebarTriggers, style: PhoneListRow.titleStyle),
            subtitle: l10n.settingsMobTriggersDesc,
            onTap: () => context.push(Routes.triggers),
          ),
          PhoneListRow(
            key: const ValueKey('more-history'),
            icon: LucideIcons.history,
            title: Text(l10n.narrowSidebarHistory, style: PhoneListRow.titleStyle),
            subtitle: l10n.settingsMobCommandHistoryDesc,
            onTap: () => context.push(Routes.commandHistory),
          ),
          PhoneListRow(
            key: const ValueKey('more-automation'),
            icon: LucideIcons.play,
            title: Text(l10n.narrowSidebarAutomation, style: PhoneListRow.titleStyle),
            subtitle: l10n.utilitiesAutomationDesc,
            onTap: () => context.push(Routes.automationSettings),
          ),
        ]),
        PhoneListGroup(l10n.phoneMoreGroupApp),
        PhoneListCard(children: [
            PhoneListRow(
            key: const ValueKey('more-settings'),
            icon: LucideIcons.settings,
            title: Text(l10n.narrowSidebarSettings, style: PhoneListRow.titleStyle),
            subtitle: l10n.phoneMoreSettingsDesc,
            onTap: () => context.push(Routes.settings),
          ),
          PhoneListRow(
            key: const ValueKey('more-account'),
            icon: LucideIcons.userCircle,
            title: Text(l10n.accountTitle, style: PhoneListRow.titleStyle),
            subtitle: l10n.settingsLinkAccountHelp,
            attention: accountAttention,
            onTap: () => context.push(Routes.profile),
          ),
          PhoneListRow(
            key: const ValueKey('more-help'),
            icon: LucideIcons.lifeBuoy,
            title: Text(l10n.helpSupport, style: PhoneListRow.titleStyle),
            subtitle: ticketReply ? l10n.ticketReplyFromSupport : l10n.phoneMoreHelpDesc,
            attention: ticketReply,
            onTap: () => context.push(Routes.help),
          ),
        ]),
      ],
    );
  }
}

/// What a Free or part-way account can unlock (moved here from the old Home
/// tab).
class _UpgradeCard extends StatelessWidget {
  const _UpgradeCard({required this.isPro, required this.isCloudSync});

  final bool isPro;
  final bool isCloudSync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PhoneUpgradeCard(
      key: const ValueKey('more-upgrade'),
      icon: !isPro ? LucideIcons.rocket : LucideIcons.cloud,
      title: !isPro && !isCloudSync
          ? l10n.homeUnlockFullExperience
          : isPro && !isCloudSync
              ? l10n.upgradeAddCloudSync
              : l10n.settingsUpgradeToSqueezed,
      subtitle: !isPro && !isCloudSync
          ? l10n.homeUnlockFullExperienceDesc
          : isPro && !isCloudSync
              ? l10n.homeSyncConnectionsDesc
              : l10n.homeUnlimitedConnectionsThemes,
      onTap: () => context.push(Routes.upgrade),
    );
  }
}

/// A guest's card at the top of More: their things are on this phone only,
/// and Sign in is a button of its own (the row opens the account).
class _GuestCard extends ConsumerWidget {
  const _GuestCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return InkWell(
      key: const ValueKey('more-guest'),
      onTap: () => context.push(Routes.profile),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
          color: AppColors.surface,
        ),
        child: Row(
          children: [
            const ProfileAvatar(size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.narrowSidebarGuest,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.onSurface)),
                  const SizedBox(height: 2),
                  Text(l10n.phoneGuestLocal, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('more-sign-in'),
              onPressed: () => signInFromAnywhere(context, ref),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandOrange,
                foregroundColor: AppColors.onBrand(AppColors.brandOrange),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 36),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              ),
              child: Text(l10n.profileSignIn),
            ),
          ],
        ),
      ),
    );
  }
}

