/// Cloud import (3.0): what an import or a later check does with what a
/// provider lists. Pure, so the rules are tested without a database:
/// a machine imported before is found again by its provider id (so a new
/// address updates the host instead of adding another), a machine already
/// here under the same address is not added twice, and a host the person
/// edited keeps their edit.
library;

import 'dart:convert';

import 'package:zestssh/features/cloud_import/cloud_machine.dart';

/// The mark an imported host carries (`connections.cloud_source`, synced):
/// which provider machine it came from, under which account name, and the
/// address and name the import set, so a later check can tell the
/// provider's changes from the person's.
class CloudLink {
  const CloudLink({
    required this.provider,
    required this.machineId,
    this.label = '',
    this.address,
    this.name,
    this.gone = false,
  });

  final CloudProvider provider;

  /// The provider's id for the machine; unique across accounts (Proxmox ids
  /// include the cluster's address).
  final String machineId;

  /// The account's name as the person gave it ("AWS production"): shown as
  /// "from AWS production", and a host is only marked gone by a check of
  /// the account it came from.
  final String label;

  /// The address and name the import (or the last check) set.
  final String? address;
  final String? name;

  /// The provider no longer lists the machine.
  final bool gone;

  CloudLink copyWith({String? label, String? address, String? name, bool? gone}) => CloudLink(
        provider: provider,
        machineId: machineId,
        label: label ?? this.label,
        address: address ?? this.address,
        name: name ?? this.name,
        gone: gone ?? this.gone,
      );

  String encode() => jsonEncode({
        'v': 1,
        'p': provider.name,
        'id': machineId,
        if (label.isNotEmpty) 'l': label,
        if (address != null) 'a': address,
        if (name != null) 'n': name,
        if (gone) 'g': true,
      });

  /// The link stored on a host, or null when there is none or it is not
  /// one (a newer app's format, damage): such a host is simply not linked.
  static CloudLink? decode(String? raw) {
    if (raw == null || raw.isEmpty || raw.length > 4096) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['v'] != 1) return null;
    final json = decoded;
    final provider = CloudProvider.values.where((p) => p.name == json['p']).firstOrNull;
    final id = json['id'];
    if (provider == null || id is! String || id.isEmpty || id.length > 1024) return null;
    String? s(String k, int max) => json[k] is String ? cleanCloudText(json[k], max: max) : null;
    return CloudLink(
      provider: provider,
      machineId: id,
      label: s('l', 80) ?? '',
      address: cloudAddressOrNull(json['a']),
      name: s('n', 80),
      gone: json['g'] == true,
    );
  }

  bool sameMachine(CloudProvider p, String id) => provider == p && machineId == id;
}

/// A host already in the destination, as the plan needs it.
class CloudExistingHost {
  const CloudExistingHost({required this.id, required this.label, required this.host, this.port = 22, this.link});

  final String id;
  final String label;
  final String host;
  final int port;
  final CloudLink? link;
}

enum CloudRowStatus {
  /// Not here yet: importing adds it.
  fresh,

  /// A host with the same address is here but was not imported from this
  /// machine: importing links it instead of adding another.
  here,

  /// Imported before and unchanged at the provider: nothing to do.
  imported,

  /// Imported before; the provider now gives another address or name:
  /// importing updates what the person has not changed themselves.
  changed,

  /// A phone, a tablet or (usually) Windows: no SSH to connect to.
  noSsh,

  /// The provider gives no address to connect to.
  noAddress,

  /// Imported from this account before, no longer listed by it.
  gone,
}

/// One line of the "Choose hosts" table.
class CloudRow {
  const CloudRow({
    required this.status,
    required this.selected,
    this.machine,
    this.address,
    this.existing,
  });

  /// The provider's machine (null for a [CloudRowStatus.gone] host).
  final CloudMachine? machine;
  final CloudRowStatus status;

  /// The address importing would set.
  final String? address;

  /// The host here it matches, if any.
  final CloudExistingHost? existing;

  /// Ticked to begin with.
  final bool selected;

  /// Whether ticking it does anything.
  bool get selectable => status == CloudRowStatus.fresh || status == CloudRowStatus.here || status == CloudRowStatus.changed || status == CloudRowStatus.noSsh;
}

