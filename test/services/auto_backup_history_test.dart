import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/auto_backup_service.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/settings_service.dart';

/// Automatic backups keep a history (3.4.2). One pool of three held the
/// daily or weekly backup and one made at every going to the background
/// after any change (a connect was one), and each of those moved the
/// schedule: within hours all three held the same, possibly damaged, state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late Directory dir;
  late SettingsService settings;
  late FlutterSecureStorage storage;
  late DateTime now;

  setUp(() async {
    L10nGlobal.update(en);
    dir = await Directory.systemTemp.createTemp('zest_auto_backups_');
    now = DateTime(2026, 11, 7, 9);
    AutoBackupService.folder = () async => dir;
    AutoBackupService.clock = () => now;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setAutoBackupInterval('daily');
    FlutterSecureStorage.setMockInitialValues({AutoBackupService.passwordKey: 'a long enough password'});
    storage = const FlutterSecureStorage();
  });
  tearDown(() async {
    AutoBackupService.resetForTest();
    await dir.delete(recursive: true);
  });

  List<String> names(AutoBackupKind kind) =>
      [for (final f in dir.listSync().whereType<File>()) if (AutoBackupKind.of(f.uri.pathSegments.last) == kind) f.uri.pathSegments.last]
        ..sort();

  Future<AutoBackupOutcome> daily(_Backups backups) => AutoBackupService.checkAndRunAutoBackup(
      backupService: backups, settings: settings, secureStorage: storage);
  Future<AutoBackupOutcome> onChange(_Backups backups) => AutoBackupService.backupIfDirty(
      backupService: backups, settings: settings, secureStorage: storage);

  group('two pools', () {
    test('each kind is named its own way, and an older name is a scheduled one', () {
      expect(AutoBackupKind.of('zestssh_auto_2026-11-07T09-00-00.zest'), AutoBackupKind.scheduled);
      expect(AutoBackupKind.of('zestssh_auto_change_2026-11-07T09-00-00-123.zest'), AutoBackupKind.onChange);
      expect(AutoBackupKind.of('zestssh_backup_2026-11-07T09-00-00.zest'), isNull, reason: 'one the person made');
      expect(AutoBackupKind.of('zestssh_auto_2026-11-07T09-00-00.zest.tmp'), isNull, reason: 'one not finished');
    });

    test('a backup on a change never moves the daily one, and never takes a daily one\'s place', () async {
      final backups = _Backups(dir, now: () => now);
      expect((await daily(backups)).status, AutoBackupStatus.made);
      final scheduledAt = settings.lastAutoBackupTime;

      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(hours: 1, minutes: 1));
        expect((await onChange(backups)).status, AutoBackupStatus.made, reason: 'change $i');
      }
      expect(settings.lastAutoBackupTime, scheduledAt, reason: 'the schedule is the daily one\'s alone');
      expect(names(AutoBackupKind.scheduled), hasLength(1), reason: 'the daily one is still there');
      expect(names(AutoBackupKind.onChange), hasLength(AutoBackupKind.onChange.keep));
      expect(AutoBackupService.scheduledDue(settings), isFalse, reason: '20 hours after it');
      now = now.add(const Duration(hours: 4));
      expect(AutoBackupService.scheduledDue(settings), isTrue, reason: 'a day after the daily one, whatever came between');
    });

    test('daily ones are kept seven deep; the oldest goes only once a newer one is made', () async {
      final backups = _Backups(dir, now: () => now);
      for (var day = 0; day < AutoBackupKind.scheduled.keep; day++) {
        expect((await daily(backups)).status, AutoBackupStatus.made);
        now = now.add(const Duration(days: 1));
      }
      final week = names(AutoBackupKind.scheduled);
      expect(week, hasLength(7));

      // A day whose backup fails deletes nothing.
      expect((await daily(_Backups(dir, now: () => now, fail: true))).status, AutoBackupStatus.failed);
      expect(names(AutoBackupKind.scheduled), week);

      expect((await daily(backups)).status, AutoBackupStatus.made);
      final after = names(AutoBackupKind.scheduled);
      expect(after, hasLength(7));
      expect(after, isNot(contains(week.first)), reason: 'the oldest, now that a newer one exists');
      expect(after.take(6), week.skip(1));
    });

    test('backups on a change never delete a scheduled one, nor one the person made', () async {
      File(p(dir, 'zestssh_auto_2026-10-01T09-00-00.zest')).writeAsBytesSync(_whole());
      File(p(dir, 'zestssh_backup_2026-10-01T09-00-00.zest')).writeAsBytesSync(_whole());
      final backups = _Backups(dir, now: () => now);
      for (var i = 0; i < 12; i++) {
        now = now.add(const Duration(hours: 2));
        await onChange(backups);
      }
      expect(File(p(dir, 'zestssh_auto_2026-10-01T09-00-00.zest')).existsSync(), isTrue);
      expect(File(p(dir, 'zestssh_backup_2026-10-01T09-00-00.zest')).existsSync(), isTrue);
      expect(names(AutoBackupKind.onChange), hasLength(6));
    });
  });

  group('one on a change, at most once an hour', () {
    test('a second within the hour makes none and runs no key derivation; after the hour one is made', () async {
      final backups = _Backups(dir, now: () => now);
      expect((await onChange(backups)).status, AutoBackupStatus.made);
      now = now.add(const Duration(minutes: 59));
      expect((await onChange(backups)).status, AutoBackupStatus.idle);
      expect(backups.exported, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      expect((await onChange(backups)).status, AutoBackupStatus.made);
      expect(backups.exported, hasLength(2));
    });

    test('one that failed counts too: it is not tried again at every switch of windows', () async {
      final failing = _Backups(dir, now: () => now, fail: true);
      expect((await onChange(failing)).status, AutoBackupStatus.failed);
      now = now.add(const Duration(minutes: 10));
      expect((await onChange(failing)).status, AutoBackupStatus.idle);
      expect(failing.exported, hasLength(1));
    });

    test('off, none is made', () async {
      await settings.setAutoBackupInterval('off');
      final backups = _Backups(dir, now: () => now);
      expect((await onChange(backups)).status, AutoBackupStatus.idle);
      expect(backups.exported, isEmpty);
    });
  });

  group('going to the background', () {
    Future<(AutoBackupOutcome, bool)> leave(_Backups backups, {required bool changed}) async {
      var taken = false;
      final outcome = await AutoBackupService.onLeaving(
          changed: changed,
          taken: () => taken = true,
          backupService: backups,
          settings: settings,
          secureStorage: storage);
      return (outcome, taken);
    }

    test('the daily one when it is due, though the app was started days ago', () async {
      await settings.setLastAutoBackupTime(now);
      final backups = _Backups(dir, now: () => now);
      now = now.add(const Duration(days: 1, minutes: 5));
      final (outcome, taken) = await leave(backups, changed: false);
      expect(outcome.status, AutoBackupStatus.made);
      expect(taken, isTrue, reason: 'it holds the changes so far');
      expect(names(AutoBackupKind.scheduled), hasLength(1));
      expect(settings.lastAutoBackupTime, now);
    });

    test('a change inside the hour is kept for the next time, not forgotten', () async {
      await settings.setLastAutoBackupTime(now);
      final backups = _Backups(dir, now: () => now);
      final (first, firstTaken) = await leave(backups, changed: true);
      expect(first.status, AutoBackupStatus.made);
      expect(firstTaken, isTrue);

      now = now.add(const Duration(minutes: 20));
      final (second, secondTaken) = await leave(backups, changed: true);
      expect(second.status, AutoBackupStatus.idle);
      expect(secondTaken, isFalse, reason: 'the change waits for the next backup');

      now = now.add(const Duration(minutes: 41));
      final (third, thirdTaken) = await leave(backups, changed: true);
      expect(third.status, AutoBackupStatus.made);
      expect(thirdTaken, isTrue);
    });

    test('nothing changed and nothing due: nothing is made', () async {
      await settings.setLastAutoBackupTime(now);
      final backups = _Backups(dir, now: () => now);
      final (outcome, taken) = await leave(backups, changed: false);
      expect(outcome.status, AutoBackupStatus.idle);
      expect(taken, isFalse);
      expect(backups.exported, isEmpty);
    });

    test('a daily one that fails is not tried again at every switch of windows', () async {
      final failing = _Backups(dir, now: () => now, fail: true);
      expect((await leave(failing, changed: false)).$1.status, AutoBackupStatus.failed);
      now = now.add(const Duration(minutes: 5));
      expect((await leave(failing, changed: false)).$1.status, AutoBackupStatus.idle);
      expect(failing.exported, hasLength(1));
      now = now.add(const Duration(hours: 1));
      expect((await leave(failing, changed: false)).$1.status, AutoBackupStatus.failed);
    });
  });

  group('the only good backup is never the one deleted', () {
    test('where none of those kept looks whole, nothing is deleted', () async {
      final good = 'zestssh_auto_2026-10-01T09-00-00.zest';
      File(p(dir, good)).writeAsBytesSync(_whole());
      for (var i = 2; i <= 8; i++) {
        File(p(dir, 'zestssh_auto_2026-10-0${i}T09-00-00.zest')).writeAsBytesSync(_whole().sublist(0, 30));
      }
      expect(await AutoBackupService.prune(dir, AutoBackupKind.scheduled), isEmpty);
      expect(File(p(dir, good)).existsSync(), isTrue);

      File(p(dir, 'zestssh_auto_2026-10-09T09-00-00.zest')).writeAsBytesSync(_whole());
      expect(await AutoBackupService.prune(dir, AutoBackupKind.scheduled),
          unorderedEquals([good, 'zestssh_auto_2026-10-02T09-00-00.zest']),
          reason: 'a newer whole one is kept now');
    });

    test('a week of much smaller backups (the data emptied) does not push out the last one that held it '
        '(found in a review)', () async {
      // The last backups while the data was there: large.
      for (var i = 1; i <= 3; i++) {
        File(p(dir, 'zestssh_auto_2026-10-0${i}T09-00-00.zest')).writeAsBytesSync(_whole(extra: 40000));
      }
      // Then the data was emptied: seven small whole ones.
      for (var i = 4; i <= 9; i++) {
        File(p(dir, 'zestssh_auto_2026-10-0${i}T09-00-00.zest')).writeAsBytesSync(_whole());
      }
      File(p(dir, 'zestssh_auto_2026-10-10T09-00-00.zest')).writeAsBytesSync(_whole());
      final deleted = await AutoBackupService.prune(dir, AutoBackupKind.scheduled);
      expect(deleted, unorderedEquals(['zestssh_auto_2026-10-01T09-00-00.zest', 'zestssh_auto_2026-10-02T09-00-00.zest']));
      expect(File(p(dir, 'zestssh_auto_2026-10-03T09-00-00.zest')).existsSync(), isTrue,
          reason: 'the newest one that held the data stays');
    });

    test('backups of about the same size rotate by count as before', () async {
      for (var i = 1; i <= 9; i++) {
        File(p(dir, 'zestssh_auto_2026-10-0${i}T09-00-00.zest')).writeAsBytesSync(_whole(extra: i * 10));
      }
      expect(await AutoBackupService.prune(dir, AutoBackupKind.scheduled),
          unorderedEquals(['zestssh_auto_2026-10-01T09-00-00.zest', 'zestssh_auto_2026-10-02T09-00-00.zest']));
    });

    test('a file is taken for whole only where it is a backup as long as its header says', () async {
      Future<bool> whole(List<int> bytes) async {
        final f = File(p(dir, 'x.zest'))..writeAsBytesSync(bytes);
        return AutoBackupService.looksWhole(f);
      }

      expect(await whole(_whole()), isTrue);
      expect(await whole(_whole().sublist(0, _whole().length - 21)), isFalse, reason: 'cut short of its least');
      expect(await whole(utf8.encode('not a backup at all, just text')), isFalse);
      expect(await whole(const []), isFalse);
    });
  });
}

