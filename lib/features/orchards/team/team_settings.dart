import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show newRecordKindsOn;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_delete_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// Team settings (4.0):
/// the team's name with Rename, and the Danger zone with Delete team,
/// which were on the everyday Overview. For owners and admins (an admin may
/// rename, only an owner deletes). Deleting keeps its confirmation, its
/// sign-in and its seven days in which an owner or an admin undoes it (the
/// banner at the top of this page and of the Overview).
class TeamSettingsView extends ConsumerWidget {
  const TeamSettingsView({super.key, required this.orchard, this.onOpen});

  final OrchardSummary orchard;

  /// Opens another Team page (a phone pushes it); by default the desktop's
  /// Team destination turns to it.
  final void Function(TeamPage page)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    void go(TeamPage page) => onOpen != null ? onOpen!(page) : ref.read(teamPageProvider.notifier).state = page;
    final runs = orchard.isOwner || orchard.role == FixedRoles.admin;
    final canDelete = orchard.isOwner && orchard.active && newRecordKindsOn.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Deleting, for its seven days: who asked, the day, and Undo.
        const OrchardStatusBanner(padding: EdgeInsets.only(bottom: 14)),
        Container(
          key: const ValueKey('team-settings-name'),
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceElevated,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.border),
          ),
          child: LayoutBuilder(builder: (context, box) {
            final words = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.teamSettingsNameTitle,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                RedactedText(
                  Redactable.account(orchardDisplayName(orchard.name, l10n)),
                  key: const ValueKey('team-settings-name-value'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, height: 1.4, color: ZestTokens.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(l10n.teamSettingsNameBody,
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textTertiary)),
              ],
            );
            final rename = runs && orchard.active
                ? teamButton(
                    key: const ValueKey('team-rename'),
                    label: l10n.teamRename,
                    icon: LucideIcons.pencil,
                    onPressed: () => showRenameOrchardDialog(context, ref, orchard),
                  )
                : null;
            final narrow = box.maxWidth < 420;
            return Row(
              crossAxisAlignment: narrow ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: [
                const TeamIconTile(icon: LucideIcons.users),
                const SizedBox(width: 12),
                Expanded(
                  child: narrow && rename != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [words, const SizedBox(height: 10), rename],
                        )
                      : words,
                ),
                if (!narrow && rename != null) ...[const SizedBox(width: 12), rename],
              ],
            );
          }),
        ),
        if (canDelete) ...[
          // Deleting the team, for everyone: owners, once new
          // kinds of record entry are on everywhere. As it was on the
          // Overview: the same words, the same button, the same flow.
          Padding(
            key: const ValueKey('team-danger-title'),
            padding: const EdgeInsets.only(top: 26),
            child: ZestSectionHeader(label: l10n.accountDangerZone, danger: true),
          ),
          TeamCallout(
            key: const ValueKey('team-delete-zone'),
            tone: TeamTone.critical,
            icon: LucideIcons.trash2,
            title: l10n.teamDeleteAction,
            body: l10n.teamDeleteZoneBody,
            action: teamButton(
              key: const ValueKey('team-delete'),
              label: l10n.teamDeleteAction,
              icon: LucideIcons.trash2,
              kind: TeamButtonKind.danger,
              onPressed: () => deleteTeamFlow(context, ref, orchard, onOpenSetup: () => go(TeamPage.setup)),
            ),
          ),
        ] else if (!orchard.isOwner && orchard.active)
          // An admin renames the team; deleting it is an owner's.
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              l10n.teamSettingsDeleteOwnersOnly,
              key: const ValueKey('team-settings-delete-owners'),
              style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary),
            ),
          ),
      ],
    );
  }
}
