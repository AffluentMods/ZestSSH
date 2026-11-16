import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/repository_text.dart';

/// What a person who clones the repository reads and runs first: no folder of a real person's
/// machine, no machine name, no pointer to documents they cannot have; build settings, Flutter
/// version and Linux packages as the code and the build need them; a README that says what the
/// code is.
void main() {
  final texts = repositoryText(Directory('.')).toList();

  test('every user folder written in the repository belongs to a made-up user', () {
    // A user name in an example path (C:\Users\<name>, /Users/<name>, /home/<name>) is one of these
    // made-up ones or a word that is not a name; never a real person's. A name is added here on
    // purpose, for an example; never by pasting a path from one's own machine.
    const madeUp = {
      'a', 'alex', 'alice', 'ana', 'Ana', 'anabel', 'bob', 'ci', 'demo', 'Demo', 'deploy', 'deploy-automation', //
      'foo', 'kham', 'li', 'linuxbrew', 'me', 'ops', 'sam', 'somchai', 'Some', 'someone', 'taro', 'user', 'victim', 'x',
      // Not user names: the app's routes and files under a "home" folder, and an elided name.
      'home_screen.dart', 'widgets', 'app_icon_shortcuts.dart', '...',
    };
    final folder = RegExp(r'(?:Users[/\\]{1,2}|/home/)([A-Za-z0-9_.-]+)');
    final found = <String>[];
    for (final file in texts) {
      for (final m in folder.allMatches(file.text)) {
        if (!madeUp.contains(m.group(1))) found.add('${file.path}: ${m.group(0)}');
      }
    }
    expect(found, isEmpty, reason: 'use a made-up user (alex, demo, deploy) in an example path');
  });

  test('no Windows machine name of the form a PC is given is written in the repository', () {
    final machine = RegExp(r'\b(?:DESKTOP-[A-Z0-9]{7}|LAPTOP-[A-Z0-9]{8})\b');
    final found = [
      for (final file in texts)
        for (final m in machine.allMatches(file.text)) '${file.path}: ${m.group(0)}',
    ];
    expect(found, isEmpty, reason: 'use a made-up name such as web-laptop-01');
  });

  test("nothing in the code points a builder at the project's private documents", () {
    // Built from its parts, so that this file does not name it either.
    final private = ['Internal', 'Docs'].join('-');
    final found = [
      for (final file in texts)
        // The frozen changelog of 3.x keeps its history as it was.
        if (file.path != 'docs/CHANGELOG-3.0.md' && file.text.contains(private)) file.path,
    ];
    expect(found, isEmpty);
    expect(
      File('packages/zest_native/hook/build.dart').readAsStringSync(),
      contains('BUILDING.md'),
      reason: "the hook's cargo error points at the public build guide",
    );
  });

  test('.env.example names every build setting the app reads, each a comment with a placeholder', () {
    final read = <String>{};
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r"fromEnvironment\(\s*'([A-Z][A-Z0-9_]*)'").allMatches(file.readAsStringSync())) {
        read.add(m.group(1)!);
      }
    }
    expect(read, contains('SYNC_API_BASE_URL'));
    final example = File('.env.example').readAsStringSync();
    final named = {
      for (final m in RegExp(r'^# ([A-Z][A-Z0-9_]*)=(.*)$', multiLine: true).allMatches(example)) m.group(1)!,
    };
    expect(named, containsAll(read), reason: 'every name the app reads');
    expect(named.difference(read), isEmpty, reason: 'and no name nothing reads');
    expect(
      RegExp(r'^[A-Z][A-Z0-9_]*=', multiLine: true).hasMatch(example),
      isFalse,
      reason: 'copied as it is, the file sets nothing (an empty value is not the default)',
    );
    for (final m in RegExp(r'^# [A-Z][A-Z0-9_]*=(.*)$', multiLine: true).allMatches(example)) {
      final value = m.group(1)!;
      expect(
        value == 'true' || value == 'false' || value.contains('example.org') || value.contains('placeholder'),
        isTrue,
        reason: 'a placeholder, never a real value: "$value"',
      );
    }
    expect(
      Process.runSync('git', ['check-ignore', '-q', '.env.example']).exitCode,
      1,
      reason: '.gitignore ignores .env and .env.*, but not the example',
    );
    expect(Process.runSync('git', ['check-ignore', '-q', '.env']).exitCode, 0);
  });

  test('the Flutter version a build needs is pinned where builders and FVM look', () {
    final fvm = jsonDecode(File('.fvmrc').readAsStringSync()) as Map<String, Object?>;
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final floor = RegExp(r'^\s+flutter: ">=([\d.]+)"', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(fvm['flutter'], floor, reason: '.fvmrc and pubspec.yaml name the same Flutter');
    expect(File('BUILDING.md').readAsStringSync(), contains('| Flutter (stable) | ${fvm['flutter']} |'));
    expect(File('README.md').readAsStringSync(), contains('Flutter ${fvm['flutter']} (`.fvmrc`)'));
  });

  test('scripts/build_linux.sh asks for every package the release build root installs', () {
    final script = File('scripts/build_linux.sh').readAsStringSync();
    final root = File('tool/linux/focal_root.sh').readAsStringSync();
    final dev = RegExp(r'\blib[\w.+-]+-dev\b').allMatches(root).map((m) => m.group(0)!).toSet()
      ..removeWhere((p) => p.startsWith('libstdc++')); // its version differs by release
    expect(dev, containsAll(['libgtk-3-dev', 'libsecret-1-dev', 'libjsoncpp-dev', 'libayatana-appindicator3-dev']));
    for (final package in [...dev, 'lld', 'libssl-dev', 'clang', 'cmake', 'ninja-build', 'pkg-config']) {
      expect(script, contains(package), reason: package);
      expect(File('BUILDING.md').readAsStringSync(), contains(package), reason: 'BUILDING.md: $package');
    }
  });

  test('OpenSSL 1.1.1 and older are refused at the CMake step on Windows and Linux', () {
    for (final path in ['windows/CMakeLists.txt', 'linux/CMakeLists.txt']) {
      final cmake = File(path).readAsStringSync();
      expect(cmake, contains('OPENSSL_VERSION VERSION_LESS "3.0"'), reason: path);
      expect(cmake, contains('FATAL_ERROR'), reason: path);
    }
  });

  test('the README says what the code is, and no longer calls any of it proprietary', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme.toLowerCase(), isNot(contains('proprietary')));
    expect(readme, isNot(contains('to be announced')));
    expect(readme, contains('GNU General Public License version 3 only ([LICENSE](LICENSE))'));
    expect(readme, contains('[LICENSE-EXCEPTION.txt](LICENSE-EXCEPTION.txt)'));
    expect(readme, contains('`GPL-3.0-only`'));
    expect(readme, contains('© 2026 Affluent Labs LLC. All rights reserved.'));
    expect(readme, contains('BUILDING.md'));
    for (final path in ['architecture.md', 'packages/zest_native/rust/Cargo.toml', 'tool/linux/build_linux_repo.sh']) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains(RegExp('LicenseRef-Proprietary|License: Proprietary|proprietary (fork|SSH)'))),
        reason: path,
      );
    }
  });
}
