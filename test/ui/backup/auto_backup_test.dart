import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/auto_backup_service.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Automatic backups (3.0). Turned on from Profile they
/// never asked for their password, so none was ever made; Settings asked
/// only when they were off before. What a run did went to the log only, and
/// a backup was never copied to the other backup places Settings said it
/// went to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  group('a run says what it did', () {
    late SettingsService settings;
    late FlutterSecureStorage storage;

    Future<void> given({String interval = 'daily', String? password, DateTime? last}) async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService(await SharedPreferences.getInstance());
      await settings.setAutoBackupInterval(interval);
      if (last != null) await settings.setLastAutoBackupTime(last);
      FlutterSecureStorage.setMockInitialValues({AutoBackupService.passwordKey: ?password});
      storage = const FlutterSecureStorage();
    }

    Future<AutoBackupOutcome> run(_Backups backups, {CopyBackup? copyTo}) => AutoBackupService.checkAndRunAutoBackup(
          backupService: backups,
          settings: settings,
          secureStorage: storage,
          copyTo: copyTo,
        );

    test('off, or not due, does nothing', () async {
      await given(interval: 'off', password: 'a long enough password');
      expect((await run(_Backups())).status, AutoBackupStatus.idle);
      await given(password: 'a long enough password', last: DateTime.now());
      final backups = _Backups();
      expect((await run(backups)).status, AutoBackupStatus.idle);
      expect(backups.exported, isEmpty);
    });

    test('on with no password makes none, and says so', () async {
      await given();
      final backups = _Backups();
      expect((await run(backups)).status, AutoBackupStatus.noPassword);
      expect(backups.exported, isEmpty);
      await given(password: '');
      expect((await run(backups)).status, AutoBackupStatus.noPassword);
    });

    test('a backup that fails says why, with what was thrown', () async {
      await given(password: 'a long enough password');
      final outcome = await run(_Backups(result: BackupResult(success: false, error: en.backupSvcCouldNotWrite, detail: 'disk full')));
      expect(outcome.status, AutoBackupStatus.failed);
      expect(outcome.error, en.backupSvcCouldNotWrite);
      expect(outcome.detail, 'disk full');
      expect(settings.lastAutoBackupTime, isNull);
    });

    test('a backup made is copied to the other backup places, and says where it could not be', () async {
      await given(password: 'a long enough password');
      final copied = <String>[];
      final outcome = await run(
        _Backups(result: const BackupResult(success: true, filePath: '/srv/demo/backups/zestssh_auto_2026.zest', recordCount: 4)),
        copyTo: (file, filename) async {
          copied.add(filename);
          return {'Nextcloud': '401 Unauthorized'};
        },
      );
      expect(outcome.status, AutoBackupStatus.made);
      expect(copied, ['zestssh_auto_2026.zest']);
      expect(outcome.notCopied, {'Nextcloud': '401 Unauthorized'});
      expect(settings.lastAutoBackupTime, isNotNull);
    });

    test('a backup on leaving does the same', () async {
      await given();
      expect((await AutoBackupService.backupIfDirty(backupService: _Backups(), settings: settings, secureStorage: storage)).status,
          AutoBackupStatus.noPassword);
      await given(password: 'a long enough password');
      final copied = <String>[];
      final outcome = await AutoBackupService.backupIfDirty(
        backupService: _Backups(result: const BackupResult(success: true, filePath: '/srv/demo/zestssh_auto_1.zest')),
        settings: settings,
        secureStorage: storage,
        copyTo: (file, filename) async {
          copied.add(filename);
          return const {};
        },
      );
      expect(outcome.status, AutoBackupStatus.made);
      expect(copied, ['zestssh_auto_1.zest']);
    });
  });

  group('turning them on', () {
    late SharedPreferences prefs;

    Future<ProviderContainer> open(WidgetTester tester, {String? password}) async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      FlutterSecureStorage.setMockInitialValues({AutoBackupService.passwordKey: ?password});
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(children: [
                TextButton(onPressed: () => setAutoBackupInterval(context, ref, 'daily'), child: const Text('daily')),
                TextButton(onPressed: () => setAutoBackupInterval(context, ref, 'off'), child: const Text('off')),
              ]),
            ),
          ),
        ),
      ));
      return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    }

    Future<String?> kept() => const FlutterSecureStorage().read(key: AutoBackupService.passwordKey);

    testWidgets('with no password kept asks for one, in the app\'s own dialog, then turns them on', (tester) async {
      await open(tester);
      await tester.tap(find.text('daily'));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsOneWidget);
      // Too short, then not the same twice: asked again.
      await tester.enterText(find.byKey(const ValueKey('auto-backup-password')), 'short');
      await tester.enterText(find.byKey(const ValueKey('auto-backup-password-again')), 'short');
      await tester.tap(find.byKey(const ValueKey('auto-backup-password-set')));
      await tester.pumpAndSettle();
      expect(find.text(en.accountBackupPasswordTooShort(BackupService.minBackupPasswordLength)), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('auto-backup-password')), 'a long enough password');
      await tester.enterText(find.byKey(const ValueKey('auto-backup-password-again')), 'a long enough passwort');
      await tester.tap(find.byKey(const ValueKey('auto-backup-password-set')));
      await tester.pumpAndSettle();
      expect(find.text(en.settingsMobPasswordsDontMatch), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('auto-backup-password-again')), 'a long enough password');
      await tester.tap(find.byKey(const ValueKey('auto-backup-password-set')));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsNothing);
      expect(await kept(), 'a long enough password');
      expect(SettingsService(prefs).autoBackupInterval, 'daily');
    });

    testWidgets('given no password stays as it was', (tester) async {
      await open(tester);
      await tester.tap(find.text('daily'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(await kept(), isNull);
      expect(SettingsService(prefs).autoBackupInterval, 'off');
      // Turning them off never asks.
      await tester.tap(find.text('off'));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsNothing);
    });

    testWidgets('with a password kept, or turned off, asks nothing', (tester) async {
      await open(tester, password: 'a long enough password');
      await tester.tap(find.text('daily'));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsNothing);
      expect(SettingsService(prefs).autoBackupInterval, 'daily');
      await tester.tap(find.text('off'));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsNothing);
      expect(SettingsService(prefs).autoBackupInterval, 'off');
    });
  });

  test('Settings and Profile turn them on the same way', () {
    for (final path in ['lib/ui/screens/settings/settings_screen.dart', 'lib/ui/screens/profile/profile_screen.dart']) {
      final source = File(path).readAsStringSync();
      expect(source, contains('setAutoBackupInterval(context, ref,'), reason: path);
      expect(source, isNot(contains('.setAutoBackupInterval(choice)')), reason: path);
      expect(source, isNot(contains("key: 'auto_backup_password'")), reason: path);
    }
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      expect(t.autoBackupNoPasswordTitle, isNot(en.autoBackupNoPasswordTitle), reason: '$locale');
      expect(t.autoBackupNoPasswordBody, isNot(en.autoBackupNoPasswordBody), reason: '$locale');
      expect(t.autoBackupFailedTitle, isNot(en.autoBackupFailedTitle), reason: '$locale');
      expect(t.autoBackupNotCopiedTitle, isNot(en.autoBackupNotCopiedTitle), reason: '$locale');
      expect(t.autoBackupNotCopiedBody('Nextcloud'), contains('Nextcloud'), reason: '$locale');
      expect(t.autoBackupOtherPlaces, isNot(en.autoBackupOtherPlaces), reason: '$locale');
    }
  });
}

/// A backup service whose export answers as told.
class _Backups implements BackupService {
  _Backups({this.result = const BackupResult(success: true, filePath: '/srv/demo/zestssh_auto.zest')});

  final BackupResult result;
  final List<String> exported = [];

  @override
  Future<BackupResult> exportBackup(String password, {String filenamePrefix = 'zestssh_backup_', bool allowUnencrypted = false}) async {
    exported.add(password);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
