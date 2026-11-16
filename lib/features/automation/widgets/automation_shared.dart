import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart' show AutomationHistoryData;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/time_text.dart';

// ══════════════════════════════════════════════════════════════════
// Shared automation-run widgets + helpers.
//
// Extracted from the old 5-tab automation_view so the Runs timeline and the
// Triggers view render past runs, badges, and filter chips identically -
// there is exactly one _HistoryRow / _StatusBadge / output-dialog in the app.
// ══════════════════════════════════════════════════════════════════

/// Whether a past run failed specifically because a credential is not enabled
/// for unattended runs (build +80's gate-blocked runs), as opposed to a normal
/// command failure. Such a run is rendered AMBER with a "Needs credentials"
/// label instead of red "Failed" - it is a one-click fix, not a real error.
///
/// Matches the two error strings the dispatcher records:
///   * `_handleOpen`     → "Unattended runs are not enabled for the credential…"
///   * `_handleWorkflow` → "Blocked: a step targets a credential not enabled…"
bool automationRunNeedsCredentials(AutomationHistoryData row) {
  if (row.success) return false;
  final err = row.stderr;
  return err.contains('nattended runs are not enabled') ||
      err.contains('Blocked: a step targets a credential not enabled');
}

/// The command/snippet label shown for a run row.
String automationCommandLabel(AutomationHistoryData e) {
  if (e.snippetName != null && e.snippetName!.isNotEmpty) {
    return e.snippetName!;
  }
  final cmd = e.command;
  return cmd.length > 60 ? '${cmd.substring(0, 57)}...' : cmd;
}

// ── Formatting helpers ─────────────────────────────────────────────

/// A run's or a key's day, as [l10n]'s language writes it (it was 2026-09-28
/// in every language).
String automationDate(AppLocalizations l10n, DateTime dt) => DateFormat.yMMMd(l10n.localeName).format(dt);

/// A run's or a key's day and time of day, as [l10n]'s language writes them:
/// the tooltip over when it was.
String automationDateTime(AppLocalizations l10n, DateTime dt) =>
    DateFormat.yMMMd(l10n.localeName).add_Hm().formatPlain(dt);

/// When an API key runs out, in [l10n]'s language: never, it has, or the day
/// it does (3.0: it said "Expires in 5 days" and "Never
/// expires" in English in every language).
String automationKeyExpiry(AppLocalizations l10n, AutomationApiKey key) {
  final at = key.expiresAt;
  if (at == null) return l10n.certGenerateValidityNever;
  if (key.isExpired) return l10n.triggersViewExpired;
  return l10n.settingsMobExpiresOn(automationDate(l10n, at));
}

String automationDuration(Duration d) {
  if (d.inSeconds < 1) return '${d.inMilliseconds}ms';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
}

// ══════════════════════════════════════════════════════════════════
// Status badge
// ══════════════════════════════════════════════════════════════════

