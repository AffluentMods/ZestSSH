import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_parsers.dart';

/// Cloud import (3.0): each provider's documented answer read into machines;
/// what comes from outside is cleaned before it can reach a host name or an
/// `ssh` command line.

void main() {
  group('cleaning', () {
    test('text: controls, zero-width marks and direction overrides go; long text is cut', () {
      expect(cleanCloudText('web\u202e1\u0000\n  prod'), 'web 1 prod');
      expect(cleanCloudText('a\u200bb'), 'a b');
      expect(cleanCloudText('x' * 200).length, 80);
      expect(cleanCloudText(null), '');
      expect(cleanCloudText(42), '42');
    });

    test('addresses: an IP or a host name, nothing that ssh would read otherwise', () {
      expect(cloudAddressOrNull('10.0.0.5'), '10.0.0.5');
      expect(cloudAddressOrNull(' 2001:db8::1 '), '2001:db8::1');
      expect(cloudAddressOrNull('web-1.example.com'), 'web-1.example.com');
      for (final bad in [
        '-oProxyCommand=calc',
        // Name-shaped, but ssh would read it as an option.
        '-oProxyCommand',
        '-p2222',
        'root@10.0.0.5',
        '10.0.0.5 -p 2222',
        'a;b',
        '127.0.0.1',
        '::1',
        '169.254.10.1',
        'fe80::1',
        '0.0.0.0',
        '::',
        '',
        'host_name',
        'x' * 300,
      ]) {
        expect(cloudAddressOrNull(bad), isNull, reason: bad);
      }
      expect(cloudAddressOrNull(12), isNull);
      // Provider address fields hold IPs: a name there (or "dhcp") is not one.
      expect(cloudIpOrNull('10.0.0.5'), '10.0.0.5');
      expect(cloudIpOrNull('dhcp'), isNull);
      expect(cloudIpOrNull('web-1.example.com'), isNull);
    });

    test('sign-in names: plain names only, never an option', () {
      expect(cloudUserOrNull('azureuser'), 'azureuser');
      expect(cloudUserOrNull('ec2-user'), 'ec2-user');
      expect(cloudUserOrNull('-oProxyCommand=x'), isNull);
      expect(cloudUserOrNull('root@x'), isNull);
      expect(cloudUserOrNull('a b'), isNull);
      expect(cloudUserOrNull(null), isNull);
    });

    test('tags: key:value, key alone when empty, duplicates and blanks dropped, at most 12', () {
      expect(cloudTagsOfMap({'env': 'prod', 'team': '', 'Name': 'x'}, skipKeys: {'Name'}), ['env:prod', 'team']);
      expect(cleanCloudTags(['a', 'a', ' ', 'b']), ['a', 'b']);
      expect(cleanCloudTags(List.generate(30, (i) => 't$i')).length, 12);
    });
  });

  test('DigitalOcean droplets', () {
    final m = parseDroplets({
      'droplets': [
        {
          'id': 3164444,
          'name': 'staging-web',
          'status': 'active',
          'networks': {
            'v4': [
              {'ip_address': '10.128.0.4', 'type': 'private'},
              {'ip_address': '203.0.113.19', 'type': 'public'},
            ],
            'v6': [
              {'ip_address': '2604:a880::18a:a001', 'type': 'public'},
            ],
          },
          'region': {'slug': 'nyc1'},
          'tags': ['staging', 'web'],
          'image': {'distribution': 'Ubuntu'},
        },
        {
          'id': 2,
          'name': 'v6-only',
          'status': 'off',
          'networks': {
            'v4': [],
            'v6': [
              {'ip_address': '2604:a880::1', 'type': 'public'},
            ],
          },
        },
        {'name': 'no id'},
      ],
    });
    expect(m, hasLength(2));
    expect(m[0].id, '3164444');
    expect(m[0].publicAddress, '203.0.113.19');
    expect(m[0].privateAddress, '10.128.0.4');
    expect(m[0].where, 'nyc1');
    expect(m[0].tags, ['staging', 'web']);
    expect(m[0].user, 'root');
    expect(m[0].running, isTrue);
    expect(m[1].publicAddress, '2604:a880::1');
    expect(m[1].running, isFalse);
    expect(() => parseDroplets({'message': 'Unable to authenticate you'}), throwsA(isA<CloudFormatException>()));
  });

  test('Hetzner servers: location either way, labels as tags, IPv6-only answers on ::1', () {
    final json = {
      'servers': [
        {
          'id': 42,
          'name': 'builder',
          'status': 'running',
          'public_net': {
            'ipv4': {'ip': '203.0.113.8'},
            'ipv6': {'ip': '2a01:4f8:c0c:1::/64'},
          },
          'private_net': [
            {'ip': '10.0.0.2'},
          ],
          'location': {'name': 'ash'},
          'labels': {'role': 'ci', 'keep': ''},
          'image': {'os_flavor': 'ubuntu'},
        },
        {
          'id': 43,
          'name': 'v6',
          'status': 'off',
          'public_net': {
            'ipv4': null,
            'ipv6': {'ip': '2a01:4f8:c0c:2::/64'},
          },
          'private_net': [],
          'datacenter': {
            'location': {'name': 'fsn1'},
          },
        },
      ],
      'meta': {
        'pagination': {'page': 1, 'next_page': 2},
      },
    };
    final m = parseHetznerServers(json);
    expect(m[0].publicAddress, '203.0.113.8');
    expect(m[0].privateAddress, '10.0.0.2');
    expect(m[0].where, 'ash');
    expect(m[0].tags, ['role:ci', 'keep']);
    expect(m[1].publicAddress, '2a01:4f8:c0c:2::1');
    expect(m[1].where, 'fsn1');
    expect(m[1].running, isFalse);
    expect(hetznerNextPage(json), 2);
    expect(hetznerNextPage({'meta': {'pagination': {'next_page': null}}}), isNull);
  });

  test('Tailscale devices: the tailnet address, the host part of the name, phones and waiting devices', () {
    final m = parseTailscaleDevices({
      'devices': [
        {
          'nodeId': 'nABC',
          'name': 'db-primary.tail1234.ts.net',
          'hostname': 'db-primary',
          'addresses': ['fd7a:115c:a1e0::1', '100.64.4.7'],
          'os': 'linux',
          'tags': ['tag:server'],
          'authorized': true,
        },
        {
          'id': '99',
          'name': 'pixel-9.tail1234.ts.net',
          'addresses': ['100.64.4.33'],
          'os': 'android',
          'authorized': true,
        },
        {
          'nodeId': 'nWAIT',
          'name': 'new.tail1234.ts.net',
          'addresses': ['100.64.4.40'],
          'os': 'linux',
          'authorized': false,
        },
        {
          'nodeId': 'nSHARED',
          'name': 'friend.other.ts.net',
          'addresses': ['100.64.90.1'],
          'os': 'windows',
          'isExternal': true,
          'connectedToControl': false,
        },
      ],
    });
    expect(m.map((d) => d.id), ['nABC', '99', 'nSHARED']);
    expect(m[0].publicAddress, '100.64.4.7');
    expect(m[0].name, 'db-primary');
    expect(m[0].where, 'tail1234.ts.net');
    expect(m[0].likelySsh, isTrue);
    expect(m[1].name, 'pixel-9');
    expect(m[1].likelySsh, isFalse, reason: 'a phone');
    expect(m[2].where, 'shared');
    expect(m[2].likelySsh, isFalse, reason: 'Windows starts unticked');
    expect(m[2].running, isFalse);
  });

  test('Azure: VMs joined to their primary network interface and its public IP', () {
    const nic = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/web-nic';
    const pip = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/web-ip';
    final m = parseAzure(
      vms: [
        {
          'id': '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/web',
          'name': 'web',
          'location': 'eastus',
          'tags': {'env': 'prod'},
          'properties': {
            'networkProfile': {
              'networkInterfaces': [
                {'id': nic.toUpperCase(), 'properties': {'primary': true}},
              ],
            },
            'storageProfile': {
              'osDisk': {'osType': 'Linux'},
            },
            'osProfile': {'adminUsername': 'azureuser'},
          },
        },
        {
          'id': '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/dc',
          'name': 'ad-dc01',
          'properties': {
            'storageProfile': {
              'osDisk': {'osType': 'Windows'},
            },
            'osProfile': {'adminUsername': '-oBad'},
          },
        },
      ],
      nics: [
        {
          'id': nic,
          'properties': {
            'ipConfigurations': [
              {
                'properties': {'primary': false, 'privateIPAddress': '10.1.0.9'},
              },
              {
                'properties': {
                  'primary': true,
                  'privateIPAddress': '10.1.0.4',
                  'publicIPAddress': {'id': pip},
                },
              },
            ],
          },
        },
      ],
      publicIps: [
        {
          'id': pip,
          'properties': {'ipAddress': '198.51.100.33'},
        },
      ],
    );
    expect(m[0].publicAddress, '198.51.100.33');
    expect(m[0].privateAddress, '10.1.0.4');
    expect(m[0].user, 'azureuser');
    expect(m[0].tags, ['env:prod']);
    expect(m[0].os, CloudOs.linux);
    expect(m[1].publicAddress, isNull);
    expect(m[1].os, CloudOs.windows);
    expect(m[1].user, isNull, reason: 'not a plain name');
  });

  test('Azure pages follow only Azure Resource Manager\'s own links', () {
    expect(azurePage({'value': [], 'nextLink': 'https://management.azure.com/subscriptions/s/x?\$skiptoken=1'}).next, isNotNull);
    for (final bad in [
      'https://evil.example/steal',
      'http://management.azure.com/x',
      'https://management.azure.com.evil.example/x',
      'https://management.azure.com:444/x',
    ]) {
      expect(azurePage({'value': [], 'nextLink': bad}).next, isNull, reason: bad);
    }
    expect(() => azurePage({'error': {}}), throwsA(isA<CloudFormatException>()));
  });

  group('Proxmox', () {
    test('resources: VMs and containers, templates left out, tags split', () {
      final r = parseProxmoxResources({
        'data': [
          {'type': 'qemu', 'vmid': 104, 'node': 'node-b', 'name': 'search', 'status': 'running', 'tags': 'ai;prod'},
          {'type': 'lxc', 'vmid': 101, 'node': 'node-a', 'name': 'metrics', 'status': 'stopped'},
          {'type': 'qemu', 'vmid': 9000, 'node': 'node-a', 'name': 'tmpl', 'template': 1},
          {'type': 'storage', 'node': 'node-a'},
        ],
      });
      expect(r.map((e) => e.vmid), [104, 101]);
      expect(r[0].tags, ['ai', 'prod']);
      expect(r[0].running, isTrue);
      expect(r[1].running, isFalse);
    });

    test('nodes', () {
      final n = parseProxmoxNodes({
        'data': [
          {'type': 'cluster', 'name': 'home'},
          {'type': 'node', 'name': 'node-a', 'ip': '192.168.20.2', 'online': 1},
          {'type': 'node', 'name': 'node-b', 'ip': 'bad ip', 'online': 0},
        ],
      });
      expect(n.map((e) => e.name), ['node-a', 'node-b']);
      expect(n[0].address, '192.168.20.2');
      expect(n[1].address, isNull);
      expect(n[1].online, isFalse);
    });

    test('guest agent: IPv4 on a real interface before bridges, loopback never', () {
      expect(
        parseProxmoxAgentAddress({
          'data': {
            'result': [
              {
                'name': 'lo',
                'ip-addresses': [
                  {'ip-address': '127.0.0.1', 'ip-address-type': 'ipv4'},
                ],
              },
              {
                'name': 'docker0',
                'ip-addresses': [
                  {'ip-address': '172.17.0.1', 'ip-address-type': 'ipv4'},
                ],
              },
              {
                'name': 'eth0',
                'ip-addresses': [
                  {'ip-address': 'fe80::1', 'ip-address-type': 'ipv6'},
                  {'ip-address': '2001:db8::5', 'ip-address-type': 'ipv6'},
                  {'ip-address': '192.168.10.27', 'ip-address-type': 'ipv4'},
                ],
              },
            ],
          },
        }),
        '192.168.10.27',
      );
      expect(
        parseProxmoxAgentAddress({
          'data': {
            'result': [
              {
                'name': 'docker0',
                'ip-addresses': [
                  {'ip-address': '172.17.0.1', 'ip-address-type': 'ipv4'},
                ],
              },
            ],
          },
        }),
        '172.17.0.1',
        reason: 'only a bridge: better than nothing',
      );
      expect(parseProxmoxAgentAddress({'data': null}), isNull);
    });

    test('containers and static config', () {
      expect(
        parseProxmoxLxcAddress({
          'data': [
            {'name': 'lo', 'inet': '127.0.0.1/8'},
            {'name': 'eth0', 'inet': '192.168.20.21/24', 'inet6': 'fd00::21/64'},
          ],
        }),
        '192.168.20.21',
      );
      expect(parseProxmoxConfigAddress({'data': {'ipconfig0': 'ip=10.0.0.5/24,gw=10.0.0.1'}}), '10.0.0.5');
      expect(parseProxmoxConfigAddress({'data': {'net0': 'name=eth0,bridge=vmbr0,ip=10.0.0.6/24'}}), '10.0.0.6');
      expect(parseProxmoxConfigAddress({'data': {'net0': 'name=eth0,bridge=vmbr0,ip=dhcp'}}), isNull);
    });
  });

  test('addresses: the public one unless private is asked for and exists', () {
    const m = CloudMachine(provider: CloudProvider.aws, id: 'i-1', name: 'x', publicAddress: '3.3.3.3', privateAddress: '10.0.0.1');
    expect(m.addressFor(preferPrivate: false), '3.3.3.3');
    expect(m.addressFor(preferPrivate: true), '10.0.0.1');
    const p = CloudMachine(provider: CloudProvider.aws, id: 'i-2', name: 'y', privateAddress: '10.0.0.2');
    expect(p.addressFor(preferPrivate: false), '10.0.0.2');
  });
}
