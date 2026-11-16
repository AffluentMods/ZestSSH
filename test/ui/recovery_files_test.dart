import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/profile/recovery_key_screen.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/utils/file_manager.dart';

/// Where the kit's picker starts: a folder of the test's own.
class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.downloads);

  final String downloads;

  @override
  Future<String?> getDownloadsPath() async => downloads;
}

/// A file picker that answers with [path], or throws [error].
class _Picker extends FilePicker {
  _Picker({this.path, this.error});

  final String? path;
  final Object? error;
  int asked = 0;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    asked++;
    if (error != null) throw error!;
    return path;
  }
}

/// The recovery kit and the recovery codes saved as files (3.0):
/// kept readable by their owner alone or not kept at all, where
/// they went shown, and a failure said in the app's language with what was
/// thrown to copy.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tmp = Directory.systemTemp.createTempSync('zest_recovery_files_');
  });

  tearDown(() {
    debugRestrictFileToOwner = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('a file kept to its owner', () {
    test('is readable by the person signed in alone', () async {
      final file = File('${tmp.path}${Platform.pathSeparator}codes.txt')..writeAsStringSync('demo');
      expect(await restrictFileToOwner(file), isTrue);
      if (Platform.isWindows) {
        final user = Platform.environment['USERNAME']!;
        final said = (await Process.run('icacls', [file.path])).stdout as String;
        final entries = said
            .split('\n')
            .map((l) => l.replaceFirst(file.path, '').trim())
            .where((l) => l.contains(':('))
            .toList();
        expect(entries, hasLength(1), reason: said);
        expect(entries.single.toLowerCase(), contains(user.toLowerCase()));
        expect(entries.single, contains('(R,W)'));
      } else {
        final mode = (await file.stat()).mode & 0x1FF;
        expect(mode, 0x180, reason: 'rw for the owner only');
      }
    });

    test('a file that is not there cannot be kept private', () async {
      expect(await restrictFileToOwner(File('${tmp.path}${Platform.pathSeparator}gone.txt')), isFalse);
    });
  });

  group('the recovery codes saved on a computer', () {
    final codes = [for (var i = 0; i < 10; i++) 'abcd$i-efgh$i'];

    Future<ProviderContainer> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showRecoveryCodes(context, codes: codes, email: 'demo@northwind.example'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    }

    /// Lets the save's real file work (and icacls) finish.
    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.text(en.twoStepCodesSave));
      await tester.pump();
    }

    /// Done is on (the dialog's own footer button, 3.4).
    bool doneChecked(WidgetTester tester) =>
        tester
            .widget<GestureDetector>(find
                .descendant(
                    of: find.byKey(const ValueKey('two-step-codes-done')), matching: find.byType(GestureDetector))
                .first)
            .onTap !=
        null;

    testWidgets('are written, kept to their owner, and where they went is shown', (tester) async {
      final path = '${tmp.path}${Platform.pathSeparator}ZestSSH_Backup_Codes.txt';
      FilePicker.platform = _Picker(path: path);
      final kept = <String>[];
      debugRestrictFileToOwner = (file) async {
        kept.add(file.path);
        return true;
      };
      await open(tester);
      await save(tester);
      await settle(tester, () => find.text(en.twoStepCodesSavedBody).evaluate().isNotEmpty);
      expect(find.text(en.twoStepCodesSavedBody), findsOneWidget);
      // Said in the same dialog, under the codes, the file's name first and
      // its folder under it (it was a second dialog over this one).
      expect(find.byType(RecoveryCodesDialog), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byKey(const ValueKey('file-saved-name'))).data,
          endsWith('ZestSSH_Backup_Codes.txt'));
      expect(kept, [path]);
      final written = File(path).readAsStringSync();
      for (final code in codes) {
        expect(written, contains(code));
      }
      expect(written, contains('demo@northwind.example'));
      expect(doneChecked(tester), isTrue, reason: 'saving them counts as saved');
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('that cannot be kept private are deleted and not counted as saved', (tester) async {
      final path = '${tmp.path}${Platform.pathSeparator}ZestSSH_Backup_Codes.txt';
      FilePicker.platform = _Picker(path: path);
      debugRestrictFileToOwner = (file) async => false;
      final container = await open(tester);
      await save(tester);
      await settle(tester, () => container.read(notificationCenterProvider).history.isNotEmpty);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.twoStepCodesNotPrivate);
      expect(File(path).existsSync(), isFalse, reason: 'never left readable by another account');
      expect(find.text(en.twoStepCodesSavedBody), findsNothing);
      expect(doneChecked(tester), isFalse);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a save that fails says so with what was thrown to copy', (tester) async {
      FilePicker.platform = _Picker(error: const FileSystemException('The disk is full', 'D:\\demo'));
      final container = await open(tester);
      await save(tester);
      await settle(tester, () => container.read(notificationCenterProvider).history.isNotEmpty);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.twoStepCodesSaveFailed);
      expect(notice.details, contains('The disk is full'));
      expect(doneChecked(tester), isFalse);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('cancelled, nothing is written or said', (tester) async {
      final picker = _Picker();
      FilePicker.platform = picker;
      var kept = 0;
      debugRestrictFileToOwner = (file) async {
        kept++;
        return true;
      };
      final container = await open(tester);
      await save(tester);
      await settle(tester, () => picker.asked > 0);
      await tester.pump();
      expect(picker.asked, 1);
      expect(kept, 0);
      expect(container.read(notificationCenterProvider).history, isEmpty);
      expect(tmp.listSync(), isEmpty);
    });
  });

  group('the recovery kit saved on a computer', () {
    // Pumped and saved as a person does: the source pins it had passed with
    // the rule gone (found in a review). A replacement kit, so the
    // sync setup's state is not written.
    Future<ProviderContainer> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      PathProviderPlatform.instance = _Paths(tmp.path);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RecoveryKeyScreen(mode: RecoveryKeyMode.replace),
        ),
      ));
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(tester.element(find.byType(RecoveryKeyScreen)));
    }

    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    testWidgets('is written and kept to its owner, and where it went is shown', (tester) async {
      final path = '${tmp.path}${Platform.pathSeparator}ZestSSH-Recovery-Kit.txt';
      FilePicker.platform = _Picker(path: path);
      final kept = <String>[];
      debugRestrictFileToOwner = (file) async {
        kept.add(file.path);
        return true;
      };
      await open(tester);
      await tester.tap(find.text(en.recoveryKeyDownloadTxt));
      await tester.pump();
      await settle(tester, () => find.text(en.recoveryKitSavedBody).evaluate().isNotEmpty);
      expect(kept, [path]);
      expect(File(path).readAsStringSync(), isNotEmpty);
      expect(find.text(en.recoveryKitSavedBody), findsOneWidget);
    });

    testWidgets('that cannot be kept private is deleted and said not saved', (tester) async {
      final path = '${tmp.path}${Platform.pathSeparator}ZestSSH-Recovery-Kit.txt';
      FilePicker.platform = _Picker(path: path);
      debugRestrictFileToOwner = (file) async => false;
      final container = await open(tester);
      await tester.tap(find.text(en.recoveryKeyDownloadTxt));
      await tester.pump();
      await settle(tester, () => container.read(notificationCenterProvider).history.isNotEmpty);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.recoveryKitNotPrivate);
      expect(File(path).existsSync(), isFalse, reason: 'never left readable by another account');
      expect(find.text(en.recoveryKitSavedBody), findsNothing);
      expect(find.text(en.recoveryKeyDownloadTxt), findsOneWidget, reason: 'not counted as saved');
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('a save that fails says so with what was thrown to copy', (tester) async {
      FilePicker.platform = _Picker(error: const FileSystemException('The disk is full', 'D:\\demo'));
      final container = await open(tester);
      await tester.tap(find.text(en.recoveryKeyDownloadTxt));
      await tester.pump();
      await settle(tester, () => container.read(notificationCenterProvider).history.isNotEmpty);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.recoveryKitNotSaved);
      expect(notice.details, contains('The disk is full'));
      await tester.pump(const Duration(seconds: 11));
    });
  });

  test('every language says them its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      for (final say in <String Function(AppLocalizations)>[
        (l) => l.recoveryKitNotSaved,
        (l) => l.recoveryKitNotPrinted,
        (l) => l.recoveryKitNotPrivate,
        (l) => l.twoStepCodesNotPrivate,
        (l) => l.twoStepCodesSavedBody,
      ]) {
        expect(say(t), isNotEmpty, reason: '$locale');
        expect(say(t), isNot(say(en)), reason: '$locale');
      }
    }
  });
}
