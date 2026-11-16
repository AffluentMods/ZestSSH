/// Cloud import (3.0): one scan per provider, each reading the provider's
/// documented read-only API and nothing else. Pages are counted and capped
/// (never an endless loop on a misbehaving answer), and a link to the next
/// page is only ever built here or checked to be the provider's own, so a
/// token is never sent anywhere else.
library;

import 'dart:async';
import 'dart:convert';

import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_parsers.dart';
import 'package:zestssh/utils/host_address.dart';

/// The most pages a scan reads from one list (thousands of machines).
const kCloudMaxPages = 100;

T _parsed<T>(T Function() parse, CloudHttp http, String what) {
  try {
    return parse();
  } on CloudFormatException catch (e) {
    throw CloudError(CloudErrorKind.answer, detail: http.scrub('$what: ${e.what}'));
  }
}

int _rawCount(Object? json, String key) {
  final v = json is Map ? json[key] : null;
  return v is List ? v.length : 0;
}

// ---------------------------------------------------------------- DigitalOcean

/// Every droplet the token can see (scope `droplet:read`).
Future<List<CloudMachine>> scanDigitalOcean(CloudHttp http, String token) async {
  const perPage = 200;
  final out = <CloudMachine>[];
  for (var page = 1; page <= kCloudMaxPages; page++) {
    final json = await http.json(
      'GET',
      Uri.https('api.digitalocean.com', '/v2/droplets', {'per_page': '$perPage', 'page': '$page'}),
      headers: {'Authorization': 'Bearer $token'},
    );
    out.addAll(_parsed(() => parseDroplets(json), http, 'DigitalOcean droplets'));
    if (_rawCount(json, 'droplets') < perPage) break;
  }
  return out;
}

// --------------------------------------------------------------------- Hetzner

/// Every server in the token's Hetzner Cloud project (a read-only token).
Future<List<CloudMachine>> scanHetzner(CloudHttp http, String token) async {
  final out = <CloudMachine>[];
  var page = 1;
  for (var n = 0; n < kCloudMaxPages; n++) {
    final json = await http.json(
      'GET',
      Uri.https('api.hetzner.cloud', '/v1/servers', {'per_page': '50', 'page': '$page'}),
      headers: {'Authorization': 'Bearer $token'},
    );
    out.addAll(_parsed(() => parseHetznerServers(json), http, 'Hetzner servers'));
    final next = hetznerNextPage(json);
    if (next == null || next <= page) break;
    page = next;
  }
  return out;
}

// ------------------------------------------------------------------- Tailscale

const _tsClientPrefix = 'tskey-client-';

