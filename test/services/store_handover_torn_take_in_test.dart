import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_start.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// StoreHandover.takeIn's "keep the website copy's data" branch renamed the
/// Store copy's own folders away first and copied the hand-over in after; a
/// copy that threw half way (a file another program holds open without
/// sharing, as a scanner can; a full disk; "A copy did not come out the
/// same") left the Store copy on a part copy, and its own data only in the
/// set-aside folders, which are deleted after 30 days (ageOut, at every start
/// of either copy). The hand-over stayed waiting, so the next start asked
/// again; a person who then kept "this app's data" kept the part copy, and 30
/// days later their own data was gone (found in a review). The
/// hand-over is now copied beside the data first and put in place only whole.
///
/// Windows only: a PowerShell holds the hand-over's file open with no sharing
/// while it is copied in.
void main() {
  late Directory root;
  late StoreHandover h;
  late SharedPreferences prefs;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_torn_take_in_');
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

  void write(Directory d, String rel, String text) {
    final f = File(p.join(d.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  String? read(Directory d, String rel) {
    final f = File(p.join(d.path, rel));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  Future<bool> storeStarts({required Future<bool> Function() ask, DateTime Function()? now}) => storeHandoverAtStart(
        rawPrefs: () async => prefs,
        handover: h,
        storeBuild: true,
        thisVersion: () async => '3.3.0.0',
        askKeepWebsite: ask,
        runUninstaller: (_, _) async => fail('no website copy installed here'),
        now: now,
      );

  /// Another program holding [path] open with no sharing, until killed.
  Future<Process> holdOpen(String path) async {
    final ps = await Process.start(windowsPowerShell, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$f = [System.IO.File]::Open('$path', 'Open', 'Read', 'None'); Write-Output 'held'; Start-Sleep -Seconds 60",
    ]);
    final held = Completer<void>();
    ps.stdout.transform(utf8.decoder).listen((s) {
      if (s.contains('held') && !held.isCompleted) held.complete();
    });
    ps.stderr.drain<void>();
    await held.future.timeout(const Duration(seconds: 30));
    return ps;
  }

  /// The website copy's data handed over, the hand-over's keychain held open
  /// by another program while the Store copy starts and [ask] is answered.
  Future<void> tornStart({required Future<bool> Function() ask}) async {
    Process? holder;
    try {
      await storeStarts(ask: () async {
        holder = await holdOpen(p.join(h.handoverFolder.path, 'roaming', 'flutter_secure_storage.dat'));
        return ask();
      });
    } finally {
      holder?.kill();
      await holder?.exitCode;
    }
  }

  test("a take-in cut short leaves this copy's own data in place, and never only where it is deleted after 30 days",
      () async {
    // The website copy's data, handed over.
    write(h.localData, 'zestssh.db', 'db of web');
    write(h.roamingData, 'flutter_secure_storage.dat', 'keys of web');
    await h.handOver();
    // The Store copy's own, different data (its private folders).
    await h.localData.delete(recursive: true);
    await h.roamingData.delete(recursive: true);
    write(h.localData, 'zestssh.db', 'db of store');
    write(h.roamingData, 'flutter_secure_storage.dat', 'keys of store');

    // First start: "keep the website copy's data"; the copy in is cut short.
    await tornStart(ask: () async => true);
    expect(h.handoverReady, isTrue, reason: 'the take-in was cut short: the hand-over waits');
    expect((read(h.localData, 'zestssh.db'), read(h.roamingData, 'flutter_secure_storage.dat')),
        ('db of store', 'keys of store'), reason: 'this copy runs on its own data, not on a part copy');
    expect(Directory('${h.localData.path} (taking in)').existsSync(), isFalse, reason: 'no part copy is left beside');

    // Second start: asked again; the person keeps "this app's data".
    await storeStarts(ask: () async => false);
    // A start 31 days later: what was set aside ages out.
    await storeStarts(
      ask: () async => fail('nothing to ask'),
      now: () => DateTime.now().add(const Duration(days: 31)),
    );
    expect((read(h.localData, 'zestssh.db'), read(h.roamingData, 'flutter_secure_storage.dat')),
        ('db of store', 'keys of store'));
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 3)));

  test('a take-in into a copy with no data of its own, cut short, leaves no part of the hand-over in it', () async {
    write(h.localData, 'zestssh.db', 'db of web');
    write(h.roamingData, 'flutter_secure_storage.dat', 'keys of web');
    await h.handOver();
    await h.localData.delete(recursive: true);
    await h.roamingData.delete(recursive: true);
    write(h.roamingData, 'shared_preferences.json', '{}'); // settings, not data
    // Something in the way of the keychain's copy (a folder of its name): the
    // copy into the roaming folder fails after the local one went in.
    final inTheWay = Directory(p.join(h.roamingData.path, 'flutter_secure_storage.dat'))..createSync(recursive: true);

    await storeStarts(ask: () async => fail('only one holds data'));
    expect(h.handoverReady, isTrue);
    expect(read(h.localData, 'zestssh.db'), isNull, reason: 'a part copy would be taken for data of its own next time');
    expect(read(h.roamingData, 'shared_preferences.json'), '{}');
    expect(Directory('${h.localData.path} (taking in)').existsSync(), isFalse);

    // The next start, nothing in the way: it all comes in.
    inTheWay.deleteSync();
    await storeStarts(ask: () async => fail('only one holds data'));
    expect((read(h.localData, 'zestssh.db'), read(h.roamingData, 'flutter_secure_storage.dat')),
        ('db of web', 'keys of web'));
    expect(h.handoverReady, isFalse);
  });

  test('the website copy\'s data kept: it is in place whole, and this copy\'s own is set aside', () async {
    write(h.localData, p.join('profiles', 'a', 'zestssh.db'), 'db of web');
    write(h.roamingData, 'flutter_secure_storage.dat', 'keys of web');
    await h.handOver();
    await h.localData.delete(recursive: true);
    await h.roamingData.delete(recursive: true);
    write(h.localData, 'zestssh.db', 'db of store');
    write(h.roamingData, 'flutter_secure_storage.dat', 'keys of store');

    expect(await h.takeIn(keepWebsite: () async => true), HandoverTaken.keptWebsite);
    expect(read(h.localData, p.join('profiles', 'a', 'zestssh.db')), 'db of web');
    expect(read(h.localData, 'zestssh.db'), isNull);
    expect(read(h.roamingData, 'flutter_secure_storage.dat'), 'keys of web');
    expect(h.lastSetAside, hasLength(2));
    expect([for (final d in h.leftovers()) p.basename(d.path)].where((n) => n.contains('(taking in)')), isEmpty);
  });
}
