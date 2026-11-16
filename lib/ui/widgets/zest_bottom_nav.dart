import 'package:flutter/material.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Data class for a navigation item.
class ZestNavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// A count shown on the icon (live sessions), or null.
  final int? count;

  /// A dot on the icon when something there needs the person (the Team,
  /// under More), when there is no count to show.
  final bool attention;

  const ZestNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.count,
    this.attention = false,
  });
}

/// The phone's tab bar (3.0 UI): a standard bar of five tabs. The
/// tab on screen takes the accent colour; the one solid accent fill a
/// screen gets belongs to its main action, not to the bar.
class ZestBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<ZestNavItem> items;

  const ZestBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.items,
  });

  static const double barHeight = 58.0;

  /// Total height of the bar, the home-gesture inset included.
  static double totalHeight(double bottomInset) => barHeight + bottomInset;

  /// A standard floating action button (56) plus its gap above the bar. The
  /// FAB floats above the nav, so lists that share a screen with one must
  /// clear it too.
  static const double fabOverhang = 56.0 + 16.0;

  /// Bottom padding a scrollable list should reserve so its LAST row stays
  /// fully visible and tappable - clearing the bar, the home-gesture inset
  /// and (optionally) a floating action button. Derived from the
  /// real chrome geometry, never a magic number.
  ///
  /// Pass [hasFab] false on screens without a floating action button to avoid
  /// reserving dead space for one.
  static double contentBottomPadding(
    BuildContext context, {
    bool hasFab = true,
  }) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const clearance = 12.0;
    return totalHeight(bottomInset) + clearance + (hasFab ? fabOverhang : 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('phone-tab-bar'),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: barHeight,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _Tab(
                    key: ValueKey('phone-tab-$i'),
                    item: items[i],
                    selected: i == selectedIndex,
                    onTap: () => onDestinationSelected(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({super.key, required this.item, required this.selected, required this.onTap});

  final ZestNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accentInk : ZestColors.textTertiary;
    final count = item.count ?? 0;
    return Semantics(
      selected: selected,
      button: true,
      label: count > 0 ? '${item.label}, $count' : item.label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(selected ? item.selectedIcon : item.icon, size: 23, color: color),
                if (count > 0)
                  Positioned(
                    top: -5,
                    right: -11,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 17),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.brandOrange,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: AppColors.surface, width: 1.5),
                      ),
                      child: Text(
                        count > 99 ? '99+' : '$count',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: AppColors.onBrand(AppColors.brandOrange),
                        ),
                      ),
                    ),
                  )
                else if (item.attention)
                  Positioned(
                    top: -1,
                    right: -3,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: AppColors.v3Warning,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
