import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_start.dart';
import 'package:zestssh/services/store_handover_version.dart';
import 'package:zestssh/utils/windows_named_lock.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// The pre-release reviews of one ZestSSH per Windows PC
/// (store_handover.dart) and what they found.
/// Run against folders that stand in for
/// %LOCALAPPDATA%, %APPDATA% and %ProgramFiles%, and an uninstall entry that
/// stands in for the registry's.
void main() {
  late Directory root;
  late StoreHandover h;
  late SharedPreferences prefs;
  Map<(bool, String), String> entry = {};

  StoreHandover handover({bool registry = true}) => StoreHandover(
    localAppData: p.join(root.path, 'Local'),
    appData: p.join(root.path, 'Roaming'),
    programFiles: p.join(root.path, 'Program Files'),
    readUninstallEntry: registry
        ? (value, {required allAccounts}) => entry[(allAccounts, value)]
        : null,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_handover_review_');
    entry = {};
    h = handover();
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

  String read(Directory d, String rel) =>
      File(p.join(d.path, rel)).readAsStringSync();

  void installStoreCopy() => Directory(
    p.join(root.path, 'Local', 'Packages', StoreHandover.packageFamily),
  ).createSync(recursive: true);

  /// The website copy's program and uninstaller in [folder].
  File installIn(String folder) {
    File(p.join(folder, 'zestssh.exe')).createSync(recursive: true);
    return File(p.join(folder, 'unins000.exe'))..createSync(recursive: true);
  }

  /// Its installer's entry, as Inno writes it.
  void entryFor(String folder, {bool allAccounts = false}) {
    entry[(allAccounts, 'InstallLocation')] = '$folder\\';
    entry[(allAccounts, 'Inno Setup: App Path')] = folder;
    entry[(allAccounts, 'UninstallString')] =
        '"${p.join(folder, 'unins000.exe')}"';
  }

  void uninstall(File unins) => unins.parent.deleteSync(recursive: true);

  Future<bool> storeStarts({
    Future<bool> Function()? ask,
    Future<String> Function(File)? website,
    Future<void> Function(File)? open,
    Future<int> Function(String, List<String>)? run,
    DateTime Function()? now,
  }) => storeHandoverAtStart(
    rawPrefs: () async => prefs,
    handover: h,
    storeBuild: true,
    thisVersion: () async => '3.3.0.0',
    websiteCopyVersion: website ?? (_) async => '3.3.0+300',
    openWebsiteCopy: open ?? (_) async => fail('not opened'),
    askKeepWebsite: ask ?? () async => fail('nothing to ask'),
    runUninstaller: run ?? (_, _) async => fail('nothing removed'),
    now: now,
  );

  Future<bool> websiteStarts({
    required Future<String?> Function() store,
    bool command = false,
    Future<void> Function()? open,
  }) => storeHandoverAtStart(
    rawPrefs: () async => prefs,
    handover: h,
    storeBuild: false,
    command: command,
    packaged: () => false,
    thisVersion: () async => '3.4.0',
    storeCopyVersion: store,
    openStoreCopy: open ?? () async {},
  );

  // ── A hand-over left waiting goes stale ─────────────────────────
  group('a hand-over left waiting', () {
    test(
      'the website copy starting as itself withdraws it, whatever the reason it stays',
      () async {
        final reasons = <String, Future<bool> Function()>{
          'the Store copy is older': () {
            installStoreCopy();
            return websiteStarts(store: () async => '3.3.0.0');
          },
          'the Store copy\'s version is not read': () {
            installStoreCopy();
            return websiteStarts(
              store: () async => throw const StoreVersionUnreadable('test'),
            );
          },
          'no Store copy for this account': () =>
              websiteStarts(store: () async => null),
          'started for a command': () =>
              websiteStarts(store: () async => '3.4.0.0', command: true),
        };
        for (final e in reasons.entries) {
          write(h.localData, 'zestssh.db', 'db of web');
          await h.handOver();
          expect(h.handoverReady, isTrue);
          expect(await e.value(), isFalse, reason: e.key);
          expect(h.handoverReady, isFalse, reason: '${e.key}: withdrawn');
          expect(h.handoverFolder.existsSync(), isFalse, reason: e.key);
          expect(
            read(h.localData, 'zestssh.db'),
            'db of web',
            reason: 'its own data stays',
          );
          takeStoreHandoverNotice();
        }
      },
    );

    test(
      'the Store copy sets aside, and does not take in, one written before the website copy was last installed or updated',
      () async {
        installStoreCopy();
        // The Store copy's own folders hide the website copy's from it: the
        // hand-over is the only way its data comes in.
        Directory(
          p.join(
            root.path,
            'Local',
            'Packages',
            StoreHandover.packageFamily,
            'LocalCache',
            'Local',
            'com.affluentlabs.zestssh',
          ),
        ).createSync(recursive: true);
        final folder = p.join(root.path, 'Local', 'Programs', 'ZestSSH');
        write(h.localData, 'zestssh.db', 'db of web, old');
        await h.handOver(
          now: DateTime.now().subtract(const Duration(days: 20)),
        );
        await h.localData.delete(recursive: true);
        // The website copy updated since: its uninstall log written now.
        final unins = installIn(folder);
        File(p.join(folder, 'unins000.dat')).writeAsStringSync('log');
        expect(
          await storeStarts(ask: () async => fail('nothing taken in')),
          isFalse,
        );
        expect(h.localData.existsSync(), isFalse, reason: 'nothing taken in');
        expect(
          takeStoreHandoverNotice(),
          StoreHandoverNotice.openWebsiteOnce,
          reason: 'opened once, it hands over again, as it is now',
        );
        expect(h.handoverReady, isFalse);
        expect(
          Directory(p.join(root.path, 'Local'))
              .listSync()
              .map((e) => p.basename(e.path))
              .where((n) => n.startsWith('ZestSSH Handover (set aside ')),
          hasLength(1),
          reason: 'set aside, not deleted',
        );
        expect(unins.existsSync(), isTrue, reason: 'nothing removed');
      },
    );

    test('the question says when each set of data was last used', () async {
      write(h.localData, 'zestssh.db', 'db of web');
      final webTime = DateTime(2026, 10, 2, 9, 15);
      File(p.join(h.localData.path, 'zestssh.db')).setLastModifiedSync(webTime);
      await h.handOver();
      expect(h.handedOverLastUsed, webTime);
      final mark = jsonDecode(read(h.handoverFolder, 'ready.json')) as Map;
      expect(DateTime.parse(mark['lastUsed'] as String).toLocal(), webTime);

      write(h.localData, 'zestssh.db', 'db of store');
      final storeTime = DateTime(2026, 11, 4, 18, 40);
      File(
        p.join(h.localData.path, 'zestssh.db'),
      ).setLastModifiedSync(storeTime);
      expect(await h.ownDataLastUsed(), storeTime);
    });
  });

  // ── The website copy, wherever it was installed ───────
  group('the website copy, found through its uninstall entry', () {
    test(
      'installed in a folder the person chose: found, and removed',
      () async {
        installStoreCopy();
        final folder = p.join(root.path, 'Apps', 'Zest SSH');
        final unins = installIn(folder);
        entryFor(folder);
        expect(h.websiteCopy?.program.path, p.join(folder, 'zestssh.exe'));
        expect(h.websiteCopy?.forAllAccounts, isFalse);
        final ran = <String>[];
        await storeStarts(
          run: (exe, _) async {
            ran.add(exe);
            uninstall(unins);
            return 0;
          },
        );
        expect(ran, [unins.path]);
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.removed);
        expect(h.websiteCopy, isNull);
      },
    );

    test(
      'only a whole path with both the program and the uninstaller, and only the uninstaller the entry names',
      () {
        final folder = p.join(root.path, 'Apps', 'ZestSSH');
        final other = p.join(root.path, 'Elsewhere');
        installIn(other);
        entry[(false, 'InstallLocation')] = r'Apps\ZestSSH';
        expect(h.websiteCopy, isNull, reason: 'not a whole path');
        File(p.join(folder, 'unins000.exe')).createSync(recursive: true);
        entry[(false, 'InstallLocation')] = folder;
        expect(h.websiteCopy, isNull, reason: 'no program beside it');
        File(p.join(folder, 'zestssh.exe')).createSync(recursive: true);
        expect(h.websiteCopy?.uninstaller.path, p.join(folder, 'unins000.exe'));
        entry[(false, 'UninstallString')] =
            '"${p.join(other, 'unins000.exe')}"';
        expect(
          h.websiteCopy?.uninstaller.path,
          p.join(other, 'unins000.exe'),
          reason: 'the folder of the uninstaller it names',
        );
        entry[(false, 'UninstallString')] =
            '"${p.join(root.path, 'Nowhere', 'unins000.exe')}"';
        expect(
          h.websiteCopy,
          isNull,
          reason:
              'it names an uninstaller that is not there: nothing else is run',
        );
        // A default folder with a copy in it is not used where an entry says otherwise.
        installIn(p.join(root.path, 'Local', 'Programs', 'ZestSSH'));
        expect(h.websiteCopy, isNull);
        entry.clear();
        expect(
          h.websiteCopy?.program.path,
          p.join(root.path, 'Local', 'Programs', 'ZestSSH', 'zestssh.exe'),
          reason: 'no entry: the installer\'s default folder, as before',
        );
      },
    );

    test(
      'no entry and nothing in the default folders: none, and a hand-over is taken in as before',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver();
        await h.localData.delete(recursive: true);
        expect(await storeStarts(), isFalse);
        expect(read(h.localData, 'zestssh.db'), 'db of web');
      },
    );
  });

  // ── Installed for every account ─────────────────────────
  group('a website copy installed for every account', () {
    for (final (how, viaEntry) in [
      ('by its machine-wide entry', true),
      ('in Program Files, with no entry read', false),
    ]) {
      test(
        '$how: never removed; told once, and again after a hand-over',
        () async {
          if (!viaEntry) h = handover(registry: false);
          installStoreCopy();
          final folder = viaEntry
              ? p.join(root.path, 'Somewhere', 'ZestSSH')
              : p.join(root.path, 'Program Files', 'ZestSSH');
          final unins = installIn(folder);
          if (viaEntry) entryFor(folder, allAccounts: true);
          expect(h.websiteCopy?.forAllAccounts, isTrue);
          var t = DateTime.now().toUtc();
          Future<void> start() => storeStarts(
            now: () => t,
            ask: () async => fail('only one holds data'),
            run: (_, _) async =>
                fail('an install for every account is never removed here'),
          );
          await start();
          expect(takeStoreHandoverNotice(), StoreHandoverNotice.forAllAccounts);
          t = t.add(const Duration(days: 3));
          await start();
          expect(takeStoreHandoverNotice(), isNull, reason: 'told once');
          write(h.localData, 'zestssh.db', 'db of web');
          await h.handOver(now: t.toLocal().add(const Duration(seconds: 1)));
          await h.localData.delete(recursive: true);
          t = t.add(const Duration(minutes: 5));
          await start();
          expect(
            takeStoreHandoverNotice(),
            StoreHandoverNotice.forAllAccounts,
            reason: 'its data came in: told again',
          );
          expect(unins.existsSync(), isTrue);
        },
      );
    }
  });

  // ── No endless start loop ────────────────────────────────────────
  group('the two copies never hand the start to each other for ever', () {
    test(
      'a Store copy that finds a hand-over written in the last minute never hands its start back',
      () async {
        installStoreCopy();
        final unins = installIn(
          p.join(root.path, 'Local', 'Programs', 'ZestSSH'),
        );
        write(h.localData, 'zestssh.db', 'db of web');
        final t = DateTime.now();
        await h.handOver(now: t.subtract(const Duration(seconds: 5)));
        await h.localData.delete(recursive: true);
        expect(
          await storeStarts(
            now: () => t,
            // The package says 3.3.0.0, the program 3.3.1: read apart.
            website: (_) async => '3.3.1+301',
            open: (_) async => fail('the start is not handed back'),
            ask: () async => fail('nothing taken in'),
          ),
          isFalse,
        );
        expect(h.handoverReady, isTrue, reason: 'nothing taken in');
        expect(unins.existsSync(), isTrue, reason: 'nothing removed');
        // An hour later, it is a newer website copy's as before.
        var opened = 0;
        expect(
          await storeStarts(
            now: () => t.add(const Duration(hours: 1)),
            website: (_) async => '3.3.1+301',
            open: (_) async => opened++,
          ),
          isTrue,
        );
        expect(opened, 1);
      },
    );

    test('a website build that runs as a package hands nothing over', () async {
      installStoreCopy();
      write(h.localData, 'zestssh.db', 'db');
      expect(
        await storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: false,
          packaged: () => true,
          storeCopyVersion: () async => '3.3.0.0',
          thisVersion: () async => '3.3.0',
          openStoreCopy: () async => fail('not opened'),
        ),
        isFalse,
      );
      expect(h.handoverFolder.existsSync(), isFalse);
    });

    test(
      'a program in WindowsApps, or with a package identity, runs as a package',
      () {
        expect(
          runsAsPackage(
            executable:
                r'C:\Program Files\WindowsApps\AffluentLabs.ZestSSH_3.3.0.0_x64__a13075jvne08e\zestssh.exe',
            fullName: () => null,
          ),
          isTrue,
        );
        expect(
          runsAsPackage(
            executable:
                r'C:\Users\Ana\AppData\Local\Programs\ZestSSH\zestssh.exe',
            fullName: () => 'AffluentLabs.ZestSSH_3.3.0.0_x64__a13075jvne08e',
          ),
          isTrue,
        );
        expect(
          runsAsPackage(
            executable:
                r'C:\Users\Ana\AppData\Local\Programs\ZestSSH\zestssh.exe',
            fullName: () => null,
          ),
          isFalse,
        );
      },
    );

    test(
      'the Store copy reads its own version from its package, as the website copy reads it',
      () {
        expect(
          storeCopyOwnVersion(
            fullName: () => 'AffluentLabs.ZestSSH_3.3.1.0_x64__a13075jvne08e',
          ),
          '3.3.1.0',
        );
        expect(
          () => storeCopyOwnVersion(fullName: () => null),
          throwsA(isA<StoreVersionUnreadable>()),
        );
      },
    );

    test(
      'this test process runs as no package',
      () => expect(currentPackageFullName(), isNull),
      skip: !Platform.isWindows,
    );
  });

  // ── What the Store copy says ───────────────────────────────────────────
  group('what the Store copy says, and when the website copy is gone', () {
    test(
      'its uninstaller answered and its program is gone: removed, though the uninstaller\'s own file stays a while',
      () async {
        final folder = p.join(root.path, 'Local', 'Programs', 'ZestSSH');
        installIn(folder);
        final program = File(p.join(folder, 'zestssh.exe'));
        expect(
          await h.removeWebsiteCopy(
            run: (_, _) async {
              program.deleteSync();
              return 0;
            },
          ),
          isTrue,
        );
      },
    );

    test(
      'the person kept the Store copy\'s data: said so, and where the other is set aside',
      () async {
        installStoreCopy();
        final unins = installIn(
          p.join(root.path, 'Local', 'Programs', 'ZestSSH'),
        );
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver();
        write(h.localData, 'zestssh.db', 'db of store');
        await storeStarts(
          ask: () async => false,
          run: (_, _) async {
            uninstall(unins);
            return 0;
          },
        );
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.removedKeptStore);
        expect(takeStoreHandoverSetAside(), hasLength(1));
      },
    );

    test(
      'the person kept the website copy\'s data: this copy\'s own folders are named where they are set aside',
      () async {
        installStoreCopy();
        final unins = installIn(
          p.join(root.path, 'Local', 'Programs', 'ZestSSH'),
        );
        write(h.localData, 'zestssh.db', 'db of web');
        write(h.roamingData, 'flutter_secure_storage.dat', 'keys of web');
        await h.handOver();
        write(h.localData, 'zestssh.db', 'db of store');
        await storeStarts(
          ask: () async => true,
          run: (_, _) async {
            uninstall(unins);
            return 0;
          },
        );
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.removed);
        final aside = takeStoreHandoverSetAside()!;
        expect(aside, hasLength(2));
        expect(aside[0], startsWith('com.affluentlabs.zestssh (set aside '));
        expect(aside[1], startsWith('ZestSSH (set aside '));
      },
    );

    test(
      'a website copy updated while this one asked: not removed this time',
      () async {
        installStoreCopy();
        final unins = installIn(
          p.join(root.path, 'Local', 'Programs', 'ZestSSH'),
        );
        var version = '3.3.0+300';
        await storeStarts(
          website: (_) async {
            final v = version;
            version = '3.4.0+310';
            return v;
          },
          run: (_, _) async => fail('read again: newer now'),
        );
        expect(unins.existsSync(), isTrue);
        expect(takeStoreHandoverNotice(), isNull);
      },
    );
  });

  // ── Written to the disk, and checked whole ───────────────────────
  group('a hand-over is whole', () {
    test('its mark lists every file it holds, with its SHA-256', () async {
      write(h.localData, p.join('profiles', 'a1', 'zestssh.db'), 'db');
      write(h.roamingData, 'flutter_secure_storage.dat', 'keys');
      await h.handOver();
      final mark = jsonDecode(read(h.handoverFolder, 'ready.json')) as Map;
      expect(
        (mark['files'] as Map).keys,
        unorderedEquals([
          'local/profiles/a1/zestssh.db',
          'roaming/flutter_secure_storage.dat',
        ]),
      );
      expect(
        mark['files']['roaming/flutter_secure_storage.dat'],
        sha256.convert(utf8.encode('keys')).toString(),
      );
    });

    for (final (what, spoil) in <(String, void Function(StoreHandover))>[
      (
        'a file changed',
        (h) => write(h.handoverFolder, p.join('local', 'zestssh.db'), 'torn'),
      ),
      (
        'a file missing',
        (h) => File(
          p.join(
            h.handoverFolder.path,
            'roaming',
            'flutter_secure_storage.dat',
          ),
        ).deleteSync(),
      ),
      (
        'a file added',
        (h) => write(
          h.handoverFolder,
          p.join('local', 'zestssh.db-wal'),
          'wal of another',
        ),
      ),
    ]) {
      test('$what: not taken in, set aside', () async {
        write(h.localData, 'zestssh.db', 'db of web');
        write(h.roamingData, 'flutter_secure_storage.dat', 'keys of web');
        await h.handOver();
        await h.localData.delete(recursive: true);
        await h.roamingData.delete(recursive: true);
        spoil(h);
        expect(
          await h.takeIn(keepWebsite: () async => fail('not asked')),
          HandoverTaken.none,
        );
        expect(h.localData.existsSync(), isFalse, reason: 'nothing taken in');
        expect(h.handoverReady, isFalse);
        expect(h.leftovers(), hasLength(1), reason: 'set aside');
      });
    }

    test('what is copied keeps its time of last change', () async {
      write(h.localData, 'zestssh.db', 'db');
      final t = DateTime(2026, 9, 1, 12);
      File(p.join(h.localData.path, 'zestssh.db')).setLastModifiedSync(t);
      await h.handOver();
      expect(
        File(
          p.join(h.handoverFolder.path, 'local', 'zestssh.db'),
        ).lastModifiedSync(),
        t,
      );
    });
  });

  // ── Copies of the data never kept for ever ─────────────────────────
  group('what a hand-over leaves', () {
    Future<void> leaveSome() async {
      write(h.localData, 'zestssh.db', 'db of web');
      await h.handOver();
      write(h.localData, 'zestssh.db', 'db of store');
      // Set aside 40 days ago, and today.
      await h.takeIn(
        keepWebsite: () async => false,
        now: DateTime.now().subtract(const Duration(days: 40)),
      );
      write(h.localData, 'zestssh.db', 'db of web 2');
      await h.handOver();
      write(h.localData, 'zestssh.db', 'db of store 2');
      write(h.roamingData, 'flutter_secure_storage.dat', 'keys');
      await h.takeIn(keepWebsite: () async => true);
      // And one waiting.
      await h.handOver();
    }

    test(
      'listed for Delete all local data: the waiting hand-over and every set-aside copy',
      () async {
        await leaveSome();
        final names = h.leftovers().map((d) => p.basename(d.path)).toList();
        expect(names, contains('ZestSSH Handover'));
        expect(
          names.where((n) => n.startsWith('ZestSSH Handover (set aside ')),
          hasLength(1),
        );
        expect(
          names.where(
            (n) => n.startsWith('com.affluentlabs.zestssh (set aside '),
          ),
          hasLength(1),
        );
        expect(
          names.where((n) => n.startsWith('ZestSSH (set aside ')),
          hasLength(1),
        );
        expect(
          names,
          isNot(contains('com.affluentlabs.zestssh')),
          reason: 'the live data is not a leftover',
        );

        final targets = await WipeTargets.onThisDevice(handover: h);
        expect(
          targets.ownedDirectories.map((d) => d.path),
          containsAll(h.leftovers().map((d) => d.path)),
        );
      },
    );

    test(
      'a set-aside copy goes after 30 days; a younger one, the live data and a waiting hand-over stay',
      () async {
        await leaveSome();
        expect(await h.ageOut(), 1);
        final names = h.leftovers().map((d) => p.basename(d.path)).toList();
        expect(names.where((n) => n.contains('(set aside ')), hasLength(2));
        expect(h.handoverReady, isTrue);
        expect(h.localData.existsSync(), isTrue);
        expect(
          await h.ageOut(now: DateTime.now().add(const Duration(days: 31))),
          2,
        );
        expect(h.leftovers().map((d) => p.basename(d.path)), [
          'ZestSSH Handover',
        ]);
      },
    );

    test('each start of either copy ages them out', () async {
      await leaveSome();
      await websiteStarts(store: () async => null);
      expect(
        h
            .leftovers()
            .map((d) => p.basename(d.path))
            .where((n) => n.contains('(set aside ')),
        hasLength(2),
      );
    });
  });

  // ── One copy at a time hands over or takes in ─────────────────────
  group('the hand-over\'s lock', () {
    test(
      'held by another: the website copy ends and leaves the hand-over alone; the Store copy ends',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver();
        final held = WindowsNamedLock.tryTake(h.lockName)!;
        addTearDown(held.release);
        expect(
          await websiteStarts(
            store: () async => '3.4.0.0',
            open: () async => fail('nothing opened'),
          ),
          isTrue,
          reason: 'this start ends',
        );
        expect(h.handoverReady, isTrue, reason: 'left alone');
        expect(
          await websiteStarts(store: () async => '3.4.0.0', command: true),
          isFalse,
          reason: 'a command runs, and leaves the hand-over alone',
        );
        expect(h.handoverReady, isTrue);
        final stopwatch = Stopwatch()..start();
        expect(await storeStarts(), isTrue, reason: 'this start ends');
        expect(stopwatch.elapsed, greaterThan(const Duration(seconds: 9)));
        expect(h.handoverReady, isTrue, reason: 'nothing taken in');

        held.release();
        expect(await storeStarts(), isFalse);
        expect(h.handoverReady, isFalse, reason: 'taken in once it is free');
      },
      skip: !Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'a named lock: one holder at a time, free again once given back',
      () {
        final name =
            'Local\\ZestSSH.Test.${DateTime.now().microsecondsSinceEpoch}';
        final first = WindowsNamedLock.tryTake(name);
        expect(first, isNotNull);
        expect(WindowsNamedLock.tryTake(name), isNull);
        first!.release();
        final again = WindowsNamedLock.tryTake(name);
        expect(again, isNotNull);
        again!.release();
      },
      skip: !Platform.isWindows,
    );

    test('each account\'s lock is its own, by its hand-over folder', () {
      final other = StoreHandover(
        localAppData: p.join(root.path, 'Other'),
        appData: p.join(root.path, 'Roaming'),
      );
      expect(h.lockName, startsWith(r'Local\ZestSSH.Handover.'));
      expect(h.lockName, isNot(other.lockName));
      expect(handover().lockName, h.lockName);
    });
  });

  // ── Info: the Store copy is opened as the website copy is ───────────────
  test(
    'the Store copy is opened with no AutoRun first, and its name, ! and all, reaches Explorer whole',
    () async {
      final command = openStoreCopyCommand();
      expect(command.arguments.take(4), ['/d', '/v:off', '/s', '/c']);
      final dir = await Directory.systemTemp.createTemp('zest_open_store_');
      addTearDown(() => dir.delete(recursive: true));
      final opener = File(p.join(dir.path, 'opener.cmd'))
        ..writeAsStringSync('@echo off\r\n>"%~dp0got.txt" echo(%1\r\n');
      final run = openAfterThisEndsCommand(
        StoreHandover.appsFolderTarget,
        opener: opener.path,
        pings: 1,
      );
      final result = await Process.run(
        windowsSystemProgram('cmd.exe'),
        run.arguments,
        environment: run.environment,
      );
      expect(result.exitCode, 0);
      expect(
        File(p.join(dir.path, 'got.txt')).readAsStringSync().trimRight(),
        '"${StoreHandover.appsFolderTarget}"',
      );
    },
    skip: !Platform.isWindows || Directory.systemTemp.path.contains(' '),
  );
}
