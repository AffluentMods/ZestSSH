/// Reading each provider's documented answer into [CloudMachine]s. Pure, so
/// every provider is tested against its documented shapes without a network.
/// Anything missing or of the wrong type is skipped or null, never a crash:
/// only an answer without its main list is a [CloudFormatException].
library;

import 'package:zestssh/features/cloud_import/cloud_machine.dart';

List<Object?> _list(Object? json, String key) {
  final v = json is Map ? json[key] : null;
  if (v is! List) throw CloudFormatException('no "$key" list');
  return v;
}

Object? _at(Object? json, List<Object> path) {
  var cur = json;
  for (final p in path) {
    if (p is String && cur is Map) {
      cur = cur[p];
    } else if (p is int && cur is List && p < cur.length) {
      cur = cur[p];
    } else {
      return null;
    }
  }
  return cur;
}

/// The first item of [list] that passes [test], else its first item.
Object? _firstOr(List<Object?> list, bool Function(Object? e) test) {
  for (final e in list) {
    if (test(e)) return e;
  }
  return list.isEmpty ? null : list.first;
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : (v is num ? '$v' : null);

// ---------------------------------------------------------------- DigitalOcean

/// Droplets from `GET /v2/droplets`.
List<CloudMachine> parseDroplets(Object? json) {
  final out = <CloudMachine>[];
  for (final d in _list(json, 'droplets')) {
    final id = _str(_at(d, ['id']));
    if (id == null) continue;
    String? v4(String type) {
      final nets = _at(d, ['networks', 'v4']);
      if (nets is! List) return null;
      for (final n in nets) {
        if (_at(n, ['type']) == type) {
          final a = cloudIpOrNull(_at(n, ['ip_address']));
          if (a != null) return a;
        }
      }
      return null;
    }

    String? v6() {
      final nets = _at(d, ['networks', 'v6']);
      if (nets is! List) return null;
      for (final n in nets) {
        if (_at(n, ['type']) == 'public') return cloudIpOrNull(_at(n, ['ip_address']));
      }
      return null;
    }

    final status = _at(d, ['status']);
    out.add(CloudMachine(
      provider: CloudProvider.digitalocean,
      id: id,
      name: cleanCloudText(_at(d, ['name'])),
      publicAddress: v4('public') ?? v6(),
      privateAddress: v4('private'),
      where: cleanCloudText(_at(d, ['region', 'slug']), max: 32),
      tags: cleanCloudTags(_at(d, ['tags']) is List ? _at(d, ['tags']) as List : const []),
      os: CloudOs.linux,
      running: status != 'off' && status != 'archive',
      user: 'root',
    ));
  }
  return out;
}

// --------------------------------------------------------------------- Hetzner

/// Servers from `GET /v1/servers` (Hetzner Cloud).
List<CloudMachine> parseHetznerServers(Object? json) {
  final out = <CloudMachine>[];
  for (final s in _list(json, 'servers')) {
    final id = _str(_at(s, ['id']));
    if (id == null) continue;
    // An IPv6-only server has a /64; the server itself answers on ::1 of it.
    String? v6() {
      final net = _at(s, ['public_net', 'ipv6', 'ip']);
      if (net is! String) return null;
      final slash = net.indexOf('/');
      final base = slash < 0 ? net : net.substring(0, slash);
      return cloudIpOrNull(base.endsWith('::') ? '${base}1' : base);
    }

    final private = _at(s, ['private_net']);
    final flavor = _at(s, ['image', 'os_flavor']);
    final status = _at(s, ['status']);
    out.add(CloudMachine(
      provider: CloudProvider.hetzner,
      id: id,
      name: cleanCloudText(_at(s, ['name'])),
      publicAddress: cloudIpOrNull(_at(s, ['public_net', 'ipv4', 'ip'])) ?? v6(),
      privateAddress: private is List && private.isNotEmpty ? cloudIpOrNull(_at(private.first, ['ip'])) : null,
      where: cleanCloudText(_at(s, ['location', 'name']) ?? _at(s, ['datacenter', 'location', 'name']), max: 32),
      tags: cloudTagsOfMap(_at(s, ['labels'])),
      os: flavor == 'windows' ? CloudOs.windows : CloudOs.linux,
      running: status != 'off' && status != 'stopping' && status != 'deleting',
      user: 'root',
    ));
  }
  return out;
}

/// The next page of Hetzner servers, or null on the last.
int? hetznerNextPage(Object? json) {
  final next = _at(json, ['meta', 'pagination', 'next_page']);
  return next is int ? next : null;
}

// ------------------------------------------------------------------- Tailscale

CloudOs _tailscaleOs(Object? os) => switch (os is String ? os.toLowerCase() : '') {
      'linux' || 'freebsd' || 'openbsd' || 'illumos' || 'solaris' => CloudOs.linux,
      'windows' => CloudOs.windows,
      'macos' => CloudOs.macos,
      'ios' || 'android' || 'tvos' => CloudOs.mobile,
      '' => CloudOs.unknown,
      _ => CloudOs.other,
    };

/// Devices from `GET /api/v2/tailnet/-/devices`. Devices waiting for an
/// admin's approval cannot be reached, so they are left out.
List<CloudMachine> parseTailscaleDevices(Object? json) {
  final out = <CloudMachine>[];
  for (final d in _list(json, 'devices')) {
    final id = _str(_at(d, ['nodeId'])) ?? _str(_at(d, ['id']));
    if (id == null || _at(d, ['authorized']) == false) continue;
    String? v4;
    String? v6;
    final addrs = _at(d, ['addresses']);
    if (addrs is List) {
      for (final a in addrs) {
        final ok = cloudIpOrNull(a);
        if (ok == null) continue;
        if (ok.contains(':')) {
          v6 ??= ok;
        } else {
          v4 ??= ok;
        }
      }
    }
    // "host.tail1234.ts.net": the host part names it, the rest is the tailnet.
    final full = cleanCloudText(_at(d, ['name']), max: 253);
    final dot = full.indexOf('.');
    final hostname = cleanCloudText(_at(d, ['hostname']));
    out.add(CloudMachine(
      provider: CloudProvider.tailscale,
      id: id,
      name: hostname.isNotEmpty ? hostname : (dot > 0 ? full.substring(0, dot) : full),
      publicAddress: v4 ?? v6,
      where: _at(d, ['isExternal']) == true ? 'shared' : (dot > 0 ? cleanCloudText(full.substring(dot + 1), max: 64) : ''),
      tags: cleanCloudTags(_at(d, ['tags']) is List ? _at(d, ['tags']) as List : const []),
      os: _tailscaleOs(_at(d, ['os'])),
      running: _at(d, ['connectedToControl']) != false,
    ));
  }
  return out;
}

// ----------------------------------------------------------------------- Azure

/// Virtual machines from the three Azure list calls (virtual machines,
/// network interfaces, public IP addresses), joined by resource id.
List<CloudMachine> parseAzure({
  required List<Object?> vms,
  required List<Object?> nics,
  required List<Object?> publicIps,
}) {
  String key(Object? id) => id is String ? id.toLowerCase() : '';
  final ipOf = <String, String>{};
  for (final p in publicIps) {
    final a = cloudIpOrNull(_at(p, ['properties', 'ipAddress']));
    if (a != null) ipOf[key(_at(p, ['id']))] = a;
  }
  final nicOf = <String, ({String? private, String? public})>{};
  for (final n in nics) {
    final configs = _at(n, ['properties', 'ipConfigurations']);
    if (configs is! List || configs.isEmpty) continue;
    final primary = _firstOr(configs, (c) => _at(c, ['properties', 'primary']) == true);
    nicOf[key(_at(n, ['id']))] = (
      private: cloudIpOrNull(_at(primary, ['properties', 'privateIPAddress'])),
      public: ipOf[key(_at(primary, ['properties', 'publicIPAddress', 'id']))],
    );
  }
  final out = <CloudMachine>[];
  for (final vm in vms) {
    final id = _str(_at(vm, ['id']));
    if (id == null) continue;
    final refs = _at(vm, ['properties', 'networkProfile', 'networkInterfaces']);
    ({String? private, String? public})? nic;
    if (refs is List && refs.isNotEmpty) {
      final primary = _firstOr(refs, (r) => _at(r, ['properties', 'primary']) == true);
      nic = nicOf[key(_at(primary, ['id']))];
    }
    final osType = _at(vm, ['properties', 'storageProfile', 'osDisk', 'osType']);
    out.add(CloudMachine(
      provider: CloudProvider.azure,
      id: id,
      name: cleanCloudText(_at(vm, ['name'])),
      publicAddress: nic?.public,
      privateAddress: nic?.private,
      where: cleanCloudText(_at(vm, ['location']), max: 32),
      tags: cloudTagsOfMap(_at(vm, ['tags'])),
      os: osType == 'Windows' ? CloudOs.windows : (osType == 'Linux' ? CloudOs.linux : CloudOs.unknown),
      user: cloudUserOrNull(_at(vm, ['properties', 'osProfile', 'adminUsername'])),
    ));
  }
  return out;
}

/// The `value` list of an Azure list page, and its next page's link when
/// that link is Azure Resource Manager's own (the token is never sent
/// anywhere else).
({List<Object?> items, Uri? next}) azurePage(Object? json) {
  final items = _list(json, 'value');
  final next = _at(json, ['nextLink']);
  Uri? uri;
  if (next is String) {
    final u = Uri.tryParse(next);
    if (u != null && u.scheme == 'https' && u.host == 'management.azure.com' && !u.hasPort) uri = u;
  }
  return (items: items, next: uri);
}

// --------------------------------------------------------------------- Proxmox

/// The VMs and containers from `GET /cluster/resources?type=vm`, without
/// addresses yet (those come from each one's guest agent or config), and
/// without templates, which never run.
List<({String node, String type, int vmid, String name, bool running, List<String> tags})> parseProxmoxResources(Object? json) {
  final out = <({String node, String type, int vmid, String name, bool running, List<String> tags})>[];
  for (final r in _list(json, 'data')) {
    final type = _at(r, ['type']);
    final vmid = _at(r, ['vmid']);
    final node = _at(r, ['node']);
    if ((type != 'qemu' && type != 'lxc') || vmid is! int || node is! String) continue;
    if (_at(r, ['template']) == 1) continue;
    final tags = _at(r, ['tags']);
    out.add((
      node: cleanCloudText(node, max: 64),
      type: type as String,
      vmid: vmid,
      name: cleanCloudText(_at(r, ['name'])),
      running: _at(r, ['status']) == 'running',
      tags: cleanCloudTags(tags is String ? tags.split(RegExp('[;, ]')) : const []),
    ));
  }
  return out;
}

/// The cluster's nodes and their addresses from `GET /cluster/status`.
List<({String name, String? address, bool online})> parseProxmoxNodes(Object? json) => [
      for (final n in _list(json, 'data'))
        if (_at(n, ['type']) == 'node' && _at(n, ['name']) is String)
          (
            name: cleanCloudText(_at(n, ['name']), max: 64),
            address: cloudIpOrNull(_at(n, ['ip'])),
            online: _at(n, ['online']) != 0,
          ),
    ];

bool _usefulInterface(String name) {
  const skip = ['lo', 'docker', 'br-', 'veth', 'virbr', 'cni', 'flannel', 'cali', 'vxlan', 'kube', 'lxc', 'lxd'];
  return !skip.any(name.startsWith);
}

/// The best address a QEMU guest agent reports
/// (`/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces`): IPv4 before
/// IPv6, real interfaces before bridges and container networks.
String? parseProxmoxAgentAddress(Object? json) {
  final ifaces = _at(json, ['data', 'result']);
  if (ifaces is! List) return null;
  String? fallback;
  for (final pass in [true, false]) {
    for (final i in ifaces) {
      final name = _at(i, ['name']);
      if (name is! String || name == 'lo' || (pass && !_usefulInterface(name))) continue;
      final addrs = _at(i, ['ip-addresses']);
      if (addrs is! List) continue;
      for (final a in addrs) {
        final ok = cloudIpOrNull(_at(a, ['ip-address']));
        if (ok == null) continue;
        if (_at(a, ['ip-address-type']) == 'ipv4') return ok;
        fallback ??= ok;
      }
    }
    if (fallback != null) return fallback;
  }
  return null;
}

/// The best address a container reports (`/nodes/{node}/lxc/{vmid}/interfaces`).
String? parseProxmoxLxcAddress(Object? json) {
  final ifaces = _at(json, ['data']);
  if (ifaces is! List) return null;
  String? v6;
  for (final i in ifaces) {
    final name = _at(i, ['name']);
    if (name is! String || !_usefulInterface(name)) continue;
    final v4 = _at(i, ['inet']);
    if (v4 is String) {
      final ok = cloudIpOrNull(v4.split('/').first);
      if (ok != null) return ok;
    }
    final six = _at(i, ['inet6']);
    if (six is String) v6 ??= cloudIpOrNull(six.split('/').first);
  }
  return v6;
}

/// A static address from a VM's or container's config (`ipconfig0: ip=...` for
/// cloud-init, `net0: ...,ip=...` for containers); DHCP gives none.
String? parseProxmoxConfigAddress(Object? json) {
  final cfg = _at(json, ['data']);
  if (cfg is! Map) return null;
  final keys = cfg.keys.whereType<String>().where((k) => RegExp(r'^(ipconfig|net)\d+$').hasMatch(k)).toList()..sort();
  for (final k in keys) {
    final v = cfg[k];
    if (v is! String) continue;
    for (final part in v.split(',')) {
      final kv = part.split('=');
      if (kv.length == 2 && kv[0].trim() == 'ip') {
        final ok = cloudIpOrNull(kv[1].split('/').first);
        if (ok != null) return ok;
      }
    }
  }
  return null;
}

// ------------------------------------------------------------------- Headscale

/// Nodes as a Headscale server lists them (`/api/v1/node`, `nodes`; before
/// 0.23, `/api/v1/machine`, `machines`): each one's given name (else its
/// name) and its first tailnet address, as a Tailscale device is read.
/// Every server numbers its nodes from 1, so a node's id is [server]
/// (`host:port` of the server's API) and its number; the bare number is its
/// [CloudMachine.formerId], what earlier versions kept.
List<CloudMachine> parseHeadscaleNodes(Object? json, {required String server}) {
  final out = <CloudMachine>[];
  final nodes = _at(json, ['nodes']) is List ? _list(json, 'nodes') : _list(json, 'machines');
  for (final n in nodes) {
    final id = _str(_at(n, ['id']));
    if (id == null) continue;
    String? address;
    final addrs = _at(n, ['ipAddresses']);
    if (addrs is List) {
      for (final a in addrs) {
        final ok = cloudIpOrNull(a);
        if (ok != null) {
          address = ok;
          break;
        }
      }
    }
    final given = cleanCloudText(_at(n, ['givenName']));
    out.add(CloudMachine(
      provider: CloudProvider.tailscale,
      id: '$server/$id',
      formerId: id,
      name: given.isNotEmpty ? given : cleanCloudText(_at(n, ['name'])),
      publicAddress: address,
      where: cleanCloudText(_at(n, ['user', 'name']), max: 64),
      tags: cleanCloudTags(_at(n, ['validTags']) is List ? _at(n, ['validTags']) as List : const []),
      running: _at(n, ['online']) != false,
    ));
  }
  return out;
}
