import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show crateLevelName;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/dashed_rounded_border.dart';

// The parts the Roles page shares on a computer and a phone (4.0):
// a level as a neutral
// pill with a meter of four steps and its word (None dashed, no steps), what
// a role may do in the team in words, and the strip that says what each
// level allows. Nothing here is orange: the page's one orange is New role.

/// Who was invited into each role and has not joined yet, by role id.
final roleInvitesProvider = FutureProvider.autoDispose.family<Map<String, int>, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  try {
    final invites = await ref.read(orchardServiceProvider).invites(orchardId);
    final out = <String, int>{};
    for (final i in invites) {
      if (!i.expired) out[i.role] = (out[i.role] ?? 0) + 1;
    }
    return out;
  } catch (e) {
    // Only a count beside a role: without ZestSSH Cloud it is left out.
    AppLogger.warning('Roles: the invitations were not read ($e)');
    return const {};
  }
});

/// What a role that may do [can] may do in the team, in words: "Invite,
/// remove, change roles, add vaults", as much of it as it may, or "None".
String roleCanWords(Set<String> can, AppLocalizations l10n) {
  final parts = [
    if (can.contains(RoleCan.invite)) l10n.rolesInTeamInvite,
    if (can.contains(RoleCan.remove)) l10n.rolesInTeamRemove,
    if (can.contains(RoleCan.changeRoles)) l10n.rolesInTeamChangeRoles,
    if (can.contains(RoleCan.createCrates)) l10n.rolesInTeamAddVaults,
  ];
  if (parts.isEmpty) return l10n.rolesInTeamNone;
  final words = parts.join(l10n.rolesInTeamSeparator);
  // The list reads as one sentence: its first letter in capitals, where the
  // language has them.
  return words.substring(0, 1).toUpperCase() + words.substring(1);
}

/// How many of the meter's four steps [level] fills: None none, Connect one,
/// Use two, Edit three, Manage all four.
int levelSteps(CrateLevel? level) => level == null ? 0 : level.index + 1;

/// A level as four small steps, filled up to [steps]; grey, never a colour of
/// its own (the word beside it says the level).
class RoleLevelMeter extends StatelessWidget {
  const RoleLevelMeter({super.key, required this.steps});

  final int steps;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(
              width: 6,
              height: 8,
              decoration: BoxDecoration(
                color: i < steps ? ZestTokens.textSecondary : ZestTokens.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A role's level in a vault, as the table and a phone's card show it: a
/// pill with the meter and the level's word; None with no steps and a dashed
/// edge; a set made by hand "Custom". [chevron] where a press changes it;
/// [open] while its levels are open; [hover] while the mouse is over it.
class RoleLevelPill extends StatelessWidget {
  const RoleLevelPill({
    super.key,
    required this.level,
    this.custom = false,
    this.chevron = false,
    this.open = false,
    this.hover = false,
    this.focused = false,
    this.width = 126,
  });

  final CrateLevel? level;
  final bool custom;
  final bool chevron;
  final bool open;
  final bool hover;
  final bool focused;

  /// Null: as wide as its words.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final none = level == null && !custom;
    final label = custom
        ? l10n.crateLevelCustom
        : level == null
            ? l10n.crateLevelNone
            : crateLevelName(level!, l10n);
    final edge = focused || open ? ZestTokens.textTertiary : (none ? ZestTokens.borderStrong : ZestTokens.border);
    final fill = none
        ? (hover ? ZestTokens.surfaceRaisedAlt : Colors.transparent)
        : (hover ? ZestTokens.surfaceHover : ZestTokens.surfaceRaised);
    final words = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: none ? FontWeight.w400 : FontWeight.w500,
        color: none ? ZestTokens.textTertiary : ZestTokens.textPrimary,
      ),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: width,
      height: 32,
      padding: EdgeInsetsDirectional.only(start: 11, end: chevron ? 7 : 11),
      decoration: none && !(focused || open)
          ? DashedRoundedBorder(color: edge, radius: 8, fill: fill)
          : BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: edge, width: focused || open ? 1.5 : 1),
            ),
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (!custom) ...[
            RoleLevelMeter(steps: levelSteps(level)),
            const SizedBox(width: 8),
          ],
          if (width == null) Flexible(child: words) else Expanded(child: words),
          if (chevron) ...[
            const SizedBox(width: 2),
            Icon(LucideIcons.chevronDown, size: 14, color: ZestTokens.textPlaceholder),
          ],
        ],
      ),
    );
  }
}

/// "What each level allows": the five levels, each with its meter, its name
/// and what it allows, in the app's own words for them. Five across where
/// there is room, two, or one under another on a phone.
class RoleLevelsStrip extends StatelessWidget {
  const RoleLevelsStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final levels = <(CrateLevel?, String, String)>[
      (null, l10n.crateLevelNone, l10n.rolesLevelNoneHelp),
      (CrateLevel.connect, l10n.crateLevelConnect, l10n.rolesLevelConnectHelp),
      (CrateLevel.use, l10n.crateLevelUse, l10n.rolesLevelUseHelp),
      (CrateLevel.edit, l10n.crateLevelEdit, l10n.rolesLevelEditHelp),
      (CrateLevel.manage, l10n.crateLevelManage, l10n.rolesLevelManageHelp),
    ];
    Widget item(CrateLevel? level, String name, String help) => Column(
          key: ValueKey('roles-levels-${level?.name ?? 'none'}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                RoleLevelMeter(steps: levelSteps(level)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(name,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(help, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textFaint)),
          ],
        );
    return Container(
      key: const ValueKey('roles-levels'),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: ZestTokens.surfacePanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Semantics(
                header: true,
                child: Text(l10n.rolesLevelsTitle,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
              ),
              Text(l10n.rolesLevelsLead, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary)),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, box) {
            final across = box.maxWidth >= 720 ? 5 : (box.maxWidth >= 420 ? 2 : 1);
            if (across == 5) {
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < levels.length; i++)
                      Expanded(
                        child: Container(
                          padding: EdgeInsetsDirectional.only(start: i == 0 ? 0 : 16, end: 16),
                          decoration: i == 0
                              ? null
                              : BoxDecoration(
                                  border: BorderDirectional(start: BorderSide(color: ZestTokens.borderSubtle)),
                                ),
                          child: item(levels[i].$1, levels[i].$2, levels[i].$3),
                        ),
                      ),
                  ],
                ),
              );
            }
            const gap = 16.0;
            final w = (box.maxWidth - gap * (across - 1)) / across;
            return Wrap(
              spacing: gap,
              runSpacing: 14,
              children: [
                for (final (level, name, help) in levels) SizedBox(width: w, child: item(level, name, help)),
              ],
            );
          }),
        ],
      ),
    );
  }
}
