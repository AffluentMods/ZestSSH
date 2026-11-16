import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/leftover_copies.dart';

/// What the app left in this device's temporary folder where it was ended in
/// the middle of something is cleared away when it starts (3.0). A Mosh or an
/// Eternal Terminal session signs in with its key written to a folder
/// zestssh_mosh_... there, a file copied from a host to another folder of it
/// or to another host goes by way of a folder zest_sftp_xfer_... or
/// zest_sftp_bridge_..., and versions before 3.0 read and saved a host's
/// files for the editor by way of folders zest_read_... and zest_write_...:
/// each held a key or a copy of a file, in the clear. They are removed when
/// they are done with, and stayed for good where the app was ended before
/// that. Nothing makes the last two any more; the others are removed only
/// once nothing in them has changed for an hour, since the app may be running
/// a second time and using them.
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zest-app-leftover-copies-test');
    addTearDown(() => temp.delete(recursive: true));
  });

  /// Runs the clearing with [temp] in the place of this device's temporary
  /// folder, at [now] (by default, now).
  Future<int> cleared({DateTime? now}) =>
      IOOverrides.runZoned(() => clearLeftoverCopies(now: now), getSystemTempDirectory: () => temp);

  /// Two hours from now: what is made now has not changed for an hour then.
  DateTime later() => DateTime.now().add(const Duration(hours: 2));

  /// Makes the folder [name] in the temporary folder, holding [files].
  void folder(String name, [List<String> files = const []]) {
    Directory('${temp.path}/$name').createSync();
    for (final file in files) {
      File('${temp.path}/$name/$file').writeAsStringSync('the words of a file on a host');
    }
  }

  List<String> left() => [for (final entry in temp.listSync()) entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty)]..sort();

  test('the folders an earlier version read and saved by way of are removed, with the copies in them', () async {
    // A file that was opened, one that was being read when the app was ended, a save, and one that had not begun.
    folder('zest_read_af1bf3b7', ['data.bin']);
    folder('zest_read_0c22d1e4', ['data.bin.zestpart', 'data.bin.zestpart.meta']);
    folder('zest_write_89573910', ['data.bin']);
    folder('zest_write_7c2ae138');

    expect(await cleared(), 4, reason: 'nothing makes them any more: however new, they are removed');
    expect(left(), isEmpty);
    expect(await cleared(), 0, reason: 'and nothing is left to remove');
  });

  test('what a crash left of a Mosh key and of copies between hosts is removed once nothing in it has changed for '
      'an hour', () async {
    folder('zestssh_mosh_4kq0vz', ['id_key']);
    // A copy to another folder of the same host, fetched; one in the middle of being fetched; one between hosts;
    // and one whose fetching had not begun.
    folder('zest_sftp_xfer_d41d8c', ['xfer.bin']);
    folder('zest_sftp_xfer_9e107d', ['xfer.bin.zestpart', 'xfer.bin.zestpart.meta']);
    folder('zest_sftp_bridge_e4d909', ['bridge.bin']);
    folder('zest_sftp_bridge_a87ff6');

    expect(await cleared(now: later()), 5);
    expect(left(), isEmpty);
    expect(await cleared(now: later()), 0, reason: 'and nothing is left to remove');
  });

  test('one the app may still be using is left: what was made, or changed, within the hour', () async {
    // Just made: the key of a session signing in, a copy being made, and a folder with nothing in it yet.
    folder('zestssh_mosh_4kq0vz', ['id_key']);
    folder('zest_sftp_xfer_d41d8c', ['xfer.bin.zestpart', 'xfer.bin.zestpart.meta']);
    folder('zest_sftp_bridge_a87ff6');

    expect(await cleared(), 0);
    expect(left(), ['zest_sftp_bridge_a87ff6', 'zest_sftp_xfer_d41d8c', 'zestssh_mosh_4kq0vz']);

    // Two hours on, one of them still being written to (half an hour ago): that one stays, the others go.
    final at = later();
    File('${temp.path}/zest_sftp_xfer_d41d8c/xfer.bin.zestpart').setLastModifiedSync(at.subtract(const Duration(minutes: 30)));

    expect(await cleared(now: at), 2);
    expect(left(), ['zest_sftp_xfer_d41d8c']);
  });

  test('nothing else is touched: not what bears another name, nor what bears the name and is not what the app '
      'made', () async {
    folder('zest_read_af1bf3b7', ['data.bin']);
    folder('zestssh_mosh_4kq0vz', ['id_key']);
    folder('another_program', ['data.bin', 'id_key', 'xfer.bin']);
    // The names, on files.
    File('${temp.path}/zest_read_notes.txt').writeAsStringSync('kept');
    File('${temp.path}/zestssh_mosh_notes.txt').writeAsStringSync('kept');
    // The names, on folders that hold something else: a file of another name, a folder (called as the copy
    // was), the file of another of the app's folders.
    folder('zest_read_holiday', ['data.bin', 'photo.jpg']);
    folder('zest_write_work');
    Directory('${temp.path}/zest_write_work/data.bin').createSync();
    File('${temp.path}/zest_write_work/data.bin/draft.txt').writeAsStringSync('kept');
    folder('zestssh_mosh_keys', ['id_key', 'id_ed25519']);
    folder('zestssh_mosh_part', ['id_key.zestpart']);
    folder('zest_sftp_xfer_music', ['xfer.bin', 'song.mp3']);
    folder('zest_sftp_bridge_mixed', ['xfer.bin']);
    folder('zest_sftp_bridge_deep');
    Directory('${temp.path}/zest_sftp_bridge_deep/bridge.bin').createSync();

    expect(await cleared(now: later()), 2);
    expect(left(), [
      'another_program',
      'zest_read_holiday',
      'zest_read_notes.txt',
      'zest_sftp_bridge_deep',
      'zest_sftp_bridge_mixed',
      'zest_sftp_xfer_music',
      'zest_write_work',
      'zestssh_mosh_keys',
      'zestssh_mosh_notes.txt',
      'zestssh_mosh_part',
    ]);
    expect(File('${temp.path}/zest_read_holiday/photo.jpg').existsSync(), isTrue);
    expect(File('${temp.path}/zest_read_holiday/data.bin').existsSync(), isTrue);
    expect(File('${temp.path}/zest_write_work/data.bin/draft.txt').existsSync(), isTrue);
    expect(File('${temp.path}/zestssh_mosh_keys/id_ed25519').existsSync(), isTrue);
    expect(File('${temp.path}/another_program/id_key').existsSync(), isTrue);
  });

  test('one that cannot be removed is left where it is, and the others are removed all the same', () async {
    folder('zest_read_0c22d1e4', ['data.bin']);
    folder('zest_read_af1bf3b7', ['data.bin']);
    folder('zest_write_89573910', ['data.bin']);
    // Held open, a file cannot be removed on Windows; elsewhere it can, and nothing is left.
    final held = File('${temp.path}/zest_read_af1bf3b7/data.bin').openSync();
    addTearDown(held.closeSync);

    final removed = await cleared();

    if (Platform.isWindows) {
      expect(removed, 2);
      expect(left(), ['zest_read_af1bf3b7']);
    } else {
      expect(removed, 3);
      expect(left(), isEmpty);
    }
  });

  test('a temporary folder that is not there is no failure', () async {
    final gone = Directory('${temp.path}/not-there');
    expect(await IOOverrides.runZoned(clearLeftoverCopies, getSystemTempDirectory: () => gone), 0);
  });

  test('the app clears them away when it starts, and before it writes a key for Mosh or Eternal Terminal', () {
    final start = File('lib/main.dart').readAsStringSync();
    expect(start, contains('unawaited(clearLeftoverCopies());'));

    final sessions = File('lib/providers/terminal_providers.dart').readAsStringSync();
    final writer = sessions.substring(sessions.indexOf('Future<String?> _resolveIdentityKeyPath('));
    final cleared = writer.indexOf('await clearLeftoverCopies();');
    expect(cleared, greaterThan(0));
    expect(cleared, lessThan(writer.indexOf("Directory.systemTemp.createTemp('zestssh_mosh_')")));
  });
}
