// Remote screens (4.0): which Proxmox guest a host is, for
// "Open console".
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/cloud_import/cloud_machine.dart' show CloudProvider;
import 'package:zestssh/features/cloud_import/cloud_plan.dart' show CloudLink;
import 'package:zestssh/features/screens/proxmox/proxmox_console.dart';

/// The Proxmox VM or container [host] was imported as (its cloud link,
/// `connections.cloud_source`); null for a host with no link, another
/// provider's machine, a cluster's node, and one its account no longer
/// lists.
ProxmoxGuest? proxmoxGuestOf(Connection host) {
  final link = CloudLink.decode(host.cloudSource);
  if (link == null || link.provider != CloudProvider.proxmox || link.gone) return null;
  return ProxmoxGuest.parse(link.machineId);
}
