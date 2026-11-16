import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/utils/redactor.dart';

/// The masking rules of recording mode (spec sections 3a to 3d and 4), pinned
/// against the real fleet the spec was audited with. Every acceptance line in
/// the spec has a test here; a rule change that breaks one of these breaks a
/// promise the settings copy makes.
void main() {
  final r = Redactor.instance;

  setUp(() {
    r.clearNames();
    r.enabled = true;
    r.level = RedactLevel.layout;
  });

  tearDown(() {
    r.clearNames();
    r.enabled = false;
    r.level = RedactLevel.layout;
    r.salt = '';
  });

  group('3a names: first two, three zeros, last two', () {
    const fleet = {
      'Hypervisor Node3': 'Hy000e3',
      'Hypervisor Node2': 'Hy000e2',
      'Hypervisor Node4': 'Hy000e4',
      'Hypervisor': 'Hy000or',
      'Mac-Studio': 'Ma000io',
      'Firewall-1': 'Fi000-1',
      'edge-router': 'ed000er',
      'Metrics': 'Me000cs',
      'Webshop': 'We000op',
      'vpn-gateway': 'vp000ay',
      'db-primary': 'db000ry',
      'Cache-01': 'Ca00001',
      'Log-Store': 'Lo000re',
      'build-runner': 'bu000er',
    };
    test('verified fleet examples', () {
      r.registerNames(fleet.keys);
      for (final e in fleet.entries) {
        expect(Redactor.name(e.key), e.value, reason: e.key);
      }
    });
    test('every mask is exactly 7 characters, whatever the input length', () {
      for (final n in ['Hypervisor', 'Hypervisor Node3', 'a-very-long-hostname-indeed']) {
        expect(Redactor.maskName(n).length, 7, reason: n);
      }
    });
    test('the original length is not inferable', () {
      expect(Redactor.name('Webshop').length, Redactor.name('build-runner').length);
    });
    test('the hypervisor cluster still clusters and sorts together', () {
      final masked = ['Hypervisor Node4', 'Hypervisor Node2', 'Hypervisor Node3']
          .map(Redactor.name)
          .toList()
        ..sort();
      expect(masked, ['Hy000e2', 'Hy000e3', 'Hy000e4']);
    });
  });

  group('3b short names: under the floor, nothing is left to hide', () {
    test('lb-2, VPN, Cache fall back to host-NN', () {
      for (final n in ['lb-2', 'VPN', 'Cache', 'Hype']) {
        final m = Redactor.name(n);
        expect(m, matches(RegExp(r'^host-\d\d$')), reason: n);
        expect(m.toLowerCase(), isNot(contains(n.toLowerCase())), reason: n);
      }
    });
    test('the floor is 7', () {
      expect(Redactor.kShortNameFloor, 7);
      expect(Redactor.name('abcdef'), matches(RegExp(r'^host-\d\d$')));
      expect(Redactor.name('abcdefg'), 'ab000fg');
    });
    test('the fallback is stable per name', () {
      expect(Redactor.name('lb-2'), Redactor.name('lb-2'));
    });
  });

  group('3c collisions across the visible set', () {
    test('colliding masks get a counter, assigned in sorted order', () {
      r.registerNames(['app-server-01', 'app-router-01', 'prod-db-01', 'prod-dns-01']);
      expect(Redactor.name('app-router-01'), 'ap00001-1'); // sorts first
      expect(Redactor.name('app-server-01'), 'ap00001-2');
      expect(Redactor.name('prod-db-01'), 'pr00001-1');
      expect(Redactor.name('prod-dns-01'), 'pr00001-2');
    });
    test('non-colliding names carry no counter', () {
      r.registerNames(['app-server-01', 'edge-router']);
      expect(Redactor.name('app-server-01'), 'ap00001');
      expect(Redactor.name('edge-router'), 'ed000er');
    });
    test('the mapping is stable across screens within a session', () {
      r.registerNames(['app-server-01', 'app-router-01']);
      final first = Redactor.name('app-server-01');
      r.registerNames(['app-server-01']); // idempotent re-register
      expect(Redactor.name('app-server-01'), first);
    });
    test('every registered name masks to a distinct value', () {
      final names = [
        'app-server-01', 'app-router-01', 'prod-db-01', 'prod-dns-01',
        'Hypervisor Node3', 'Hypervisor Node2', 'lb-2', 'lb-3', 'VPN',
      ];
      r.registerNames(names);
      final masked = names.map(Redactor.name).toSet();
      expect(masked.length, names.length);
    });
  });

  group('masking twice is a no-op', () {
    // A composed tab label ("Hy000e3, Fi000-1") is built from masked pieces
    // and then masked again by the pill that renders it. Every screen must
    // still agree, so a value that already has a mask's shape passes through.
    test('layout masks, counters and the short fallback', () {
      r.registerNames(['Hypervisor Node3', 'app-server-01', 'app-router-01', 'lb-2']);
      for (final n in ['Hypervisor Node3', 'app-server-01', 'app-router-01', 'lb-2']) {
        final once = Redactor.name(n);
        expect(Redactor.name(once), once, reason: n);
        expect(Redactor.line(once), once, reason: n);
      }
    });
    test('strict words', () {
      r.level = RedactLevel.strict;
      r.registerNames(['Hypervisor Node3', 'lb-2']);
      for (final n in ['Hypervisor Node3', 'lb-2']) {
        final once = Redactor.name(n);
        expect(Redactor.name(once), once, reason: n);
      }
    });
    test('a REAL host that is named like a mask is still masked', () {
      r.registerNames(['willow', 'host-42']);
      r.level = RedactLevel.strict;
      expect(Redactor.name('willow'), isNot('willow'));
      r.level = RedactLevel.layout;
      expect(Redactor.name('host-42'), isNot('host-42'));
    });
  });

  group('3d everything else', () {
    test('IPv4 lands in RFC 5737 TEST-NET-1 and preserves a port', () {
      final a = Redactor.address('10.244.95.249');
      expect(a, matches(RegExp(r'^192\.0\.2\.\d{1,3}$')));
      final last = int.parse(a.split('.').last);
      expect(last, inInclusiveRange(1, 254));
      expect(Redactor.address('10.12.111.1:2222'),
          matches(RegExp(r'^192\.0\.2\.\d{1,3}:2222$')));
    });
    test('IPv6 lands in RFC 3849', () {
      expect(Redactor.address('2001:4860:4860::8888'),
          matches(RegExp(r'^2001:db8::[0-9a-f]{1,4}$')));
      expect(Redactor.address('fe80::1'), startsWith('2001:db8::'));
    });
    test('a DNS name becomes host-NN.example.invalid (RFC 2606)', () {
      expect(Redactor.address('prod.db.local'),
          matches(RegExp(r'^host-\d\d\.example\.invalid$')));
      expect(Redactor.address('nas.home:8443'),
          matches(RegExp(r'^host-\d\d\.example\.invalid:8443$')));
    });
    test('no generated address is in real private space', () {
      for (final real in ['10.0.0.1', '192.168.1.5', '172.16.0.20', '8.8.8.8']) {
        expect(Redactor.address(real), startsWith('192.0.2.'), reason: real);
      }
    });
    test('usernames and key names are obviously synthetic', () {
      expect(Redactor.username('alex'), matches(RegExp(r'^user\d\d$')));
      expect(Redactor.username('alex'), Redactor.username('alex'));
      expect(Redactor.keyName('Alex'), matches(RegExp(r'^key-\d\d$')));
    });
    test('the SHA256 fake is the length of a real one and decodes to a marker', () {
      const real = 'SHA256:Aq65otBkq++WRjtuKV+Xxu5fTMXxuE3isnjpem4u3xs=';
      final fake = Redactor.fingerprint(real);
      expect(fake.length, real.length);
      expect(fake, startsWith('SHA256:'));
      final digest = base64.decode(fake.substring('SHA256:'.length));
      expect(digest.length, 32, reason: 'a SHA-256 digest is 32 bytes');
      expect(utf8.decode(digest.sublist(0, 28)), 'REDACTED-BY-ZESTSSH-REC-MODE');
      expect(fake, isNot(contains('Aq65')));
    });
    test('a non-SHA256 fingerprint keeps its prefix and is bulleted', () {
      expect(Redactor.fingerprint('MD5:ab:cd:ef'), startsWith('MD5:•'));
    });
    test('a password is fixed-width bullets', () {
      expect(r.apply('hunter2', RedactKind.password), Redactor.passwordMask);
      expect(r.apply('a-much-longer-passphrase', RedactKind.password),
          Redactor.passwordMask);
    });
  });

  group('free text', () {
    test('user@ip inside a credential label', () {
      final out = Redactor.line('root@10.77.0.10');
      expect(out, matches(RegExp(r'^user\d\d@192\.0\.2\.\d{1,3}$')));
    });
    test('a key comment holding user@host', () {
      final out = Redactor.line('ops@mac-studio');
      expect(out, matches(RegExp(r'^user\d\d@host-\d\d\.example\.invalid$')));
      expect(out, isNot(contains('mac-studio')));
    });
    test('a standalone IPv4 and a dotted DNS name', () {
      final out = Redactor.line('ping 10.12.111.1 then ssh prod.db.local');
      expect(out, isNot(contains('10.12.111.1')));
      expect(out, isNot(contains('prod.db.local')));
      expect(out, contains('192.0.2.'));
      expect(out, contains('.example.invalid'));
    });
    test('a registered host name embedded in prose is masked by the name rule', () {
      r.registerNames(['db-primary', 'Hypervisor', 'Hypervisor Node3']);
      expect(Redactor.line('restart db-primary now'), 'restart db000ry now');
      // Longest first: the cluster member is masked whole, not as "Hy000or Node3".
      expect(Redactor.line('Hypervisor Node3 is down'), 'Hy000e3 is down');
    });
    test('a substituted fake is never re-substituted', () {
      final once = Redactor.line('root@10.77.0.10');
      expect(Redactor.line(once), once);
    });
  });

  group('apply: the only entry point screens use', () {
    test('is a pass-through while recording mode is off', () {
      r.enabled = false;
      expect(r.apply('Hypervisor Node3', RedactKind.host), 'Hypervisor Node3');
      expect(Redactable.host('Hypervisor Node3').display, 'Hypervisor Node3');
    });
    test('masks every kind while recording mode is on', () {
      expect(Redactable.host('Hypervisor Node3').display, 'Hy000e3');
      expect(Redactable.group('Security').display, 'Se000ty');
      expect(Redactable.workspace('Main').display, matches(RegExp(r'^host-\d\d$')));
      expect(Redactable.account("Alex's Tree").display, 'Al000ee');
      expect(Redactable.address('10.244.95.249').display, startsWith('192.0.2.'));
      expect(Redactable.username('alex').display, matches(RegExp(r'^user\d\d$')));
      expect(Redactable.keyName('Alex').display, matches(RegExp(r'^key-\d\d$')));
      expect(Redactable.keyComment('ops@mac-studio').display,
          isNot(contains('mac-studio')));
      expect(Redactable.fingerprint('SHA256:abc=').display, Redactor.fakeSha256);
      expect(Redactable.password('hunter2').display, Redactor.passwordMask);
    });
    test('toString is the display form, so string interpolation is safe', () {
      final host = Redactable.host('Hypervisor Node3');
      expect('$host', 'Hy000e3');
      expect(host.toString(), isNot(contains('Hypervisor')));
    });
  });

  group('4 Strict level', () {
    test('names become unrelated list words, distinct per name', () {
      r.level = RedactLevel.strict;
      const names = ['Hypervisor Node3', 'Firewall-1', 'db-primary', 'lb-2', 'VPN', 'edge-router'];
      r.registerNames(names);
      final words = names.map(Redactor.name).toList();
      for (final w in words) {
        expect(Redactor.strictWords, contains(w.split('-').first));
      }
      expect(words.toSet().length, names.length);
    });
    test('a strict word shares no letters with the original where possible', () {
      r.level = RedactLevel.strict;
      r.registerNames(['lb-2', 'VPN', 'db-primary']);
      for (final n in ['lb-2', 'VPN', 'db-primary']) {
        final w = Redactor.name(n);
        final own = n.toLowerCase().split('').where((c) => RegExp('[a-z]').hasMatch(c)).toSet();
        final shared = w.split('').where(own.contains);
        expect(shared, isEmpty, reason: '$n -> $w');
      }
    });
    test('strict never keeps the layout shape', () {
      r.level = RedactLevel.strict;
      expect(Redactor.name('Hypervisor Node3'), isNot(startsWith('Hy')));
      expect(Redactor.name('Hypervisor Node3'), isNot(endsWith('e3')));
    });
  });

  group('address-shaped values that arrive as names', () {
    // A label-less host shows its address, a Quick Connect session is
    // labelled `user@host`: through the name rule those kept their digits
    // (`10.50.0.24` became `1000024`).
    test('an IP, a user@host or a dotted name is routed to its own rule', () {
      expect(Redactor.name('10.50.0.24'), startsWith('192.0.2.'));
      expect(Redactor.name('root@10.50.0.24'),
          matches(RegExp(r'^user\d\d@192\.0\.2\.\d{1,3}$')));
      expect(Redactor.name('root@10.50.0.24:22'),
          matches(RegExp(r'^user\d\d@192\.0\.2\.\d{1,3}:22$')));
      expect(Redactor.name('node3.local'),
          matches(RegExp(r'^host-\d\d\.example\.invalid$')));
      expect(Redactor.name('nas.home:22'),
          matches(RegExp(r'^host-\d\d\.example\.invalid:22$')));
      expect(Redactor.name('2001:db8:1::5'), startsWith('2001:db8::'));
      expect(Redactor.name('[2001:db8:1::5]:22'),
          matches(RegExp(r'^\[2001:db8::[0-9a-f]{1,4}\]:22$')));
    });
    test('a plain name still takes the name rule', () {
      expect(Redactor.name('Hypervisor Node3'), 'Hy000e3');
      expect(Redactor.name('lb-2'), matches(RegExp(r'^host-\d\d$')));
      expect(Redactor.name('1.9.7'), isNot(startsWith('192.0.2.')),
          reason: 'digits with dots are not an IPv4 without four octets');
    });
    test('line breaks are never kept', () {
      expect(Redactor.name('a\nb-cdefg'), isNot(contains('\n')));
    });
  });

  group('free text: the gaps a review found', () {
    test('underscores and plus signs are part of a name or a user', () {
      expect(Redactor.line('deploy@build_server'),
          matches(RegExp(r'^user\d\d@host-\d\d\.example\.invalid$')));
      expect(Redactor.line('root@my_host.lan'),
          matches(RegExp(r'^user\d\d@host-\d\d\.example\.invalid$')));
      expect(Redactor.line('my_host.internal.lan'),
          matches(RegExp(r'^host-\d\d\.example\.invalid$')));
      expect(Redactor.line('bob+admin@host.example.com'),
          matches(RegExp(r'^user\d\d@host-\d\d\.example\.invalid$')));
    });
    test('IPv6 bare, bracketed with a port, with a zone id, behind user@', () {
      expect(Redactor.line('ping 2001:4860:4860::8888 now'),
          matches(RegExp(r'^ping 2001:db8::[0-9a-f]{1,4} now$')));
      expect(Redactor.line('[2001:db8:85a3::1]:22'),
          matches(RegExp(r'^\[2001:db8::[0-9a-f]{1,4}\]:22$')));
      expect(Redactor.line('root@[fe80::1%eth0]'),
          matches(RegExp(r'^user\d\d@\[2001:db8::[0-9a-f]{1,4}\]$')));
      expect(Redactor.line('ssh root@fe80::1'),
          matches(RegExp(r'^ssh user\d\d@2001:db8::[0-9a-f]{1,4}$')));
    });
    test('a clock time, a version or a file name is not an address', () {
      expect(Redactor.line('at 12:30:45 on 1.9.7'), 'at 12:30:45 on 1.9.7');
      expect(Redactor.line('see readme.txt for details'),
          'see readme.txt for details');
      expect(Redactor.line('e.g. the tab bar'), 'e.g. the tab bar');
    });
    test('a single-dot name with a port, a local suffix or a user prefix', () {
      expect(Redactor.line('open nas.home:22 now'),
          matches(RegExp(r'^open host-\d\d\.example\.invalid:22 now$')));
      expect(Redactor.line('node3.local is down'),
          matches(RegExp(r'^host-\d\d\.example\.invalid is down$')));
      expect(Redactor.line('root@node3'),
          matches(RegExp(r'^user\d\d@host-\d\d\.example\.invalid$')));
    });
    test('credentials inside a URL go entirely', () {
      final out = Redactor.line('https://user:pass@host.example.com/x');
      expect(out, isNot(contains('pass')));
      expect(out,
          matches(RegExp(r'^https://user\d\d:•+@host-\d\d\.example\.invalid/x$')));
    });
    test('a@b@c is masked whole', () {
      expect(Redactor.line('a@b@c'),
          matches(RegExp(r'^user\d\d@host-\d\d\.example\.invalid$')));
    });
    test('registered names and addresses match case-insensitively', () {
      r.registerNames(['Hypervisor Node3']);
      r.registerAddresses(['Node3.Home']);
      expect(Redactor.line('hypervisor node3 is down'), 'Hy000e3 is down');
      expect(Redactor.line('NODE3.HOME went away'),
          matches(RegExp(r'^host-\d\d\.example\.invalid went away$')));
    });
  });

  group('a mask shape is not a free pass', () {
    test('a real value shaped like a mask is masked unless this session made it',
        () {
      expect(Redactable.account('ash').display, isNot('ash'));
      expect(Redactable.account('willow').display, isNot('willow'));
      expect(Redactable.host('host-42').display, isNot('host-42'));
      expect(Redactable.host('ab000cd').display, isNot('ab000cd'));
      expect(Redactable.network('moss').display, isNot('moss'));
    });
    test('a label composed from produced masks passes through whole', () {
      r.registerNames(['Hypervisor Node3', 'Firewall-1']);
      final a = Redactor.name('Hypervisor Node3');
      final b = Redactor.name('Firewall-1');
      expect(Redactable.host('$a, $b').display, '$a, $b');
      expect(Redactable.host('$a +2').display, '$a +2');
      expect(Redactable.host(a).display, a);
    });
  });

  group('fingerprint prefixes', () {
    test('only a known algorithm prefix is kept', () {
      expect(Redactor.fingerprint('ab:cd:ef:01:23'), '•' * 24,
          reason: 'a bare hex digest has no prefix, its first pair is data');
      expect(Redactor.fingerprint('md5:ab:cd'), startsWith('MD5:•'));
      expect(Redactor.fingerprint('SHA512:xyz'), startsWith('SHA512:•'));
      expect(Redactor.fingerprint('sha256:xyz'), Redactor.fakeSha256);
    });
  });

  group('the install salt', () {
    String probe() => [
          Redactor.username('root'),
          Redactor.address('10.0.0.1'),
          Redactor.address('nas.home'),
          Redactor.address('fe80::1'),
          Redactor.keyName('id_ed25519'),
          Redactor.name('lb-2'),
        ].join(' ');
    test('masks are stable for one salt and differ between salts', () {
      r.salt = 'install-a';
      final a1 = probe();
      final a2 = probe();
      r.salt = 'install-b';
      final b = probe();
      expect(a1, a2);
      expect(a1, isNot(b));
    });
    test('the layout name rule does not depend on the salt', () {
      r.salt = 'install-a';
      expect(Redactor.name('Hypervisor Node3'), 'Hy000e3');
      r.salt = 'install-b';
      expect(Redactor.name('Hypervisor Node3'), 'Hy000e3');
    });
  });

  group('paths: mask each segment, keep the shape', () {
    test('layout masks segments but preserves separators and markers', () {
      final masked = Redactable.path('/home/alice/acme-secret').display;
      // Leading slash + segment count preserved; no real name survives.
      expect(masked.startsWith('/'), isTrue);
      expect(masked.split('/').where((s) => s.isNotEmpty), hasLength(3));
      expect(masked.contains('alice'), isFalse);
      expect(masked.contains('acme-secret'), isFalse);
      expect(masked.contains('home'), isFalse);
    });

    test('~, . and .. markers are kept', () {
      expect(Redactable.path('~/proj').display.startsWith('~/'), isTrue);
      expect(Redactable.path('../up').display.startsWith('../'), isTrue);
    });

    test('strict replaces segments with unrelated words', () {
      r.level = RedactLevel.strict;
      final masked = Redactable.path('/var/log').display;
      expect(masked.contains('var'), isFalse);
      expect(masked.contains('log'), isFalse);
      expect(Redactor.strictWords.any(masked.contains), isTrue);
    });

    test('passes through untouched when recording mode is off', () {
      r.enabled = false;
      expect(Redactable.path('/home/alice/proj').display, '/home/alice/proj');
    });
  });

  group('commands: replaced whole by a stand-in from the pool', () {
    const real = 'ssh root@10.0.0.7 "cat /etc/shadow" # acme prod';

    test('the stand-in comes from the pool and keeps nothing of the real one',
        () {
      final fake = Redactable.command(real).display;
      expect(Redactor.fakeCommands, contains(fake));
      expect(fake.contains('10.0.0.7'), isFalse);
      expect(fake.contains('acme'), isFalse);
      expect(fake.contains('shadow'), isFalse);
    });

    test('deterministic: the same command reads the same everywhere', () {
      expect(Redactable.command(real).display,
          Redactable.command(real).display);
      expect(Redactable.command('  $real  ').display,
          Redactable.command(real).display);
    });

    test('strict replaces it too (the screen hides history at strict; the '
        'rule still never leaks)', () {
      r.level = RedactLevel.strict;
      expect(Redactor.fakeCommands, contains(Redactable.command(real).display));
    });

    test('the pool itself names nothing real', () {
      for (final c in Redactor.fakeCommands) {
        expect(Redactor.line(c), c, reason: c);
      }
    });

    test('empty stays empty, and off means the real command', () {
      expect(Redactable.command('').display, '');
      r.enabled = false;
      expect(Redactable.command(real).display, real);
    });
  });
}
