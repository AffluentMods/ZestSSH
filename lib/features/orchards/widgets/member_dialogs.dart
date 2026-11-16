import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/time_text.dart';

// The questions the Members screen asks before changing someone (3.0):
// which role, when their access ends (their access to each vault is
// the member panel's Vault access). Each returns the answer, or
// null when the person closed the dialog.

String crateLevelName(CrateLevel level, AppLocalizations l10n) => switch (level) {
      CrateLevel.connect => l10n.crateLevelConnect,
      CrateLevel.use => l10n.crateLevelUse,
      CrateLevel.edit => l10n.crateLevelEdit,
      CrateLevel.manage => l10n.crateLevelManage,
    };

/// The level [switches] are exactly (agent forwarding aside), or null for
/// a set no level matches (made by hand).
CrateLevel? exactLevel(Set<String> switches) {
  final core = {...switches}..remove(CrateSwitches.agent);
  for (final l in CrateLevel.values) {
    if (_same(levelSwitches(l), core)) return l;
  }
  return null;
}

bool _same(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

/// The levels [mine] (this account's switches on a Crate) lets it give:
/// those whose switches it has itself, the Crate's own limits aside.
List<CrateLevel> levelsWithin(Set<String> mine, Set<String> allow) => [
      for (final l in CrateLevel.values)
        if (levelSwitches(l).where((s) => !CrateSwitches.capped.contains(s) || allow.contains(s)).every(mine.contains))
          l,
    ];

/// "Oct 12, 2026": the last day of access ending at [endsAt] (seconds
/// since the epoch) where it runs to the end of a day, and the day with
/// the time ("Oct 12, 2026, 3:30 PM") where it ends at a time.
String accessThrough(int endsAt, BuildContext context) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final at = secondsAsDate(endsAt);
  if (isWholeDayEnd(endsAt)) {
    return DateFormat.yMMMd(locale).format(at.subtract(const Duration(seconds: 1)));
  }
  return DateFormat.yMMMd(locale).add_jm().formatPlain(at);
}

/// Whether access ending at [endsAt] runs to the end of a day on this
/// device's clock (it ends at midnight), not to a time within one.
bool isWholeDayEnd(int endsAt) {
  final at = secondsAsDate(endsAt);
  return at.hour == 0 && at.minute == 0 && at.second == 0;
}

/// The end of [day] on this device's clock, in seconds since the epoch.
int endOfDay(DateTime day) => DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch ~/ 1000;

// ── Role ────────────────────────────────────────────────────────────────

/// Picks one of [roles] (id, name, what it opens) for [name], with
/// [current] selected. The roles in [locked] show but cannot be picked,
/// with [lockedNote] saying why (Admin before anyone compared codes with
/// them, 3.0). Returns the role picked, when it differs.
Future<String?> pickMemberRole(
  BuildContext context, {
  required String name,
  required String current,
  required List<({String id, String label, String summary})> roles,
  Set<String> locked = const {},
  String? lockedNote,
}) async {
  final l10n = AppLocalizations.of(context)!;
  var picked = current;
  final result = await showZestModal<String>(
    context: context,
    size: ZestModalSize.standard,
    child: StatefulBuilder(
      builder: (context, setState) => ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.info,
        icon: LucideIcons.userCog,
        title: l10n.orchardRolePickTitle(name),
        subtitle: l10n.orchardRolePickSubtitle,
        body: RadioGroup<String>(
          groupValue: picked,
          onChanged: (v) => setState(() => picked = v ?? picked),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in roles)
                RadioListTile<String>(
                  key: ValueKey('pick-role-${r.id}'),
                  value: r.id,
                  dense: true,
                  enabled: !locked.contains(r.id),
                  contentPadding: EdgeInsets.zero,
                  title: Text(r.label, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
                  subtitle: Text(
                    locked.contains(r.id) && lockedNote != null ? '${r.summary}\n$lockedNote' : r.summary,
                    style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
                  ),
                ),
            ],
          ),
        ),
        primaryAction: (
          label: l10n.save,
          onPressed: picked == current ? null : () => Navigator.of(context).pop(picked),
          icon: LucideIcons.check,
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      ),
    ),
  );
  return result;
}

