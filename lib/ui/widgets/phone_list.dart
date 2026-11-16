import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// How wide a phone page's content is drawn on a tablet: one column this
/// wide, centred, as the phone Hosts page has its list there. A page's
/// search, cards and list keep one left edge in it, and pages one width (the
/// hosts' search ran the full width over the centred list, and Networks
/// hugged the left at another width).
const double kPhonePageMaxWidth = 760;

/// [child] in the one column a phone page's content takes on a tablet
/// ([kPhonePageMaxWidth], centred); on a phone, the whole width.
class PhonePageColumn extends StatelessWidget {
  const PhonePageColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kPhonePageMaxWidth),
          child: child,
        ),
      );
}

/// The label over a run of [PhoneListRow]s on a phone (3.0 UI): the More
/// tab's groups and Settings' groups.
class PhoneListGroup extends StatelessWidget {
  const PhoneListGroup(this.label, {super.key});

  final String label;

  // The section label every page has (mono, the brand's tick, a hairline).
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 0),
        child: ZestSectionHeader(label: label),
      );
}

/// A group's rows in one card, divided by hairlines (3.0: each row was a card
/// of its own, a list of boxes).
class PhoneListCard extends StatelessWidget {
  const PhoneListCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: _InCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 0.6, thickness: 0.6, indent: 62, color: AppColors.v3BorderSubtle),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Marks rows drawn inside a [PhoneListCard]: flat, the card is their box.
class _InCard extends InheritedWidget {
  const _InCard({required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_InCard>() != null;

  @override
  bool updateShouldNotify(_InCard oldWidget) => false;
}

/// A row of a phone's list that opens a page (3.0 UI): the accent's icon
/// tile, the name, what it holds or its value under it, and a chevron. A
/// [destructive] row (Settings' reset) is in the error colour, without the
/// chevron, as it asks before it does anything.
class PhoneListRow extends StatelessWidget {
  const PhoneListRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.subtitleMaxLines = 2,
    this.attention = false,
    this.destructive = false,
  });

  static TextStyle get titleStyle =>
      TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ZestColors.textPrimary);

  final IconData icon;
  final Widget title;
  final String? subtitle;

  /// Null lets the words under the name take the lines they need.
  final int? subtitleMaxLines;
  final VoidCallback onTap;
  final bool attention;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ink = destructive ? AppColors.error : AppColors.accentInk;
    final tile = destructive ? AppColors.error : AppColors.brandOrange;
    // In a card, a flat row; alone, its own card.
    final inCard = _InCard.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: inCard ? 0 : 6),
      child: Material(
        color: inCard ? Colors.transparent : AppColors.surface,
        borderRadius: BorderRadius.circular(inCard ? 0 : 12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(inCard ? 0 : 12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: inCard
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.v3BorderSubtle),
                  ),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: tile.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(icon, size: 18, color: ink),
                    ),
                    if (attention)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: Container(
                          key: const ValueKey('more-attention'),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: AppColors.v3Warning,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.surface, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: subtitleMaxLines,
                          overflow: subtitleMaxLines == null ? null : TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, height: 1.35, color: AppColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!destructive) Icon(LucideIcons.chevronRight, size: 18, color: ZestColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row's icon in the accent's tile, as Settings' list and the More tab draw
/// theirs (3.0 UI), for the rows of a phone's settings pages too: an Icon's
/// place takes it as it took the Icon. [color] tints the tile and the glyph
/// (the accent unless given: red for what removes, grey for what is off).
class PhoneIconTile extends StatelessWidget {
  const PhoneIconTile(this.icon, {super.key, this.size, this.color});

  final IconData? icon;

  /// The glyph's size: 18 unless given, and never more than 20 in the tile.
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? AppColors.accentInk;
    final tint = color ?? AppColors.brandOrange;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: math.min(size ?? 18, 20), color: ink),
    );
  }
}

/// What a Free or part-way account can unlock, at the top of a phone's list,
/// outlined: the page's one solid accent belongs to nothing here.
class PhoneUpgradeCard extends StatelessWidget {
  const PhoneUpgradeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.brandOrange.withValues(alpha: 0.4)),
          color: AppColors.brandOrange.withValues(alpha: 0.06),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.accentInk, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.accentInk)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 18, color: AppColors.accentInk),
          ],
        ),
      ),
    );
  }
}

/// A phone list's search field (3.0 UI): the surface's fill, a subtle edge
/// that takes the accent on focus, a search glyph, and a clear button once
/// there is text. It grows with the text size, where the desktop's list
/// field keeps 36 high.
class PhoneSearchField extends StatelessWidget {
  const PhoneSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder edge(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color),
        );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: TextStyle(fontSize: 15, color: ZestColors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.surface,
        hintText: hintText,
        hintStyle: TextStyle(fontSize: 15, color: ZestColors.textTertiary),
        prefixIcon: Icon(LucideIcons.search, size: 18, color: ZestColors.textTertiary),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  key: const ValueKey('phone-search-clear'),
                  icon: Icon(LucideIcons.x, size: 18, color: ZestColors.textTertiary),
                  tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: edge(AppColors.v3BorderSubtle),
        border: edge(AppColors.v3BorderSubtle),
        focusedBorder: edge(AppColors.brandOrange),
      ),
    );
  }
}
