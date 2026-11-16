import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_start.dart';
import 'package:zestssh/services/store_handover_version.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// What each copy does at its start (modelled on
/// Spotify): the website's hands over and ends where the Store's is installed;
/// the Store's takes a hand-over in, removes the website's once its data is in,
/// and says so once the app is up.
void main() {
  late Directory root;
  late StoreHandover h;
  late SharedPreferences prefs;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_handover_start_');
    h = StoreHandover(
      localAppData: p.join(root.path, 'Local'),
      appData: p.join(root.path, 'Roaming'),
    );
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    takeStoreHandoverNotice();
  });
  tearDown(() => root.delete(recursive: true));

  void write(Directory d, String rel, String text) {
    final f = File(p.join(d.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  void installStoreCopy() => Directory(
    p.join(root.path, 'Local', 'Packages', StoreHandover.packageFamily),
  ).createSync(recursive: true);

  // The website copy as its installer leaves it: its program beside its
  // uninstaller, in its folder.
  File installWebsiteCopy() {
    final folder = p.join(root.path, 'Local', 'Programs', 'ZestSSH');
    File(p.join(folder, 'zestssh.exe')).createSync(recursive: true);
    return File(p.join(folder, 'unins000.exe'))..createSync(recursive: true);
  }

  // What its uninstaller does: the program folder goes.
  void uninstall(File unins) => unins.parent.deleteSync(recursive: true);

  // The Store copy reads the website copy's version from its program and its
  // own from its program (found in a review): in the
  // Store copy's tests below, the same release unless a test says otherwise.
  Future<String> websiteSameRelease(File _) async => '3.3.0+300';
  Future<String> storeVersion() async => '3.3.0';

  group('the website copy', () {
    test('with no Store copy on the PC: starts as it always has', () async {
      write(h.localData, 'zestssh.db', 'db');
      var opened = false;
      var asked = 0;
      expect(
        await storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: false,
          openStoreCopy: () async => opened = true,
          storeCopyVersion: () async {
            asked++;
            return '3.3.0.0';
          },
          thisVersion: () async => '3.3.0',
        ),
        isFalse,
      );
      expect(opened, isFalse);
      expect(asked, 0, reason: 'no Store copy: its version is not even read');
      expect(h.handoverFolder.existsSync(), isFalse);
      expect(takeStoreHandoverNotice(), isNull);
    });

    test(
      'with the Store copy installed: hands its data over, opens it, and ends',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db');
        var opened = false;
        expect(
          await storeHandoverAtStart(
            rawPrefs: () async => prefs,
            handover: h,
            storeBuild: false,
            openStoreCopy: () async => opened = true,
            storeCopyVersion: () async => '3.3.0.0',
            thisVersion: () async => '3.3.0',
          ),
          isTrue,
        );
        expect(opened, isTrue);
        expect(h.handoverReady, isTrue);
        expect(takeStoreHandoverNotice(), isNull);
      },
    );

    test(
      'with the Store copy installed and nothing to hand over: still goes to it',
      () async {
        installStoreCopy();
        var opened = false;
        expect(
          await storeHandoverAtStart(
            rawPrefs: () async => prefs,
            handover: h,
            storeBuild: false,
            openStoreCopy: () async => opened = true,
            storeCopyVersion: () async => '3.3.0.0',
            thisVersion: () async => '3.3.0',
          ),
          isTrue,
        );
        expect(opened, isTrue);
        expect(h.handoverReady, isTrue, reason: 'an empty hand-over');
      },
    );
  });

  // Only to a Store copy at least as new as this one (found in a
  // review): a website 3.3 whose data is already in per-account
  // profiles, handing over to a Store copy still on 3.2.7, would open that copy
  // on data it cannot read.
  group('the website copy and the Store copy\'s version', () {
    Future<bool> start({
      required Future<String?> Function() store,
      String mine = '3.3.0',
      void Function()? onOpen,
    }) => storeHandoverAtStart(
      rawPrefs: () async => prefs,
      handover: h,
      storeBuild: false,
      openStoreCopy: () async => onOpen?.call(),
      storeCopyVersion: store,
      thisVersion: () async => mine,
    );

    test(
      'a Store copy older than this one: hands nothing over, starts as it is, and says so once',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db of 3.3');
        var opened = 0;
        expect(
          await start(store: () async => '3.2.7.0', onOpen: () => opened++),
          isFalse,
        );
        expect(opened, 0);
        expect(h.handoverFolder.existsSync(), isFalse);
        expect(
          File(p.join(h.localData.path, 'zestssh.db')).readAsStringSync(),
          'db of 3.3',
        );
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.storeCopyOlder);
        expect(takeStoreHandoverNotice(), isNull, reason: 'said once');

        // The next start, the Store copy not updated yet: nothing said again.
        expect(
          await start(store: () async => '3.2.7.0', onOpen: () => opened++),
          isFalse,
        );
        expect(opened, 0);
        expect(takeStoreHandoverNotice(), isNull, reason: 'said once');
      },
    );

    test(
      'a Store copy updated, but still older: said again, once, for that version',
      () async {
        installStoreCopy();
        await start(store: () async => '3.2.7.0');
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.storeCopyOlder);
        await start(store: () async => '3.2.9.0');
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.storeCopyOlder);
        await start(store: () async => '3.2.9.0');
        expect(takeStoreHandoverNotice(), isNull);
      },
    );

    test(
      'a Store copy as new as this one, or newer: hands over as before',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db');
        for (final store in ['3.3.0.0', '3.3.1.0', '3.10.0.0', '4.0.0.0']) {
          var opened = 0;
          expect(
            await start(store: () async => store, onOpen: () => opened++),
            isTrue,
            reason: store,
          );
          expect(opened, 1, reason: store);
          expect(h.handoverReady, isTrue, reason: store);
          expect(takeStoreHandoverNotice(), isNull, reason: store);
        }
      },
    );

    test(
      'the older Store copy updated by the Store: the next start hands over',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db');
        expect(await start(store: () async => '3.2.7.0'), isFalse);
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.storeCopyOlder);
        expect(await start(store: () async => '3.3.0.0'), isTrue);
        expect(h.handoverReady, isTrue);
        expect(takeStoreHandoverNotice(), isNull);
      },
    );

    test(
      'its folder there but no such package for this account: starts as it is, says nothing',
      () async {
        installStoreCopy();
        var opened = 0;
        expect(
          await start(store: () async => null, onOpen: () => opened++),
          isFalse,
        );
        expect(opened, 0);
        expect(h.handoverFolder.existsSync(), isFalse);
        expect(takeStoreHandoverNotice(), isNull);
      },
    );

    test(
      'a version that cannot be read: the safe side, nothing handed over and nothing said',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db');
        final unread = <String, Future<bool> Function()>{
          'the lookup fails': () => start(
            store: () async => throw const StoreVersionUnreadable('test'),
          ),
          'the Store copy\'s is not a version': () =>
              start(store: () async => 'garbage'),
          'this copy\'s own is unknown': () =>
              start(store: () async => '3.3.0.0', mine: ''),
        };
        for (final e in unread.entries) {
          var opened = 0;
          expect(
            await storeHandoverAtStart(
              rawPrefs: () async => prefs,
              handover: h,
              storeBuild: false,
              openStoreCopy: () async => opened++,
              storeCopyVersion: () async => '3.3.0.0',
              thisVersion: () async => '3.3.0',
            ),
            isTrue,
            reason: 'the same PC with the versions read goes over',
          );
          expect(opened, 1);
          await h.handoverFolder.delete(recursive: true);
          expect(await e.value(), isFalse, reason: e.key);
          expect(h.handoverFolder.existsSync(), isFalse, reason: e.key);
          expect(takeStoreHandoverNotice(), isNull, reason: e.key);
          expect(prefs.getString('store_handover_older_told'), isNull);
        }
      },
    );
  });

  group('the Store copy', () {
    test('alone on the PC: nothing to do, nothing to say', () async {
      installStoreCopy();
      expect(
        await storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: true,
          runUninstaller: (_, _) async => fail('nothing to remove'),
        ),
        isFalse,
      );
      expect(takeStoreHandoverNotice(), isNull);
    });

    test(
      'takes a hand-over in, removes the website copy, and says so once',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver();
        await h.localData.delete(recursive: true);
        final ran = <String>[];
        expect(
          await storeHandoverAtStart(
            rawPrefs: () async => prefs,
            handover: h,
            storeBuild: true,
            thisVersion: storeVersion,
            websiteCopyVersion: websiteSameRelease,
            askKeepWebsite: () async => fail('only one holds data'),
            runUninstaller: (exe, args) async {
              ran.add(exe);
              uninstall(unins);
              return 0;
            },
          ),
          isFalse,
        );
        expect(ran, hasLength(1));
        expect(
          File(p.join(h.localData.path, 'zestssh.db')).readAsStringSync(),
          'db of web',
        );
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.removed);
        expect(takeStoreHandoverNotice(), isNull, reason: 'said once');
      },
    );

    test(
      'an uninstaller that fails: says the website copy is still there',
      () async {
        installStoreCopy();
        installWebsiteCopy();
        await storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: true,
          thisVersion: storeVersion,
          websiteCopyVersion: websiteSameRelease,
          runUninstaller: (_, _) async => 1,
        );
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.notRemoved);
      },
    );

    test(
      'a removal that did not go is tried again a day later, not at every start',
      () async {
        installStoreCopy();
        installWebsiteCopy();
        var t = DateTime.utc(2026, 11, 4, 9);
        var runs = 0;
        Future<void> start() => storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: true,
          thisVersion: storeVersion,
          websiteCopyVersion: websiteSameRelease,
          now: () => t,
          runUninstaller: (_, _) async {
            runs++;
            return 1;
          },
        );
        await start();
        expect(runs, 1);
        t = t.add(const Duration(hours: 5));
        await start();
        expect(runs, 1, reason: 'within a day');
        t = t.add(const Duration(hours: 20));
        await start();
        expect(runs, 2);
      },
    );

    test(
      'the website copy\'s data hidden from it: waits, and asks for the website copy to be opened once',
      () async {
        installStoreCopy();
        installWebsiteCopy();
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
        await storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: true,
          thisVersion: storeVersion,
          websiteCopyVersion: websiteSameRelease,
          runUninstaller: (_, _) async => fail('its data is not in yet'),
        );
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.openWebsiteOnce);
      },
    );

    test(
      'its folders hiding a website copy that held no data: removes it once that copy has been opened',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
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
        await h.handOver();
        await storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: true,
          thisVersion: storeVersion,
          websiteCopyVersion: websiteSameRelease,
          askKeepWebsite: () async => fail('nothing to ask'),
          runUninstaller: (_, _) async {
            uninstall(unins);
            return 0;
          },
        );
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.removed);
      },
    );

    test(
      'both hold data: asks, and the answer decides which is kept',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver();
        write(h.localData, 'zestssh.db', 'db of store');
        var asked = 0;
        await storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: true,
          thisVersion: storeVersion,
          websiteCopyVersion: websiteSameRelease,
          askKeepWebsite: () async {
            asked++;
            return false;
          },
          runUninstaller: (_, _) async {
            uninstall(unins);
            return 0;
          },
        );
        expect(asked, 1);
        expect(
          File(p.join(h.localData.path, 'zestssh.db')).readAsStringSync(),
          'db of store',
        );
        // It kept its own: the notice says so, and names what was set aside
        // (found in a review; it said this
        // one had everything the website copy held).
        expect(
          takeStoreHandoverNotice(),
          StoreHandoverNotice.removedKeptStore,
        );
        expect(takeStoreHandoverSetAside(), [
          matches(r'^ZestSSH Handover \(set aside \d{4}-\d\d-\d\d \d{6}\)$'),
        ]);
        expect(takeStoreHandoverSetAside(), isNull, reason: 'said once');
      },
    );
  });

  // The other direction (found in a review): the
  // Store copy takes over only a website copy of at most its own version. A
  // newer one (3.4 on zestssh.com before the Store has it) is left as it is
  // and opens in the Store copy's place, which shows nothing.
  group('the Store copy and the website copy\'s version', () {
    String websiteProgram() =>
        p.join(root.path, 'Local', 'Programs', 'ZestSSH', 'zestssh.exe');
    String dbIn(Directory d) =>
        File(p.join(d.path, 'zestssh.db')).readAsStringSync();

    test(
      'a website copy older than this one, or the same release: taken over as before',
      () async {
        installStoreCopy();
        for (final website in ['3.2.7+299', '3.3.0+300', '3.3.0+301', '3.3.0']) {
          final unins = installWebsiteCopy();
          write(h.localData, 'zestssh.db', 'db of web $website');
          await h.handOver();
          await h.localData.delete(recursive: true);
          var opened = 0;
          final ran = <String>[];
          expect(
            await storeHandoverAtStart(
              rawPrefs: () async => prefs,
              handover: h,
              storeBuild: true,
              thisVersion: storeVersion,
              websiteCopyVersion: (_) async => website,
              openWebsiteCopy: (_) async => opened++,
              askKeepWebsite: () async => fail('only one holds data'),
              runUninstaller: (exe, _) async {
                ran.add(exe);
                uninstall(unins);
                return 0;
              },
            ),
            isFalse,
            reason: website,
          );
          expect(opened, 0, reason: website);
          expect(ran, [unins.path], reason: website);
          expect(dbIn(h.localData), 'db of web $website');
          expect(h.handoverFolder.existsSync(), isFalse, reason: website);
          expect(
            takeStoreHandoverNotice(),
            StoreHandoverNotice.removed,
            reason: website,
          );
          await h.localData.delete(recursive: true);
          await prefs.clear();
        }
      },
    );

    test(
      'a newer website copy: nothing copied or removed, the start handed to it, and nothing shown',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
        // A hand-over waiting from before the website copy was updated, and
        // the Store copy's own data beside it.
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver(now: DateTime.now().subtract(const Duration(hours: 1)));
        write(h.localData, 'zestssh.db', 'db of store');
        final opened = <String>[];
        for (final website in ['3.4.0+310', '3.3.1+305', '4.0.0+500']) {
          expect(
            await storeHandoverAtStart(
              rawPrefs: () async => prefs,
              handover: h,
              storeBuild: true,
              thisVersion: storeVersion,
              websiteCopyVersion: (program) async {
                expect(program.path, websiteProgram());
                return website;
              },
              openWebsiteCopy: (program) async => opened.add(program.path),
              askKeepWebsite: () async => fail('nothing is asked: nothing shows'),
              runUninstaller: (_, _) async => fail('nothing is removed'),
            ),
            isTrue,
            reason: 'this copy ends, $website opens in its place',
          );
          expect(
            takeStoreHandoverNotice(),
            isNull,
            reason: 'this copy shows nothing: $website',
          );
        }
        expect(opened, List.filled(3, websiteProgram()));
        expect(unins.existsSync(), isTrue, reason: 'not removed');
        expect(h.handoverReady, isTrue, reason: 'the hand-over is not taken');
        expect(
          File(
            p.join(h.handoverFolder.path, 'local', 'zestssh.db'),
          ).readAsStringSync(),
          'db of web',
        );
        expect(dbIn(h.localData), 'db of store', reason: 'nothing copied');
        expect(prefs.getKeys(), isEmpty, reason: 'nothing written');
      },
    );

    test(
      'a newer website copy whose real folders this copy shares: the same, its data untouched',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
        write(h.localData, 'zestssh.db', 'db of 3.4');
        var opened = 0;
        expect(
          await storeHandoverAtStart(
            rawPrefs: () async => prefs,
            handover: h,
            storeBuild: true,
            thisVersion: storeVersion,
            websiteCopyVersion: (_) async => '3.4.0+310',
            openWebsiteCopy: (_) async => opened++,
            runUninstaller: (_, _) async => fail('nothing is removed'),
          ),
          isTrue,
        );
        expect(opened, 1);
        expect(unins.existsSync(), isTrue);
        expect(dbIn(h.localData), 'db of 3.4');
        expect(h.handoverFolder.existsSync(), isFalse);
        expect(takeStoreHandoverNotice(), isNull);
      },
    );

    test(
      'the website copy, opened in its place, stays and says once that the Store copy needs updating: neither hands back',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
        write(h.localData, 'zestssh.db', 'db of 3.4');
        var websiteOpened = 0;
        var storeOpened = 0;
        Future<bool> storeStarts(String mine) => storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: true,
          thisVersion: () async => mine,
          websiteCopyVersion: (_) async => '3.4.0+310',
          openWebsiteCopy: (_) async => websiteOpened++,
          askKeepWebsite: () async => fail('the same data: nothing asked'),
          runUninstaller: (_, _) async {
            uninstall(unins);
            return 0;
          },
        );
        Future<bool> websiteStarts() => storeHandoverAtStart(
          rawPrefs: () async => prefs,
          handover: h,
          storeBuild: false,
          thisVersion: () async => '3.4.0',
          storeCopyVersion: () async => '3.3.0.0',
          openStoreCopy: () async => storeOpened++,
        );
        for (var round = 1; round <= 2; round++) {
          expect(await storeStarts('3.3.0'), isTrue, reason: 'round $round');
          expect(takeStoreHandoverNotice(), isNull);
          expect(
            await websiteStarts(),
            isFalse,
            reason: 'round $round: the website copy stays',
          );
          expect(
            takeStoreHandoverNotice(),
            round == 1 ? StoreHandoverNotice.storeCopyOlder : isNull,
            reason: 'round $round: said once',
          );
        }
        expect(websiteOpened, 2);
        expect(storeOpened, 0);
        expect(unins.existsSync(), isTrue);
        expect(dbIn(h.localData), 'db of 3.4');

        // The Store has 3.4 now: its next start takes the website copy over.
        expect(await storeStarts('3.4.0'), isFalse);
        expect(websiteOpened, 2);
        expect(unins.existsSync(), isFalse);
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.removed);
      },
    );

    test(
      'a version that cannot be read: neither taken over nor handed the start; starts as itself and looks again next start',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver();
        await h.localData.delete(recursive: true);
        Future<String> noVersion(File _) async =>
            throw const ProgramVersionUnreadable('test');
        Future<String> notRead() async => throw Exception('test');
        final unread = [
          ('its program holds no version', noVersion, storeVersion),
          ('it holds what is not a version', (File _) async => 'x', storeVersion),
          ('it holds an empty one', (File _) async => '', storeVersion),
          ('this copy\'s own is empty', websiteSameRelease, () async => ''),
          ('this copy\'s own is not read', websiteSameRelease, notRead),
        ];
        for (final (why, website, mine) in unread) {
          expect(
            await storeHandoverAtStart(
              rawPrefs: () async => prefs,
              handover: h,
              storeBuild: true,
              thisVersion: mine,
              websiteCopyVersion: website,
              openWebsiteCopy: (_) async => fail('not handed the start'),
              askKeepWebsite: () async => fail('nothing asked'),
              runUninstaller: (_, _) async => fail('nothing removed'),
            ),
            isFalse,
            reason: '$why: this copy starts',
          );
          expect(h.handoverReady, isTrue, reason: '$why: nothing taken in');
          expect(h.localData.existsSync(), isFalse, reason: why);
          expect(unins.existsSync(), isTrue, reason: why);
          expect(takeStoreHandoverNotice(), isNull, reason: why);
          expect(prefs.getKeys(), isEmpty, reason: why);
        }

        // The next start, both read: taken over as before.
        expect(
          await storeHandoverAtStart(
            rawPrefs: () async => prefs,
            handover: h,
            storeBuild: true,
            thisVersion: storeVersion,
            websiteCopyVersion: websiteSameRelease,
            openWebsiteCopy: (_) async => fail('the same release'),
            askKeepWebsite: () async => fail('only one holds data'),
            runUninstaller: (_, _) async {
              uninstall(unins);
              return 0;
            },
          ),
          isFalse,
        );
        expect(dbIn(h.localData), 'db of web');
        expect(takeStoreHandoverNotice(), StoreHandoverNotice.removed);
      },
    );

    test(
      'a newer website copy that could not be opened: this copy starts, and still takes nothing in and removes nothing',
      () async {
        installStoreCopy();
        final unins = installWebsiteCopy();
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver(now: DateTime.now().subtract(const Duration(hours: 1)));
        await h.localData.delete(recursive: true);
        expect(
          await storeHandoverAtStart(
            rawPrefs: () async => prefs,
            handover: h,
            storeBuild: true,
            thisVersion: storeVersion,
            websiteCopyVersion: (_) async => '3.4.0+310',
            openWebsiteCopy: (_) async =>
                throw const ProcessException('cmd.exe', [], 'test'),
            askKeepWebsite: () async => fail('nothing asked'),
            runUninstaller: (_, _) async => fail('nothing removed'),
          ),
          isFalse,
        );
        expect(h.handoverReady, isTrue);
        expect(unins.existsSync(), isTrue);
        expect(takeStoreHandoverNotice(), isNull);
      },
    );

    test(
      'no website copy: nothing is read, and a waiting hand-over is taken in as before',
      () async {
        installStoreCopy();
        write(h.localData, 'zestssh.db', 'db of web');
        await h.handOver();
        await h.localData.delete(recursive: true);
        expect(
          await storeHandoverAtStart(
            rawPrefs: () async => prefs,
            handover: h,
            storeBuild: true,
            thisVersion: () async => fail('not read'),
            websiteCopyVersion: (_) async => fail('not read'),
            openWebsiteCopy: (_) async => fail('none to open'),
            askKeepWebsite: () async => fail('only one holds data'),
            runUninstaller: (_, _) async => fail('none to remove'),
          ),
          isFalse,
        );
        expect(dbIn(h.localData), 'db of web');
        expect(h.handoverFolder.existsSync(), isFalse);
        expect(takeStoreHandoverNotice(), isNull);
      },
    );
  });

  // Opened once this process has ended, as the website copy opens the Store
  // copy: the two share the "one ZestSSH at a time" check
  // (windows/runner/single_instance.cpp).
  group('opening the website copy once the Store copy has ended', () {
    test('Explorer opens it, after a pause, its path only in a variable', () {
      const target =
          r'C:\Users\Ana Maria\AppData\Local\Programs\ZestSSH\zestssh.exe';
      final command = openAfterThisEndsCommand(target);
      expect(command.arguments.take(4), ['/d', '/v:off', '/s', '/c']);
      expect(
        command.arguments.last,
        startsWith('${windowsSystemProgram('ping.exe')} -n 3 127.0.0.1 >nul & '),
      );
      expect(command.arguments.last, contains(windowsExplorer));
      expect(command.arguments.join(' '), isNot(contains('Ana Maria')));
      expect(command.environment.values.single, '"$target"');
    });

    test(
      'cmd.exe hands the whole path on: a space, an &, a %, a ^ or a ! in it stays part of it',
      () async {
        final dir = await Directory.systemTemp.createTemp('zest_open_');
        addTearDown(() => dir.delete(recursive: true));
        // Stands in for Explorer: writes down the one argument it was given.
        final opener = File(p.join(dir.path, 'opener.cmd'))
          ..writeAsStringSync('@echo off\r\n>"%~dp0got.txt" echo(%1\r\n');
        const target =
            r'C:\Users\Ana Maria & Co 100% (x) ^y !z\AppData\Local\Programs\ZestSSH\zestssh.exe';
        final command = openAfterThisEndsCommand(
          target,
          opener: opener.path,
          pings: 1,
        );
        final run = await Process.run(
          windowsSystemProgram('cmd.exe'),
          command.arguments,
          environment: command.environment,
        );
        expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
        expect(
          File(p.join(dir.path, 'got.txt')).readAsStringSync().trimRight(),
          '"$target"',
        );
      },
      skip: !Platform.isWindows || Directory.systemTemp.path.contains(' '),
    );
  });
}
