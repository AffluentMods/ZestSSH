import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/join_team.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart';
import 'package:zestssh/features/orchards/widgets/orchard_sso_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// The phone's space switcher (3.0): the Home tab's title shows the
/// space on screen, and tapping it opens [showSpaceSwitcherSheet].
class MobileSpaceTitle extends ConsumerWidget {
  const MobileSpaceTitle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Watched so the sheet has the list the moment it opens.
    ref.watch(orchardSummariesProvider);
    final orchard = ref.watch(activeOrchardProvider).valueOrNull;
    final name = orchard == null
        ? treeDisplayName(ref, l10n)
        : orchardDisplayName(orchard.name, l10n);
    // Said as a button that opens the spaces (it was a heading with a
    // picture in it), a finger's 48 high (it was 38: 4.0, the accessibility
    // pass).
    return Semantics(
      button: true,
      child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showSpaceSwitcherSheet(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset('assets/ZestSSH.png', width: 30, height: 30, excludeFromSemantics: true),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RedactedText(
                    Redactable.account(name),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // What kind of space, where the name does not say it already
                  // (Personal under "Personal" said it twice).
                  if (orchard != null || name != l10n.treeSelectorPersonal)
                    Text(
                      orchard == null ? l10n.treeSelectorPersonal : l10n.orchardTeam,
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (spacesNeedAttention(ref)) ...[
              const SpacesAttentionDot(key: ValueKey('space-title-attention')),
              const SizedBox(width: 4),
            ],
            Icon(LucideIcons.chevronDown, size: 14, color: AppColors.textSecondary),
          ],
        ),
      ),
      ),
    );
  }
}

/// Your Tree and your Orchards, each paired with plain words, the one on
/// screen checked; then making an Orchard, a Crate in the Orchard on
/// screen, and syncing.
Future<void> showSpaceSwitcherSheet(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final space = ref.read(activeSpaceProvider);
  final orchards = ref.read(orchardSummariesProvider).valueOrNull ?? const [];
  final active = space is OrchardSpace
      ? orchards.where((o) => o.id == space.orchardId).firstOrNull
      : null;
  final invitations = ref.read(myInvitesProvider);
  final treeName = treeDisplayName(ref, l10n);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          _SpaceTile(
            icon: LucideIcons.user,
            title: treeName,
            subtitle: l10n.containerCrateDescription,
            selected: space is TreeSpace,
            onTap: () {
              Navigator.pop(sheet);
              switchToSpace(context, ref, const TreeSpace());
            },
          ),
          for (final o in orchards)
            _SpaceTile(
              icon: LucideIcons.users,
              title: orchardDisplayName(o.name, l10n),
              subtitle: orchardSubtitle(o, ref, l10n),
              selected: space is OrchardSpace && space.orchardId == o.id,
              onTap: () {
                Navigator.pop(sheet);
                switchToSpace(context, ref, OrchardSpace(o.id));
              },
            ),
          const Divider(),
          ListTile(
            leading: const Icon(LucideIcons.plus),
            title: Text(l10n.orchardCreateAction),
            onTap: () {
              Navigator.pop(sheet);
              showCreateOrchardDialog(context, ref);
            },
          ),
          // Always there: opening it asks the server.
          ListTile(
            leading: const Icon(LucideIcons.mail),
            title: Text(invitations.isEmpty
                ? l10n.myInvitationsTitle
                : l10n.myInvitationsAction(invitations.length)),
            onTap: () {
              Navigator.pop(sheet);
              showMyInvitations(context);
            },
          ),
          // With an invite code (typed, pasted or scanned).
          ListTile(
            key: const ValueKey('space-join-team'),
            leading: const Icon(LucideIcons.qrCode),
            title: Text(l10n.joinTeamTitle),
            onTap: () {
              Navigator.pop(sheet);
              showJoinTeam(context);
            },
          ),
          if (active != null && active.active && active.canAddCrates)
            ListTile(
              leading: const Icon(LucideIcons.package),
              title: Text(l10n.crateNewAction),
              onTap: () {
                Navigator.pop(sheet);
                showNewCrateDialog(context, ref, active.id);
              },
            ),
          if (active != null && active.active)
            ListTile(
              leading: const Icon(LucideIcons.packageOpen),
              title: Text(l10n.orchardCrates),
              onTap: () {
                Navigator.pop(sheet);
                showOrchardCrates(context, ref, active.id);
              },
            ),
          if (active != null && active.active && active.isOwner)
            ListTile(
              leading: const Icon(LucideIcons.shieldCheck),
              title: Text(l10n.orchardRoles),
              onTap: () {
                Navigator.pop(sheet);
                showOrchardRoles(context, ref, active.id);
              },
            ),
          // Everyone sees the rules; owners change them, even while held back
          // by them.
          if (active != null && (active.active || active.status == 'rules'))
            ListTile(
              leading: const Icon(LucideIcons.scrollText),
              title: Text(l10n.orchardRules),
              onTap: () {
                Navigator.pop(sheet);
                showOrchardRules(context, ref, active.id);
              },
            ),
          if (active != null && active.active && active.isOwner)
            ListTile(
              leading: const Icon(LucideIcons.globe),
              title: Text(l10n.teamPageSignIn),
              onTap: () {
                Navigator.pop(sheet);
                showOrchardSignIn(context, active);
              },
            ),
          if (active != null && active.active && (active.isOwner || active.role == FixedRoles.admin))
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: Text(l10n.orchardRenameAction),
              onTap: () {
                Navigator.pop(sheet);
                showRenameOrchardDialog(context, ref, active);
              },
            ),
          if (active != null)
            ListTile(
              leading: const Icon(LucideIcons.users),
              title: Text(active.invitesWaiting > 0
                  ? l10n.orchardMembersWaiting(active.invitesWaiting)
                  : l10n.orchardMembers),
              onTap: () {
                Navigator.pop(sheet);
                showOrchardMembers(context, ref, active.id);
              },
            ),
          if (orchards.isNotEmpty)
            ListTile(
              leading: const Icon(LucideIcons.refreshCw),
              title: Text(l10n.orchardSyncNow),
              onTap: () {
                Navigator.pop(sheet);
                syncOrchardsNow(context, ref);
              },
            ),
        ],
      ),
    ),
  );
}

class _SpaceTile extends StatelessWidget {
  const _SpaceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: RedactedText(Redactable.account(title)),
        subtitle: Text(subtitle),
        trailing: selected ? Icon(LucideIcons.check, color: AppColors.accentInk) : null,
        onTap: onTap,
      );
}
