import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/services/store_handover.dart';

/// One ZestSSH per Windows PC, the Store's preferred (modelled on
/// Spotify): the website's copy hands its data over and the Store's takes
/// it in, asking which to keep where both hold some; nothing is ever deleted that
/// was not copied first. Run against folders that stand in for %LOCALAPPDATA% and
/// %APPDATA%.
void main() {
  late Directory root;
  late StoreHandover h;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_handover_');
    h = StoreHandover(
      localAppData: p.join(root.path, 'Local'),
      appData: p.join(root.path, 'Roaming'),
    );
  });
  tearDown(() => root.delete(recursive: true));

  void write(Directory d, String rel, String text) {
    final f = File(p.join(d.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  String read(Directory d, String rel) =>
      File(p.join(d.path, rel)).readAsStringSync();

  void websiteData(String tag) {
    write(h.localData, p.join('profiles', 'a1', 'zestssh.db'), 'db of $tag');
    write(h.roamingData, 'flutter_secure_storage.dat', 'keys of $tag');
    write(h.roamingData, 'shared_preferences.json', '{"of":"$tag"}');
  }

  test(
    'the Store copy is installed where Windows keeps its package folder',
    () {
      expect(h.storeCopyInstalled, isFalse);
      Directory(
        p.join(root.path, 'Local', 'Packages', StoreHandover.packageFamily),
      ).createSync(recursive: true);
      expect(h.storeCopyInstalled, isTrue);
      expect(
        StoreHandover.appsFolderTarget,
        r'shell:AppsFolder\AffluentLabs.ZestSSH_a13075jvne08e!zestssh',
      );
    },
  );

  test(
    'the website copy hands its data over whole, marked ready last, its own files untouched',
    () async {
      websiteData('web');
      expect(await h.handOver(), isTrue);
      expect(h.handoverReady, isTrue);
      expect(
        read(h.handoverFolder, p.join('local', 'profiles', 'a1', 'zestssh.db')),
        'db of web',
      );
      expect(
        read(h.handoverFolder, p.join('roaming', 'flutter_secure_storage.dat')),
        'keys of web',
      );
      expect(
        read(h.localData, p.join('profiles', 'a1', 'zestssh.db')),
        'db of web',
        reason: 'the original stays',
      );
    },
  );

  test(
    'a Store copy with no data takes the hand-over in, and it goes',
    () async {
      websiteData('web');
      await h.handOver();
      // As a Store copy installed first sees it: its own (empty) folders.
      await h.localData.delete(recursive: true);
      await h.roamingData.delete(recursive: true);
      var asked = false;
      expect(
        await h.takeIn(keepWebsite: () async => asked = true),
        HandoverTaken.takenIn,
      );
      expect(asked, isFalse, reason: 'nothing to ask: only one has data');
      expect(
        read(h.localData, p.join('profiles', 'a1', 'zestssh.db')),
        'db of web',
      );
      expect(read(h.roamingData, 'flutter_secure_storage.dat'), 'keys of web');
      expect(h.handoverFolder.existsSync(), isFalse);
    },
  );

  test(
    'a Store copy that shares the website copy\'s files: the same, nothing moves, nothing asked',
    () async {
      websiteData('web');
      await h.handOver();
      expect(
        await h.takeIn(keepWebsite: () async => fail('not asked')),
        HandoverTaken.same,
      );
      expect(h.handoverFolder.existsSync(), isFalse);
    },
  );

  test(
    'both hold data: the website copy\'s kept, the Store copy\'s set aside, not deleted',
    () async {
      websiteData('web');
      await h.handOver();
      websiteData('store');
      final now = DateTime.utc(2026, 11, 4, 22, 30, 5);
      expect(
        await h.takeIn(keepWebsite: () async => true, now: now),
        HandoverTaken.keptWebsite,
      );
      expect(
        read(h.localData, p.join('profiles', 'a1', 'zestssh.db')),
        'db of web',
      );
      final aside = Directory(
        '${h.localData.path} (set aside 2026-11-04 223005)',
      );
      expect(
        read(aside, p.join('profiles', 'a1', 'zestssh.db')),
        'db of store',
      );
      expect(
        Directory(
          '${h.roamingData.path} (set aside 2026-11-04 223005)',
        ).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'both hold data: the Store copy\'s kept, the website copy\'s put away beside it',
    () async {
      websiteData('web');
      await h.handOver();
      websiteData('store');
      final now = DateTime.utc(2026, 11, 4, 22, 30, 5);
      expect(
        await h.takeIn(keepWebsite: () async => false, now: now),
        HandoverTaken.keptStore,
      );
      expect(
        read(h.localData, p.join('profiles', 'a1', 'zestssh.db')),
        'db of store',
      );
      final put = Directory(
        '${h.handoverFolder.path} (set aside 2026-11-04 223005)',
      );
      expect(
        read(put, p.join('local', 'profiles', 'a1', 'zestssh.db')),
        'db of web',
      );
      expect(h.handoverReady, isFalse);
    },
  );

  test(
    'a website copy with no data marks an empty hand-over: nothing to take, and nothing asked',
    () async {
      expect(await h.handOver(), isFalse, reason: 'no data');
      expect(h.handoverReady, isTrue, reason: 'heard from all the same');
      websiteData('store');
      expect(
        await h.takeIn(keepWebsite: () async => fail('not asked')),
        HandoverTaken.empty,
      );
      expect(
        read(h.localData, p.join('profiles', 'a1', 'zestssh.db')),
        'db of store',
      );
      expect(h.handoverFolder.existsSync(), isFalse);
      expect(
        h.mayRemoveWebsiteCopy(taken: HandoverTaken.empty),
        isFalse,
        reason: 'not installed here',
      );
    },
  );

  test('a hand-over cut short (no ready mark) is never taken', () async {
    websiteData('web');
    await h.handOver();
    File(p.join(h.handoverFolder.path, 'ready.json')).deleteSync();
    expect(
      await h.takeIn(keepWebsite: () async => fail('not asked')),
      HandoverTaken.none,
    );
  });

  test(
    'the website copy\'s program is the one beside its uninstaller: the copy that would go',
    () {
      expect(h.websiteProgram, isNull, reason: 'not installed');
      File(
        p.join(root.path, 'Local', 'Programs', 'ZestSSH', 'unins000.exe'),
      ).createSync(recursive: true);
      expect(h.websiteProgram, isNull, reason: 'no program beside it');
      File(
        p.join(root.path, 'Local', 'Programs', 'ZestSSH', 'zestssh.exe'),
      ).createSync(recursive: true);
      expect(
        h.websiteProgram?.path,
        p.join(root.path, 'Local', 'Programs', 'ZestSSH', 'zestssh.exe'),
      );
    },
  );

  test(
    'the website copy goes only once its data is in the Store copy',
    () async {
      final family = Directory(
        p.join(root.path, 'Local', 'Packages', StoreHandover.packageFamily),
      );
      family.createSync(recursive: true);
      expect(
        h.mayRemoveWebsiteCopy(taken: HandoverTaken.none),
        isFalse,
        reason: 'not installed',
      );
      final unins = File(
        p.join(root.path, 'Local', 'Programs', 'ZestSSH', 'unins000.exe'),
      )..createSync(recursive: true);
      File(
        p.join(root.path, 'Local', 'Programs', 'ZestSSH', 'zestssh.exe'),
      ).createSync(recursive: true);
      expect(
        h.mayRemoveWebsiteCopy(taken: HandoverTaken.none),
        isTrue,
        reason: 'the Store copy shares its real files',
      );
      Directory(
        p.join(family.path, 'LocalCache', 'Local', 'com.affluentlabs.zestssh'),
      ).createSync(recursive: true);
      expect(h.websiteDataHiddenFromStore, isTrue);
      expect(
        h.mayRemoveWebsiteCopy(taken: HandoverTaken.none),
        isFalse,
        reason: 'its data is hidden: wait for its hand-over',
      );
      expect(h.mayRemoveWebsiteCopy(taken: HandoverTaken.takenIn), isTrue);

      final ran = <String>[];
      final gone = await h.removeWebsiteCopy(
        run: (exe, args) async {
          ran.add('$exe ${args.join(' ')}');
          unins.parent.deleteSync(recursive: true);
          return 0;
        },
      );
      expect(gone, isTrue);
      expect(
        ran.single,
        endsWith('unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'),
      );
    },
  );
}
