import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/store_handover.dart';

/// A fix (e4509ab3) added the Microsoft Store hand-over's leftovers to
/// WipeTargets.onThisDevice, which every Delete all local data uses, the one
/// that wipes only the profile on screen too. A hand-over and what it set
/// aside are copies of the whole data folders: every profile on the
/// computer, another person's included. Person A wiping only A's profile
/// deleted person B's set-aside copy, which B was told stays 30 days (found in a
/// review). A wipe of one profile now takes that profile's
/// part of each copy, and a copy whole only where no one else's is in it;
/// Everything takes them all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late StoreHandover handover;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_wipe_handover_');
    handover = StoreHandover(localAppData: p.join(root.path, 'Local'), appData: p.join(root.path, 'Roaming'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => p.join(root.path, 'docs'),
        'getApplicationSupportDirectory' => p.join(root.path, 'support'),
        _ => null,
      };
    });
    Profiles.turnOn();
    Profiles.bind(ActiveProfile(id: 'aaaa', dir: root));
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    Profiles.debugReset();
    await root.delete(recursive: true);
  });

  /// A file of [text] at [rel] under [dir].
  void write(String dir, String rel, String text) => File(p.join(dir, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  String local(String suffix) => p.join(root.path, 'Local', 'com.affluentlabs.zestssh$suffix');
  String roaming(String suffix) => p.join(root.path, 'Roaming', 'Affluent Labs', 'ZestSSH$suffix');
  const stampB = ' (set aside 2026-11-05 101501)';
  const stampA = ' (set aside 2026-11-04 090000)';

  Set<String> targetsOf(WipeTargets t) => {for (final d in t.ownedDirectories) p.normalize(d.path)};

  test('a wipe of one profile does not reach a set-aside copy that holds another profile; it takes its own part',
      () async {
    // What the person chose not to keep at the hand-over: the whole data
    // folder, person B's profile and person A's in it, and the PC's keychain.
    write(local(stampB), p.join('profiles', 'bbbb', 'zestssh.db'), 'person B');
    write(local(stampB), p.join('profiles', 'aaaa', 'zestssh.db'), 'person A');
    write(roaming(stampB), 'flutter_secure_storage.dat', 'keychain of the PC');
    final targets = targetsOf(await WipeTargets.onThisDevice(handover: handover));
    expect(targets, isNot(contains(p.normalize(local(stampB)))),
        reason: 'a wipe of profile aaaa only deleted a copy of profile bbbb (and every other profile on this computer)');
    expect(targets, isNot(contains(p.normalize(roaming(stampB)))), reason: 'the keychain of everyone in that copy');
    expect(targets, contains(p.normalize(p.join(local(stampB), 'profiles', 'aaaa'))), reason: 'its own part goes');
  });

  test('a copy that holds only this profile goes whole, its keychain with it', () async {
    write(local(stampA), p.join('profiles', 'aaaa', 'zestssh.db'), 'person A');
    write(roaming(stampA), 'flutter_secure_storage.dat', 'keychain');
    // A hand-over waiting, of this profile alone (and the folders' own files).
    write(handover.handoverFolder.path, p.join('local', 'profiles', 'aaaa', 'zestssh.db'), 'person A');
    write(handover.handoverFolder.path, p.join('local', 'profiles', 'move.lock'), '');
    final targets = targetsOf(await WipeTargets.onThisDevice(handover: handover));
    expect(targets, containsAll([local(stampA), roaming(stampA), handover.handoverFolder.path].map(p.normalize)));
  });

  test('a hand-over waiting with someone else\'s profile in it keeps theirs; this profile\'s part goes', () async {
    write(handover.handoverFolder.path, p.join('local', 'profiles', 'aaaa', 'zestssh.db'), 'person A');
    write(handover.handoverFolder.path, p.join('local', 'profiles', 'bbbb', 'zestssh.db'), 'person B');
    final targets = targetsOf(await WipeTargets.onThisDevice(handover: handover));
    expect(targets, isNot(contains(p.normalize(handover.handoverFolder.path))));
    expect(targets, contains(p.normalize(p.join(handover.handoverFolder.path, 'local', 'profiles', 'aaaa'))));
  });

  test('Everything takes every copy, whoever is in it', () async {
    write(local(stampB), p.join('profiles', 'bbbb', 'zestssh.db'), 'person B');
    write(roaming(stampB), 'flutter_secure_storage.dat', 'keychain of the PC');
    final targets = targetsOf(await WipeTargets.onThisDevice(everything: true, handover: handover));
    expect(targets, containsAll([local(stampB), roaming(stampB)].map(p.normalize)));
  });
}
