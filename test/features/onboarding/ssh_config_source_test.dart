import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart' show kCsvMaxHosts;
import 'package:zestssh/features/onboarding/data/display_text_sanitizer.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';

void main() {
  const source = SshConfigSource();

  group('SshConfigSource.parse (F1 rules)', () {
    const sample = '''
# my ssh config
Host web1 web2
  HostName example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519

Host db
  HostName 10.0.0.5
  ProxyJump user@web1:2222

Host *
  ForwardAgent yes

Host prod-*
  User root

Host badport
  HostName host.example
  Port 99999

Host spaced
  HostName has space
''';

    final result = source.parse(sample);

    test('expands multi-alias Host lines into one entry each', () {
      final aliases = result.entries.map((e) => e.alias).toList();
      expect(aliases, containsAll(<String>['web1', 'web2', 'db']));
      final web1 = result.entries.firstWhere((e) => e.alias == 'web1');
      expect(web1.hostname, 'example.com');
      expect(web1.port, 2222);
      expect(web1.user, 'deploy');
      expect(web1.identityFile, '~/.ssh/id_ed25519');
    });

    test('parses ProxyJump and strips user@host:port to the bare host', () {
      final db = result.entries.firstWhere((e) => e.alias == 'db');
      expect(db.proxyJump, 'user@web1:2222');
      expect(db.proxyJumpHost, 'web1');
    });

    test('skips wildcard-only host blocks with a wildcard reason', () {
      final wildcards = result.skipped
          .where((s) => s.reason == SshSkipReason.wildcard)
          .map((s) => s.label)
          .toList();
      expect(wildcards, contains('*'));
      expect(wildcards, contains('prod-*'));
    });

    test('skips entries with an invalid port', () {
      expect(
        result.skipped.any((s) =>
            s.reason == SshSkipReason.port && s.label.contains('badport')),
        isTrue,
      );
    });

    test('skips entries with an invalid hostname', () {
      expect(
        result.skipped.any(
            (s) => s.reason == SshSkipReason.host && s.label == 'spaced'),
        isTrue,
      );
    });

    test('never emits a wildcard alias as an importable entry', () {
      expect(result.entries.any((e) => e.alias.contains('*')), isFalse);
    });

    test('empty input yields an empty, non-null result', () {
      final empty = source.parse('');
      expect(empty.isEmpty, isTrue);
      expect(empty.hasImportable, isFalse);
    });
  });

  group('a config that may be anything', () {
    test('an address with a dash in front is no host: it reads as an option wherever it is passed later', () {
      final r = source.parse('Host evil\n  HostName -oProxyCommand=calc\n\nHost -bad\n\nHost fine\n  HostName fine.example.com\n');
      expect(r.entries.map((e) => e.alias), ['fine']);
      expect(r.skipped.map((s) => s.label).toSet(), containsAll(['evil']));
      expect(r.skipped.every((s) => s.reason == SshSkipReason.host || s.reason == SshSkipReason.wildcard), isTrue);
    });

    test('its forms of a line are read as before: a key, then white space or an equals sign with white space around it', () {
      final r = source.parse('Host=a\n HostName = a.example.com\n Port=2222\n User\tdeploy\n'
          'host b\r\n  hostname\tb.example.com\r\n  port   2200\r\n'
          'Host c\r  HostName c.example.com\r  User x=y\r');
      final by = {for (final e in r.entries) e.alias: e};
      expect(by.keys, ['a', 'b', 'c']);
      expect((by['a']!.hostname, by['a']!.port, by['a']!.user), ('a.example.com', 2222, 'deploy'));
      expect((by['b']!.hostname, by['b']!.port), ('b.example.com', 2200));
      expect((by['c']!.hostname, by['c']!.user), ('c.example.com', 'x=y'));
    });

    test('a line with nothing after its first word, or with only an equals sign before it, says nothing', () {
      final r = source.parse('Host a\n  HostName\n  =b\n  = c\n  User deploy\n');
      expect(r.entries.single.hostname, 'a');
      expect(r.entries.single.user, 'deploy');
    });

    test('at most as many hosts are read as from any host file, and it says so', () {
      final many = source.parse('Host ${List.generate(kCsvMaxHosts + 1, (i) => 'h$i').join(' ')}\n');
      expect(many.entries, hasLength(kCsvMaxHosts));
      expect(many.cut, isTrue);
      final exactly = source.parse('Host ${List.generate(kCsvMaxHosts, (i) => 'h$i').join(' ')}\n');
      expect(exactly.entries, hasLength(kCsvMaxHosts));
      expect(exactly.cut, isFalse);
    });
  });

  group('F1 display-text sanitization (untrusted config)', () {
    // \u202e = RIGHT-TO-LEFT OVERRIDE, \u200e = LEFT-TO-RIGHT MARK,
    // \u2066/\u2069 = isolate controls, \u0007 = BEL, \u007f = DEL.
    // All must be stripped before an imported field renders on a host card.
    test('strips bidi/RTL spoofing chars from an imported User', () {
      final result = source.parse(
        'Host bidiuser\n'
        '  HostName ok.example\n'
        '  User de\u202eploy\u200e\n',
      );
      final entry = result.entries.firstWhere((e) => e.alias == 'bidiuser');
      expect(entry.user, 'deploy');
    });

    test('strips control/bidi chars from an imported IdentityFile', () {
      final result = source.parse(
        'Host idf\n'
        '  HostName ok2.example\n'
        '  IdentityFile ~/.ssh/id\u200eed\n',
      );
      final entry = result.entries.firstWhere((e) => e.alias == 'idf');
      expect(entry.identityFile, '~/.ssh/ided');
    });

    test('a User that is nothing but format controls is dropped', () {
      final result = source.parse(
        'Host ctl\n'
        '  HostName ok3.example\n'
        '  User \u202e\u200e\n',
      );
      final entry = result.entries.firstWhere((e) => e.alias == 'ctl');
      expect(entry.user, isNull);
    });

    test('sanitizeDisplayText strips controls + bidi, keeps benign text', () {
      expect(sanitizeDisplayText('web1'), 'web1');
      // C0 control (BEL) and DEL removed; surrounding letters kept.
      expect(sanitizeDisplayText('a\u0007b\u007fc'), 'abc');
      // Bidi override / isolate controls removed.
      expect(sanitizeDisplayText('e\u202evil\u2066spoof\u2069'), 'evilspoof');
      // TAB/LF/CR are intentionally preserved (multi-line notes survive).
      expect(sanitizeDisplayText('a\tb\nc'), 'a\tb\nc');
    });

    test('sanitizeDisplayText caps length after stripping', () {
      final long = 'x' * 5000;
      expect(sanitizeDisplayText(long, maxLen: 512).length, 512);
      // Stripped chars do not count toward the visible budget.
      final padded = '\u202e${'y' * 300}';
      expect(sanitizeDisplayText(padded, maxLen: 300).length, 300);
    });
  });
}
