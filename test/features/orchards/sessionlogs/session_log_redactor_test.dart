import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/sessionlogs/session_log_redactor.dart';

/// What a team session log leaves out (3.0): the session's known
/// secrets, private key blocks, passwords in URLs, authorization headers,
/// well-known token formats and labelled secret values; ordinary text stays.

void main() {
  test("the session's own secrets, wherever they appear, longest first; short values are not looked for", () {
    final r = SessionLogRedactor()
      ..addSecret('hunter2secret')
      ..addSecret('hunter2')
      ..addSecret('abc');
    expect(r.redact('echo hunter2secret; echo hunter2 && echo abc'), 'echo [redacted]; echo [redacted] && echo abc');
    expect(r.secrets, ['hunter2secret', 'hunter2']);
    // Regular-expression characters in a secret are taken literally.
    final dots = SessionLogRedactor()..addSecret('p.a*s+s');
    expect(dots.redact('x p.a*s+s y pXaas'), 'x [redacted] y pXaas');
  });

  test('a private key block is left out whole', () {
    final r = SessionLogRedactor();
    const key = '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nAAAA\n-----END OPENSSH PRIVATE KEY-----';
    expect(r.redact('cat id\n$key\n\$ '), 'cat id\n[redacted private key]\n\$ ');
    const rsa = '-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----';
    expect(r.redact(rsa), '[redacted private key]');
    // A public key or certificate stays.
    const cert = '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----';
    expect(r.redact(cert), cert);
  });

  test('several private key blocks: each BEGIN with the first END after it; one with no END stays', () {
    final r = SessionLogRedactor();
    const a = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----';
    const b = '-----BEGIN EC PRIVATE KEY-----\nBBBB\n-----END EC PRIVATE KEY-----';
    const open = '-----BEGIN PRIVATE KEY-----\nCCCC';
    expect(r.redact('one\n$a\ntwo\n$b\nthree\n$open'),
        'one\n[redacted private key]\ntwo\n[redacted private key]\nthree\n$open');
    // A BEGIN inside a block ends with that block's END.
    expect(r.redact('x\n-----BEGIN PRIVATE KEY-----\nDDDD\n-----BEGIN RSA PRIVATE KEY-----\nEEEE\n'
            '-----END RSA PRIVATE KEY-----\ny\n-----END PRIVATE KEY-----\nz'),
        'x\n[redacted private key]\ny\n-----END PRIVATE KEY-----\nz');
    // An END with no BEGIN before it stays.
    expect(r.redact('-----END PRIVATE KEY-----\n$a'), '-----END PRIVATE KEY-----\n[redacted private key]');
  });

  test('output crafted to be slow is not: every pattern runs in time linear in the text', () {
    final r = SessionLogRedactor()..addSecret('hunter2-pass');
    const n = 192 * 1024;
    final shapes = {
      'a-': 'a-' * (n ~/ 2),
      'a.': 'a.' * (n ~/ 2),
      'eyJ-': 'eyJ-' * (n ~/ 4),
      'sk-': 'sk-' * (n ~/ 3),
      'BEGIN without END': '-----BEGIN PRIVATE KEY-----\n' * (n ~/ 28),
      'BEGIN words': '-----BEGIN ${'A ' * (n ~/ 2)}',
      'password spaces': ('password${' ' * 50}') * (n ~/ 58),
      'scheme user': 'a://b:' * (n ~/ 6),
    };
    final took = Stopwatch()..start();
    for (final e in shapes.entries) {
      final each = Stopwatch()..start();
      r.redact(e.value);
      SessionLogRedactor.openPrivateKeyAt(e.value);
      expect(each.elapsedMilliseconds, lessThan(2000), reason: e.key);
    }
    expect(took.elapsedMilliseconds, lessThan(5000));
  });

  test('an open private key block is found, so the text after it waits for its end', () {
    expect(SessionLogRedactor.openPrivateKeyAt('ok\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc'), 3);
    expect(SessionLogRedactor.openPrivateKeyAt('-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\nmore'), isNull);
    expect(SessionLogRedactor.openPrivateKeyAt('nothing here'), isNull);
    expect(
        SessionLogRedactor.openPrivateKeyAt(
            '-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n-----BEGIN EC PRIVATE KEY-----\ny'),
        56);
  });

  test('passwords in URLs, authorization headers and labelled values', () {
    final r = SessionLogRedactor();
    expect(r.redact('git clone https://alice:s3cr3t@git.example.com/repo'),
        'git clone https://alice:[redacted]@git.example.com/repo');
    expect(r.redact('curl -H "Authorization: Bearer abc.def-123"'), 'curl -H "Authorization: Bearer [redacted]"');
    expect(r.redact('authorization: basic dXNlcjpwYXNz'), 'authorization: basic [redacted]');
    expect(r.redact('export DB_PASSWORD=correct-horse'), 'export DB_PASSWORD=[redacted]');
    expect(r.redact('password: hunter22'), 'password: [redacted]');
    expect(r.redact('{"api_key": "abcd1234"}'), '{"api_key": "[redacted]"}');
    expect(r.redact('aws_secret_access_key = wJalrXUtnFEMI'), 'aws_secret_access_key = [redacted]');
    expect(r.redact('MYSQL_ROOT_PASSWORD=pa55word GITHUB_TOKEN=abc123x'),
        'MYSQL_ROOT_PASSWORD=[redacted] GITHUB_TOKEN=[redacted]');
  });

  test('well-known token formats', () {
    final r = SessionLogRedactor();
    for (final token in [
      'ghp_${'a' * 36}',
      'github_pat_${'b' * 60}',
      'glpat-${'c' * 20}',
      'AKIAABCDEFGHIJKLMNOP',
      'xoxb-1234567890-abcdef',
      'sk_live_${'d' * 24}',
      'AIza${'e' * 35}',
      'sk-ant-${'f' * 40}',
      'npm_${'g' * 36}',
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop',
    ]) {
      expect(r.redact('x $token y'), 'x [redacted] y', reason: token);
    }
  });

  test('ordinary terminal text stays as it was', () {
    final r = SessionLogRedactor();
    for (final line in [
      r'$ ls -la /etc/ssh',
      'Password authentication is enabled',
      "Enter password for 'alice':",
      'total 48 drwxr-xr-x 2 root root 4096 Sep 25 12:00 .',
      'https://example.com/path?query=1',
      'The token count is 5',
      'sk-1 short',
      'AKIA is a prefix',
    ]) {
      expect(r.redact(line), line, reason: line);
    }
  });
}
