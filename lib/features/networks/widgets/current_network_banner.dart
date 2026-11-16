import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/network_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../models/network.dart';
import '../models/network_trigger.dart';
import 'trigger_summary.dart';

/// Slim, cross-tab banner (Doc-3 A2) that shows which network profile is
/// currently active, WHY it matched, and a manual-override control to force
/// a different one.
///
/// Mounted at the top of the mobile home PageView (beside `UpdateBanner`) so
/// it's visible on every tab. Renders nothing until networks load, and stays
/// hidden entirely when the user has no user-defined networks (with only the
/// system Default there's nothing meaningful to say or to switch between),
/// and while the Default is the one in use, unless the person forced it.
class CurrentNetworkBanner extends ConsumerWidget {
  const CurrentNetworkBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    final networks = ref.watch(allNetworksProvider).valueOrNull;
    if (networks == null) return const SizedBox.shrink();
    final hasCustom = networks.any((n) => !n.isFallback);
    if (!hasCustom) return const SizedBox.shrink();

    final effective = ref.watch(effectiveNetworkProvider).valueOrNull;
    if (effective == null) return const SizedBox.shrink();

    final overrideId = ref.watch(manualNetworkOverrideIdProvider);
    final isForced =
        overrideId != null && networks.any((n) => n.id == overrideId);
    // Only where a network of the person's own is in use (4.0):
    // the Default, which every place falls back to, said
    // nothing worth a row over every tab. Forced by the person, it shows,
    // with the way back to Automatic.
    if (effective.isFallback && !isForced) return const SizedBox.shrink();

    // Why this profile is active: the manual override, or (in auto mode) the
    // trigger the detector matched on.
    final reason = ref.watch(detectedNetworkMatchProvider).valueOrNull?.reason;
    final why = isForced
        ? l10n.networkBannerForcedReason
        : _whyLabel(l10n, reason, ref);

    final color = effective.effectiveColor;

    // The profile name identifies the environment: painted (and announced) in
    // its display form (recording mode).
    final shownName = Redactable.network(effective.name).displayIn(ref);

    return Semantics(
      container: true,
      label: l10n.networkBannerSemantics(shownName),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.v3Surface,
          border: Border(
            bottom:
                BorderSide(color: AppColors.v3BorderSubtle, width: 0.8),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Identity - tapping opens the full Networks screen.
            Expanded(
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => context.push('/networks'),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child:
                              Icon(effective.icon, size: 16, color: color),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      shownName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.v3TextPrimary,
                                      ),
                                    ),
                                  ),
                                  if (isForced) ...[
                                    const SizedBox(width: 6),
                                    Icon(
                                      LucideIcons.pin,
                                      size: 11,
                                      color: AppColors.v3AccentInk,
                                    ),
                                  ],
                                ],
                              ),
                              if (why != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Text(
                                    why,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppColors.v3TextTertiary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _OverrideChip(
              forced: isForced,
              onTap: () =>
                  _showPicker(context, ref, networks, overrideId),
            ),
          ],
        ),
      ),
    );
  }

  /// Force a network profile, or fall back to Automatic (which clears the
  /// override so the user can never get stranded on a profile that no longer
  /// fits): one of a few, the app's choice (3.4), a computer's dialog and a
  /// phone's sheet. Writes through [manualNetworkOverrideProvider], which
  /// persists the choice. (A sheet of its own before, with a line under its
  /// title and a tick in the accent.)
  Future<void> _showPicker(
    BuildContext context,
    WidgetRef ref,
    List<Network> networks,
    String? currentOverrideId,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    // Automatic is a choice of its own (no network has an empty id).
    const automatic = '';
    final picked = await showZestChoice<String>(
      context,
      title: l10n.networkPickerTitle,
      subtitle: l10n.networkPickerHelp,
      icon: LucideIcons.network,
      selected: currentOverrideId ?? automatic,
      choices: [
        ZestChoice(
          value: automatic,
          label: l10n.networkPickerAuto,
          detail: l10n.networkPickerAutoDescription,
          icon: LucideIcons.radar,
          key: const ValueKey('network-override-auto'),
        ),
        for (final net in networks)
          ZestChoice(
            value: net.id,
            // Painted: the profile name in its display form.
            label: Redactable.network(net.name).displayIn(ref),
            detail: summariseTriggers(context, net.triggers, ref: ref),
            icon: net.icon,
            key: ValueKey('network-override-${net.id}'),
          ),
      ],
    );
    if (picked == null) return;
    ref.read(manualNetworkOverrideProvider).value = picked == automatic ? null : picked;
  }
}

/// The "Auto" / "Forced" pill on the right of the banner - opens the picker.
class _OverrideChip extends StatelessWidget {
  const _OverrideChip({required this.forced, required this.onTap});

  final bool forced;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accent =
        forced ? AppColors.v3AccentInk : AppColors.v3TextSecondary;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: forced
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.14)
                : AppColors.v3Background,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: forced
                  ? AppColors.v3AccentPrimary.withValues(alpha: 0.4)
                  : AppColors.v3BorderDefault,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                forced ? LucideIcons.pin : LucideIcons.slidersHorizontal,
                size: 12,
                color: accent,
              ),
              const SizedBox(width: 5),
              Text(
                forced
                    ? l10n.networkBannerForcedChip
                    : l10n.networkBannerAutoChip,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Localized "why this profile is active" caption from the winning trigger.
/// Returns null when nothing meaningful can be said (unknown/absent trigger).
/// Painted, so a subnet or an SSID takes its display form (recording mode).
String? _whyLabel(
    AppLocalizations l10n, NetworkTrigger? reason, WidgetRef ref) {
  if (reason == null) return null;
  return switch (reason) {
    SsidTrigger(:final ssid) =>
      l10n.hostNetworksMatchWhySsid(Redactable.network(ssid).displayIn(ref)),
    SubnetTrigger(:final cidr) =>
      l10n.hostNetworksMatchWhySubnet(maskedCidr(cidr, ref)),
    CellularTrigger() => l10n.hostNetworksMatchWhyCellular,
    ConnectivityTrigger(:final kind) =>
      l10n.hostNetworksMatchWhyConnectivity(_kindLabel(l10n, kind)),
    AlwaysTrigger() => l10n.hostNetworksMatchWhyFallback,
    _ => null,
  };
}

String _kindLabel(AppLocalizations l10n, ConnectivityKind kind) =>
    switch (kind) {
      ConnectivityKind.wifi => l10n.networkConnectivityWifi,
      ConnectivityKind.ethernet => l10n.networkConnectivityEthernet,
      ConnectivityKind.cellular => l10n.networkConnectivityCellular,
      ConnectivityKind.vpn => l10n.networkConnectivityVpn,
      ConnectivityKind.none => l10n.networkConnectivityNone,
    };