/// What a role opens, in words: "Production: Use, Staging: Edit".
String roleSummary(Map<String, Set<String>> crates, List<CrateSummary> known, AppLocalizations l10n) {
  if (crates.isEmpty) return l10n.orchardRoleNoCrates;
  final parts = <String>[];
  for (final e in crates.entries) {
    final crate = known.where((c) => c.id == e.key).firstOrNull;
    final level = exactLevel(e.value);
    parts.add('${crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n)}: '
        '${level == null ? l10n.crateLevelCustom : crateLevelName(level, l10n)}');
  }
  return parts.join(', ');
}

// ── End date ────────────────────────────────────────────────────────────

/// When someone's access ends ([title] says whose): a day, or no end.
/// Returns the new value as a record (its [endsAt] null for no end), or null
/// when closed unchanged. With [requireEnd] no end is not on offer: a guest
/// outside the team's domains has one, and it cannot be taken away.
Future<({int? endsAt})?> pickAccessEnd(BuildContext context,
    {required String title, required int? current, bool requireEnd = false}) {
  return showZestModal<({int? endsAt})>(
    context: context,
    size: ZestModalSize.standard,
    child: _EndDateDialog(title: title, current: current, requireEnd: requireEnd),
  );
}

class _EndDateDialog extends StatefulWidget {
  const _EndDateDialog({required this.title, required this.current, this.requireEnd = false});

  final String title;
  final int? current;
  final bool requireEnd;

  @override
  State<_EndDateDialog> createState() => _EndDateDialogState();
}

class _EndDateDialogState extends State<_EndDateDialog> {
  late int? _endsAt = widget.current;

  /// A time already gone was picked.
  String? _problem;

