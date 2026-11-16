import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// A shell to run the install with, where this machine has one.
String? _shell() {
  for (final candidate in ['sh', r'C:\Program Files\Git\usr\bin\sh.exe', '/bin/sh']) {
    try {
      final r = Process.runSync(candidate, ['-c', 'echo ok']);
      if (r.exitCode == 0 && '${r.stdout}'.trim() == 'ok') return candidate;
    } catch (_) {}
  }
  return null;
}

Identity _key({String? public, String method = 'publicKey'}) => Identity(
      id: 'k1',
      label: 'Deploy key',
      username: 'deploy',
      authMethod: method,
      publicKeyData: public,
      colorIndex: 0,
      isDefault: false,
      allowUnattended: false,
      usesAgent: false,
      passwordAfterKey: false,
      createdAt: DateTime(2026, 10, 15),
    );

Connection _host(String id) => Connection(
      id: id,
      label: id,
      host: '$id.example.com',
      port: 22,
      colorIndex: 0,
      protocol: 'ssh',
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: DateTime(2026, 10, 15),
      updatedAt: DateTime(2026, 10, 15),
    );

/// Install a key on hosts (3.0): what is run on a host adds the key as
/// `ssh-copy-id` adds it, run here with a real shell in a home made for the
/// test: the folder and the file made where they are not, the key added
/// after a line end where the file has none, a key there already (whatever
/// its comment or options) left as it is, and nothing done with no key to
/// read. And how each host's end is told and said.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final shell = _shell();
  const line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTheTestOnly alex@laptop';

  /// Runs the install in [home], given [input]: what it printed, and how it
  /// ended.
  Future<({String out, int code})> install(Directory home, String input) async {
    final p = await Process.start(shell!, ['-c', kInstallKeyCommand], environment: {'HOME': home.path});
    p.stdin.add(utf8.encode(input));
    await p.stdin.close();
    final out = await p.stdout.transform(utf8.decoder).join();
    await p.stderr.drain<void>();
    return (out: out, code: await p.exitCode);
  }

  String keysIn(Directory home) => File('${home.path}/.ssh/authorized_keys').readAsStringSync();

  group('what is run on a host', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('zestssh-install-key-'));
    tearDown(() => home.deleteSync(recursive: true));

    test('in a home with no .ssh: both made, the key added; again: there already, nothing changed', () async {
      final first = await install(home, '$line\n');
      expect((first.code, first.out.trim()), (0, kKeyAdded));
      expect(keysIn(home), '$line\n');
      final again = await install(home, '$line\n');
      expect((again.code, again.out.trim()), (0, kKeyThere));
      expect(keysIn(home), '$line\n');
    }, skip: shell == null ? 'no shell on this machine' : false);

    test('a file that does not end in a line end gets one before the key; one that holds it with options and '
        'another comment is left as it is', () async {
      Directory('${home.path}/.ssh').createSync();
      File('${home.path}/.ssh/authorized_keys').writeAsStringSync('ssh-rsa AAAAB3NzaOther other@host');
      expect((await install(home, line)).out.trim(), kKeyAdded, reason: 'no line end after the key read');
      expect(keysIn(home), 'ssh-rsa AAAAB3NzaOther other@host\n$line\n');

      final options = 'no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTheTestOnly morgan@desktop\n';
      File('${home.path}/.ssh/authorized_keys').writeAsStringSync(options);
      expect((await install(home, '$line\n')).out.trim(), kKeyThere);
      expect(keysIn(home), options);
    }, skip: shell == null ? 'no shell on this machine' : false);

    test('nothing to read, or no key in it: nothing is done', () async {
      final none = await install(home, '');
      expect(none.code, 3);
      expect(none.out, isEmpty);
      final word = await install(home, 'just-one-word\n');
      expect(word.code, 4);
      expect(Directory('${home.path}/.ssh').existsSync(), isFalse);
    }, skip: shell == null ? 'no shell on this machine' : false);
  });

  test('the line a key is installed as: its public key, one line, with a key in it; none for a key without one',
      () {
    expect(installLineOf(_key(public: '  $line\n')), line);
    expect(installLineOf(_key(public: null)), isNull);
    expect(installLineOf(_key(public: '')), isNull);
    expect(installLineOf(_key(public: 'ssh-ed25519')), isNull);
    expect(installLineOf(_key(public: 'ssh-ed25519 AAAA\nssh-rsa BBBB')), isNull);
    // An RSA key kept named by the signature it makes (rsa-sha2-256), as lines made before 3.0 named it.
    expect(installLineOf(_key(public: 'rsa-sha2-256 AAAAB3NzaC1yc2E deploy')), 'ssh-rsa AAAAB3NzaC1yc2E deploy');
  });

  test('how a host\'s part ended, and how it is said', () {
    HostRun done(String out, {int code = 0, String? signal}) =>
        HostRun(host: _host('web'), state: HostRunState.done, exitCode: code, signal: signal, output: out, user: 'deploy');
    expect(keyInstallEndOf(done('$kKeyAdded\n')), KeyInstallEnd.added);
    expect(keyInstallEndOf(done('$kKeyThere\n')), KeyInstallEnd.there);
    expect(keyInstallEndOf(done('$kKeyAdded\n', code: 7)), KeyInstallEnd.notAdded);
    expect(keyInstallEndOf(done('$kKeyAdded\n', signal: 'KILL')), KeyInstallEnd.notAdded);
    expect(keyInstallEndOf(done('')), KeyInstallEnd.notAdded);
    expect(keyInstallEndOf(HostRun(host: _host('web'), state: HostRunState.failed)), isNull);
    expect([keyInstalledOn(done(kKeyAdded)), keyInstalledOn(done(kKeyThere)), keyInstalledOn(done(''))],
        [true, true, false]);

    expect(keyInstallWords(done(kKeyAdded), en), en.installKeyAdded('deploy'));
    expect(keyInstallWords(done(kKeyThere), en), en.installKeyThere('deploy'));
    expect(keyInstallWords(done('', code: 1), en), en.installKeyNotAdded);
    expect(keyInstallWords(HostRun(host: _host('web'), state: HostRunState.running), en), en.installKeyInstalling);
    expect(keyInstallWords(HostRun(host: _host('web'), state: HostRunState.signingIn), en), en.runOnHostsSigningIn);
    expect(keyInstallWords(HostRun(host: _host('web'), state: HostRunState.failed), en), en.runOnHostsFailed);
  });
}
