import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/store_handover.dart';

/// What a wipe reaches on a computer: the folders of the profile on screen, and
/// nothing of another's. With no profile open it reaches nothing, for those same
/// folders would then be everyone's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  // This Windows account's folders of the Microsoft Store hand-over, in the
  // test's: the real ones are never looked at here.
  late StoreHandover handover;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_wipe_targets_');
    handover = StoreHandover(localAppData: p.join(root.path, 'Local'), appData: p.join(root.path, 'Roaming'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => p.join(root.path, 'docs'),
        'getApplicationSupportDirectory' => p.join(root.path, 'support'),
        _ => null,
      };
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    Profiles.debugReset();
    await root.delete(recursive: true);
  });

  test('with no profile open it reaches nothing', () async {
    Profiles.turnOn();
    final targets = await WipeTargets.onThisDevice(handover: handover);
    expect(targets.ownedDirectories, isEmpty);
    expect(targets.ownedFiles, isEmpty);
  });

  test('with one open it reaches that one\'s folders alone, the local backup destination\'s copies among them', () async {
    Profiles.turnOn();
    Profiles.bind(ActiveProfile(id: 'aaaa', dir: root));
    final targets = await WipeTargets.onThisDevice(handover: handover);
    final docs = p.join(root.path, 'docs');
    expect(targets.ownedDirectories.map((d) => p.normalize(d.path)), [
      p.join(docs, 'ZestSSH', 'session-logs', 'aaaa'),
      p.join(docs, 'ZestSSH', 'transcripts', 'aaaa'),
      p.join(docs, 'ZestSSH', 'backups', 'aaaa'),
    ]);
    expect(targets.ownedFiles, isNotEmpty);
    for (final set in targets.ownedFiles) {
      expect(p.basename(set.directory.path), 'aaaa', reason: 'files of a person, in the folder of the profile');
      expect(set.matches('zestssh_logs_1.txt'), isFalse, reason: 'the app\'s own logs are the device\'s');
      expect(set.matches('zestssh_backup_1.zest'), isFalse, reason: 'a backup the person exported is theirs');
    }
  });

  test('on a phone it is what it always was', () async {
    final targets = await WipeTargets.onThisDevice(handover: handover);
    final docs = p.join(root.path, 'docs');
    expect(targets.ownedDirectories.map((d) => p.normalize(d.path)), [
      p.join(docs, 'ZestSSH', 'session-logs'),
      p.join(docs, 'ZestSSH', 'transcripts'),
    ]);
    expect(targets.ownedFiles.any((set) => set.matches('zestssh_logs_1.txt')), isTrue);
  });

  // Found in a security review: a hand-over
  // still waiting, and what one set aside, are full copies of the data.
  test('on Windows, a hand-over still waiting and what one set aside go too', () async {
    Profiles.turnOn();
    Profiles.bind(ActiveProfile(id: 'aaaa', dir: root));
    final local = p.join(root.path, 'Local');
    final roaming = p.join(root.path, 'Roaming', 'Affluent Labs');
    for (final d in [
      p.join(local, 'ZestSSH Handover'),
      p.join(local, 'ZestSSH Handover (set aside 2026-11-05 101500)'),
      p.join(local, 'com.affluentlabs.zestssh (set aside 2026-11-05 101501)'),
      p.join(roaming, 'ZestSSH (set aside 2026-11-05 101501)'),
      // Not the hand-over's: the live data, and a folder of the person's.
      p.join(local, 'com.affluentlabs.zestssh'),
      p.join(local, 'Notes (set aside 2026-11-05 101500)'),
    ]) {
      Directory(d).createSync(recursive: true);
    }
    final targets = await WipeTargets.onThisDevice(handover: handover);
    final paths = targets.ownedDirectories.map((d) => p.normalize(d.path)).toList();
    expect(paths, containsAll([
      p.join(local, 'ZestSSH Handover'),
      p.join(local, 'ZestSSH Handover (set aside 2026-11-05 101500)'),
      p.join(local, 'com.affluentlabs.zestssh (set aside 2026-11-05 101501)'),
      p.join(roaming, 'ZestSSH (set aside 2026-11-05 101501)'),
    ]));
    expect(paths, isNot(contains(p.join(local, 'com.affluentlabs.zestssh'))));
    expect(paths, isNot(contains(p.join(local, 'Notes (set aside 2026-11-05 101500)'))));
  });
}
