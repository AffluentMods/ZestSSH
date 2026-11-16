import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../core/theme/group_color.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/connection_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/recording_masked_field.dart';
import '../../../ui/widgets/recording_reveal_gate.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_color_picker.dart';
import '../../../ui/widgets/zest_field.dart';
import '../data/network_icon_catalog.dart';
import '../state/network_controller.dart';
import 'network_rule_words.dart';

/// Map a [Color] (a [ZestColorPicker] result) back onto the closed
/// [GroupColor] enum the model persists. An exact preset match wins; anything
/// else (a custom colour from the popover) snaps to the nearest GroupColor by
/// RGB distance, since the domain model only stores the nine enum tokens.
GroupColor groupColorFromColor(Color c) {
  final argb = c.toARGB32();
  for (final g in GroupColor.values) {
    if (g.value.toARGB32() == argb) return g;
  }
  final r = (argb >> 16) & 0xFF, gg = (argb >> 8) & 0xFF, b = argb & 0xFF;
  GroupColor best = GroupColor.blue;
  var bestDist = 1 << 30;
  for (final g in GroupColor.values) {
    if (g == GroupColor.gray) continue; // reserved for the Default network
    final v = g.value.toARGB32();
    final dr = r - ((v >> 16) & 0xFF);
    final dgg = gg - ((v >> 8) & 0xFF);
    final db = b - (v & 0xFF);
    final dist = dr * dr + dgg * dgg + db * db;
    if (dist < bestDist) {
      bestDist = dist;
      best = g;
    }
  }
  return best;
}

/// The 1.7 name field. Shared by Simple + Advanced identity columns.
///
/// The name identifies the user's environment: while recording mode is on it
/// renders as the masked, read-only stand-in (a tap runs the reveal gate) and
/// the controller's real text is never touched.
class NetworkNameField extends ConsumerWidget {
  const NetworkNameField({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (ref.watch(recordingModeProvider)) {
      return ZestField.custom(
        label: l10n.zestNetworkFieldName,
        // Its own name measured, with its icon ("Nombre" and "Название" were
        // cut in the 88 pixels beside the icon).
        labelWidth: zestFieldLabelWidth(context, [l10n.zestNetworkFieldName], icons: true, min: 120),
        leadingIcon: LucideIcons.tag,
        helperText: controller.nameError,
        child: RecordingMaskedValue(
          controller: controller.nameController,
          mask: (v) => Redactable.network(v).display,
          placeholder: l10n.zestNetworkNamePlaceholder,
        ),
      );
    }
    return ZestField(
      label: l10n.zestNetworkFieldName,
      labelWidth: zestFieldLabelWidth(context, [l10n.zestNetworkFieldName], icons: true, min: 120),
      leadingIcon: LucideIcons.tag,
      controller: controller.nameController,
      placeholder: l10n.zestNetworkNamePlaceholder,
      errorText: controller.nameError,
      onChanged: (_) {
        if (controller.nameError != null) {
          controller.setErrors(
            name: null,
            triggers: controller.triggersError,
          );
        }
        controller.markDirty();
      },
    );
  }
}

/// Group-colour swatch row (the [ZestColorPicker]) wired to the controller.
/// Hidden by the caller for the Default network (which is always gray).
class NetworkColorField extends StatelessWidget {
  const NetworkColorField({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    return ZestColorPicker(
      presets: AppColors.labelPalette,
      // Allow ANY custom colour - the network persists it as an ARGB override
      // (colorValue) that wins over the GroupColor token.
      allowCustom: true,
      // The design shows the dashed+slash None swatch first on the colour row.
      // A Network always carries a GroupColor token PLUS an optional custom
      // ARGB override (unlike a connection/group, whose colour index is
      // nullable), so there is no true "no colour" state to sit in - None here
      // means "drop any custom override and fall back to the palette token".
      // It therefore never holds the selection ring; a preset always wins, as
      // the design shows (a blue preset is selected, None is not).
      allowNone: true,
      noneSelected: false,
      onNoneSelected: () {
        if (controller.colorValue != null) controller.setColor(controller.color);
      },
      selected: controller.colorValue != null
          ? Color(controller.colorValue!)
          : controller.color.value,
      onChanged: (c) {
        // An exact preset match round-trips as the GroupColor token (and clears
        // any custom value); anything else persists as a custom colour.
        final argb = c.toARGB32();
        GroupColor? preset;
        for (final g in GroupColor.values) {
          if (g.value.toARGB32() == argb) {
            preset = g;
            break;
          }
        }
        if (preset != null) {
          controller.setColor(preset);
        } else {
          controller.setColorValue(argb);
        }
      },
    );
  }
}

/// Icon grid. The SELECTED tile has the app's selection: the accent's ring
/// (it took the network's colour before, a blue
/// selection in a page whose every other selection is orange).
class NetworkIconGrid extends StatelessWidget {
  const NetworkIconGrid({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final icon in networkIconChoices)
          _IconTile(
            icon: icon,
            label: networkIconLabel(l10n, icon),
            selected: icon.codePoint == controller.icon.codePoint,
            onTap: () => controller.setIcon(icon),
          ),
      ],
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Icon-only tiles (no caption); the localized name survives as the
    // tooltip.
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? ZestTokens.brandFill : ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? ZestTokens.brand : ZestTokens.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Icon(icon,
              size: 17,
              color: selected ? ZestTokens.brandInk : ZestTokens.textSecondary),
        ),
      ),
    );
  }
}

