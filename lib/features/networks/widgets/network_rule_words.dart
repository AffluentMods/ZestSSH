import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../database/daos/connections_dao.dart' show ConnectionWithDetails;
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/connection_providers.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/connection_picker_dialog.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_field.dart';
import '../engine/cidr.dart';
import '../models/network_trigger.dart';
import 'trigger_summary.dart' show maskedCidr;
import 'package:zestssh/ui/widgets/host_row.dart';

/// The range Tailscale gives its devices' addresses from: a "Tailscale is
/// up" rule is an IP range rule of it (this device has an address there).
const tailscaleCidr = '100.64.0.0/10';

/// Whether [cidr] is Tailscale's range ([tailscaleCidr]).
bool isTailscaleCidr(String cidr) => Cidr.tryParse(cidr.trim())?.toString() == tailscaleCidr;

/// A rule in words, as the Networks page and its editor say it:
/// `Wi-Fi is "home"`, `on cellular`, `Tailscale
/// is up`. Pass [ref] where it is painted, so a name or an address takes its
/// display form (recording mode).
String networkRuleWords(AppLocalizations l10n, NetworkTrigger trigger, {WidgetRef? ref}) => switch (trigger) {
      SsidTrigger(:final ssid) => l10n.netRuleWifi(ref == null ? ssid : Redactable.network(ssid).displayIn(ref)),
      SubnetTrigger(:final cidr) =>
        isTailscaleCidr(cidr) ? l10n.netRuleTailscale : l10n.netRuleIp(ref == null ? cidr : maskedCidr(cidr, ref)),
      CellularTrigger() => l10n.netRuleCellular,
      ConnectivityTrigger(:final kind) => switch (kind) {
          ConnectivityKind.wifi => l10n.netRuleOnWifi,
          ConnectivityKind.ethernet => l10n.netRuleEthernet,
          ConnectivityKind.cellular => l10n.netRuleCellular,
          ConnectivityKind.vpn => l10n.netRuleVpn,
          ConnectivityKind.none => l10n.netRuleOffline,
        },
      _ => '-',
    };

/// When a network applies, in words: its first rule, and how many more.
String networkWhenWords(AppLocalizations l10n, List<NetworkTrigger> triggers, {WidgetRef? ref}) {
  if (triggers.isEmpty) return '-';
  final first = networkRuleWords(l10n, triggers.first, ref: ref);
  return triggers.length == 1 ? l10n.netPageWhen(first) : l10n.netPageWhenMore(first, triggers.length - 1);
}

/// A saved host by its id, with its key and group; null when it is gone.
ConnectionWithDetails? hostById(WidgetRef ref, String? id) {
  if (id == null) return null;
  for (final c in ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[]) {
    if (c.connection.id == id) return c;
  }
  return null;
}

/// A host's name as it is painted (recording mode).
String hostNameShown(WidgetRef ref, ConnectionWithDetails host) => host.connection.label.isNotEmpty
    ? Redactable.host(host.connection.label).displayIn(ref)
    : Redactable.address(host.connection.host).displayIn(ref);

/// A host's own icon, as its card draws it.
class NetworkHostIcon extends ConsumerWidget {
  const NetworkHostIcon({super.key, required this.host, this.size = 18});

  final ConnectionWithDetails host;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HostGlyph(host: host.connection, group: host.group, size: size);
  }
}

/// The jump host a network's hosts are reached through ("Reach via"): the
/// host's icon, its name and its address, opening the app's host picker. It
/// was a plain dropdown of names.
class NetworkJumpHostField extends ConsumerWidget {
  const NetworkJumpHostField({super.key, required this.hostId, required this.onChanged, this.label});

  final String? hostId;
  final ValueChanged<String> onChanged;

  /// The field's name; the "Jump host" of the editor by default.
  final String? label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final host = hostById(ref, hostId);
    final name = label ?? l10n.netEdJumpHost;
    return Semantics(
      button: true,
      label: name,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('network-jump-host'),
          borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
          onTap: () async {
            final picked = await ConnectionPickerDialog.show(context, title: name);
            final c = picked.connection;
            if (c != null) onChanged(c.connection.id);
          },
          child: ZestField.custom(
            label: name,
            labelWidth: zestFieldLabelWidth(context, [name], min: 110),
            child: Row(
              children: [
                if (host != null) ...[
                  NetworkHostIcon(host: host, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hostNameShown(ref, host),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    Redactable.address(host.connection.host).displayIn(ref),
                    style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary),
                  ),
                ] else
                  Expanded(
                    child: Text(
                      l10n.netEdPickJumpHost,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textPlaceholder),
                    ),
                  ),
                const SizedBox(width: 8),
                Icon(LucideIcons.chevronDown, size: 14, color: ZestTokens.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