/// The table for [machines] against the [hosts] already in the destination.
/// [label] is the account name, which decides which linked hosts that are no
/// longer listed show as gone. Machines come first in name order, then the
/// gone hosts.
List<CloudRow> planCloudImport({
  required CloudProvider provider,
  required List<CloudMachine> machines,
  required List<CloudExistingHost> hosts,
  required String label,
  required bool preferPrivate,
}) {
  final account = label.trim().toLowerCase();
  final byMachine = <String, CloudExistingHost>{};
  // Hosts this account linked by an id earlier versions kept
  // ([CloudMachine.formerId]): the same machine only for this account (two
  // Headscale servers both have a node 1).
  final byFormer = <String, CloudExistingHost>{};
  final byAddress = <String, CloudExistingHost>{};
  for (final h in hosts) {
    final link = h.link;
    if (link != null && link.provider == provider) {
      byMachine[link.machineId] = h;
      if (link.label.trim().toLowerCase() == account) byFormer[link.machineId] = h;
    }
    if (h.port == 22) byAddress.putIfAbsent(h.host.toLowerCase(), () => h);
  }
  final sorted = [...machines]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final rows = <CloudRow>[];
  final seen = <String>{};
  for (final m in sorted) {
    if (!seen.add(m.id)) continue; // a provider listing one machine twice
    final address = m.addressFor(preferPrivate: preferPrivate);
    final former = m.formerId;
    final linked = byMachine[m.id] ?? (former == null ? null : byFormer[former]);
    if (linked != null) {
      final link = linked.link!;
      final moved = address != null && address != link.address;
      final renamed = m.name.isNotEmpty && m.name != link.name;
      final changed = (moved || renamed || link.gone) && _wouldChange(linked, link, address: address, name: m.name);
      rows.add(CloudRow(
        machine: m,
        status: changed ? CloudRowStatus.changed : CloudRowStatus.imported,
        address: address,
        existing: linked,
        selected: changed,
      ));
      continue;
    }
    if (address == null) {
      rows.add(CloudRow(machine: m, status: CloudRowStatus.noAddress, selected: false));
      continue;
    }
    final same = byAddress[address.toLowerCase()];
    if (same != null) {
      rows.add(CloudRow(machine: m, status: CloudRowStatus.here, address: address, existing: same, selected: false));
      continue;
    }
    rows.add(CloudRow(
      machine: m,
      status: m.likelySsh ? CloudRowStatus.fresh : CloudRowStatus.noSsh,
      address: address,
      selected: m.likelySsh,
    ));
  }
  final listed = {for (final m in machines) ...[m.id, ?m.formerId]};
  for (final h in hosts) {
    final link = h.link;
    if (link == null || link.provider != provider || link.gone || listed.contains(link.machineId)) continue;
    if (link.label.trim().toLowerCase() != account) continue;
    rows.add(CloudRow(status: CloudRowStatus.gone, existing: h, selected: false));
  }
  return rows;
}

/// Whether updating [host] from the provider would change anything: an
/// address or name the person changed themselves stays theirs.
bool _wouldChange(CloudExistingHost host, CloudLink link, {String? address, required String name}) {
  if (link.gone) return true;
  final addressOurs = link.address == null || host.host == link.address;
  final nameOurs = link.name == null || host.label == link.name;
  return (addressOurs && address != null && address != host.host) || (nameOurs && name.isNotEmpty && name != host.label);
}

/// What updating a linked [host] from [machine] sets: the provider's new
/// address and name where the host still has the ones the import set, and a
/// fresh link either way.
({String? host, String? label, CloudLink link}) cloudUpdateFor(
  CloudExistingHost host,
  CloudMachine machine, {
  required String? address,
  required String label,
}) {
  final link = host.link!;
  final addressOurs = link.address == null || host.host == link.address;
  final nameOurs = link.name == null || host.label == link.name;
  final newHost = addressOurs && address != null && address != host.host ? address : null;
  final newLabel = nameOurs && machine.name.isNotEmpty && machine.name != host.label ? machine.name : null;
  return (
    host: newHost,
    label: newLabel,
    link: CloudLink(
      provider: machine.provider,
      machineId: machine.id,
      label: link.label.isNotEmpty ? link.label : label,
      address: address ?? link.address,
      name: machine.name.isNotEmpty ? machine.name : link.name,
    ),
  );
}
