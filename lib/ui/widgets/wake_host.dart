import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/wol_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';

/// Waking a saved host with Wake-on-LAN (3.0): one action for every place
/// that offers it, on a phone and on a computer. Until this was here only a
/// phone's host cards could send the packet, though the host editor saves
/// the address to wake on every device.
///
/// What it says is what it knows: that the packet was sent, never that the
/// machine is up (nothing answers a magic packet), or why it was not sent.

/// How one packet is sent for a host: its address to wake, where to send it
/// and on which port. [WolService.send] in the app; a test puts its own
/// here.
typedef WolSender = Future<WolResult> Function({
  required String macAddress,
  required String broadcastAddress,
  required int port,
});

final wolSenderProvider = Provider<WolSender>((ref) => ({
      required String macAddress,
      required String broadcastAddress,
      required int port,
    }) =>
        WolService.send(macAddress: macAddress, broadcastAddress: broadcastAddress, port: port));

/// Whether the host [hostId] of the space on screen is in a Crate that is
/// closed on this device, with the Crate's own words for it; null where it
/// is not (always, in your Tree). A test puts its own here.
final hostClosedProvider = Provider<Future<CrateClosedOffline?> Function(String hostId)>(
    (ref) => (hostId) => itemClosedIn(ref.read(databaseProvider), 'host', hostId));

/// Whether [connection] has an address to wake saved: what decides, in every
/// menu, whether Wake is offered for it.
bool canWake(Connection connection) => (connection.wolMacAddress ?? '').trim().isNotEmpty;

/// What is said of how sending went for the host shown as [label].
/// [address] is where the packet was to go and [port] on which port, as the
/// host has them; [section] the host editor's own name for where they are
/// changed.
String wakeResultText(
  AppLocalizations l10n,
  WolResult result, {
  required String label,
  required String address,
  required int port,
}) {
  final section = l10n.connectionWakeOnLan;
  return switch (result.problem) {
    null => l10n.homeWolSent(label),
    WolProblem.badMacAddress => l10n.wolNotSentBadMac(label, section),
    WolProblem.badAddress => l10n.wolNotSentBadAddress(address, section),
    WolProblem.badPort => l10n.wolNotSentBadPort(label, '$port'),
    WolProblem.notSent => l10n.wolNotSentNoNetwork(label),
  };
}

/// Sends a Wake-on-LAN packet for [connection] and says how that went.
///
/// A host whose Crate is closed on this device (its offline limit, or
/// access given for a time that has ended) is not woken: what a closed
/// Crate holds is not used, here as everywhere, and the reason is said in
/// the Crate's own words.
Future<void> wakeHost(BuildContext context, WidgetRef ref, Connection connection) async {
  final mac = (connection.wolMacAddress ?? '').trim();
  if (mac.isEmpty) return;
  final address = (connection.wolBroadcastAddress ?? '').trim();
  final broadcast = address.isEmpty ? WolService.defaultBroadcast : address;
  final port = connection.wolPort ?? WolService.defaultPort;

  try {
    final closed = await ref.read(hostClosedProvider)(connection.id);
    if (closed != null) {
      if (context.mounted) showTopSnackBar(context, closed.message, isWarning: true);
      return;
    }
  } catch (e) {
    // The database closed under the screen (the app locked): nothing is
    // sent for a host that cannot be asked about, and that is said (it
    // returned with nothing said).
    AppLogger.warning('WoL: the host could not be asked about ($e)');
    if (context.mounted) {
      showTopSnackBar(context, AppLocalizations.of(context)!.devicesActionFailed, isError: true, details: '$e');
    }
    return;
  }

  final result = await ref.read(wolSenderProvider)(macAddress: mac, broadcastAddress: broadcast, port: port);
  if (!context.mounted) return;
  showTopSnackBar(
    context,
    wakeResultText(
      AppLocalizations.of(context)!,
      result,
      label: Redactable.host(connection.label).display,
      address: Redactable.address(broadcast).display,
      port: port,
    ),
    isSuccess: result.sent,
    isError: !result.sent,
    details: result.detail,
  );
}
