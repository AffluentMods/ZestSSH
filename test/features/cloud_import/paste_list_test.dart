import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/paste_list.dart';

/// Paste a list: one host per line, for an app with no
/// export. Every shape a line may take, and the lines that are none.
void main() {
  (String?, String, int, int) shape(PastedHost h) => (h.user, h.host, h.port, h.line);

  test('every accepted shape, with its line number; blank lines and # comments left out', () {
    final r = parsePasteList('''
web-01.example.com
deploy@web-02.example.com

# the database
db.example.com:2200
ops@203.0.113.10:2222
[2001:db8::1]:2222
root@[2001:db8::2]
2001:db8::3
weird@name@host.example.com
''');
    expect(r.errors, isEmpty);
    expect([for (final h in r.hosts) shape(h)], [
      (null, 'web-01.example.com', 22, 1),
      ('deploy', 'web-02.example.com', 22, 2),
      (null, 'db.example.com', 2200, 5),
      ('ops', '203.0.113.10', 2222, 6),
      (null, '2001:db8::1', 2222, 7),
      ('root', '2001:db8::2', 22, 8),
      (null, '2001:db8::3', 22, 9),
      ('weird@name', 'host.example.com', 22, 10),
    ], reason: 'the user is everything before the last @; a bare IPv6 address takes port 22');
  });

  test('junk is an error with its line number, the rest still read', () {
    final r = parsePasteList(
        '@\nhost:\nhost:99999\nuser@\nhost:0\nhost:22:33x\n[2001:db8::1\nspace host\n-oProxyCommand\nok.example.com');
    expect([for (final e in r.errors) (e.line, e.text)], [
      (1, '@'),
      (2, 'host:'),
      (3, 'host:99999'),
      (4, 'user@'),
      (5, 'host:0'),
      (6, 'host:22:33x'),
      (7, '[2001:db8::1'),
      (8, 'space host'),
      (9, '-oProxyCommand'),
    ]);
    expect([for (final h in r.hosts) shape(h)], [(null, 'ok.example.com', 22, 10)]);
  });

  test('a user that reads as an option, carries a colon or hides text is an error; a domain account is fine', () {
    final r = parsePasteList('-oProxyCommand=x@a.example.com\nroot:secret@b.example.com\nad\u202emin@c.example.com\n'
        'ops@corp.example.com@d.example.com');
    expect([for (final e in r.errors) e.line], [1, 2, 3]);
    expect([for (final h in r.hosts) shape(h)], [('ops@corp.example.com', 'd.example.com', 22, 4)]);
  });

  test('Windows line ends and surrounding spaces change nothing', () {
    final r = parsePasteList('  a.example.com  \r\nb.example.com:2022\r\n');
    expect([for (final h in r.hosts) (h.host, h.port)], [('a.example.com', 22), ('b.example.com', 2022)]);
    expect(r.errors, isEmpty);
  });
}