/// Localised label for a network icon, keyed by codePoint so it stays in sync
/// with [networkIconChoices].
String networkIconLabel(AppLocalizations l10n, IconData icon) {
  final cp = icon.codePoint;
  if (cp == LucideIcons.home.codePoint) return l10n.networkIconHome;
  if (cp == LucideIcons.briefcase.codePoint) return l10n.networkIconWork;
  if (cp == LucideIcons.building.codePoint) return l10n.networkIconBuilding;
  if (cp == LucideIcons.coffee.codePoint) return l10n.networkIconCafe;
  if (cp == LucideIcons.wifi.codePoint) return l10n.networkIconWifi;
  if (cp == LucideIcons.signal.codePoint) return l10n.networkIconSignal;
  if (cp == LucideIcons.cloud.codePoint) return l10n.networkIconCloud;
  if (cp == LucideIcons.globe.codePoint) return l10n.networkIconGlobe;
  if (cp == LucideIcons.shield.codePoint) return l10n.networkIconShield;
  if (cp == LucideIcons.lock.codePoint) return l10n.networkIconLock;
  if (cp == LucideIcons.airplay.codePoint) return l10n.networkIconAirplay;
  return l10n.networkIconNetwork;
}

/// The "Reach via" selector: the host this network's hosts are reached
/// through, as through a jump host (the connection resolver dials it; it was
/// saved and used by nothing before). The app's host picker,
/// with the host's icon and address, and a way back to none (it was a plain
/// dropdown of names).
class NetworkVpnField extends ConsumerWidget {
  const NetworkVpnField({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // A host that was deleted reads as none, as the resolver takes it.
    final known = hostById(ref, controller.bringUpVpn) != null;
    return Row(
      children: [
        Expanded(
          child: NetworkJumpHostField(
            hostId: known ? controller.bringUpVpn : null,
            onChanged: controller.setBringUpVpn,
            label: l10n.zestNetworkReachVia,
          ),
        ),
        if (controller.bringUpVpn != null) ...[
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('network-reach-via-none'),
            icon: const Icon(LucideIcons.x, size: 15),
            color: ZestTokens.textTertiary,
            tooltip: l10n.zestNetworkVpnNone,
            onPressed: () => controller.setBringUpVpn(null),
          ),
        ],
      ],
    );
  }
}

/// resolved match expression below it in dim JetBrainsMono, copyable, live.
class NetworkDerivedLine extends ConsumerWidget {
  const NetworkDerivedLine({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final expr = derivedMatchExpression(
      controller.triggers,
      isFallback: controller.isFallback,
    );
    // Total host count feeds the "N hosts go through VPN" clause - a bring-up
    // VPN routes every host reached while this network is active.
    final totalHosts =
        ref.watch(connectionsWithDetailsProvider).valueOrNull?.length ?? 0;
    final summary = _plainSummary(l10n, totalHosts);
    // The expression quotes the triggers' subnets and SSIDs: painted in its
    // display form (the SSIDs by the name rule, the subnets by the free-text
    // scan); the copy keeps the real one behind the gate.
    final shownExpr = Redactable.freeText(
      derivedMatchExpression(
        controller.triggers,
        isFallback: controller.isFallback,
        displaySsid: (s) => Redactable.network(s).displayIn(ref),
      ),
    ).displayIn(ref);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary != null) ...[
            Text(
              summary,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: ZestTokens.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  shownExpr,
                  maxLines: 3,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    fontFamily: 'JetBrainsMono',
                    color: ZestTokens.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _CopyButton(text: expr),
            ],
          ),
        ],
      ),
    );
  }

  /// Plain-language routing summary, or null when this network has no routing
  /// effects to describe (so only the expression shows). Clauses are joined
  /// with commas and closed with a period, as the design has them.
  String? _plainSummary(AppLocalizations l10n, int totalHosts) {
    if (controller.isFallback) return null;
    final clauses = <String>[];
    if (controller.bringUpVpn != null && totalHosts > 0) {
      clauses.add(l10n.zestNetworkSummaryVpn(totalHosts));
    }
    final diffAddress = controller.overrides
        .where((o) =>
            !o.skip &&
            (o.addressController.text.trim().isNotEmpty ||
                o.portController.text.trim().isNotEmpty))
        .length;
    if (diffAddress > 0) {
      clauses.add(l10n.zestNetworkSummaryDiffAddress(diffAddress));
    }
    final skipped = controller.overrides.where((o) => o.skip).length;
    if (skipped > 0) {
      clauses.add(l10n.zestNetworkSummarySkipped(skipped));
    }
    if (clauses.isEmpty) return null;
    return '${clauses.join(', ')}.';
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(LucideIcons.copy, size: 14),
      color: ZestTokens.textTertiary,
      splashRadius: 16,
      tooltip: MaterialLocalizations.of(context).copyButtonLabel,
      onPressed: () async {
        // The expression carries the real subnets: reveal gate (spec 5).
        if (!await confirmRevealWhileRecording(context)) return;
        await Clipboard.setData(ClipboardData(text: text));
      },
    );
  }
}
