import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_tags_providers.dart';
import '../../../core/theme/zest_colors.dart';

/// Horizontal scrolling strip of tag filter chips.
///
/// Multi-select with OR semantics - a host matches if it has *any* of
/// the selected tags. Tapping a selected chip removes it from the
/// filter set; the trailing "Clear" chip wipes the entire selection.
///
/// Reads the tag vocabulary live from [allTagsProvider] so newly-added
/// tags show up without the parent having to refresh anything. Chip
/// labels are decorated with the per-tag host count from
/// [tagCountsProvider]. The whole widget folds away when the
/// vocabulary is empty so we don't take up vertical space for nothing.
class TagFilterChips extends ConsumerWidget {
  const TagFilterChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(allTagsProvider).valueOrNull ?? const <String>[];
    if (tags.isEmpty) return const SizedBox.shrink();

    final counts =
        ref.watch(tagCountsProvider).valueOrNull ?? const <String, int>{};
    final selected = ref.watch(activeTagFiltersProvider);
    final notifier = ref.read(activeTagFiltersProvider.notifier);

    return SizedBox(
      height: 26,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final tag in tags) ...[
            _TagChip(
              label: counts[tag] != null ? '$tag · ${counts[tag]}' : tag,
              selected: selected.contains(tag),
              onTap: () => notifier.toggle(tag),
            ),
            const SizedBox(width: 8),
          ],
          if (selected.isNotEmpty)
            _TagChip(
              icon: LucideIcons.filterX,
              label: AppLocalizations.of(context)!.zestCommonClear,
              selected: false,
              muted: true,
              onTap: notifier.clear,
            ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    this.icon,
    required this.label,
    required this.selected,
    this.muted = false,
    required this.onTap,
  });
  final IconData? icon;
  final String label;
  final bool selected;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? ZestColors.textPrimary : ZestColors.bgSurface;
    final fg = selected
        ? ZestColors.bgContent
        : (muted ? ZestColors.textTertiary : ZestColors.textPrimary);
    final border = selected
        ? null
        : Border.all(color: ZestColors.borderDefault, width: 0.5);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(13),
              border: border,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 12, color: fg),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
