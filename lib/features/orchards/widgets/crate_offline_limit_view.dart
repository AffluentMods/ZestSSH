import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show ItemRules;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart' show kOfflinePassMax;
import 'package:zestssh/features/orchards/rules/orchard_rules.dart' show kOutageExcuseMax;
import 'package:zestssh/features/orchards/team/team_words.dart' show offlineSpanWords;
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart' show showPassFromOwner, showSignHandedRequest;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart' show cloudStatusConfigProvider;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

// A Crate's own offline limit on screen (3.0, the outage work): on each
// Crate's row, owners say how long a device may go without reaching
// ZestSSH Cloud before the Crate closes on it, after a yes that says what
// that means when a limit is set or made shorter; everyone else sees the
// limit the Crate has. And a host of a Crate that is closed on this device
// says so before anyone tries to connect to it.

/// A Crate row's offline limit: the owners' choice, and what everyone else
/// is told.
class CrateOfflineLimitLine extends ConsumerStatefulWidget {
  const CrateOfflineLimitLine({super.key, required this.orchard, required this.crate});

  final OrchardSummary orchard;
  final CrateSummary crate;

  /// The limits offered: none, a working day, a day, three days, a week
  /// and thirty days. A Crate's limit is there to be shorter than the
  /// Orchard's own, hence the working day.
  static const choices = [0, 8, 24, 72, 168, 720];

  @override
  ConsumerState<CrateOfflineLimitLine> createState() => _CrateOfflineLimitLineState();
}

class _CrateOfflineLimitLineState extends ConsumerState<CrateOfflineLimitLine> {
  bool _busy = false;

  /// A new limit, asked about first where it keeps people out sooner; the
  /// Vaults window steps aside meanwhile.
  Future<void> _set(int hours) => overWindow(context, () => _setNow(hours));

  Future<void> _setNow(int hours) async {
    final now = widget.crate.offlineHours;
    if (hours == now) return;
    final l10n = AppLocalizations.of(context)!;
    final name = crateDisplayName(widget.crate, l10n);
    // A limit that is new, or shorter than the one there is, keeps people
    // out sooner: asked first, with what it means. A longer one, or none,
    // is not.
    if (hours > 0 && (now == 0 || hours < now)) {
      final go = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.neutral,
        title: l10n.crateOfflineSetTitle(name, offlineSpanWords(l10n, hours)),
        body: l10n.vaultUiOfflineSetLead,
        bullets: [
          l10n.vaultUiOfflineSetClosed,
          l10n.vaultUiOfflineSetEvery,
          l10n.vaultUiOfflineSetOpen,
          // What an outage of ZestSSH Cloud's own means for the limit:
          // excused where one can be proven to this build, and counted
          // where none can, which is said too.
          ref.read(cloudStatusConfigProvider).isSet
              ? l10n.orchardRulesOfflineOutageNote(kOutageExcuseMax.inDays)
              : l10n.orchardRulesOfflineOutageCounts(kOfflinePassMax.inDays),
        ],
        confirmLabel: l10n.crateOfflineSetConfirm,
      );
      if (go != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).setCrateOfflineLimit(widget.orchard.id, widget.crate.id, hours),
        summary: (what: l10n.stepUpCrateOffline(name), effects: const []),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.orchardChangeSaved, isSuccess: true);
    } catch (e) {
      AppLogger.warning("A Crate's offline limit: not changed ($e)");
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
    final hours = crate.offlineHours;
    // Changed by owners, on a device the Crate is open on.
    final owner = o.isOwner && o.active && !crate.closedOffline;
    if (!owner && hours <= 0) return const SizedBox.shrink();
    const choices = CrateOfflineLimitLine.choices;
    // A window opened from here takes the screen while it is up.
    void open(Future<void> Function() show) => overWindow(context, show);
    return VaultSettingGroup(
      title: l10n.vaultUiGroupOffline,
      rows: [
        VaultSettingRow(
          label: l10n.orchardRulesOffline,
          // Everyone else is told the limit it has.
          helper: owner ? l10n.crateOfflineTooltip : l10n.crateOfflineNote(offlineSpanWords(l10n, hours)),
          helperKey: owner ? null : ValueKey('crate-offline-note-${crate.id}'),
          tooltip: owner ? null : l10n.crateOfflineTooltip,
          control: owner
              ? ZestSelect<int>(
                  key: ValueKey('crate-offline-${crate.id}'),
                  width: 150,
                  value: choices.contains(hours) ? hours : null,
                  // A limit set elsewhere that is none of the choices (a
                  // setup file, say) is shown as what it is.
                  hint: offlineSpanWords(l10n, hours),
                  onChanged: _busy ? null : (v) => _set(v),
                  items: [
                    for (final h in choices)
                      ZestSelectItem(h, h == 0 ? l10n.orchardRulesOfflineOff : offlineSpanWords(l10n, h)),
                  ],
                )
              : null,
        ),
        // With a limit: a device that is, or will be, past it asks an owner
        // for an offline pass from here (rules/offline_pass.dart), and an
        // owner signs the request a member hands over.
        if (hours > 0 && o.active) ...[
          VaultSettingRow(
            label: l10n.vaultUiStatusPass,
            helper: l10n.vaultUiPassHelp,
            control: vaultButton(
              context,
              key: ValueKey('crate-offline-pass-${crate.id}'),
              onPressed: () => open(() => showPassFromOwner(context, orchardId: o.id, crateId: crate.id)),
              icon: LucideIcons.qrCode,
              label: l10n.vaultUiAskOwner,
            ),
          ),
          if (owner)
            VaultSettingRow(
              label: l10n.vaultUiSignLabel,
              helper: l10n.vaultUiSignHelp,
              control: vaultButton(
                context,
                key: ValueKey('crate-offline-sign-${crate.id}'),
                onPressed: () => open(() => showSignHandedRequest(context)),
                icon: LucideIcons.fileSignature,
                label: l10n.certSignButton,
              ),
            ),
        ],
      ],
    );
  }
}

/// Whether the host [connectionId] on screen is in a Crate that its own
/// offline limit has closed on this device.
bool hostCrateClosed(WidgetRef ref, String connectionId) {
  final rules = ItemRules.of(ref, 'host');
  final orchard = rules.orchard;
  if (orchard == null) return false;
  final crateId = rules.crates[connectionId] ?? orchard.defaultCrateId;
  return orchard.crates.any((c) => c.id == crateId && c.closedOffline);
}

/// Before connecting: a host whose Crate is closed on this device says so,
/// in a line on its panel ([compact] false) or a small mark on its card.
class HostCrateClosedNote extends ConsumerWidget {
  const HostCrateClosedNote({super.key, required this.connectionId, this.compact = false});

  final String connectionId;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hostCrateClosed(ref, connectionId)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Tooltip(
          message: l10n.hostCrateClosed,
          child: Icon(LucideIcons.wifiOff,
              key: ValueKey('host-closed-mark-$connectionId'), size: 13, color: AppColors.v3Warning),
        ),
      );
    }
    return Padding(
      key: ValueKey('host-closed-note-$connectionId'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(LucideIcons.wifiOff, size: 13, color: AppColors.v3Warning),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(l10n.hostCrateClosed,
                style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary)),
          ),
        ],
      ),
    );
  }
}
