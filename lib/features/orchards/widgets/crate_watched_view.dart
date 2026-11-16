import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show ItemRules;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/logger.dart';

// Watched Crates on screen (3.0, session moderation): on each
// Crate's row, owners turn watched sessions on or off after a yes that says
// what it means (a session starts only once someone else who manages the
// Crate is watching, typing is held while nobody is, SFTP and forwarding go
// off, everyone is told, and that it is the app that keeps the rule);
// everyone else sees that sessions there are watched. And a host says so
// before anyone connects to it.
//
// Under it, for a watched Crate (3.0, the outage work): who connects to its
// hosts while ZestSSH Cloud cannot be reached and nobody can be asked to
// watch, owners alone or everyone who may connect there, each with a
// reason. Everyone sees which; owners change it, after a yes that says what
// it means.

/// A Crate row's watched sessions: the owners' switch, and what everyone
/// else is told.
class CrateWatchedLine extends ConsumerStatefulWidget {
  const CrateWatchedLine({super.key, required this.orchard, required this.crate});

  final OrchardSummary orchard;
  final CrateSummary crate;

  @override
  ConsumerState<CrateWatchedLine> createState() => _CrateWatchedLineState();
}

class _CrateWatchedLineState extends ConsumerState<CrateWatchedLine> {
  bool _busy = false;

  /// Watched sessions on or off, after a yes; the Vaults window steps aside
  /// meanwhile.
  Future<void> _set(bool on) => overWindow(context, () => _setNow(on));

  Future<void> _setNow(bool on) async {
    final l10n = AppLocalizations.of(context)!;
    final name = crateDisplayName(widget.crate, l10n);
    // What turning it on means, in a lead and its consequences; turning it
    // off takes a protection away, so its button is red.
    final go = await ZestConfirmDialog.show(
      context,
      tone: on ? ZestDialogTone.neutral : ZestDialogTone.destructive,
      title: on ? l10n.crateWatchedOnTitle(name) : l10n.crateWatchedOffTitle(name),
      body: on ? l10n.vaultUiWatchedOnLead : l10n.crateWatchedOffBody,
      bullets: on
          ? [
              l10n.vaultUiWatchedOnHeld,
              l10n.vaultUiWatchedOnOff,
              // Watching needs ZestSSH Cloud: what an outage of it means
              // here is said before the rule is turned on.
              l10n.vaultUiWatchedOnAway,
              l10n.vaultUiToldEveryone,
              l10n.vaultUiWatchedOnApp,
            ]
          : null,
      confirmLabel: on ? l10n.crateWatchedTurnOn : l10n.crateWatchedTurnOff,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).setCrateWatched(widget.orchard.id, widget.crate.id, on),
        summary: (what: l10n.stepUpWatched(name), effects: const []),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.orchardChangeSaved, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Watched sessions: not changed ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Who connects with nobody watching while ZestSSH Cloud cannot be
  /// reached: [everyone] who may connect there, or owners alone.
  Future<void> _setAway(bool everyone) => overWindow(context, () => _setAwayNow(everyone));

  Future<void> _setAwayNow(bool everyone) async {
    final l10n = AppLocalizations.of(context)!;
    final name = crateDisplayName(widget.crate, l10n);
    final go = await ZestConfirmDialog.show(
      context,
      // Everyone: whom to allow it for is the one sentence that warns.
      tone: everyone ? ZestDialogTone.warning : ZestDialogTone.info,
      title: everyone ? l10n.vaultUiAwayOnTitle(name) : l10n.vaultUiAwayOffTitle(name),
      body: everyone ? l10n.vaultUiAwayOnLead : l10n.vaultUiAwayOffLead,
      bullets: everyone ? [l10n.vaultUiAwayOnRecord, l10n.vaultUiToldEveryone] : [l10n.vaultUiToldEveryone],
      warning: everyone ? l10n.vaultUiAwayOnTrust : null,
      confirmLabel: everyone ? l10n.crateUnwatchedAwayAllow : l10n.crateUnwatchedAwayOwnersOnly,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).setCrateUnwatchedAway(widget.orchard.id, widget.crate.id, everyone),
        summary: (what: l10n.stepUpUnwatchedAway(name), effects: const []),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.orchardChangeSaved, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Watched sessions: who connects with nobody watching was not changed ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final o = widget.orchard;
    final crate = widget.crate;
    final on = ref.watch(teamWatchedCratesProvider(o.id)).valueOrNull?.contains(crate.id);
    if (on == null) return const SizedBox.shrink();
    final owner = o.isOwner && o.active;
    if (!owner && !on) return const SizedBox.shrink();
    // A watched Crate says who connects while nobody can be asked to watch.
    final everyone = on ? ref.watch(teamUnwatchedAwayCratesProvider(o.id)).valueOrNull?.contains(crate.id) : null;
    // Rows of the card's Access group, each with 12 above it.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        VaultSettingRow(
          label: l10n.crateWatched,
          helper: l10n.sessionWatchedTooltip,
          compact: true,
          control: owner
              ? ZestSwitch(
                  key: ValueKey('crate-watched-${crate.id}'),
                  value: on,
                  onChanged: _busy ? null : (v) => _set(v),
                )
              : ZestStatusPill(
                  key: ValueKey('crate-sessions-watched-${crate.id}'),
                  kind: ZestStatusKind.warning,
                  icon: LucideIcons.eye,
                  label: l10n.crateWatchedOnNote,
                ),
        ),
        if (everyone != null) ...[
          const SizedBox(height: 12),
          KeyedSubtree(
            key: ValueKey('crate-unwatched-away-${crate.id}'),
            child: VaultSettingRow(
              label: everyone ? l10n.crateUnwatchedAwayEveryoneNote : l10n.crateUnwatchedAwayOwnersNote,
              tooltip: l10n.crateUnwatchedAwayTooltip,
              control: owner
                  ? vaultButton(
                      context,
                      key: ValueKey('crate-unwatched-away-change-${crate.id}'),
                      label: l10n.settingsInlineChange,
                      onPressed: _busy ? null : () => _setAway(!everyone),
                    )
                  : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// Whether sessions to the host [connectionId] on screen are watched: its
/// Crate is marked so, as this device's record says.
bool hostSessionsWatched(WidgetRef ref, String connectionId) {
  final rules = ItemRules.of(ref, 'host');
  final orchard = rules.orchard;
  if (orchard == null) return false;
  final crateId = rules.crates[connectionId] ?? orchard.defaultCrateId;
  final watched = ref.watch(teamWatchedCratesProvider(orchard.id)).valueOrNull;
  return crateId != null && (watched?.contains(crateId) ?? false);
}

/// Before connecting: a host whose sessions are watched says so, in a line
/// on its panel ([compact] false) or a small mark on its card.
class HostSessionsWatchedNote extends ConsumerWidget {
  const HostSessionsWatchedNote({super.key, required this.connectionId, this.compact = false});

  final String connectionId;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hostSessionsWatched(ref, connectionId)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Tooltip(
          message: l10n.hostSessionsWatched,
          child: Icon(LucideIcons.userCheck,
              key: ValueKey('host-watched-mark-$connectionId'), size: 13, color: AppColors.v3Warning),
        ),
      );
    }
    return Padding(
      key: ValueKey('host-watched-note-$connectionId'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(LucideIcons.userCheck, size: 13, color: AppColors.v3Warning),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: l10n.sessionWatchedTooltip,
              child: Text(l10n.hostSessionsWatched,
                  style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary)),
            ),
          ),
        ],
      ),
    );
  }
}
