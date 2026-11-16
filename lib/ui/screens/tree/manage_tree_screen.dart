import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show showCreateOrchardDialog;
import 'package:zestssh/providers/tree_providers.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/sync/sync_now.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/ui/widgets/ink_layer.dart';

/// Manage Tree page - covers the broad "what is this tree, who's in
/// it, how do I switch / leave" surface area.
///
/// A "tree" in ZestSSH is the top-level container the user lives in:
/// their hosts, identities, snippets, port forwards, etc. all belong
/// to a tree. Free + Squeezed tiers have a single Personal tree.
/// The Juiced tier will eventually support multiple trees +
/// collaborator invites - that surface is rendered as a locked
/// upsell card here until Cloud Sync lands the multi-tree backend.
class ManageTreeScreen extends ConsumerWidget {
  const ManageTreeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(currentUserProvider);
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final hostCount = connectionsAsync.valueOrNull?.length ?? 0;
    final isCloudSync = ref.watch(isCloudSyncProvider);
    // Sync is free with any backend; the Juiced flag only says whether the
    // hosted ZestSSH Cloud storage is unlocked. Label the tree by whether sync
    // is actually set up on this device, naming the hosted store when that is
    // the backend in use, so a user syncing to their own WebDAV/S3/Drive is
    // not told the tree is local-only.
    final syncOn = ref.watch(syncIsActiveProvider).valueOrNull ?? false;
    final hostedBackend =
        ref.watch(syncProviderConfigProvider).kind.isHosted;
    final syncLabel = !syncOn
        ? l10n.manageTreeSyncLocalOnly
        : hostedBackend
            ? l10n.manageTreeSyncViaCloud
            : l10n.manageTreeSyncedGeneric;

    // A name given with "Rename tree" wins over the account-derived one.
    final treeName =
        ref.watch(treeNameOverrideProvider) ?? _treeName(user, l10n);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.manageTreeTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TreeHeroCard(
                  treeName: treeName,
                  hostCount: hostCount,
                  syncLabel: syncLabel,
                ),
                const SizedBox(height: 28),
                _SectionHeader(l10n.manageTreeMembers),
                const SizedBox(height: 8),
                _MembersCard(
                  user: user,
                  isCloudSync: isCloudSync,
                ),
                const SizedBox(height: 28),
                _SectionHeader(l10n.manageTreeTreeSettings),
                const SizedBox(height: 8),
                _TreeSettingsCard(
                  treeName: treeName,
                  syncOn: syncOn,
                ),
                const SizedBox(height: 28),
                _SectionHeader(l10n.manageTreeDangerZone, danger: true),
                const SizedBox(height: 8),
                _DangerZoneCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _treeName(dynamic user, AppLocalizations l10n) {
    if (user == null) return l10n.manageTreeDefaultName;
    final displayName = user.displayName as String?;
    final email = user.email as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      final first = displayName.trim().split(RegExp(r'\s+')).first;
      return l10n.manageTreePossessiveName(first);
    }
    if (email != null && email.contains('@')) {
      return l10n.manageTreePossessiveName(email.split('@').first);
    }
    return l10n.manageTreeDefaultName;
  }
}

// ══════════════════════════════════════════════════════════════════
// Hero card
// ══════════════════════════════════════════════════════════════════

class _TreeHeroCard extends StatelessWidget {
  const _TreeHeroCard({
    required this.treeName,
    required this.hostCount,
    required this.syncLabel,
  });

  final String treeName;
  final int hostCount;

  /// 'Synced via ZestSSH Cloud', 'Synced' (bring-your-own store) or
  /// 'Local-only', decided by the parent from the real sync state.
  final String syncLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.brandOrange.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color:
                      AppColors.brandOrange.withValues(alpha: 0.45),
                  width: 0.6),
            ),
            child: Icon(LucideIcons.user,
                size: 26, color: AppColors.accentInk),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  treeName,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onBackground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.manageTreeHostCountWithSync(hostCount, syncLabel),
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Section header
// ══════════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, {this.danger = false});
  final String label;

  /// The Danger zone: the header in red.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: ZestSectionHeader(label: label, danger: danger),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Members
// ══════════════════════════════════════════════════════════════════

class _MembersCard extends StatelessWidget {
  const _MembersCard({required this.user, required this.isCloudSync});
  final dynamic user;
  final bool isCloudSync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final displayName = user?.displayName ?? l10n.manageTreeYou;
    final email = user?.email ?? 'guest@local';

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: InkLayer(
        child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: AppColors.brandOrange.withValues(alpha: 0.18),
              child: Text(
                (displayName as String).isNotEmpty
                    ? displayName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: AppColors.accentInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            title: Text(
              displayName,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              email,
              style: TextStyle(
                  fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
            trailing: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.brandOrange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                l10n.manageTreeOwner,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accentInk,
                ),
              ),
            ),
          ),
          // People are invited to a team, not to the personal space: the row
          // makes one (where teams are built in; it said "coming in 3.0").
          if (kOrchardsEnabled) ...[
            Divider(height: 1, color: AppColors.divider),
            const _InviteRow(),
          ],
        ],
        ),
      ),
    );
  }
}

