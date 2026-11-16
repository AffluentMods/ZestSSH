import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/features/changelog/changelog_data.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show AccountPlan;
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show PlanChip;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_surfaces.dart' show readableShade;
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestInkOnTint;
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The in-app "What's new" changelog, the same release notes shown at
/// zestssh.com/changelog (see [kChangelog]). A centred dialog: a header with
/// the title and a close button, then the full history newest first, each
/// version grouped into its categories the way the website groups them.
Future<void> showWhatsNewDialog(BuildContext context) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: const WhatsNewDialog(),
  );
}

/// The changelog category colours, mirroring the website's taxonomy so the
/// two read as one product. No AppColors equivalents exist for this set of
/// five semantic hues, so they live here beside the data they label.
Color _categoryColor(ChangelogCategory c) {
  switch (c) {
    case ChangelogCategory.breaking:
      return const Color(0xFFEF5350);
    case ChangelogCategory.security:
      return const Color(0xFF34D399);
    case ChangelogCategory.features:
      return const Color(0xFFA78BFA);
    case ChangelogCategory.improvements:
      return const Color(0xFF60A5FA);
    case ChangelogCategory.fixes:
      return const Color(0xFFFF7A22);
  }
}

String _categoryLabel(ChangelogCategory c, AppLocalizations l10n) {
  switch (c) {
    case ChangelogCategory.breaking:
      return l10n.changelogCategoryBreaking;
    case ChangelogCategory.security:
      return l10n.changelogCategorySecurity;
    case ChangelogCategory.features:
      return l10n.changelogCategoryFeatures;
    case ChangelogCategory.improvements:
      return l10n.changelogCategoryImprovements;
    case ChangelogCategory.fixes:
      return l10n.changelogCategoryFixes;
  }
}

class WhatsNewDialog extends StatefulWidget {
  const WhatsNewDialog({super.key});

  @override
  State<WhatsNewDialog> createState() => _WhatsNewDialogState();
}

class _WhatsNewDialogState extends State<WhatsNewDialog> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    // The app's dialog (3.4): its header, no line under it, the history
    // scrolling under it, closed by its X.
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.sparkles,
      title: l10n.helpWhatsNew,
      maxWidth: 560,
      maxHeight: media.size.height * 0.86,
      bodyScrolls: false,
      body: Scrollbar(
        controller: _scroll,
        child: ListView.separated(
          controller: _scroll,
          primary: false,
          padding: const EdgeInsets.only(bottom: 4),
          itemCount: kChangelog.length,
          separatorBuilder: (_, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Divider(height: 1, color: AppColors.v3BorderSubtle),
          ),
          itemBuilder: (context, i) => _ReleaseBlock(
            entry: kChangelog[i],
            isCurrent: i == 0,
          ),
        ),
      ),
    );
  }
}

class _ReleaseBlock extends StatelessWidget {
  const _ReleaseBlock({required this.entry, required this.isCurrent});

  final ChangelogEntry entry;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date heading + Current pill + version badge, like the reference:
        // the badges under the date where the two do not fit beside each
        // other (in the dialog's width, a long month was cut in two).
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Text(
              entry.date,
              style: TextStyle(
                color: AppColors.v3TextPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCurrent) ...[
                  _Pill(
                    text: l10n.changelogCurrent,
                    color: AppColors.brandOrange,
                  ),
                  const SizedBox(width: 8),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.v3Background,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.v3BorderSubtle),
                  ),
                  child: Text(
                    entry.version,
                    style: TextStyle(
                      color: AppColors.v3TextSecondary,
                      fontSize: 12,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (entry.tag != null) ...[
          const SizedBox(height: 6),
          Text(
            entry.tag!,
            style: TextStyle(
              color: AppColors.v3TextTertiary,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        const SizedBox(height: 12),
        for (final section in entry.sections) ...[
          _CategoryHeader(
            label: _categoryLabel(section.category, l10n),
            color: _categoryColor(section.category),
            count: section.notes.length,
          ),
          const SizedBox(height: 8),
          for (final note in section.notes)
            _NoteRow(note: note, color: _categoryColor(section.category)),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    required this.label,
    required this.color,
    required this.count,
  });

  final String label;
  final Color color;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              // The kind's colour in the shade that reads on the dialog at
              // 4.5:1 (Daylight's green was 1.9:1; its dot keeps the colour).
              color: readableShade(color, [AppColors.v3Elevated, AppColors.v3Surface]),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            color: AppColors.v3TextTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note, required this.color});

  final ChangelogNote note;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 10),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: note.text),
                  if (note.tier != null)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: _TierPill(note.tier!),
                      ),
                    ),
                ],
              ),
              style: TextStyle(
                color: AppColors.v3TextSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The tier badge on a note. Squeezed (Pro) and Juiced (Cloud) are brand
/// names, shown verbatim in every language like the website's pills; a tap
/// says what each plan is (the plan's chip and its popover, 4.0).
class _TierPill extends StatelessWidget {
  const _TierPill(this.tier);
  final ChangelogTier tier;

  @override
  Widget build(BuildContext context) =>
      PlanChip(plan: tier == ChangelogTier.pro ? AccountPlan.squeezed : AccountPlan.juiced);
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          // The shade that reads on its own wash (the orange was 2.3:1 on
          // Daylight's).
          color: zestInkOnTint(color, 0.14),
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
