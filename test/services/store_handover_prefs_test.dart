import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// The real Windows store of the preferences, with its folder moved into the
// test's: the transitive packages the app runs on Windows.
// ignore: depend_on_referenced_packages
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_start.dart';

/// The Store copy takes a hand-over in before the preferences are first read
/// (found in a review). Windows' store of the
/// preferences (shared_preferences_windows) keeps them in memory from their
/// first read and writes the whole file at each change: read before the
/// website copy's file was copied in, the Store copy's old ones went back over
/// it at the first change, every setting of the website copy lost (its app
/// lock among them, which the move to profiles reads from there).
class _Folder extends PathProviderWindows {
  _Folder(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  late Directory root;
  late StoreHandover h;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest_handover_prefs_');
    h = StoreHandover(
      localAppData: p.join(root.path, 'Local'),
      appData: p.join(root.path, 'Roaming'),
    );
    // The store as the app has it on Windows, writing the file
    // shared_preferences.json in the copy's roaming folder.
    SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
      ..pathProvider = _Folder(h.roamingData.path);
    SharedPreferences.resetStatic();
    takeStoreHandoverNotice();
    takeStoreHandoverSetAside();
  });
  tearDown(() async {
    SharedPreferences.resetStatic();
    await root.delete(recursive: true);
  });

  File prefsFile() =>
      File(p.join(h.roamingData.path, 'shared_preferences.json'));
  Map<String, dynamic> onDisk() =>
      jsonDecode(prefsFile().readAsStringSync()) as Map<String, dynamic>;

  void write(Directory d, String rel, String text) {
    final f = File(p.join(d.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  // The website copy's data, with its settings: its app lock on.
  const websitePrefs = {
    'flutter.app_locale': 'de',
    'flutter.security_lock_enabled': true,
    'flutter.terminal_font_size': 15,
  };

  Future<void> websiteHandsOver() async {
    write(h.localData, 'zestssh.db', 'db of web');
    write(h.roamingData, 'flutter_secure_storage.dat', 'keys of web');
    write(h.roamingData, 'shared_preferences.json', jsonEncode(websitePrefs));
    await h.handOver();
  }

  File installWebsiteCopy() {
    Directory(
      p.join(root.path, 'Local', 'Packages', StoreHandover.packageFamily),
    ).createSync(recursive: true);
    final folder = p.join(root.path, 'Local', 'Programs', 'ZestSSH');
    File(p.join(folder, 'zestssh.exe')).createSync(recursive: true);
    return File(p.join(folder, 'unins000.exe'))..createSync(recursive: true);
  }

  Future<bool> storeStarts({Future<bool> Function()? ask}) =>
      storeHandoverAtStart(
        // As main.dart passes it: asked for, never read before.
        rawPrefs: SharedPreferences.getInstance,
        handover: h,
        storeBuild: true,
        thisVersion: () async => '3.3.0.0',
        websiteCopyVersion: (_) async => '3.3.0+300',
        askKeepWebsite: ask ?? () async => fail('only one holds data'),
        runUninstaller: (exe, _) async {
          File(exe).parent.deleteSync(recursive: true);
          return 0;
        },
      );

  test(
    'taken in by a Store copy with no data: the website copy\'s settings stay, its app lock among them',
    () async {
      installWebsiteCopy();
      await websiteHandsOver();
      // The Store copy as installed first and started once: no data, and a
      // preferences file of its own.
      await h.localData.delete(recursive: true);
      await h.roamingData.delete(recursive: true);
      write(
        h.roamingData,
        'shared_preferences.json',
        jsonEncode({'flutter.terminal_font_size': 11}),
      );

      expect(await storeStarts(), isFalse);
      expect(takeStoreHandoverNotice(), StoreHandoverNotice.removed);

      // On the disk: the website copy's, and the removal's time beside them.
      final disk = onDisk();
      for (final e in websitePrefs.entries) {
        expect(disk[e.key], e.value, reason: e.key);
      }
      expect(disk['flutter.store_handover_remove_tried'], isA<String>());
      // And what the rest of the start reads (main.dart: the move to profiles
      // reads the app lock from here).
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('security_lock_enabled'), isTrue);
      expect(prefs.getString('app_locale'), 'de');
      expect(prefs.getInt('terminal_font_size'), 15);
      // A change now keeps them.
      await prefs.setBool('some_switch', true);
      expect(onDisk()['flutter.security_lock_enabled'], isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'both held data and the website copy\'s was kept: its settings, not the Store copy\'s',
    () async {
      installWebsiteCopy();
      await websiteHandsOver();
      write(h.localData, 'zestssh.db', 'db of store');
      write(h.roamingData, 'flutter_secure_storage.dat', 'keys of store');
      write(
        h.roamingData,
        'shared_preferences.json',
        jsonEncode({
          'flutter.terminal_font_size': 11,
          'flutter.app_locale': 'fr',
        }),
      );

      expect(await storeStarts(ask: () async => true), isFalse);

      final disk = onDisk();
      for (final e in websitePrefs.entries) {
        expect(disk[e.key], e.value, reason: e.key);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('terminal_font_size'), 15);
      expect(prefs.getBool('security_lock_enabled'), isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'the question is asked in this copy\'s language, read from its file: the preferences are not opened for it',
    () async {
      write(
        h.roamingData,
        'shared_preferences.json',
        jsonEncode({'flutter.app_locale': 'fr'}),
      );
      expect(h.preferredLanguage, 'fr');
      write(h.roamingData, 'shared_preferences.json', '{not json');
      expect(h.preferredLanguage, isNull);
      await prefsFile().delete();
      expect(h.preferredLanguage, isNull);
    },
  );

  test(
    'main.dart reads no preferences before the hand-over, and passes them to it to be read after',
    () {
      final main = File(
        'lib/main.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final start = main.indexOf('void _runMainWindow()');
      final end = main.indexOf('\n}\n', start);
      final body = main.substring(start, end);
      final handover = body.indexOf('storeHandoverAtStart(');
      expect(handover, greaterThan(0));
      expect(
        body,
        contains('storeHandoverAtStart(rawPrefs: systemPreferences,'),
      );
      // The hand-over runs on Windows only. The Mac's notice after an update
      // (3.3.2) reads the preferences before it, inside its macOS-only block,
      // where no hand-over ever runs: that block is the one place allowed.
      final macStart = body.indexOf('if (Platform.isMacOS && _adminArgs == null) {');
      final macEnd = macStart < 0 ? -1 : body.indexOf('\n    }\n', macStart);
      for (final read in [
        'systemPreferences()',
        'appPreferences()',
        'SharedPreferences.getInstance()',
      ]) {
        for (var at = body.indexOf(read); at >= 0; at = body.indexOf(read, at + 1)) {
          final inMacBlock = macStart >= 0 && at > macStart && at < macEnd;
          expect(
            at > handover || inMacBlock,
            isTrue,
            reason:
                '$read before the hand-over: the preferences would be held in memory from before it',
          );
        }
      }
    },
  );
}