/// Small status-badge pill (a tinted label). Used by run rows and API-key
/// rows alike.
class AutomationStatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const AutomationStatusBadge({
    super.key,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Filter chip (all / success / failed)
// ══════════════════════════════════════════════════════════════════

class AutomationFilterChip extends StatefulWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const AutomationFilterChip({
    super.key,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<AutomationFilterChip> createState() => _AutomationFilterChipState();
}

class _AutomationFilterChipState extends State<AutomationFilterChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.12)
                : (_hovered ? AppColors.v3Hover : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: widget.isActive
                  ? AppColors.v3AccentPrimary.withValues(alpha: 0.3)
                  : AppColors.v3BorderDefault,
              width: 0.5,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: widget.isActive
                  ? AppColors.v3AccentInk
                  : AppColors.v3TextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Past-run row
// ══════════════════════════════════════════════════════════════════

/// A single past automation run. Amber-aware: a run blocked by the
/// unattended-credentials gate reads AMBER ("Needs credentials"), everything
/// else reads green (success) or red (failed).
class AutomationHistoryRow extends StatefulWidget {
  final AutomationHistoryData entry;

  const AutomationHistoryRow({super.key, required this.entry});

  @override
  State<AutomationHistoryRow> createState() => _AutomationHistoryRowState();
}

class _AutomationHistoryRowState extends State<AutomationHistoryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final e = widget.entry;
    final elapsed = Duration(milliseconds: e.elapsedMs);
    final needsCreds = automationRunNeedsCredentials(e);

    // Result colour + icon + badge, keyed on the three outcomes.
    final Color color;
    final IconData icon;
    final String badge;
    if (needsCreds) {
      color = AppColors.v3Warning;
      icon = LucideIcons.keyRound;
      badge = l10n.zestAutoOutcomeNeedsCreds;
    } else if (e.success) {
      color = AppColors.v3Success;
      icon = LucideIcons.checkCircle2;
      badge = l10n.zestAutoOutcomeSucceeded;
    } else {
      color = AppColors.v3Error;
      icon = LucideIcons.xCircle;
      badge = l10n.zestAutoOutcomeFailed;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _hovered ? AppColors.v3Hover : AppColors.v3Surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.v3BorderDefault, width: 0.5),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // §7.3 channel rule: a 3px left bar encodes the row's outcome.
              Container(width: 3, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 14, color: color),
                      const SizedBox(width: 10),

                      // Command + timestamp/duration
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              automationCommandLabel(e),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppColors.v3TextPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Tooltip(
                              message: automationDateTime(l10n, e.timestamp),
                              waitDuration: const Duration(milliseconds: 400),
                              child: Text(
                                '${timeAgoWords(l10n, e.timestamp)}'
                                '  -  ${automationDuration(elapsed)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.v3TextTertiary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      AutomationStatusBadge(label: badge, color: color),
                      const SizedBox(width: 8),

                      // View output
                      Tooltip(
                        message: l10n.zestAutoViewOutput,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => showAutomationRunOutput(context, e),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  l10n.zestAutoViewOutput,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.v3AccentInk,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Icon(
                                  LucideIcons.chevronRight,
                                  size: 12,
                                  color: AppColors.v3AccentInk,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Run-output dialog
// ══════════════════════════════════════════════════════════════════

/// Show the captured stdout / stderr (and exit status) for a past run.
void showAutomationRunOutput(
  BuildContext context,
  AutomationHistoryData entry,
) {
  final l10n = AppLocalizations.of(context)!;
  final needsCreds = automationRunNeedsCredentials(entry);
  // What the run came to, by the dialog's meaning (3.4): a green tick for one
  // that went through, red for one that failed, neutral for one that waits
  // for a sign-in.
  final tone = needsCreds
      ? ZestDialogTone.neutral
      : (entry.success ? ZestDialogTone.success : ZestDialogTone.destructive);
  final headerIcon = needsCreds
      ? LucideIcons.keyRound
      : (entry.success ? LucideIcons.checkCircle2 : LucideIcons.xCircle);

  Widget section(String label, String text, Color color) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.v3TextTertiary,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 260),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
                height: 1.4,
                color: color,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        size: ZestModalSize.standard,
        tone: tone,
        icon: headerIcon,
        title: entry.command,
        subtitle: entry.exitCode == null ? null : l10n.zestAutoRunExitCode(entry.exitCode!),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            section(
              l10n.zestAutoStdout,
              entry.stdout,
              AppColors.v3TextPrimary,
            ),
            section(
              l10n.zestAutoStderr,
              entry.stderr,
              AppColors.v3Error,
            ),
            if (entry.stdout.isEmpty && entry.stderr.isEmpty)
              Text(
                l10n.zestAutoRunNoOutput,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.v3TextTertiary,
                ),
              ),
          ],
        ),
        // Close in the footer, in the accent even where the run failed.
        primaryBrand: true,
        primaryKey: const ValueKey('automation-run-output-close'),
        primaryAction: (label: l10n.zestAutoClose, icon: null, onPressed: () => Navigator.of(ctx).pop()),
        autofocusPrimary: true,
      ),
    ),
  );
}
