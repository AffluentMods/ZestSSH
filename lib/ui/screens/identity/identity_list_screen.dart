import 'package:zestssh/features/orchards/certs/crate_authorities.dart' show authorityOfKey;
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show showMoveCopyDialog, transferOffer;
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestInkOnTint;
import 'package:flutter/services.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/screens/identity/key_users.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Lists all configured identities (username + auth method pairs).
class IdentityListScreen extends ConsumerWidget {
  const IdentityListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final identitiesAsync = ref.watch(identitiesProvider);
    final usageCounts =
        ref.watch(identityUsageCountsProvider).valueOrNull ?? {};
    final lastUsedMap =
        ref.watch(identityLastUsedProvider).valueOrNull ?? {};

    return Scaffold(
      appBar: AppBar(title: Text(l10n.identityListTitle)),
      body: DesktopContentWrapper(
        child: identitiesAsync.when(
        data: (identities) {
          if (identities.isEmpty) {
            return ZestEmptyState(
              icon: LucideIcons.keyRound,
              title: l10n.identityNoIdentities,
              message: l10n.identityNoIdentitiesDesc,
              actionLabel: l10n.homeAddNewIdentity,
              onAction: () => context.push(Routes.identityEdit),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: identities.length,
            itemBuilder: (context, index) {
              final identity = identities[index];
              return _IdentityCard(
                identity: identity,
                count: usageCounts[identity.id] ?? 0,
                lastUsed: lastUsedMap[identity.id],
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(l10n.identityLoadError)),
      )),
      // Named by its tooltip, which names the button itself (a label
      // around it named a node above it, and the button was unnamed).
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.homeAddNewIdentity,
        onPressed: () => context.push(Routes.identityEdit),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }
}

class _IdentityCard extends ConsumerWidget {
  final Identity identity;
  final int count;
  final DateTime? lastUsed;

  const _IdentityCard({
    required this.identity,
    required this.count,
    this.lastUsed,
  });

  static const _keyColor = AppColors.identityKey;
  static const _passwordColor = AppColors.identityPassword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isKey = identity.authMethod == 'publicKey';
    final accentColor = isKey ? _keyColor : _passwordColor;
    // The kind's words and glyph on its own wash, in the shade that reads
    // there (Daylight's teal was 2.7:1).
    final badgeInk = zestInkOnTint(accentColor, 0.12);

    final usageLabel = count == 0
        ? l10n.identityNotInUse
        : count == 1
            ? l10n.identityOneConnection
            : l10n.identityConnectionCount(count);

    // Avatar icon
    final avatarIcon = isKey ? LucideIcons.keyRound : LucideIcons.lock;

    // Key strength
    Color? strengthColor;
    String? strengthLabel;
    if (isKey && identity.keyType != null) {
      final kt = identity.keyType!.toLowerCase();
      if (kt.contains('ed25519')) {
        strengthColor = AppColors.keyStrengthStrong;
        strengthLabel = l10n.identityListStrengthStrong;
      } else if (kt.contains('ecdsa')) {
        strengthColor = AppColors.keyStrengthGood;
        strengthLabel = l10n.identityListStrengthGood;
      } else if (kt.contains('rsa')) {
        strengthColor = Colors.amber;
        strengthLabel = l10n.identityListStrengthLegacy;
      }
    }

    // Fingerprint preview: masked first, then shortened, so the recording-mode
    // fake is cut the same way a real value is.
    String? fingerprint;
    if (isKey &&
        identity.publicKeyFingerprint != null &&
        identity.publicKeyFingerprint!.isNotEmpty) {
      final fp = Redactable.fingerprint(identity.publicKeyFingerprint!)
          .displayIn(ref);
      fingerprint = fp.length > 20 ? '${fp.substring(0, 20)}...' : fp;
    }

    // Key comment
    String? keyComment;
    if (isKey && identity.publicKeyData != null) {
      final parts = identity.publicKeyData!.trim().split(' ');
      if (parts.length >= 3) {
        keyComment = parts.sublist(2).join(' ');
      }
    }

    // Last used, in the shared compact words, counting on past a week.
    final lastUsedText = lastUsed == null ? null : timeAgoWords(l10n, lastUsed!, keepCounting: true);

    return Semantics(
      // Announced rather than painted, but the recording-mode golden test
      // counts semantics labels as rendered strings, and a recording can
      // carry audio.
      label: '${Redactable.keyName(identity.label).displayIn(ref)}, '
          '${Redactable.username(identity.username).displayIn(ref)}, '
          '${isKey ? (identity.keyType ?? l10n.identityListKeyLabel) : l10n.identityPassword}'
          '${identity.isDefault ? ', ${l10n.identityDefault}' : ''}'
          ', $usageLabel',
      button: true,
      hint: l10n.identityEditHint,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push('/identity/edit/${identity.id}'),
            onLongPress: () => _showContextMenu(context, ref),
            borderRadius: BorderRadius.circular(12),
            child: Row(
              children: [
                Container(width: 4, height: 80, color: accentColor),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: count == 0
                        ? accentColor.withValues(alpha: 0.08)
                        : accentColor.withValues(alpha: 0.15),
                    child: Icon(
                      avatarIcon,
                      color: count == 0
                          ? AppColors.textSecondary
                          : accentColor,
                      size: 24,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Name + DEFAULT badge
                        Row(
                          children: [
                            Expanded(
                              child: RedactedText(
                                Redactable.keyName(identity.label),
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: count == 0
                                      ? AppColors.textSecondary
                                      : null,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (identity.isDefault) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.brandOrange
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  l10n.identityDefault.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.accentInk,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        // Username + auth badge + strength
                        Row(
                          children: [
                            Flexible(
                              child: RedactedText(
                                Redactable.username(identity.username),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'JetBrainsMono',
                                  color: AppColors.textSecondary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: accentColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isKey ? LucideIcons.keyRound : LucideIcons.lock,
                                    size: 10,
                                    color: badgeInk,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    isKey
                                        ? (identity.keyType ??
                                            l10n.identityListKeyLabel)
                                        : l10n.identityPassword,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: badgeInk,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (strengthColor != null) ...[
                              const SizedBox(width: 4),
                              Icon(LucideIcons.shield,
                                  size: 12, color: strengthColor),
                              const SizedBox(width: 2),
                              Text(
                                strengthLabel!,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: strengthColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                        // Fingerprint / key comment + usage + last used
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (fingerprint != null) ...[
                              Flexible(
                                child: Text(
                                  fingerprint,
                                  style: TextStyle(
                                    fontFamily: 'JetBrainsMono',
                                    fontSize: 10,
                                    color: AppColors.textSecondary
                                        .withValues(alpha: 0.45),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ] else if (keyComment != null) ...[
                              Flexible(
                                child: RedactedText(
                                  Redactable.keyComment(keyComment),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.textSecondary
                                        .withValues(alpha: 0.5),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            if (fingerprint != null || keyComment != null)
                              const SizedBox(width: 6),
                            Text(
                              usageLabel,
                              style: TextStyle(
                                fontSize: 10,
                                // "Not in use" in the muted grey that reads
                                // (faded to 0.4 it was 2 to 2.3:1).
                                color: count == 0
                                    ? AppColors.v3TextTertiary
                                    : AppColors.textSecondary,
                              ),
                            ),
                            if (lastUsedText != null)
                              Text(
                                ' · $lastUsedText',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textSecondary
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(LucideIcons.chevronRight,
                      size: 20, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isKey = identity.authMethod == 'publicKey';
    // Move to... and Copy to...: Personal, or a team's vault (3.4); never the
    // key a vault signs certificates with, which belongs to its vault.
    final offer = identity.authMethod == 'teamCertificate' || authorityOfKey(ref, identity) != null
        ? (move: false, copy: false)
        : transferOffer(ref, TransferKinds.key, [identity.id]);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      // Taller than a sheet's default height on a short screen: it takes the
      // height it needs and scrolls (as the Keys list's own sheet).
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: RedactedText(
                  Redactable.keyName(identity.label),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(LucideIcons.pencil),
                title: Text(l10n.edit),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/identity/edit/${identity.id}');
                },
              ),
              ListTile(
                leading: const Icon(LucideIcons.star),
                title: Text(l10n.identityListSetAsDefault),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(identityCrudProvider).setDefault(identity.id);
                  showTopSnackBar(
                    context,
                    l10n.homeSetAsDefault(
                        Redactable.keyName(identity.label).display),
                  );
                },
              ),
              if (isKey && identity.publicKeyData != null)
                ListTile(
                  leading: const Icon(LucideIcons.share2),
                  title: Text(l10n.identityListSharePublicKey),
                  onTap: () async {
                    Navigator.pop(ctx);
                    // A key goes to the clipboard: reveal gate (spec 5).
                    if (!await confirmRevealWhileRecording(context, ref)) {
                      return;
                    }
                    if (!context.mounted) return;
                    Clipboard.setData(
                        ClipboardData(text: identity.publicKeyData!));
                    showTopSnackBar(context, l10n.identityListPublicKeyCopied);
                  },
                ),
              for (final (mode, icon, label) in [
                if (offer.move) (TransferMode.move, LucideIcons.folderInput, l10n.transferMoveTo),
                if (offer.copy) (TransferMode.copy, LucideIcons.copyPlus, l10n.transferCopyTo),
              ])
                ListTile(
                  key: ValueKey('key-sheet-${mode.name}-to'),
                  leading: Icon(icon),
                  title: Text(label),
                  onTap: () {
                    Navigator.pop(ctx);
                    showMoveCopyDialog(context, ref, kind: TransferKinds.key, keys: [identity.id], mode: mode);
                  },
                ),
              ListTile(
                leading:
                    Icon(LucideIcons.trash2, color: AppColors.error),
                title: Text(l10n.delete,
                    style: TextStyle(color: AppColors.error)),
                onTap: () async {
                  Navigator.pop(ctx);
                  // The hosts that use it, by name (up to five, then how
                  // many more).
                  final users = count > 0 ? await keyUsersLines(ref, l10n, identity.id) : const <String>[];
                  if (!context.mounted) return;
                  final confirmed = await ZestConfirmDialog.show(
                    context,
                    tone: ZestDialogTone.destructive,
                    title: l10n.identityListDeleteConfirmTitle(
                          Redactable.keyName(identity.label).display),
                    body: l10n.identityListDeleteUsageMessage(count),
                    bullets: users,
                    confirmLabel: l10n.delete,
                  );
                  if (confirmed == true) {
                    await ref
                        .read(identityCrudProvider)
                        .delete(identity.id);
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
