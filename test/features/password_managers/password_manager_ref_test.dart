import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';

/// Password manager references and their command lines (3.0): a
/// reference is data other people can edit, so nothing in it may reach a
/// command line as an option; tools are found by absolute path only, never
/// in the current folder, and on Windows only `.exe` files run.
void main() {
  group('references', () {
    test('1Password: op://vault/item/[section/]field only', () {
      expect(PasswordRef.onePassword('op://Engineering/db-prod/password')?.target, 'op://Engineering/db-prod/password');
      expect(PasswordRef.onePassword('op://Eng/db prod/Login details/password'), isNotNull);
      expect(PasswordRef.onePassword('  op://a/b/c  ')?.target, 'op://a/b/c');
      for (final bad in [
        'op://a/b',
        'op://a/b/c/d/e',
        'op://a/b/c?attribute=otp',
        'op://a//c',
        '--out-file=/tmp/x',
        'op://a/b/c\nop://x/y/z',
        'https://a/b/c',
        'op://a/b/${'c' * kPasswordRefMaxLength}',
        'op://-rf/b/c',
        'op://a/--x/c',
        'op://a/b/ /c',
        '',
      ]) {
        expect(PasswordRef.onePassword(bad), isNull, reason: bad);
      }
    });

    test('Bitwarden: an item id, a UUID', () {
      expect(PasswordRef.bitwarden('5F2C0E3A-1B2C-4D3E-8F9A-0B1C2D3E4F5A')?.target, '5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a');
      for (final bad in ['bank', '--session', '5f2c0e3a-1b2c-4d3e-8f9a', '5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a extra']) {
        expect(PasswordRef.bitwarden(bad), isNull, reason: bad);
      }
    });

    test('KeePassXC: an entry path and an attribute, neither read as an option', () {
      final ref = PasswordRef.keePassXc('Servers/web1')!;
      expect((ref.target, ref.attribute, ref.field), ('Servers/web1', 'Password', null));
      expect(PasswordRef.keePassXc('Servers/web1', attribute: 'root password')?.attribute, 'root password');
      for (final bad in ['-a', '--key-file=/x', 'a\u0000b', '']) {
        expect(PasswordRef.keePassXc(bad), isNull, reason: bad);
      }
      expect(PasswordRef.keePassXc('Servers/web1', attribute: '--no-password'), isNull);
    });

    test('stored and read back; anything else stored reads as nothing', () {
      for (final ref in [
        PasswordRef.onePassword('op://Eng/db/password')!,
        PasswordRef.bitwarden('5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a')!,
        PasswordRef.keePassXc('Servers/web1')!,
        PasswordRef.keePassXc('Servers/web1', attribute: 'root')!,
      ]) {
        expect(PasswordRef.decode(ref.encode()), ref);
      }
      for (final bad in [
        null,
        '',
        'op://Eng/db/password',
        '{"v":2,"m":"op","t":"op://a/b/c"}',
        '{"v":1,"m":"op","t":"--version"}',
        '{"v":1,"m":"bw","t":"bank"}',
        '{"v":1,"m":"op","t":"op://a/b/c","f":"x"}',
        '{"v":1,"m":"kpx","t":"-x"}',
        '{"v":1,"m":"zz","t":"a"}',
        '[1]',
      ]) {
        expect(PasswordRef.decode(bad), isNull, reason: '$bad');
      }
    });
  });

  group('finding a tool', () {
    String? find(PasswordManagerKind kind, Set<String> files, Map<String, String> env,
            {bool windows = false, bool mac = false, String? configured}) =>
        findPasswordManagerCli(kind,
            configured: configured, environment: env, exists: files.contains, isWindows: windows, isMacOS: mac);

    test('Windows: the usual places, then PATH, absolute folders only, .exe only', () {
      final env = {
        'LOCALAPPDATA': r'C:\Users\a\AppData\Local',
        'USERPROFILE': r'C:\Users\a',
        'ProgramFiles': r'C:\Program Files',
        'Path': r'.;tools;C:\bin;C:\npm',
      };
      expect(find(PasswordManagerKind.onePassword, {r'C:\Users\a\AppData\Local\Microsoft\WinGet\Links\op.exe'}, env, windows: true),
          r'C:\Users\a\AppData\Local\Microsoft\WinGet\Links\op.exe');
      expect(find(PasswordManagerKind.keePassXc, {r'C:\Program Files\KeePassXC\keepassxc-cli.exe'}, env, windows: true),
          r'C:\Program Files\KeePassXC\keepassxc-cli.exe');
      expect(find(PasswordManagerKind.bitwarden, {r'C:\bin\bw.exe'}, env, windows: true), r'C:\bin\bw.exe');
      // Never the current folder or a relative one, never a .cmd.
      expect(find(PasswordManagerKind.bitwarden, {r'.\bw.exe', r'tools\bw.exe', r'C:\npm\bw.cmd'}, env, windows: true), isNull);
      expect(find(PasswordManagerKind.bitwarden, {r'C:\npm\bw.cmd'}, env, windows: true, configured: r'C:\npm\bw.cmd'), isNull);
      expect(find(PasswordManagerKind.bitwarden, {r'D:\apps\bw.exe'}, env, windows: true, configured: r'D:\apps\bw.exe'),
          r'D:\apps\bw.exe');
      expect(find(PasswordManagerKind.bitwarden, {r'bw.exe'}, env, windows: true, configured: 'bw.exe'), isNull,
          reason: 'a configured path must be absolute');
    });

    test('macOS: the app bundle and Homebrew (a GUI app does not get the shell PATH)', () {
      expect(find(PasswordManagerKind.keePassXc, {'/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli'}, const {}, mac: true),
          '/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli');
      expect(find(PasswordManagerKind.onePassword, {'/opt/homebrew/bin/op'}, const {}, mac: true), '/opt/homebrew/bin/op');
    });

    test('Linux: the usual places, then PATH', () {
      expect(find(PasswordManagerKind.bitwarden, {'/snap/bin/bw'}, const {}), '/snap/bin/bw');
      expect(find(PasswordManagerKind.onePassword, {'/home/a/bin/op'}, const {'PATH': 'bin:/home/a/bin'}), '/home/a/bin/op');
      expect(find(PasswordManagerKind.onePassword, {'bin/op'}, const {'PATH': 'bin'}), isNull);
    });
  });

  test('command lines: names after --, a Bitwarden id as it is', () {
    expect(fetchArgs(PasswordRef.onePassword('op://Eng/db/password')!),
        ['read', '--no-newline', '--', 'op://Eng/db/password']);
    expect(fetchArgs(PasswordRef.bitwarden('5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a')!),
        ['get', 'password', '5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a']);
    expect(
        fetchArgs(PasswordRef.keePassXc('Servers/web1', attribute: 'root')!,
            database: const KeePassXcDatabase(path: '/home/a/p.kdbx', keyFile: '/home/a/p.key')),
        ['show', '--quiet', '--show-protected', '--attributes', 'root', '--key-file', '/home/a/p.key', '--', '/home/a/p.kdbx', 'Servers/web1']);
  });

  test('the answer is the password, one line end taken off; spaces stay', () {
    expect(passwordFromOutput('p a s s \n'), 'p a s s ');
    expect(passwordFromOutput('pass\r\n'), 'pass');
    expect(passwordFromOutput('pass'), 'pass');
    expect(passwordFromOutput('pass\n\n'), 'pass\n');
  });

  test('what an error means', () {
    expect(classifyFailure(PasswordManagerKind.onePassword, '[ERROR] authorization prompt dismissed, please try again'),
        PmFailure.cancelled);
    expect(classifyFailure(PasswordManagerKind.onePassword, '[ERROR] account is not signed in'), PmFailure.notSignedIn);
    expect(classifyFailure(PasswordManagerKind.onePassword, "[ERROR] \"db\" isn't an item in the \"Eng\" vault"),
        PmFailure.notFound);
    expect(classifyFailure(PasswordManagerKind.bitwarden, 'Vault is locked.'), PmFailure.locked);
    expect(classifyFailure(PasswordManagerKind.bitwarden, 'You are not logged in.'), PmFailure.notSignedIn);
    expect(classifyFailure(PasswordManagerKind.bitwarden, 'Invalid master password.'), PmFailure.wrongPassword);
    expect(classifyFailure(PasswordManagerKind.bitwarden, 'Not found.'), PmFailure.notFound);
    expect(
        classifyFailure(PasswordManagerKind.keePassXc,
            'Error while reading the database: Invalid credentials were provided, please try again.'),
        PmFailure.wrongPassword);
    expect(classifyFailure(PasswordManagerKind.keePassXc, 'Could not find entry with path Servers/web2.'), PmFailure.notFound);
    expect(classifyFailure(PasswordManagerKind.keePassXc, 'something else'), PmFailure.failed);
  });
}
