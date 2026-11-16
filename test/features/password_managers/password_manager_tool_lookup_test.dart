import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';

/// A password manager's tool is looked for where its own installs put it
/// (the 1Password app was installed and the
/// picker said op was not there): on Windows the 1Password CLI's winget
/// package folder and its guide's Program Files folder, Bitwarden's winget
/// package, Scoop's own folder; on macOS and Linux Bitwarden from npm (its
/// prefix, ~/.npm-global, Volta, nvm), ~/.local/bin, Nix and Linuxbrew. The
/// rules stay: an absolute path, an .exe on Windows, nothing from a relative
/// folder, and a folder name that could step out is never one.
void main() {
  String? find(
    PasswordManagerKind kind,
    Set<String> files,
    Map<String, String> env, {
    bool windows = false,
    bool mac = false,
    Map<String, List<String>> dirs = const {},
    String? configured,
  }) =>
      findPasswordManagerCli(kind,
          configured: configured,
          environment: env,
          exists: files.contains,
          listDir: (d) => dirs[d] ?? const [],
          isWindows: windows,
          isMacOS: mac);

  const local = r'C:\Users\a\AppData\Local';
  const winEnv = {
    'LOCALAPPDATA': local,
    'USERPROFILE': r'C:\Users\a',
    'ProgramFiles': r'C:\Program Files',
    'Path': r'C:\Windows',
  };
  const packages = '$local\\Microsoft\\WinGet\\Packages';

  group('Windows', () {
    test("1Password's winget package folder, found by its name, links off", () {
      const op = '$packages\\AgileBits.1Password.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\\op.exe';
      expect(
          find(PasswordManagerKind.onePassword, {op}, winEnv, windows: true, dirs: {
            packages: ['Git.Git_Microsoft.Winget.Source_8wekyb3d8bbwe', 'AgileBits.1Password.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe'],
          }),
          op);
      // Without the listing, it is not guessed.
      expect(find(PasswordManagerKind.onePassword, {op}, winEnv, windows: true), isNull);
    });

    test("1Password's guide's folder in Program Files", () {
      expect(find(PasswordManagerKind.onePassword, {r'C:\Program Files\1Password CLI\op.exe'}, winEnv, windows: true),
          r'C:\Program Files\1Password CLI\op.exe');
    });

    test("Bitwarden's winget package; Scoop's own folders; Chocolatey's shims", () {
      const bw = '$packages\\Bitwarden.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\\bw.exe';
      expect(
          find(PasswordManagerKind.bitwarden, {bw}, winEnv, windows: true, dirs: {
            packages: ['Bitwarden.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe'],
          }),
          bw);
      expect(find(PasswordManagerKind.bitwarden, {r'D:\scoop\shims\bw.exe'}, {...winEnv, 'SCOOP': r'D:\scoop'}, windows: true),
          r'D:\scoop\shims\bw.exe');
      expect(
          find(PasswordManagerKind.keePassXc, {r'C:\Users\a\scoop\apps\keepassxc\current\keepassxc-cli.exe'}, winEnv,
              windows: true),
          r'C:\Users\a\scoop\apps\keepassxc\current\keepassxc-cli.exe');
      expect(
          find(PasswordManagerKind.onePassword, {r'C:\ProgramData\chocolatey\bin\op.exe'},
              {...winEnv, 'ProgramData': r'C:\ProgramData'}, windows: true),
          r'C:\ProgramData\chocolatey\bin\op.exe');
    });

    test('a folder name that could step out of Packages is never one, and .exe only', () {
      expect(
          find(PasswordManagerKind.onePassword, {'$packages\\AgileBits.1Password.CLI_..\\..\\op.exe'}, winEnv,
              windows: true,
              dirs: {
                packages: [r'AgileBits.1Password.CLI_..\..'],
              }),
          isNull);
      const cmd = '$packages\\Bitwarden.CLI_x\\bw.cmd';
      expect(
          find(PasswordManagerKind.bitwarden, {cmd}, winEnv, windows: true, dirs: {
            packages: ['Bitwarden.CLI_x'],
          }),
          isNull);
    });
  });

  group('macOS and Linux', () {
    test("Bitwarden from npm: its prefix, ~/.npm-global, Volta, nvm's newest Node", () {
      expect(find(PasswordManagerKind.bitwarden, {'/opt/npm/bin/bw'}, const {'NPM_CONFIG_PREFIX': '/opt/npm'}, mac: true),
          '/opt/npm/bin/bw');
      expect(find(PasswordManagerKind.bitwarden, {'/Users/a/.npm-global/bin/bw'}, const {'HOME': '/Users/a'}, mac: true),
          '/Users/a/.npm-global/bin/bw');
      expect(find(PasswordManagerKind.bitwarden, {'/home/a/.volta/bin/bw'}, const {'HOME': '/home/a'}), '/home/a/.volta/bin/bw');
      expect(
          find(PasswordManagerKind.bitwarden, {'/home/a/.nvm/versions/node/v20.11.0/bin/bw', '/home/a/.nvm/versions/node/v22.3.0/bin/bw'},
              const {'HOME': '/home/a'},
              dirs: {
                '/home/a/.nvm/versions/node': ['v20.11.0', 'v22.3.0', '../evil'],
              }),
          '/home/a/.nvm/versions/node/v22.3.0/bin/bw');
      // npm's places are Bitwarden's only.
      expect(find(PasswordManagerKind.onePassword, {'/home/a/.volta/bin/op'}, const {'HOME': '/home/a'}), isNull);
    });

    test('~/Applications for KeePassXC, ~/.local/bin, Nix and Linuxbrew', () {
      expect(
          find(PasswordManagerKind.keePassXc, {'/Users/a/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli'},
              const {'HOME': '/Users/a'},
              mac: true),
          '/Users/a/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli');
      expect(find(PasswordManagerKind.onePassword, {'/home/a/.local/bin/op'}, const {'HOME': '/home/a'}), '/home/a/.local/bin/op');
      expect(find(PasswordManagerKind.onePassword, {'/run/current-system/sw/bin/op'}, const {}), '/run/current-system/sw/bin/op');
      expect(find(PasswordManagerKind.keePassXc, {'/home/linuxbrew/.linuxbrew/bin/keepassxc-cli'}, const {}),
          '/home/linuxbrew/.linuxbrew/bin/keepassxc-cli');
    });
  });

  test('a path chosen runs by the same rules as one found', () {
    bool runs(String p, {bool windows = false}) =>
        passwordManagerToolRunnable(p, exists: (_) => true, isWindows: windows);
    expect(runs(r'D:\tools\op.exe', windows: true), isTrue);
    expect(runs(r'D:\tools\op.cmd', windows: true), isFalse);
    expect(runs(r'op.exe', windows: true), isFalse);
    expect(runs('/usr/local/bin/op'), isTrue);
    expect(runs('bin/op'), isFalse);
    expect(passwordManagerToolRunnable('/usr/local/bin/op', exists: (_) => false, isWindows: false), isFalse);
  });
}
