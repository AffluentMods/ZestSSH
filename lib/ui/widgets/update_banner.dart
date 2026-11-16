import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/update_check_now.dart' show openUpdate;

/// A slim, dismissible banner shown when a newer app version is available.
///
/// Renders nothing when there is no update (or it was dismissed / disabled),
/// so it can be dropped at the top of any screen unconditionally. Desktop
/// and sideloaded-Android builds are where it matters - the manifest check
/// already skips iOS.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateBannerProvider);
    if (update == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final accent = update.critical ? AppColors.v3Warning : AppColors.v3AccentPrimary;
    final ink = update.critical ? AppColors.v3Warning : AppColors.v3AccentInk;

    return Semantics(
      liveRegion: true,
      label: l10n.updateBannerVersionAvailable(update.version),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          border: Border(
            bottom: BorderSide(color: accent.withValues(alpha: 0.5), width: 0.8),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              update.critical ? LucideIcons.shieldAlert : LucideIcons.arrowUpCircle,
              size: 16,
              color: ink,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    update.critical
                        ? l10n.updateBannerImportantUpdate(update.version)
                        : l10n.updateBannerVersionAvailable(update.version),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3TextPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (update.notes != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        update.notes!,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.v3TextSecondary,
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              // The update's dialog, as the title bar's pill opens it (the
              // download page on a build that does not update itself).
              onPressed: () => openUpdate(context, ref, update),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: accent,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                minimumSize: const Size(0, 32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                textStyle: const TextStyle(
                  fontFamily: 'GeistSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(l10n.updateBannerUpdateAction),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: () => ref.read(updateBannerProvider.notifier).dismiss(),
              icon: const Icon(LucideIcons.x, size: 15),
              color: AppColors.v3TextTertiary,
              tooltip: l10n.updateBannerDismissTooltip,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }
}
