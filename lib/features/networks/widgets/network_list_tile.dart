import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../theme/app_colors.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../models/network.dart';
import 'trigger_summary.dart';

/// A row on the Networks page representing one [Network] in the
/// evaluation order. The Default network gets the same visual treatment
/// minus the drag handle and delete affordance - the parent page is
/// responsible for hiding those when [showDragHandle] is false.
class NetworkListTile extends ConsumerWidget {
  const NetworkListTile({
    super.key,
    required this.network,
    required this.isMatched,
    required this.onTap,
    this.order,
    this.showDragHandle = true,
    this.onDelete,
    this.dragHandle,
    this.overrideBadge,
  });

  /// The network represented by this row.
  final Network network;

  /// 1-based position in the evaluation order, shown as a leading badge so
  /// the "first match wins" priority is explicit (A4). Null hides the badge.
  final int? order;

  /// Whether this network is the one the detector currently matches.
  /// Drives the "Matched now" pill on the right.
  final bool isMatched;

  /// Tapping the body opens the editor (Section 6).
  final VoidCallback onTap;

  /// When false, the trailing drag handle is suppressed. Always false
  /// for the Default network.
  final bool showDragHandle;

  /// When non-null, a delete affordance is shown in the trailing area.
  /// Null on Default so users can't even attempt to delete it.
  final VoidCallback? onDelete;

  /// The reorderable's drag handle, supplied by the [ReorderableListView]
  /// builder. Null when [showDragHandle] is false.
  final Widget? dragHandle;

  /// Optional "{n} host overrides" badge (A3), supplied by the parent row
  /// so the tile stays presentation-only. Null when no hosts override on
  /// this network. Rendered in the trailing area before the matched pill.
  final Widget? overrideBadge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Custom colour (colorValue) wins over the GroupColor token.
    final color = network.effectiveColor;

    return Material(
      color: AppColors.v3Surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          // Asymmetric pill shape: the 3px color bar sits flush left with
          // a slight inset on the right side so the rounded corner reads
          // as a pill, matching the host card pattern.
          padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.v3BorderDefault.withValues(alpha: 0.6),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              // 3px color bar flush-left
              Container(
                width: 3,
                height: 36,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(2),
                    bottomLeft: Radius.circular(2),
                  ),
                ),
              ),

              // Evaluation-order badge - makes the top-down priority explicit.
              if (order != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 18,
                  child: Text(
                    '$order',
                    textAlign: TextAlign.center,
                    // An order, in the app's own type (monospace is for
                    // values to copy; 3.0 quick wins).
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ] else
                const SizedBox(width: 12),

              // Tinted icon container
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(
                  network.icon,
                  size: 18,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),

              // Name + trigger summary
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The profile name identifies the user's environment:
                    // painted in its display form (recording mode).
                    RedactedText(
                      Redactable.network(network.name),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.v3TextPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summariseTriggers(context, network.triggers, ref: ref),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      // What makes it match, as words: the app's own type.
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.v3TextTertiary,
                      ),
                    ),
                  ],
                ),
              ),

              // Override-count badge (A3) - tappable disclosure supplied by
              // the parent row. Sits before the matched pill so the live
              // "Matched now" state stays closest to the edit affordances.
              if (overrideBadge != null) ...[
                const SizedBox(width: 8),
                overrideBadge!,
              ],

              // "Matched now" pill (live)
              if (isMatched) ...[
                const SizedBox(width: 8),
                _MatchedPill(label: l10n.networksMatchedNow),
              ],

              // Visible edit affordance - the whole row is tappable, but a
              // pencil makes "this opens the editor" obvious at a glance (A4).
              const SizedBox(width: 4),
              IconButton(
                tooltip: l10n.networksEdit,
                iconSize: 15,
                onPressed: onTap,
                splashRadius: 18,
                icon: Icon(
                  LucideIcons.pencil,
                  color: AppColors.v3TextTertiary,
                ),
              ),

              // Delete (non-default only)
              if (onDelete != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: l10n.networksDelete,
                  iconSize: 16,
                  onPressed: onDelete,
                  splashRadius: 18,
                  icon: Icon(
                    LucideIcons.trash2,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ],

              // Drag handle (non-default only)
              if (showDragHandle && dragHandle != null) ...[
                const SizedBox(width: 4),
                dragHandle!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The words beside a network when the detector currently matches it.
/// Live-updates from the detector stream - the parent rebuilds with a
/// different `isMatched` and the words come or go. Plain text in the accent
/// (it was a pill; chips are for filters and what needs someone, the 3.0
/// quick wins), as this list is the phone's and the tablet's alone.
class _MatchedPill extends StatelessWidget {
  const _MatchedPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      key: const ValueKey('network-matched-now'),
      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.v3AccentInk),
    );
  }
}
