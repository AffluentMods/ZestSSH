import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart' show DangerExplanation;
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// Confirmation shown BEFORE a destructive command is broadcast (fanned out)
/// to multiple hosts (Doc-3 Part C / C1).
///
/// Distinct from `showDangerousCommandDialog`, which guards a single session.
/// This one exists purely to gate the MULTIPLICATION of a destructive command
/// across every host in the broadcast group, and it deliberately:
///
///   * lists every target host **by name** (not a count) so the blast radius
///     is explicit, warning per host; and
///   * makes the confirm action **click-only** with nothing autofocused, so
///     the Enter the user just pressed to submit the command cannot also
///     confirm the dialog. Cancelling is the safe/easy path (Esc, scrim, or
///     the Cancel button).
///
/// It reuses [ZestDialogShell] for the app's dialog chrome. That matters for
/// the Enter-safety requirement: the shell's primary button takes a key only
/// once it has the focus, the shell autofocuses nothing here, and the modal
/// is given no Enter of its own - unlike [ZestConfirmDialog], whose confirm
/// button autofocuses, which would let the just-pressed Enter confirm.
///
/// Each host is named and shown as it is in a list (its own icon, where
/// [targetHostIds] says which saved host it is), masked while a screen is
/// recorded.
///
/// Returns `true` only when the user explicitly clicks the confirm button;
/// cancel, Escape, and scrim-dismiss all resolve to `false`.
Future<bool> showBroadcastDangerousDialog(
  BuildContext context, {
  required String command,
  required List<DangerousCommandMatch> matches,
  required List<String> targetHostNames,
  List<String?>? targetHostIds,
}) async {
  // The app's modal (a phone's sheet), with no Enter of its own: the Enter
  // just pressed to send the command cannot confirm it.
  final result = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    // Scrim dismiss = cancel = do not broadcast. Safe default.
    barrierDismissible: true,
    child: Builder(builder: (ctx) {
      final l10n = AppLocalizations.of(ctx)!;
      // By the worst of what was found, as the question for one session: what
      // is only worth a look is not called destructive, and it is still asked,
      // because it goes to every host.
      final harm = worstDangerLevel(matches) == DangerLevel.harm;
      return ZestDialogShell(
        tone: harm ? ZestDialogTone.destructive : ZestDialogTone.neutral,
        icon: LucideIcons.radio,
        title: harm ? l10n.broadcastDangerousTitle : l10n.broadcastLookTitle,
        subtitle: l10n.broadcastDangerousSubtitle,
        body: _BroadcastDangerousBody(
          command: command,
          matches: matches,
          targetHostNames: targetHostNames,
          targetHostIds: targetHostIds,
          l10n: l10n,
        ),
        // Primary = click-only, not autofocused → the just-pressed Enter can't
        // trigger it. This is the whole reason for not reusing ZestConfirmDialog.
        primaryAction: (
          label: l10n.broadcastDangerousConfirm,
          icon: LucideIcons.radio,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
        secondaryAction: (
          label: l10n.broadcastDangerousCancel,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
      );
    }),
  );
  return result ?? false;
}

class _BroadcastDangerousBody extends StatelessWidget {
  const _BroadcastDangerousBody({
    required this.command,
    required this.matches,
    required this.targetHostNames,
    required this.targetHostIds,
    required this.l10n,
  });

  final String command;
  final List<DangerousCommandMatch> matches;
  final List<String> targetHostNames;
  final List<String?>? targetHostIds;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── The exact command ──────────────────────────────────────
        _sectionLabel(l10n.broadcastDangerousCommandLabel),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Text(
            commandForQuestion(command, max: kMaxCommandShown),
            key: const ValueKey('broadcast-danger-command'),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
              height: 1.4,
              color: worstDangerLevel(matches) == DangerLevel.harm ? AppColors.v3Error : AppColors.v3TextPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 14),

        // ── Why it was flagged ─────────────────────────────────────
        _sectionLabel(l10n.broadcastDangerousReasonHeader),
        const SizedBox(height: 6),
        // What each risky part does, in the app's language and in a sentence
        // that says what to do; the same kind found twice is said once.
        ...{for (final m in matches.reversed) m.kind: m}.entries.toList().reversed.map(
          (found) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: found.key.level == DangerLevel.harm
                      ? Icon(LucideIcons.alertCircle, size: 14, color: AppColors.v3Error)
                      : Icon(LucideIcons.eye, size: 14, color: AppColors.v3Warning),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        found.key.describe(l10n),
                        style: TextStyle(
                          fontFamily: 'GeistSans',
                          fontSize: 13,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                          color: AppColors.v3TextSecondary,
                        ),
                      ),
                      DangerExplanation(
                        found.key.explain(l10n, found.value.quotedIn(command)),
                        style: TextStyle(
                          fontFamily: 'GeistSans',
                          fontSize: 12.5,
                          height: 1.4,
                          color: AppColors.v3TextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // ── The blast radius: every target host, by name ───────────
        _sectionLabel(
          l10n.broadcastDangerousTargetsHeader(targetHostNames.length),
        ),
        const SizedBox(height: 6),
        ...targetHostNames.indexed.map(
          (at) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _TargetGlyph(hostId: targetHostIds == null ? null : targetHostIds![at.$1]),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    Redactable.host(at.$2).display,
                    style: TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 13,
                      height: 1.45,
                      color: AppColors.v3TextPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: 'GeistSans',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppColors.v3TextSecondary,
        ),
      );
}

/// A saved host's own icon; a session of no saved host has the server's.
class _TargetGlyph extends StatelessWidget {
  const _TargetGlyph({required this.hostId});

  final String? hostId;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(LucideIcons.server, size: 14, color: AppColors.v3AccentInk);
    final id = hostId;
    if (id == null) return fallback;
    return Consumer(builder: (context, ref, _) {
      final host = ref.watch(hostsByIdProvider)[id]?.connection;
      return host == null ? fallback : HostGlyph(host: host, size: 16);
    });
  }
}
