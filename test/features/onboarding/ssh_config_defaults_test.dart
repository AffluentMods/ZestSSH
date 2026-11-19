import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/onboarding/data/onboarding_import.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';
import 'package:zestssh/utils/ssh_config_parser.dart';

/// An SSH config is read as OpenSSH reads it, for what the import takes: each
/// host gets the first value the file gives it, from its own block, from the
/// blocks of patterns that match it (`Host *` above all) and from what stands
/// before the first `Host` line. Each host was read from its own block alone:
/// a config that keeps `User` and `IdentityFile` under `Host *` came in with
/// neither. And a `ProxyJump` is set up only where it is one host that is
/// here: a route of several hosts was linked to its first, which leaves the
/// others out.
void main() {
  const source = SshConfigSource();
  OnboardingSshEntry host(SshConfigScanResult r, String alias) => r.entries.firstWhere((e) => e.alias == alias);

  test('what Host * says holds for the hosts above and below it that say nothing of their own', () {
    final r = source.parse('''
Host app
  HostName 192.0.2.10
Host db
  HostName 192.0.2.11
  User postgres
Host build
  HostName 192.0.2.12
Host *
  User deploy
  IdentityFile ~/.ssh/id_ed25519
  Port 2200
''');
    expect(r.entries.map((e) => e.alias), ['app', 'db', 'build']);
    expect([host(r, 'app').user, host(r, 'app').identityFile, host(r, 'app').port], ['deploy', '~/.ssh/id_ed25519', 2200]);
    expect(host(r, 'db').user, 'postgres', reason: 'its own value comes first in the file');
    expect(host(r, 'db').identityFile, '~/.ssh/id_ed25519');
    expect(host(r, 'build').user, 'deploy');
    // The block of the pattern is still listed as not a host of its own.
    expect(r.skipped.map((s) => (s.label, s.reason)), [('*', SshSkipReason.wildcard)]);
  });

  test('the first value in the file is the one that holds: a Host * above a host comes before the host\'s own', () {
    final r = source.parse('''
Host *
  User first
Host app
  HostName 192.0.2.10
  User second
''');
    expect(host(r, 'app').user, 'first');
  });

  test('what stands before the first Host line holds for every host, and is not listed as left out', () {
    final r = source.parse('''
User everyone
Port 2022

Host app
  HostName 192.0.2.10
Host db
  HostName 192.0.2.11
  Port 5022
''');
    expect([host(r, 'app').user, host(r, 'app').port], ['everyone', 2022]);
    expect([host(r, 'db').user, host(r, 'db').port], ['everyone', 2022], reason: 'the first Port in the file');
    expect(r.skipped, isEmpty);
  });

  test('patterns: a star, a question mark, several on a line, and one taken out with !', () {
    final r = source.parse('''
Host web1 web2 db1 cache
  HostName 192.0.2.1
Host web? !web2
  User www
Host *1
  Port 2201
Host * !cache
  IdentityFile ~/.ssh/most
''');
    expect(host(r, 'web1').user, 'www');
    expect(host(r, 'web2').user, isNull, reason: 'taken out by !web2');
    expect(host(r, 'db1').user, isNull);
    expect([host(r, 'web1').port, host(r, 'db1').port, host(r, 'web2').port], [2201, 2201, 22]);
    expect(host(r, 'cache').identityFile, isNull);
    expect(host(r, 'web2').identityFile, '~/.ssh/most');
    expect(SshConfigParser.hostMatches('!web2', 'web1'), isFalse, reason: 'a line of negations alone matches nothing');
    expect(SshConfigParser.hostMatches('a*b*c', 'axxbyyc'), isTrue);
    expect(SshConfigParser.hostMatches('a*b*c', 'axxbyy'), isFalse);
    expect(SshConfigParser.hostMatches('*' * 40 + 'z', 'a' * 4000), isFalse, reason: 'and in no time');
  });

  test('a directive written twice in a block: the first one is taken', () {
    final r = source.parse('''
Host app
  HostName 192.0.2.10
  IdentityFile ~/.ssh/first
  IdentityFile ~/.ssh/second
  User one
  User two
''');
    expect([host(r, 'app').identityFile, host(r, 'app').user], ['~/.ssh/first', 'one']);
  });

  test('a host named in two blocks gets the first value of each from the whole file', () {
    final r = source.parse('''
Host app
  HostName 192.0.2.10
Host app
  HostName 198.51.100.7
  User later
''');
    expect(r.entries.map((e) => (e.hostname, e.user)).toSet(), {('192.0.2.10', 'later')});
  });

  test('a Match block is left out, and what follows it belongs to it', () {
    final r = source.parse('''
Host app
  HostName 192.0.2.10
Match host app
  User matched
Host *
  Port 2200
''');
    expect(host(r, 'app').user, isNull);
    expect(host(r, 'app').port, 2200);
  });

  test('a port that is none, given by a pattern, leaves out each host it is for, by its own name', () {
    final r = source.parse('''
Host app db
  HostName 192.0.2.10
Host *
  Port 99999
''');
    expect(r.entries, isEmpty);
    expect(r.skipped.where((s) => s.reason == SshSkipReason.port).map((s) => s.label), ['app', 'db']);
  });

  group('ProxyJump', () {
    OnboardingSshEntry entry(String alias, {String? jump, int port = 22, String? user}) =>
        OnboardingSshEntry(alias: alias, hostname: '$alias.example.com', port: port, user: user, proxyJump: jump);

    test('one host, with the user and the port written with it', () {
      expect(entry('db', jump: 'bastion').jumpHop, (host: 'bastion', user: null, port: null));
      expect(entry('db', jump: 'admin@bastion:2222').jumpHop, (host: 'bastion', user: 'admin', port: 2222));
      expect(entry('db', jump: '[2001:db8::1]:2200').jumpHop, (host: '2001:db8::1', user: null, port: 2200));
      expect(entry('db', jump: 'admin@bastion:2222').proxyJumpHost, 'bastion');
    });

    test('a route of several hosts stands for no one host: it is not linked to its first', () {
      final chained = entry('db', jump: 'edge,inner');
      expect(chained.jumpHop, isNull);
      expect(chained.proxyJumpHost, isNull);
      expect(chained.hasJumpRoute, isTrue);
      expect(jumpTargetOf(chained, {'edge': entry('edge'), 'inner': entry('inner')}, const []), isNull);
    });

    test('none, and nothing, are no route', () {
      for (final jump in [null, '', '  ', 'none', 'NONE']) {
        expect(entry('db', jump: jump).hasJumpRoute, isFalse, reason: '$jump');
        expect(entry('db', jump: jump).jumpHop, isNull);
      }
    });

    test('a host of this import is the one to connect through only as it is set up', () {
      final byAlias = {'bastion': entry('bastion', port: 2222, user: 'admin'), 'db': entry('db')};
      ({String? alias, String? savedId})? to(String jump) => jumpTargetOf(entry('db', jump: jump), byAlias, const []);
      expect(to('bastion'), (alias: 'bastion', savedId: null));
      expect(to('admin@bastion:2222'), (alias: 'bastion', savedId: null));
      expect(to('root@bastion'), isNull, reason: 'another user than the host has');
      expect(to('bastion:22'), isNull, reason: 'another port than the host has');
      expect(to('elsewhere'), isNull, reason: 'not here');
      expect(to('db'), isNull, reason: 'never through itself');
    });

    test('a saved host is found by its name or its address, with the port and the user it has', () {
      const saved = <SavedHop>[
        (id: 'h-1', label: 'Bastion', host: 'bastion.example.com', port: 2222, user: 'admin'),
        (id: 'h-2', label: 'edge', host: '192.0.2.9', port: 22, user: null),
      ];
      ({String? alias, String? savedId})? to(String jump) => jumpTargetOf(entry('db', jump: jump), const {}, saved);
      expect(to('bastion.example.com'), (alias: null, savedId: 'h-1'));
      expect(to('admin@bastion.example.com:2222'), (alias: null, savedId: 'h-1'));
      expect(to('bastion.example.com:22'), isNull);
      expect(to('edge'), (alias: null, savedId: 'h-2'));
      expect(to('someone@edge'), isNull, reason: 'the saved host signs in as nobody in particular');
      expect(to('192.0.2.9'), (alias: null, savedId: 'h-2'));
    });
  });
}