  static int _seconds(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

  /// [at] to the minute.
  static DateTime _minute(DateTime at) => DateTime(at.year, at.month, at.day, at.hour, at.minute);

  void _set(int endsAt) => setState(() {
        _endsAt = endsAt;
        _problem = null;
      });

  /// A time on the day the end is on (before, a date
  /// alone was all there was).
  Future<void> _pickTime() async {
    final l10n = AppLocalizations.of(context)!;
    final ends = _endsAt;
    if (ends == null) return;
    final whole = isWholeDayEnd(ends);
    final day = secondsAsDate(whole ? ends - 1 : ends);
    final time = await showTimePicker(
      context: context,
      initialTime: whole ? const TimeOfDay(hour: 17, minute: 0) : TimeOfDay.fromDateTime(day),
    );
    if (time == null || !mounted) return;
    final picked = _seconds(DateTime(day.year, day.month, day.day, time.hour, time.minute));
    if (picked <= _seconds(DateTime.now())) {
      setState(() => _problem = l10n.orchardEndPast);
      return;
    }
    _set(picked);
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final shown = _endsAt == null ? now.add(const Duration(days: 30)) : secondsAsDate(_endsAt! - 1);
    final first = DateTime(now.year, now.month, now.day);
    final last = DateTime(now.year + 5, now.month, now.day);
    final day = await showDatePicker(
      context: context,
      // One further off than can be picked (from before there was a limit)
      // opens at the furthest that can.
      initialDate: shown.isBefore(first) ? first : (shown.isAfter(last) ? last : shown),
      firstDate: first,
      lastDate: last,
    );
    if (day == null || !mounted) return;
    // A time already set stays, on the new day.
    final ends = _endsAt;
    if (ends != null && !isWholeDayEnd(ends)) {
      final at = secondsAsDate(ends);
      final moved = _seconds(DateTime(day.year, day.month, day.day, at.hour, at.minute));
      if (moved > _seconds(DateTime.now())) return _set(moved);
    }
    _set(endOfDay(day));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ends = _endsAt;
    final now = DateTime.now();
    // The quick ends: two times from now, to the minute, and two days.
    final quick = <(String, String, int)>[
      ('end-quick-hour', l10n.orchardEndQuickHour, _seconds(_minute(now.add(const Duration(hours: 1))))),
      ('end-quick-8h', l10n.orchardEndQuick8Hours, _seconds(_minute(now.add(const Duration(hours: 8))))),
      ('end-quick-today', l10n.orchardEndQuickToday, endOfDay(now)),
      ('end-quick-week', l10n.orchardEndQuickWeek, endOfDay(now.add(const Duration(days: 7)))),
    ];
    final offset = now.timeZoneOffset;
    final hours = offset.inMinutes.abs() ~/ 60, minutes = offset.inMinutes.abs() % 60;
    final zone = '${now.timeZoneName} (UTC${offset.isNegative ? '-' : '+'}'
        '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')})';
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.calendarClock,
      title: widget.title,
      subtitle: l10n.orchardEndDateBody,
      body: RadioGroup<bool>(
        groupValue: ends != null,
        onChanged: (v) => v == true ? _pick() : setState(() => _endsAt = null),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.requireEnd)
              RadioListTile<bool>(
                key: const ValueKey('end-none'),
                value: false,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.orchardEndDateNone, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
              ),
            RadioListTile<bool>(
              key: const ValueKey('end-on'),
              value: true,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                ends == null
                    ? l10n.orchardEndDatePick
                    : isWholeDayEnd(ends)
                        ? l10n.orchardEndDateOn(accessThrough(ends, context))
                        : l10n.orchardMemberEndsOn(accessThrough(ends, context)),
                key: const ValueKey('end-words'),
                style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
              ),
              secondary: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('end-pick'),
                    icon: const Icon(LucideIcons.calendar, size: 16),
                    tooltip: l10n.orchardEndDatePick,
                    onPressed: _pick,
                  ),
                  IconButton(
                    key: const ValueKey('end-time'),
                    icon: const Icon(LucideIcons.clock, size: 16),
                    tooltip: l10n.orchardEndSetTime,
                    onPressed: ends == null ? null : _pickTime,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (key, label, at) in quick)
                  ZestButton(
                    key: ValueKey(key),
                    label: label,
                    onPressed: () => _set(at),
                  ),
              ],
            ),
            if (_problem != null) ...[
              const SizedBox(height: 8),
              Text(_problem!,
                  key: const ValueKey('end-problem'),
                  style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3Error)),
            ],
            const SizedBox(height: 10),
            Text(l10n.orchardEndZone(zone),
                key: const ValueKey('end-zone'),
                style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
          ],
        ),
      ),
      primaryAction: (
        label: l10n.save,
        onPressed: ends == widget.current || (widget.requireEnd && ends == null)
            ? null
            : () => Navigator.of(context).pop((endsAt: ends)),
        icon: LucideIcons.check,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

// ── Making an owner ─────────────────────────────────────────────────────

/// Asks before making [name] an owner, with the choice to step down in the
/// same step. Returns whether to step down, or null when cancelled.
Future<bool?> confirmMakeOwner(BuildContext context, {required String name}) {
  final l10n = AppLocalizations.of(context)!;
  var stepDown = false;
  return showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    child: StatefulBuilder(
      builder: (context, setState) => ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.warning,
        icon: LucideIcons.crown,
        title: l10n.orchardMakeOwnerTitle(name),
        subtitle: l10n.orchardMakeOwnerLead,
        // That nobody else can change an owner's access: the one sentence
        // that warns, in amber.
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ZestCallout(l10n.orchardMakeOwnerWarning(name)),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const ValueKey('owner-step-down'),
              value: stepDown,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l10n.orchardMakeOwnerStepDown, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
              onChanged: (v) => setState(() => stepDown = v ?? false),
            ),
          ],
        ),
        primaryAction: (
          label: l10n.orchardMakeOwnerConfirm,
          onPressed: () => Navigator.of(context).pop(stepDown),
          icon: LucideIcons.crown,
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      ),
    ),
  );
}