class _InviteRow extends ConsumerWidget {
  const _InviteRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Working with others is a team, sold as seats, not part of Juiced: the
    // row makes one, the same for everyone.
    return ListTile(
      key: const ValueKey('manage-tree-invite'),
      leading: Icon(LucideIcons.userPlus,
          size: 20, color: AppColors.onSurfaceVariant),
      title: Text(
        l10n.manageTreeInviteCollaborator,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        l10n.manageTreeInviteComingSoon,
        style: TextStyle(
            fontSize: 11, color: AppColors.onSurfaceVariant),
      ),
      trailing: Icon(LucideIcons.chevronRight,
          size: 14, color: AppColors.onSurfaceDim),
      onTap: () => showCreateOrchardDialog(context, ref),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Tree settings
// ══════════════════════════════════════════════════════════════════

class _TreeSettingsCard extends ConsumerWidget {
  const _TreeSettingsCard({
    required this.treeName,
    required this.syncOn,
  });
  final String treeName;

  /// Whether sync is set up on this device, with any storage: sync is free,
  /// and Juiced only brings ZestSSH Cloud's (it said Juiced was needed).
  final bool syncOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: InkLayer(
        child: Column(
        children: [
          ListTile(
            leading: Icon(LucideIcons.pencil,
                size: 18, color: AppColors.onSurfaceVariant),
            title: Text(l10n.manageTreeRenameTree,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
            subtitle: Text(
              l10n.manageTreeCurrentlyNamed(treeName),
              style: TextStyle(
                  fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
            trailing: Icon(LucideIcons.chevronRight,
                size: 14, color: AppColors.onSurfaceDim),
            onTap: () => _showRenameDialog(context, ref, treeName),
          ),
          Divider(height: 1, color: AppColors.divider),
          ListTile(
            leading: Icon(LucideIcons.refreshCw,
                size: 18, color: AppColors.onSurfaceVariant),
            title: Text(l10n.manageTreeForceSyncNow,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
            subtitle: Text(
              syncOn
                  ? l10n.manageTreeForceSyncActive
                  : l10n.manageTreeForceSyncUpsell,
              key: const ValueKey('manage-tree-sync-subtitle'),
              style: TextStyle(
                  fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
            trailing: Icon(LucideIcons.chevronRight,
                size: 14, color: AppColors.onSurfaceDim),
            onTap: syncOn
                // Syncs (it said where else to look, and synced nothing).
                ? () => runSyncNow(context, ref)
                : () => showTopSnackBar(
                    context, l10n.manageTreeSyncRequiresJuiced),
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _showRenameDialog(
      BuildContext context, WidgetRef ref, String currentName) async {
    final l10n = AppLocalizations.of(context)!;
    // Tree rename is a SharedPreferences entry rather than a server-side
    // mutation today (single-tree mode). Using prefs lets every screen
    // pick up the change without rewiring sync.
    final rawName = await showZestInputDialog(
      context: context,
      title: l10n.manageTreeRenameTree,
      icon: LucideIcons.pencil,
      fieldLabel: l10n.manageTreeTreeNameLabel,
      hintText: l10n.manageTreeTreeNameHint,
      initialValue: currentName,
      confirmLabel: l10n.save,
      validator: (v) => v.trim().isEmpty ? l10n.manageTreeEnterAName : null,
    );
    final newName = rawName?.trim();
    if (newName == null || newName.isEmpty || !context.mounted) return;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(kTreeNameOverrideKey, newName);
    // The Tree menu and this screen watch the provider, so both update.
    ref.read(treeNameOverrideProvider.notifier).state = newName;
    if (!context.mounted) return;
    showTopSnackBar(context, l10n.manageTreeRenamedTo(newName));
  }
}

// ══════════════════════════════════════════════════════════════════
// Danger zone - sign out + delete
// ══════════════════════════════════════════════════════════════════

class _DangerZoneCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: InkLayer(
        child: Column(
        children: [
          ListTile(
            leading: Icon(LucideIcons.logOut,
                size: 18, color: AppColors.onSurfaceVariant),
            title: Text(l10n.manageTreeSignOut,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
            subtitle: Text(
              l10n.manageTreeSignOutSubtitle,
              style: TextStyle(
                  fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
            trailing: Icon(LucideIcons.chevronRight,
                size: 14, color: AppColors.onSurfaceDim),
            onTap: () => _confirmSignOut(context, ref),
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.read(profileControllerProvider);
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.manageTreeSignOutConfirmTitle,
      body: profiles.on
          ? [
              l10n.signOutLocksBody,
              if (profiles.openSessions > 0) l10n.signOutSessionsClose(profiles.openSessions),
            ].join('\n\n')
          : l10n.manageTreeSignOutConfirmBody,
      confirmLabel: l10n.manageTreeSignOut,
    );
    if (ok != true || !context.mounted) return;
    try {
      await signOutAccount(ref);
      if (!context.mounted) return;
      showTopSnackBar(context, l10n.manageTreeSignedOut);
    } catch (e) {
      if (!context.mounted) return;
      showTopSnackBar(context, l10n.treeSelectorNotSignedOut, isError: true, details: '$e');
    }
  }
}