String p(Directory dir, String name) => '${dir.path}${Platform.pathSeparator}$name';

/// The bytes of a backup as exportBackup writes one, with a sealed part of
/// the least length ([extra] bytes more).
Uint8List _whole({int extra = 0}) {
  final header = utf8.encode(jsonEncode({'memory': 131072, 'iterations': 3, 'parallelism': 1}));
  return Uint8List.fromList([
    ...utf8.encode('ZEST'),
    3,
    (header.length >> 8) & 0xff,
    header.length & 0xff,
    ...header,
    ...List.filled(BackupService.leastSealed + 20 + extra, 7),
  ]);
}

/// A backup service whose export writes a whole backup into [dir], named as
/// the real one names it, or fails.
class _Backups implements BackupService {
  _Backups(this.dir, {required this.now, this.fail = false});

  final Directory dir;
  final DateTime Function() now;
  final bool fail;
  final List<String> exported = [];

  @override
  Future<BackupResult> exportBackup(String password,
      {String filenamePrefix = 'zestssh_backup_', bool allowUnencrypted = false}) async {
    exported.add(filenamePrefix);
    if (fail) return const BackupResult(success: false, error: 'disk full');
    final stamp = now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
    final file = File(p(dir, '$filenamePrefix$stamp.zest'))..writeAsBytesSync(_whole());
    return BackupResult(success: true, filePath: file.path, recordCount: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