/// Every device on the tailnet. [secret] is an API access token
/// (`tskey-api-...`) or an OAuth client secret (`tskey-client-<id>-...`,
/// which carries its client id); a client secret is exchanged for a one-hour
/// token first, so a client with only the `devices:core:read` scope works.
Future<List<CloudMachine>> scanTailscale(CloudHttp http, String secret) async {
  var bearer = secret;
  if (secret.startsWith(_tsClientPrefix)) {
    final rest = secret.substring(_tsClientPrefix.length);
    final dash = rest.indexOf('-');
    if (dash <= 0) throw CloudError(CloudErrorKind.signIn, detail: 'The OAuth client secret is not in the tskey-client-<id>-<secret> form.');
    final token = await http.json(
      'POST',
      Uri.https('api.tailscale.com', '/api/v2/oauth/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'client_id=${Uri.encodeQueryComponent(rest.substring(0, dash))}&client_secret=${Uri.encodeQueryComponent(secret)}',
    );
    final access = token is Map ? token['access_token'] : null;
    if (access is! String || access.isEmpty) {
      throw CloudError(CloudErrorKind.answer, detail: 'Tailscale gave no access token.');
    }
    http.hide(access);
    bearer = access;
  }
  final json = await http.json(
    'GET',
    Uri.https('api.tailscale.com', '/api/v2/tailnet/-/devices'),
    headers: {'Authorization': 'Bearer $bearer'},
  );
  return _parsed(() => parseTailscaleDevices(json), http, 'Tailscale devices');
}

// ------------------------------------------------------------------- Headscale

/// Every node of a Headscale server at [server] (the address of its API),
/// read with an API key ([apiKey], `headscale apikeys create`). Newer servers
/// answer `/api/v1/node`; older ones only `/api/v1/machine`. Over https only,
/// as every cloud import is: over plain http the key would go to whoever
/// answers.
Future<List<CloudMachine>> scanHeadscale(CloudHttp http, String server, String apiKey) async {
  var text = server.trim();
  if (!text.contains('://')) text = 'https://$text';
  final base = Uri.tryParse(text);
  if (base == null || base.host.isEmpty || (base.scheme != 'https' && base.scheme != 'http')) {
    throw CloudError(CloudErrorKind.answer, detail: 'Not a server address: $server');
  }
  if (base.scheme != 'https') {
    throw CloudError(CloudErrorKind.notAllowed, detail: 'A Headscale server is reached over https only: $server');
  }
  Uri at(String path) => base.replace(path: '${base.path.replaceAll(RegExp(r'/+$'), '')}$path');
  final headers = {'Authorization': 'Bearer $apiKey'};
  Object? json;
  try {
    json = await http.json('GET', at('/api/v1/node'), headers: headers);
  } on CloudError catch (e) {
    if (e.status != 404) rethrow;
    json = await http.json('GET', at('/api/v1/machine'), headers: headers);
  }
  return _parsed(() => parseHeadscaleNodes(json, server: '${base.host.toLowerCase()}:${base.port}'), http, 'Headscale nodes');
}

// ----------------------------------------------------------------------- Azure

const _azureCompute = '2024-07-01';
const _azureNetwork = '2024-05-01';
const _azureSubscriptions = '2022-12-01';

final _azureTenant = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$');
final _guid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Whether [s] is an access token already (a JWT, as `az account
/// get-access-token` prints), not a client secret.
bool looksLikeAzureAccessToken(String s) => s.startsWith('eyJ') && s.split('.').length == 3;

/// Every virtual machine in [subscription] (or, left empty, in every enabled
/// subscription the credentials can read). [secret] is a service
/// principal's client secret (with [tenant] and [clientId]), or an access
/// token for `https://management.azure.com`.
Future<List<CloudMachine>> scanAzure(
  CloudHttp http, {
  required String secret,
  String tenant = '',
  String clientId = '',
  String subscription = '',
}) async {
  var bearer = secret;
  if (!looksLikeAzureAccessToken(secret)) {
    if (!_azureTenant.hasMatch(tenant) || clientId.trim().isEmpty) {
      throw CloudError(CloudErrorKind.signIn, detail: 'A client secret needs the tenant ID and the client (application) ID.');
    }
    final token = await http.json(
      'POST',
      Uri.https('login.microsoftonline.com', '/$tenant/oauth2/v2.0/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: [
        'grant_type=client_credentials',
        'client_id=${Uri.encodeQueryComponent(clientId.trim())}',
        'client_secret=${Uri.encodeQueryComponent(secret)}',
        'scope=${Uri.encodeQueryComponent('https://management.azure.com/.default')}',
      ].join('&'),
    );
    final access = token is Map ? token['access_token'] : null;
    if (access is! String || access.isEmpty) {
      throw CloudError(CloudErrorKind.answer, detail: 'Microsoft Entra gave no access token.');
    }
    http.hide(access);
    bearer = access;
  }
  final headers = {'Authorization': 'Bearer $bearer'};

  Future<List<Object?>> all(Uri first) async {
    final items = <Object?>[];
    Uri? next = first;
    for (var n = 0; next != null && n < kCloudMaxPages; n++) {
      final json = await http.json('GET', next, headers: headers);
      final page = _parsed(() => azurePage(json), http, 'Azure list');
      items.addAll(page.items);
      next = page.next;
    }
    return items;
  }

  final subs = <String>[];
  final wanted = subscription.trim();
  if (wanted.isNotEmpty) {
    if (!_guid.hasMatch(wanted)) throw CloudError(CloudErrorKind.notFound, detail: 'A subscription ID looks like 00000000-0000-0000-0000-000000000000.');
    subs.add(wanted);
  } else {
    final listed = await all(Uri.https('management.azure.com', '/subscriptions', {'api-version': _azureSubscriptions}));
    for (final s in listed) {
      if (s is Map && s['state'] == 'Enabled' && s['subscriptionId'] is String && _guid.hasMatch(s['subscriptionId'] as String)) {
        subs.add(s['subscriptionId'] as String);
      }
    }
  }
  final out = <CloudMachine>[];
  for (final sub in subs) {
    Uri list(String provider, String version) =>
        Uri.https('management.azure.com', '/subscriptions/$sub/providers/$provider', {'api-version': version});
    final results = await Future.wait([
      all(list('Microsoft.Compute/virtualMachines', _azureCompute)),
      all(list('Microsoft.Network/networkInterfaces', _azureNetwork)),
      all(list('Microsoft.Network/publicIPAddresses', _azureNetwork)),
    ]);
    out.addAll(parseAzure(vms: results[0], nics: results[1], publicIps: results[2]));
  }
  return out;
}

// --------------------------------------------------------------------- Proxmox

/// A Proxmox API token as the `Authorization` header wants it:
/// `USER@REALM!TOKENID=SECRET`, with or without the `PVEAPIToken=` prefix.
/// Null when it is not in that form.
String? proxmoxTokenValue(String raw) {
  var s = raw.trim();
  if (s.startsWith('PVEAPIToken=')) s = s.substring('PVEAPIToken='.length);
  final ok = RegExp(r'^[^\s@!=]+@[^\s@!=]+![A-Za-z][A-Za-z0-9._-]*=[^\s]+$').hasMatch(s);
  return ok ? s : null;
}

/// The Proxmox API's base (`https://host:8006`) from what was typed, or null
/// when it is not an https address. A missing port means Proxmox's 8006.
Uri? proxmoxBase(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  // An IPv6 address typed bare goes between brackets, as a URL takes it
  // (it was not read as an address at all).
  if (!s.contains('://')) s = 'https://${bracketIpv6(s)}';
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty) return null;
  return Uri(scheme: 'https', host: u.host, port: u.hasPort ? u.port : 8006);
}

