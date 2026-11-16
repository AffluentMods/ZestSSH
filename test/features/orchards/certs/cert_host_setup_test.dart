import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';

/// The script a host runs to trust a Crate's authority (3.0), run
/// for real in WSL bash with stand-ins for sshd and systemctl and a scratch
/// directory in place of /etc/ssh: a fresh host gets ZestSSH's drop-in and
/// key file; a host that already trusts another authority keeps it, with
/// the key added to the same file; running it twice adds nothing; a new key
/// replaces the old one and nothing else; and a host whose sshd does not
/// read the drop-in is told what to add. Skips itself without WSL.
void main() {
  const key1 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne+Ky/One zestssh-ca-1';
  const key2 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo+Ky/Two zestssh-ca-2';
  const other = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherCompanyCA other-ca';

  test('the key line is quoted for the shell, whatever its comment holds', () {
    final script = certHostSetupScript(keyLine: "ssh-ed25519 AAAA it's-mine");
    expect(script, contains("KEY='ssh-ed25519 AAAA it'\\''s-mine'"));
    expect(certHostSetupScript(keyLine: key2, oldKeyLines: const [key1]),
        contains("OLD='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne+Ky/One'"));
    expect(ed25519KeyLine(List.filled(32, 7), 'zestssh-ca-3'),
        startsWith('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA'));
  });

  group('run on a host (WSL)', () {
    late bool wsl;
    setUpAll(() async {
      try {
        final r = await Process.run('wsl', ['-d', 'Ubuntu', '-e', 'true']).timeout(const Duration(seconds: 20));
        wsl = r.exitCode == 0;
      } catch (_) {
        wsl = false;
      }
    });

    /// Runs [scripts] in turn on one scratch host set up by [prepare] (bash,
    /// with ROOT set), then prints [show] (bash).
    Future<String> onHost(List<String> scripts, {String prepare = '', required String show}) async {
      final harness = StringBuffer()
        ..writeln('set -e')
        ..writeln(r'ROOT=$(mktemp -d)')
        ..writeln(r'mkdir -p "$ROOT/bin" "$ROOT/etc/ssh"')
        ..writeln(r"cat > $ROOT/bin/sshd <<'SHIM'")
        ..writeln('#!/bin/sh')
        ..writeln(r'if [ "$1" = "-t" ]; then exit 0; fi')
        ..writeln(r'if [ -f "$ROOT/notread" ]; then echo "trustedusercakeys none"; exit 0; fi')
        ..writeln(r'if [ -f "$ROOT/preset" ]; then echo "trustedusercakeys $(cat "$ROOT/preset")"; exit 0; fi')
        ..writeln(r'if [ -f "$ROOT/etc/ssh/sshd_config.d/10-zestssh.conf" ]; then')
        ..writeln(r'''  awk '{print "trustedusercakeys " $2}' "$ROOT/etc/ssh/sshd_config.d/10-zestssh.conf"; exit 0''')
        ..writeln('fi')
        ..writeln(r'echo "trustedusercakeys none"')
        ..writeln('SHIM')
        ..writeln(r"cat > $ROOT/bin/systemctl <<'SHIM'")
        ..writeln('#!/bin/sh')
        ..writeln(r'echo "$1 $2" >> "$ROOT/reloads"')
        ..writeln('SHIM')
        ..writeln(r'chmod +x "$ROOT/bin/sshd" "$ROOT/bin/systemctl"')
        ..writeln(r'export ROOT PATH="$ROOT/bin:$PATH"')
        ..writeln(prepare);
      for (var i = 0; i < scripts.length; i++) {
        final body = scripts[i].replaceAll('/etc/ssh', r'$ROOT/etc/ssh');
        harness
          ..writeln("cat > \$ROOT/setup$i.sh <<'SETUP'")
          ..write(body)
          ..writeln('SETUP')
          ..writeln('echo "== run $i"')
          ..writeln('ROOT="\$ROOT" sh -c "\$(sed "s|\\\$ROOT|\$ROOT|g" "\$ROOT/setup$i.sh")"');
      }
      harness
        ..writeln('echo "== show"')
        ..writeln(show)
        ..writeln(r'rm -rf "$ROOT"');
      final p = await Process.start('wsl', ['-d', 'Ubuntu', '-e', 'bash', '-s']);
      p.stdin.write(harness.toString().replaceAll('\r\n', '\n'));
      await p.stdin.close();
      final out = await p.stdout.transform(utf8.decoder).join();
      final err = await p.stderr.transform(utf8.decoder).join();
      final code = await p.exitCode;
      expect(code, 0, reason: 'stdout:\n$out\nstderr:\n$err');
      return out.replaceAll('\r\n', '\n');
    }

    String after(String out) => out.substring(out.indexOf('== show\n') + '== show\n'.length);

    test('a fresh host gets the drop-in and the key, once however often it runs', () async {
      if (!wsl) return markTestSkipped('WSL is not available');
      final script = certHostSetupScript(keyLine: key1);
      final out = await onHost([script, script],
          show: r'cat "$ROOT/etc/ssh/sshd_config.d/10-zestssh.conf"; echo --; cat "$ROOT/etc/ssh/zestssh_user_ca.pub"; '
              r'echo --; cat "$ROOT/reloads"');
      final lines = after(out).trimRight().split('\n');
      expect(lines.first, matches(RegExp(r'^TrustedUserCAKeys /tmp/\S+/etc/ssh/zestssh_user_ca\.pub$')));
      expect(lines.skip(1), ['--', key1, '--', 'reload ssh', 'reload ssh']);
      expect(out, isNot(contains('does not read')));
    });

    test('a host that trusts another authority keeps it; the key joins the same file', () async {
      if (!wsl) return markTestSkipped('WSL is not available');
      final out = await onHost(
        [certHostSetupScript(keyLine: key1)],
        // An authority already trusted, its file without a final newline.
        prepare: 'printf %s "$other" > "\$ROOT/etc/ssh/company_ca.pub"; '
            'echo "\$ROOT/etc/ssh/company_ca.pub" > "\$ROOT/preset"',
        show: r'cat "$ROOT/etc/ssh/company_ca.pub"; echo --; ls "$ROOT/etc/ssh"',
      );
      expect(after(out).trimRight().split('\n'), [other, key1, '--', 'company_ca.pub']);
    });

    test('a new key replaces the old one, and only that', () async {
      if (!wsl) return markTestSkipped('WSL is not available');
      final out = await onHost(
        [certHostSetupScript(keyLine: key1), certHostSetupScript(keyLine: key2, oldKeyLines: const [key1])],
        prepare: 'printf "%s\\n" "$other" > "\$ROOT/etc/ssh/company_ca.pub"; '
            'echo "\$ROOT/etc/ssh/company_ca.pub" > "\$ROOT/preset"',
        show: r'cat "$ROOT/etc/ssh/company_ca.pub"',
      );
      expect(after(out).trimRight().split('\n'), [other, key2]);
    });

    test('an sshd that does not read the drop-in: the host is told what to add', () async {
      if (!wsl) return markTestSkipped('WSL is not available');
      final out = await onHost([certHostSetupScript(keyLine: key1)],
          prepare: r'touch "$ROOT/notread"', show: 'true');
      // (The scratch directory stands in for /etc/ssh in what it says.)
      expect(
          out,
          matches(RegExp(r'sshd does not read \S*/etc/ssh/sshd_config\.d: add "TrustedUserCAKeys '
              r'\S*/etc/ssh/zestssh_user_ca\.pub" to \S*/etc/ssh/sshd_config')));
    });
  });
}
