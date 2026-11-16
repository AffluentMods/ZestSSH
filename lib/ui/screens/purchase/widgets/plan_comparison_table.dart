import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeMonitorLimit, freeSessionLimit;
import 'package:zestssh/theme/app_colors.dart';

/// Feature row data for the comparison table.
class _FeatureRow {
  final String name;
  final String fresh; // Free
  final String squeezed; // Squeezed: what Pro unlocks
  final String juiced; // Juiced: ZestSSH Cloud, with Free or with Squeezed

  const _FeatureRow(this.name, this.fresh, this.squeezed, this.juiced);
}

const _yes = '✓';
const _no = '✗';
const _unlimited = '∞';

/// A comparison table showing Fresh (Free) vs Squeezed vs Juiced features,
/// as the app holds each to them (3.0, 16 October 2026: it said, in English,
/// that Free kept 3 hosts, 5 snippets and 3 themes and had no sync and no
/// backups, and that Juiced had every Squeezed feature; Free keeps hosts and
/// snippets without limit, has every built-in theme, syncs with storage of
/// one's own and backs up, and Juiced is ZestSSH Cloud alone). The counts are
/// the limits the app checks ([freeSessionLimit], [freeMonitorLimit]).
class PlanComparisonTable extends StatelessWidget {
  const PlanComparisonTable({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final features = <_FeatureRow>[
      // What every one of them has.
      _FeatureRow(l10n.planRowBasics, _yes, _yes, _yes),
      _FeatureRow(l10n.planRowOwnStorageSync, _yes, _yes, _yes),
      _FeatureRow(l10n.planRowBackups, _yes, _yes, _yes),
      _FeatureRow(l10n.planRowBuiltInThemes, _yes, _yes, _yes),
      _FeatureRow(l10n.upgradeFeaturePortForwarding, _yes, _yes, _yes),
      // What Squeezed unlocks.
      _FeatureRow(l10n.planRowSessions, '$freeSessionLimit', _unlimited, '$freeSessionLimit'),
      _FeatureRow(l10n.planRowMonitors, '$freeMonitorLimit', _unlimited, '$freeMonitorLimit'),
      _FeatureRow(l10n.upgradeFeatureAllThemes, _no, _yes, _no),
      _FeatureRow(l10n.upgradeFeatureJumpServer, _no, _yes, _no),
      _FeatureRow(l10n.upgradeFeatureSpeechToText, _no, _yes, _no),
      _FeatureRow(l10n.deskUpgSqueezedFeatureAutomation, _no, _yes, _no),
      // What Juiced is.
      _FeatureRow(l10n.planRowZestCloud, _no, _no, _yes),
    ];
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
        color: AppColors.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // ── Header row ──────────────────────────────────
          _buildHeaderRow(l10n),
          Divider(height: 1, color: AppColors.divider),

          // ── Feature rows ────────────────────────────────
          for (var i = 0; i < features.length; i++) ...[
            _buildFeatureRow(features[i], isEven: i.isEven),
            if (i < features.length - 1)
              Divider(height: 1, color: AppColors.divider),
          ],
        ],
      ),
    );
  }

  Widget _buildHeaderRow(AppLocalizations l10n) {
    return Container(
      color: AppColors.surfaceContainer,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                l10n.upgradeFeature,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
          // Fresh
          Expanded(
            flex: 2,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: AppColors.onSurfaceDim.withValues(alpha: 0.15),
                ),
                child: Text(
                  l10n.upgradeFreshTitle,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
          // Squeezed and Juiced, side by side: neither holds the other.
          for (final name in [l10n.upgradeSqueezedTitle, l10n.upgradeFeatureCloudSync])
            Expanded(
              flex: 2,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: AppColors.brandOrange.withValues(alpha: 0.15),
                  ),
                  child: Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: AppColors.accentInk,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFeatureRow(_FeatureRow feature, {required bool isEven}) {
    return Container(
      color: isEven ? Colors.transparent : AppColors.surfaceContainer.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Row(
        children: [
          // Feature name
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                feature.name,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.onSurface,
                ),
              ),
            ),
          ),
          for (final value in [feature.fresh, feature.squeezed, feature.juiced])
            Expanded(
              flex: 2,
              child: Center(child: _buildCellValue(value)),
            ),
        ],
      ),
    );
  }

  Widget _buildCellValue(String value) {
    if (value == _yes) {
      return Icon(
        LucideIcons.checkCircle2,
        size: 18,
        color: AppColors.accentInk.withValues(alpha: 0.85),
      );
    }
    if (value == _no) {
      return Icon(
        LucideIcons.xCircle,
        size: 18,
        color: AppColors.onSurfaceDim.withValues(alpha: 0.4),
      );
    }
    // A count ("2", "5") or no limit ("∞").
    return Text(
      value,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.onSurface,
      ),
    );
  }
}
