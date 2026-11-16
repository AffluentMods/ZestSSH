import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_scans.dart';

/// Cloud import (3.0): each provider's scan against a stand-in of its API:
/// the requests it makes, the pages it reads (and where it stops), and the
/// tokens it sends where.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('DigitalOcean', () {
    test('reads 200 at a time until a short page, with the token as Bearer', () async {
      final pages = <String>[];
      final machines = await scanDigitalOcean(
        CloudHttp(MockClient((req) async {
          expect(req.url.host, 'api.digitalocean.com');
          expect(req.headers['Authorization'], 'Bearer dop_v1_token');
          final page = int.parse(req.url.queryParameters['page']!);
          pages.add('$page');
          final count = page == 1 ? 200 : 5;
          return _json({
            'droplets': [
              for (var i = 0; i < count; i++)
                {'id': page * 1000 + i, 'name': 'd$i', 'networks': {'v4': [], 'v6': []}},
            ],
          });
        })),
        'dop_v1_token',
      );
      expect(machines, hasLength(205));
      expect(pages, ['1', '2']);
    });

    test('an answer that never ends stops at the page cap', () async {
      var calls = 0;
      await scanDigitalOcean(
        CloudHttp(MockClient((req) async {
          calls++;
          return _json({
            'droplets': [
              for (var i = 0; i < 200; i++) {'id': i},
            ],
          });
        })),
        't0k3n-value',
      );
      expect(calls, kCloudMaxPages);
    });

    test('an answer without droplets is an unexpected answer', () async {
      await expectLater(
        scanDigitalOcean(CloudHttp(MockClient((req) async => _json({'x': 1}))), 't0k3n-value'),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.answer)),
      );
    });
  });

  group('Hetzner', () {
    test('follows next_page, and only forward', () async {
      final asked = <String>[];
      final machines = await scanHetzner(
        CloudHttp(MockClient((req) async {
          expect(req.url.host, 'api.hetzner.cloud');
          expect(req.headers['Authorization'], 'Bearer hz-token');
          final page = req.url.queryParameters['page']!;
          asked.add(page);
          return _json({
            'servers': [
              {'id': int.parse(page), 'name': 's$page'},
            ],
            'meta': {
              'pagination': {'next_page': page == '1' ? 2 : (page == '2' ? 2 : null)},
            },
          });
        })),
        'hz-token',
      );
      expect(asked, ['1', '2'], reason: 'page 2 pointing at page 2 again ends it');
      expect(machines.map((m) => m.id), ['1', '2']);
    });
  });

  group('Tailscale', () {
    test('an API access token is used as it is', () async {
      final machines = await scanTailscale(
        CloudHttp(MockClient((req) async {
          expect(req.url.toString(), 'https://api.tailscale.com/api/v2/tailnet/-/devices');
          expect(req.headers['Authorization'], 'Bearer tskey-api-abc-def');
          return _json({
            'devices': [
              {'nodeId': 'n1', 'name': 'a.t.ts.net', 'addresses': ['100.64.0.1'], 'os': 'linux'},
            ],
          });
        })),
        'tskey-api-abc-def',
      );
      expect(machines.single.publicAddress, '100.64.0.1');
    });

    test('an OAuth client secret is exchanged first, its client id taken from it, and the new token kept out of details', () async {
      final seen = <http.Request>[];
      final client = CloudHttp(MockClient((req) async {
        seen.add(req);
        if (req.url.path == '/api/v2/oauth/token') {
          return _json({'access_token': 'short-lived-access', 'token_type': 'Bearer', 'expires_in': 3600});
        }
        expect(req.headers['Authorization'], 'Bearer short-lived-access');
        return http.Response('denied short-lived-access', 403);
      }), secrets: ['tskey-client-kAbC123CNTRL-SeCrEt']);
      try {
        await scanTailscale(client, 'tskey-client-kAbC123CNTRL-SeCrEt');
        fail('no error');
      } on CloudError catch (e) {
        expect(e.kind, CloudErrorKind.notAllowed);
        expect(e.detail, isNot(contains('short-lived-access')));
      }
      expect(seen.first.method, 'POST');
      expect(Uri.splitQueryString(seen.first.body), {
        'client_id': 'kAbC123CNTRL',
        'client_secret': 'tskey-client-kAbC123CNTRL-SeCrEt',
      });
    });

    test('a client secret without its id is refused before any request', () async {
      var calls = 0;
      await expectLater(
        scanTailscale(CloudHttp(MockClient((req) async {
          calls++;
          return _json({});
        })), 'tskey-client-'),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.signIn)),
      );
      expect(calls, 0);
    });
  });

  group('Azure', () {
    const sub = '11111111-2222-3333-4444-555555555555';
    const off = '99999999-2222-3333-4444-555555555555';

    test('a service principal signs in, every enabled subscription is read, and only Azure\'s own next links are followed', () async {
      final asked = <String>[];
      final machines = await scanAzure(
        CloudHttp(MockClient((req) async {
          asked.add('${req.method} ${req.url.host}${req.url.path}');
          if (req.url.host == 'login.microsoftonline.com') {
            expect(req.url.path, '/contoso.onmicrosoft.com/oauth2/v2.0/token');
            final form = Uri.splitQueryString(req.body);
            expect(form['grant_type'], 'client_credentials');
            expect(form['client_id'], 'app-id');
            expect(form['client_secret'], 'sp-secret');
            expect(form['scope'], 'https://management.azure.com/.default');
            return _json({'access_token': 'arm-token'});
          }
          expect(req.headers['Authorization'], 'Bearer arm-token');
          if (req.url.path == '/subscriptions') {
            return _json({
              'value': [
                {'subscriptionId': sub, 'state': 'Enabled'},
                {'subscriptionId': off, 'state': 'Disabled'},
              ],
            });
          }
          expect(req.url.path, startsWith('/subscriptions/$sub/'));
          if (req.url.path.endsWith('virtualMachines')) {
            final second = req.url.queryParameters.containsKey('page2');
            return _json({
              'value': [
                {'id': '/subscriptions/$sub/vm/${second ? 'b' : 'a'}', 'name': second ? 'b' : 'a'},
              ],
              'nextLink': second
                  ? 'https://evil.example/subscriptions/$sub/providers/Microsoft.Compute/virtualMachines?page3=1'
                  : 'https://management.azure.com/subscriptions/$sub/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01&page2=1',
            });
          }
          return _json({'value': []});
        })),
        secret: 'sp-secret',
        tenant: 'contoso.onmicrosoft.com',
        clientId: 'app-id',
      );
      expect(machines.map((m) => m.name), ['a', 'b']);
      expect(asked.where((a) => a.contains('evil')), isEmpty);
      expect(asked.where((a) => a.contains(off)), isEmpty, reason: 'disabled subscription');
    });

    test('an access token is used as it is; a named subscription is the only one read', () async {
      final token = 'eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJ4In0.c2ln';
      final asked = <String>[];
      await scanAzure(
        CloudHttp(MockClient((req) async {
          asked.add(req.url.path);
          expect(req.headers['Authorization'], 'Bearer $token');
          return _json({'value': []});
        })),
        secret: token,
        subscription: sub,
      );
      expect(asked, hasLength(3));
      expect(asked.every((p) => p.startsWith('/subscriptions/$sub/providers/')), isTrue);
    });

    test('bad tenant or subscription ids are refused before any request', () async {
      var calls = 0;
      final client = CloudHttp(MockClient((req) async {
        calls++;
        return _json({'value': []});
      }));
      await expectLater(scanAzure(client, secret: 's3cret-value', tenant: '../evil', clientId: 'x'),
          throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.signIn)));
      await expectLater(scanAzure(client, secret: 'eyJa.eyJb.c2ln', subscription: 'x/../../y'),
          throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.notFound)));
      expect(calls, 0);
    });
  });

  group('Proxmox', () {
    test('tokens and addresses as typed', () {
      expect(proxmoxTokenValue('root@pam!zestssh=aaaa-bbbb'), 'root@pam!zestssh=aaaa-bbbb');
      expect(proxmoxTokenValue('PVEAPIToken=root@pam!zestssh=aaaa-bbbb'), 'root@pam!zestssh=aaaa-bbbb');
      expect(proxmoxTokenValue('root@pam=secret'), isNull);
      expect(proxmoxTokenValue('just-a-password'), isNull);
      expect(proxmoxBase('192.168.20.10'), Uri.parse('https://192.168.20.10:8006'));
      expect(proxmoxBase('https://pve.lan:8443/#v1:0:18'), Uri.parse('https://pve.lan:8443'));
      expect(proxmoxBase('http://pve.lan'), isNull, reason: 'https only');
      expect(proxmoxBase('https://user:pw@pve.lan'), isNull);
      expect(proxmoxBase(''), isNull);
    });

    test('guests with addresses from the agent, the container, or the config, plus the nodes', () async {
      final asked = <String>[];
      final machines = await scanProxmox(
        CloudHttp(MockClient((req) async {
          expect(req.url.host, '192.168.20.10');
          expect(req.url.port, 8006);
          expect(req.headers['Authorization'], 'PVEAPIToken=root@pam!z=uuid');
          final p = req.url.path.replaceFirst('/api2/json/', '');
          asked.add(p);
          return switch (p) {
            'cluster/resources' => _json({
                'data': [
                  {'type': 'qemu', 'vmid': 104, 'node': 'node-b', 'name': 'search', 'status': 'running'},
                  {'type': 'qemu', 'vmid': 105, 'node': 'node-b', 'name': 'runner', 'status': 'running'},
                  {'type': 'lxc', 'vmid': 101, 'node': 'node-a', 'name': 'metrics', 'status': 'running'},
                  {'type': 'qemu', 'vmid': 106, 'node': 'node-a', 'name': 'off', 'status': 'stopped'},
                ],
              }),
            'cluster/status' => _json({
                'data': [
                  {'type': 'node', 'name': 'node-a', 'ip': '192.168.20.2', 'online': 1},
                ],
              }),
            'nodes/node-b/qemu/104/agent/network-get-interfaces' => _json({
                'data': {
                  'result': [
                    {
                      'name': 'eth0',
                      'ip-addresses': [
                        {'ip-address': '192.168.10.27', 'ip-address-type': 'ipv4'},
                      ],
                    },
                  ],
                },
              }),
            'nodes/node-b/qemu/105/agent/network-get-interfaces' => http.Response('{"data":null,"message":"QEMU guest agent is not running"}', 500),
            'nodes/node-b/qemu/105/config' => _json({
                'data': {'ipconfig0': 'ip=192.168.10.22/24,gw=192.168.10.1'},
              }),
            'nodes/node-a/lxc/101/interfaces' => _json({
                'data': [
                  {'name': 'eth0', 'inet': '192.168.20.21/24'},
                ],
              }),
            'nodes/node-a/qemu/106/config' => _json({'data': {}}),
            _ => http.Response('not here', 404),
          };
        })),
        base: Uri.parse('https://192.168.20.10:8006'),
        token: 'root@pam!z=uuid',
      );
      final byId = {for (final m in machines) m.id: m};
      expect(byId['192.168.20.10:8006/node/node-a']!.privateAddress, '192.168.20.2');
      expect(byId['192.168.20.10:8006/node/node-a']!.user, 'root');
      expect(byId['192.168.20.10:8006/node-b/104']!.privateAddress, '192.168.10.27');
      expect(byId['192.168.20.10:8006/node-b/105']!.privateAddress, '192.168.10.22', reason: 'no agent: the static address');
      expect(byId['192.168.20.10:8006/node-a/101']!.privateAddress, '192.168.20.21');
      expect(byId['192.168.20.10:8006/node-a/106']!.privateAddress, isNull);
      expect(byId['192.168.20.10:8006/node-a/106']!.running, isFalse);
      expect(asked, isNot(contains('nodes/node-a/qemu/106/agent/network-get-interfaces')), reason: 'a stopped VM has no agent to ask');
    });

    test('a refused token stops the scan at once instead of looking like missing addresses', () async {
      var guestRequests = 0;
      await expectLater(
        scanProxmox(
          CloudHttp(MockClient((req) async {
            final p = req.url.path.replaceFirst('/api2/json/', '');
            if (p.startsWith('nodes/')) guestRequests++;
            if (p == 'cluster/resources') {
              return _json({
                'data': [
                  {'type': 'qemu', 'vmid': 1, 'node': 'n', 'name': 'a', 'status': 'running'},
                ],
              });
            }
            if (p == 'cluster/status') return _json({'data': []});
            return http.Response('', 401);
          })),
          base: Uri.parse('https://pve:8006'),
          token: 'root@pam!z=uuid',
          parallel: 1,
        ),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.signIn)),
      );
      expect(guestRequests, 1, reason: 'no second request (the config) after the token was refused');
    });

    test('a standalone node without its address in cluster/status uses the address typed', () async {
      final machines = await scanProxmox(
        CloudHttp(MockClient((req) async {
          final p = req.url.path.replaceFirst('/api2/json/', '');
          if (p == 'cluster/resources') return _json({'data': []});
          return _json({
            'data': [
              {'type': 'node', 'name': 'pve', 'online': 1},
            ],
          });
        })),
        base: Uri.parse('https://192.168.1.10:8006'),
        token: 'root@pam!z=uuid',
      );
      expect(machines.single.privateAddress, '192.168.1.10');
    });
  });
}
