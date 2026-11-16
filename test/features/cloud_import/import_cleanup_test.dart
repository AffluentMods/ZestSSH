import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_parsers.dart';
import 'package:zestssh/features/cloud_import/cloud_scans.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/onboarding/data/onboarding_import.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';

/// The import cleanup: Headscale in the Tailscale import,
/// termius-export's files (its hosts.csv, the keys its SSH config names),
/// and Paste a list as a host file.
void main() {
  group('Headscale', () {
    final nodes = {
      'nodes': [
        {
          'id': '7',
          'name': 'web-01-abc',
          'givenName': 'web-01',
          'ipAddresses': ['100.64.0.7', 'fd7a:115c:a1e0::7'],
          'user': {'name': 'ops'},
          'validTags': ['tag:prod'],
          'online': true,
        },
        {'id': '8', 'name': 'db', 'ipAddresses': ['fd7a:115c:a1e0::8'], 'online': false},
      ],
    };

    test('a node: its given name, its first tailnet address, its user and tags', () {
      final m = parseHeadscaleNodes(nodes, server: 'headscale.example.com:443');
      expect([for (final x in m) (x.id, x.formerId, x.name, x.publicAddress, x.where, x.running)], [
        ('headscale.example.com:443/7', '7', 'web-01', '100.64.0.7', 'ops', true),
        ('headscale.example.com:443/8', '8', 'db', 'fd7a:115c:a1e0::8', '', false),
      ]);
      expect(m.first.tags, ['tag:prod']);
    });

    test('asks /api/v1/node with the key; an older server answering 404 is asked /api/v1/machine', () async {
      final asked = <String>[];
      final client = MockClient((req) async {
        asked.add('${req.url.path} ${req.headers['Authorization']}');
        if (req.url.path == '/api/v1/node') return http.Response('not found', 404);
        return http.Response(jsonEncode({'machines': nodes['nodes']}), 200);
      });
      final m = await scanHeadscale(CloudHttp(client, secrets: ['hs-api-key-123']), 'headscale.example.com', 'hs-api-key-123');
      expect(asked, ['/api/v1/node Bearer hs-api-key-123', '/api/v1/machine Bearer hs-api-key-123']);
      expect(m.map((x) => x.id), ['headscale.example.com:443/7', 'headscale.example.com:443/8'],
          reason: 'a node is known by its server too: every server has a node 1');
    });

    test('over https only: to a plain http address the key is never sent', () async {
      var sent = 0;
      final client = MockClient((req) async {
        sent++;
        return http.Response(jsonEncode(nodes), 200);
      });
      for (final server in ['http://headscale.example.com', 'http://192.168.1.20:8080', 'ftp://headscale.example.com']) {
        await expectLater(scanHeadscale(CloudHttp(client), server, 'k'), throwsA(isA<CloudError>()), reason: server);
      }
      expect(sent, 0);
      await scanHeadscale(CloudHttp(client), 'https://192.168.1.20:8443/', 'k');
      expect(sent, 1);
    });
  });

  test("termius-export's hosts.csv: its columns read (Groups, KeyLabel), the rest named as left out", () {
    const csv = 'Groups,Label,Tags,Hostname,Protocol,Port,Username,Password,IdentityFile,KeyLabel,KeyPassphrase,ProxyType,ProxyHost,ProxyPort\n'
        'Production,web-01,"web,eu",web-01.example.com,ssh,2222,deploy,,keys/deploy,deploy key,,,,\n';
    final f = readHostFile(csv);
    expect(f.problem, isNull);
    final r = f.rows.single;
    expect((r.name, r.host, r.port, r.user, r.group, r.key), ('web-01', 'web-01.example.com', 2222, 'deploy', 'Production', 'deploy key'));
    expect(r.tags, ['web', 'eu']);
    expect(f.ignored, containsAll(['Password', 'IdentityFile', 'KeyPassphrase']));
  });

  test('a pasted list as a host file: hosts checked as CSV lines are, a bad line kept with its line number', () {
    final f = readPastedHosts('ops@a.example.com:2200\n\nhost:99999\n# note\nb.example.com');
    expect([for (final r in f.rows) (r.line, r.host, r.port, r.user, r.problem)], [
      (1, 'a.example.com', 2200, 'ops', null),
      (3, '', 22, null, CsvRowProblem.badHost),
      (5, 'b.example.com', 22, null, null),
    ]);
    expect(f.rows[1].name, 'host:99999');
    expect(readPastedHosts('\n# nothing\n').problem, CsvFileProblem.empty);
  });

  test("the keys an SSH config names are read next to it (termius-export's keys/), a ~ is the home folder; "
      'what is no private key, or is not there, is left out', () async {
    final dir = await Directory.systemTemp.createTemp('zest_identity_');
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}/keys').create();
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n';
    await File('${dir.path}/keys/deploy').writeAsString(pem);
    await File('${dir.path}/keys/deploy.pub').writeAsString('ssh-ed25519 AAAA deploy');
    final config = '${dir.path}/sshconfig';
    final entries = [
      const OnboardingSshEntry(alias: 'a', hostname: 'a.example.com', user: 'deploy', identityFile: 'keys/deploy'),
      const OnboardingSshEntry(alias: 'b', hostname: 'b.example.com', user: 'deploy', identityFile: 'keys/deploy.pub'),
      const OnboardingSshEntry(alias: 'c', hostname: 'c.example.com', user: 'ops', identityFile: 'keys/missing'),
      const OnboardingSshEntry(alias: 'd', hostname: 'd.example.com'),
      // A network path is never opened (Windows would sign in to it).
      const OnboardingSshEntry(alias: 'e', hostname: 'e.example.com', identityFile: r'\\files.example.com\keys\id'),
      const OnboardingSshEntry(alias: 'f', hostname: 'f.example.com', identityFile: '//files.example.com/keys/id'),
      // Windows reads the slashes mixed as one too (found in a security audit),
      // and these go through its own namespaces to the same place.
      const OnboardingSshEntry(alias: 'g', hostname: 'g.example.com', identityFile: r'/\files.example.com\keys\id'),
      const OnboardingSshEntry(alias: 'h', hostname: 'h.example.com', identityFile: r'\/files.example.com/keys/id'),
      const OnboardingSshEntry(alias: 'i', hostname: 'i.example.com', identityFile: r'\??\UNC\files.example.com\keys\id'),
    ];
    final keys = await readIdentityKeys(entries, configPath: config);
    expect(keys, {'keys/deploy': pem});
  });

  test('a network path is not opened at all: the file behind the mixed form is there, and it is not read', () async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    final dir = await Directory.systemTemp.createTemp('zest_identity_');
    addTearDown(() => dir.delete(recursive: true));
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n';
    final key = File('${dir.path}\\fake_key')..writeAsStringSync(pem);
    // The same file through this computer's own administrative share: reading it
    // would be a sign-in to 127.0.0.1.
    final rest = key.path.substring(3);
    final mixed = '/\\127.0.0.1\\C\$\\$rest';
    final keys = await readIdentityKeys([
      OnboardingSshEntry(alias: 'a', hostname: 'a.example.com', identityFile: mixed),
    ]);
    expect(keys, isEmpty);
  });

  test('only a regular file of key size is read; a relative path without its config is not read at all', () async {
    final dir = await Directory.systemTemp.createTemp('zest_identity_');
    addTearDown(() => dir.delete(recursive: true));
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n';
    // A folder whose name a config gives as a key.
    await Directory('${dir.path}/keys/folder').create(recursive: true);
    // A key-looking file far larger than any key.
    await File('${dir.path}/keys/huge').writeAsString(pem + ('A' * (70 * 1024)));
    await File('${dir.path}/keys/deploy').writeAsString(pem);
    final entries = [
      const OnboardingSshEntry(alias: 'a', hostname: 'a.example.com', identityFile: 'keys/folder'),
      const OnboardingSshEntry(alias: 'b', hostname: 'b.example.com', identityFile: 'keys/huge'),
      const OnboardingSshEntry(alias: 'c', hostname: 'c.example.com', identityFile: 'keys/deploy'),
    ];
    expect(await readIdentityKeys(entries, configPath: '${dir.path}/sshconfig'), {'keys/deploy': pem});
    // Without the config file's place, "keys/deploy" would be read from
    // wherever the app runs: it is not read.
    final here = Directory.current;
    addTearDown(() => Directory.current = here);
    Directory.current = dir;
    expect(await readIdentityKeys(entries), isEmpty);
  });
}