/// Every VM and container on the cluster (addresses from the guest agent or
/// the container's interfaces, else a static address in its config) and the
/// cluster's own nodes. The token needs the PVEAuditor role; reading guest
/// agent addresses also needs VM.GuestAgent.Audit (VM.Monitor before
/// Proxmox VE 9), without which static addresses are used.
Future<List<CloudMachine>> scanProxmox(CloudHttp http, {required Uri base, required String token, int parallel = 6}) async {
  final headers = {'Authorization': 'PVEAPIToken=$token'};
  Uri api(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'https', host: base.host, port: base.port, path: '/api2/json/$path', queryParameters: query);

  final resources = await http.json('GET', api('cluster/resources', {'type': 'vm'}), headers: headers);
  final cluster = _parsed(() => parseProxmoxResources(resources), http, 'Proxmox resources');
  List<({String name, String? address, bool online})> nodes;
  try {
    nodes = parseProxmoxNodes(await http.json('GET', api('cluster/status'), headers: headers));
  } on CloudError catch (e) {
    if (e.kind != CloudErrorKind.notAllowed) rethrow;
    nodes = const [];
  } on CloudFormatException {
    nodes = const [];
  }

  Future<String?> addressOf(({String node, String type, int vmid, String name, bool running, List<String> tags}) vm) async {
    final path = 'nodes/${Uri.encodeComponent(vm.node)}/${vm.type}/${vm.vmid}';
    if (vm.running) {
      try {
        final live = vm.type == 'qemu'
            ? parseProxmoxAgentAddress(await http.json('GET', api('$path/agent/network-get-interfaces'), headers: headers))
            : parseProxmoxLxcAddress(await http.json('GET', api('$path/interfaces'), headers: headers));
        if (live != null) return live;
      } on CloudError catch (e) {
        // No guest agent, not allowed to ask it, or too old a Proxmox: the
        // config may still have a static address.
        if (e.kind == CloudErrorKind.signIn || e.kind == CloudErrorKind.offline || e.kind == CloudErrorKind.certificate) rethrow;
      }
    }
    try {
      return parseProxmoxConfigAddress(await http.json('GET', api('$path/config'), headers: headers));
    } on CloudError catch (e) {
      if (e.kind == CloudErrorKind.signIn || e.kind == CloudErrorKind.offline || e.kind == CloudErrorKind.certificate) rethrow;
      return null;
    }
  }

  // A few lookups at a time: a cluster has dozens of guests.
  final addresses = List<String?>.filled(cluster.length, null);
  var nextIndex = 0;
  Future<void> worker() async {
    while (nextIndex < cluster.length) {
      final i = nextIndex++;
      addresses[i] = await addressOf(cluster[i]);
    }
  }

  await Future.wait([for (var w = 0; w < parallel; w++) worker()]);

  // Guest ids repeat across clusters: the cluster's address makes them unique.
  final cluster0 = '${base.host}:${base.port}';
  return [
    for (final n in nodes)
      CloudMachine(
        provider: CloudProvider.proxmox,
        id: '$cluster0/node/${n.name}',
        name: n.name,
        privateAddress: n.address ?? (nodes.length == 1 ? cloudIpOrNull(base.host) ?? cloudAddressOrNull(base.host) : null),
        where: 'node',
        os: CloudOs.linux,
        running: n.online,
        user: 'root',
        kind: 'node',
      ),
    for (var i = 0; i < cluster.length; i++)
      CloudMachine(
        provider: CloudProvider.proxmox,
        id: '$cluster0/${cluster[i].node}/${cluster[i].vmid}',
        name: cluster[i].name.isEmpty ? '${cluster[i].type}-${cluster[i].vmid}' : cluster[i].name,
        privateAddress: addresses[i],
        where: cluster[i].node,
        tags: cluster[i].tags,
        os: CloudOs.unknown,
        running: cluster[i].running,
        kind: cluster[i].type,
      ),
  ];
}

/// For tests and Copy details: [value] as pretty JSON.
String cloudJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);
