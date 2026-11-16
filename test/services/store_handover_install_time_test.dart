import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_start.dart';

/// The stale check (StoreHandover.takeIn, websiteInstalledAt) counted the
/// website program's own time of last change as "last installed or updated".
/// Inno Setup writes each installed file with the time stamp it had when the
/// installer was built, as local time (TimeStampsInUTC is not set in
/// installer/zestssh_setup.iss, and Inno's default is no): a zestssh.exe
/// built at 15:00 in California is written as 15:00 in the installing PC's
/// own time zone. On a PC west of the build machine (Alaska, Hawaii) that is
/// hours after the real install, and a hand-over written right after a real
/// install or update (the website copy's update relaunch hands over at once)
/// was "older than the install", set aside, and never taken in (found in a
/// review). The install's time is its uninstall log's, unins000.dat,
/// which the installer writes at every install and update.
void main() {
  late Directory root;
  late StoreHandover h;
  late SharedPreferences prefs;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_handover_time_');
    h = StoreHandover(
      localAppData: p.join(root.path, 'Local'),
      appData: p.join(root.path, 'Roaming'),
      programFiles: p.join(root.path, 'Program Files'),
    );
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    takeStoreHandoverNotice();
    takeStoreHandoverSetAside();
  });
  tearDown(() => root.delete(recursive: true));

  /// The website copy installed [installedAgo] ago (its uninstall log), its
  /// program stamped [programAhead] from now; its data handed over now; the
  /// Store copy, whose own folders hide the website copy's, starts. Whether
  /// the data came in.
  Future<bool> takenIn(Duration programAhead, {Duration installedAgo = const Duration(minutes: 10)}) async {
    final now = DateTime.now();
    Directory(
      p.join(root.path, 'Local', 'Packages', StoreHandover.packageFamily, 'LocalCache', 'Local', 'com.affluentlabs.zestssh'),
    ).createSync(recursive: true);
    final folder = p.join(root.path, 'Local', 'Programs', 'ZestSSH');
    final program = File(p.join(folder, 'zestssh.exe'))..createSync(recursive: true);
    final unins = File(p.join(folder, 'unins000.exe'))..createSync(recursive: true);
    File(p.join(folder, 'unins000.dat'))
      ..writeAsStringSync('log')
      ..setLastModifiedSync(now.subtract(installedAgo));
    program.setLastModifiedSync(now.add(programAhead));

    final db = File(p.join(h.localData.path, 'zestssh.db'))
      ..createSync(recursive: true)
      ..writeAsStringSync('db of web');
    await h.handOver(now: now);
    // In this test the two copies' folders are one path: the website copy's
    // go, as the Store copy (with its own private folders) sees it.
    await db.parent.delete(recursive: true);

    final gone = await storeHandoverAtStart(
      rawPrefs: () async => prefs,
      handover: h,
      storeBuild: true,
      thisVersion: () async => '3.3.0.0',
      websiteCopyVersion: (_) async => '3.3.0+300',
      openWebsiteCopy: (_) async => fail('not opened'),
      askKeepWebsite: () async => fail('only one holds data'),
      runUninstaller: (exe, _) async {
        unins.parent.deleteSync(recursive: true);
        return 0;
      },
      now: () => now.add(const Duration(seconds: 5)),
    );
    expect(gone, isFalse);
    return File(p.join(h.localData.path, 'zestssh.db')).existsSync();
  }

  test('with the program stamped a day before, the hand-over is taken in', () async {
    expect(await takenIn(const Duration(days: -1)), isTrue);
  });

  test('a hand-over written after the website copy was installed is taken in, whatever time Inno stamped on its program',
      () async {
    expect(
      await takenIn(const Duration(hours: 2)),
      isTrue,
      reason: 'written after the install (unins000.dat), the hand-over is not out of date; it was set aside because '
          'zestssh.exe carries the build machine\'s local wall time, 2 hours ahead on this PC',
    );
  });

  test('a hand-over written before the website copy was last updated is still set aside, not taken in', () async {
    // The update's uninstall log is a minute newer than the hand-over.
    expect(await takenIn(const Duration(days: -1), installedAgo: const Duration(minutes: -1)), isFalse);
  });
}
