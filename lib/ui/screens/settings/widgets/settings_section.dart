import 'package:flutter/material.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';

/// A group of a phone's settings page (3.0 UI): its name as every section
/// header (ZestSectionHeader), over its rows in one card on the surface with
/// a subtle edge. With [card] false, the name alone over [child] (a grid of
/// themes, say). With [title] null, no header: a page of one section has its
/// name in its app bar already.
///
/// The rows are the one settings row of the phone (3.0 UI review: three
/// looks across the pages): the name as Settings' list draws its own
/// (PhoneListRow.titleStyle), what it does under it in the secondary text
/// (it took the theme's text colour, a list tile's colour overriding the
/// style's), the icon tile beside them, a grey chevron, and an inset hairline
/// between rows. The icon and the chevron stand level with a row of one line
/// (a name and its More, with or without a value under it) and near the top of
/// a taller one (4.0: rows are one line, their help behind More; at the top of
/// every row they stood higher than the name, found by the device run of 13
/// November 2026).
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.child, this.card = true});

  final String? title;
  final Widget child;
  final bool card;

  /// The rows' look, for a card that draws rows of its own the same way.
  static ListTileThemeData rowTheme(BuildContext context) {
    final base = Theme.of(context).textTheme;
    return ListTileThemeData(
      // Glyphs standing alone in a row (a chevron): grey; the icon tiles
      // bring their own colour.
      iconColor: ZestTokens.textTertiary,
      contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
      horizontalTitleGap: 12,
      minLeadingWidth: 36,
      minVerticalPadding: 12,
      titleAlignment: ListTileTitleAlignment.titleHeight,
      // In the app's own font, without the theme's wide tracking: a list
      // tile's styles stand in for the theme's, its font family too.
      titleTextStyle: base.bodyLarge?.merge(PhoneListRow.titleStyle.copyWith(letterSpacing: 0, height: 1.3)),
      subtitleTextStyle: base.bodyMedium
          ?.merge(TextStyle(fontSize: 12.5, height: 1.35, letterSpacing: 0, color: AppColors.textSecondary)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A column of rows has a hairline between each, inset to the words.
    var rows = child;
    final column = child;
    if (column is Column && column.children.length > 1) {
      rows = Column(
        mainAxisSize: column.mainAxisSize,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < column.children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, indent: 60, color: AppColors.v3BorderSubtle),
            column.children[i],
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 0),
            child: ZestSectionHeader(label: title!),
          )
        else
          const SizedBox(height: 12),
        if (!card)
          child
        else
          Container(
            key: const ValueKey('settings-section-card'),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Material(
              type: MaterialType.transparency,
              // Its own row look, whole, in the theme too: a list tile
              // paints its subtitle with the theme's list text colour where
              // one is set, whatever its style says.
              child: Theme(
                data: Theme.of(context).copyWith(listTileTheme: rowTheme(context)),
                child: ListTileTheme(data: rowTheme(context), child: rows),
              ),
            ),
          ),
      ],
    );
  }
}
