import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../models/network_trigger.dart';

/// The display form of a CIDR (recording mode): the network prefix goes
/// through the address rule and the `/len` survives, so `192.168.10.0/24` reads
/// `192.0.2.7/16`. With [ref] the caller rebuilds on a toggle; without it the
/// value is a one-shot snapshot (for a masked field's own builder, which
/// already watches the recording providers).
String maskedCidr(String cidr, [WidgetRef? ref]) {
  final slash = cidr.indexOf('/');
  final prefix = slash < 0 ? cidr : cidr.substring(0, slash);
  final suffix = slash < 0 ? '' : cidr.substring(slash);
  final r = Redactable.address(prefix);
  return '${ref == null ? r.display : r.displayIn(ref)}$suffix';
}

/// Build a one-line localized summary of a network's triggers, suitable
/// for the list tile and the per-host overrides badge.
///
/// Examples:
///   AlwaysTrigger             → "Always (fallback)"
///   SubnetTrigger("192.168.10/24")    → "Subnet 192.168.10.0/24"
///   SsidTrigger("home-net")   → "WiFi 'home-net'"
///   CellularTrigger           → "On cellular"
///   ConnectivityTrigger(wifi) → "On WiFi"
///   [subnet, ssid]            → "Subnet 192.168.10.0/24 + 1 more"
///
/// Pass [ref] wherever the result is PAINTED, so a subnet (address rule) or an
/// SSID (name rule) is masked while recording mode is on; omit it for
/// matching / search, which must see the real value.
///
/// Empty trigger lists fall back to a non-loaded-l10n-safe placeholder
/// (`"-"`) - they shouldn't occur in stored data because the editor
/// blocks save in that state, but a corrupt row shouldn't crash the page.
String summariseTriggers(
  BuildContext context,
  List<NetworkTrigger> triggers, {
  WidgetRef? ref,
}) {
  if (triggers.isEmpty) return '-';
  final l10n = AppLocalizations.of(context)!;
  final first = describeTrigger(context, triggers.first, ref: ref);
  if (triggers.length == 1) return first;
  return l10n.networksTriggerSummaryMulti(first, triggers.length - 1);
}

/// Localized description of a single trigger. Useful in the editor's
/// row UI as well as the summary builder above. [ref] as for
/// [summariseTriggers]: given for painting, omitted for matching.
String describeTrigger(
  BuildContext context,
  NetworkTrigger trigger, {
  WidgetRef? ref,
}) {
  final l10n = AppLocalizations.of(context)!;
  return switch (trigger) {
    AlwaysTrigger() => l10n.networksTriggerSummaryAlways,
    SubnetTrigger(:final cidr) => l10n.networksTriggerSummarySubnet(
        ref == null ? cidr : maskedCidr(cidr, ref)),
    SsidTrigger(:final ssid) => l10n.networksTriggerSummarySsid(
        ref == null ? ssid : Redactable.network(ssid).displayIn(ref)),
    CellularTrigger() => l10n.networksTriggerSummaryCellular,
    ConnectivityTrigger(:final kind) =>
      l10n.networksTriggerSummaryConnectivity(_connectivityLabel(l10n, kind)),
    // The internal `_UnknownTrigger` falls into the default branch - it
    // lives in a private class outside this file's reach. The wildcard
    // covers it without exposing it as a switch arm.
    _ => l10n.networksTriggerSummaryAlways,
  };
}

String _connectivityLabel(AppLocalizations l10n, ConnectivityKind kind) {
  return switch (kind) {
    ConnectivityKind.wifi => l10n.networkConnectivityWifi,
    ConnectivityKind.ethernet => l10n.networkConnectivityEthernet,
    ConnectivityKind.cellular => l10n.networkConnectivityCellular,
    ConnectivityKind.vpn => l10n.networkConnectivityVpn,
    ConnectivityKind.none => l10n.networkConnectivityNone,
  };
}
