import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// The four ways to get servers into ZestSSH, ordered by value:
/// import from SSH config, scan the local network, restore from sync, add
/// one manually.
///
/// Shared between the first-run onboarding screen and the empty host grid so
/// the paths are identical everywhere. Purely presentational - the caller
/// wires each action.
class GetConnectedOptions extends StatelessWidget {
  const GetConnectedOptions({
    super.key,
    required this.onImport,
    required this.onScan,
    required this.onRestore,
    required this.onAdd,
    this.importSubtitle,
    this.importPrimary = false,
    this.importEnabled = true,
  });

  final VoidCallback onImport;
  final VoidCallback onScan;
  final VoidCallback onRestore;
  final VoidCallback onAdd;

  /// Overrides the default import subtitle - used by onboarding to show the
  /// count of servers detected in `~/.ssh/config` (or "none found").
  final String? importSubtitle;

  /// Highlights the import tile as the recommended path (when a config with
  /// importable hosts was detected).
  final bool importPrimary;

  /// When false the import tile is shown but not tappable (e.g. no config
  /// exists) - it explains rather than sitting inert.
  final bool importEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OptionTile(
          icon: LucideIcons.download,
          title: l10n.firstRunImportTitle,
          subtitle: importSubtitle ?? l10n.firstRunImportDescNone,
          primary: importPrimary,
          enabled: importEnabled,
          onTap: onImport,
        ),
        const SizedBox(height: 12),
        _OptionTile(
          icon: LucideIcons.wifi,
          title: l10n.firstRunScanTitle,
          subtitle: l10n.firstRunScanDesc,
          onTap: onScan,
        ),
        const SizedBox(height: 12),
        _OptionTile(
          icon: LucideIcons.downloadCloud,
          title: l10n.firstRunRestoreTitle,
          subtitle: l10n.firstRunRestoreDesc,
          onTap: onRestore,
        ),
        const SizedBox(height: 12),
        _OptionTile(
          icon: LucideIcons.plusCircle,
          title: l10n.firstRunAddTitle,
          subtitle: l10n.firstRunAddDesc,
          onTap: onAdd,
        ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final borderColor = primary
        ? AppColors.brandOrange.withValues(alpha: 0.55)
        : AppColors.divider;
    final bgColor = primary
        ? AppColors.brandOrange.withValues(alpha: 0.08)
        : AppColors.surface;

    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: borderColor,
                width: primary ? 1.0 : 0.5,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.brandOrange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: AppColors.accentInk),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.onSurface,
                              ),
                            ),
                          ),
                          if (primary) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.brandOrange
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Icon(LucideIcons.star,
                                  size: 11, color: AppColors.accentInk),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textSecondary,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (enabled)
                  Icon(LucideIcons.chevronRight,
                      size: 20, color: AppColors.onSurfaceDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
