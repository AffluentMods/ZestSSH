import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/update_dialog.dart';

/// "Update available" at the top right of the title bar, beside Search and
/// the bell, in the brand's orange so it cannot be missed (3.0: a
/// simple update button that appears in the top
/// right or somewhere obvious). A click opens the update's dialog. It shows only
/// while a newer release is known, and only on a computer's build from the
/// website: a store's build and a phone never show it
/// ([inAppUpdateSupportedProvider]). It says "Major update available" where
/// the release's first number is higher than this copy's. It stays hidden
/// where the release is installed by itself at the next start, or the person
/// chose "Ignore update" ([updateNoticeHiddenProvider]); the status bar's
/// version still offers the update.
class UpdateAvailablePill extends ConsumerStatefulWidget {
  const UpdateAvailablePill({super.key});

  @override
  ConsumerState<UpdateAvailablePill> createState() => _UpdateAvailablePillState();
}

class _UpdateAvailablePillState extends ConsumerState<UpdateAvailablePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(inAppUpdateSupportedProvider)) return const SizedBox.shrink();
    final update = ref.watch(availableUpdateProvider);
    if (update == null || ref.watch(updateNoticeHiddenProvider)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final current = ref.watch(appVersionProvider).valueOrNull;
    final label = current != null && isMajorUpdate(current, update.version) ? l10n.appUpdatePillMajor : l10n.appUpdatePill;
    final fill = AppColors.v3AccentPrimary;
    final ink = AppColors.onBrand(fill);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Tooltip(
        message: update.critical
            ? l10n.desktopStatusUpdateCriticalTooltip(update.version)
            : l10n.desktopStatusUpdateAvailableTooltip(update.version),
        child: Semantics(
          button: true,
          label: label,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              key: const ValueKey('update-pill'),
              onTap: () => showUpdateDialog(context, update),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: _hover ? Color.lerp(fill, Colors.white, 0.12) : fill,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(color: fill.withValues(alpha: _hover ? 0.45 : 0.28), blurRadius: _hover ? 12 : 8),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(update.critical ? LucideIcons.shield : LucideIcons.arrowUpCircle, size: 14, color: ink),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'GeistSans',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
