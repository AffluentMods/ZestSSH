import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/ssh_config_export.dart';

/// A file picker that answers with [path] (null: cancelled).
class _Picker extends FilePicker {
  _Picker(this.path);

  final String? path;
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
    return path;
  }
}

/// "Connections as SSH config" (3.0): written twice,
/// always left in the documents folder, and a file that could not be written
/// ended the export with nothing said.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late Directory tmp;
  late SharedPreferences prefs;
  final at = DateTime(2026, 10, 3);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('zest_ssh_config_');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('one Host block for each, with its address and port', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (id, label, host, port) in [('a', 'web 01', '10.50.0.11', 22), ('b', 'db-01', '10.50.0.12', 2222)]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            port: Value(port),
            createdAt: at,
            updatedAt: at,
          ));
    }
    final text = buildSshConfig(await db.connectionsDao.getAll(), at);
    expect(text, startsWith('# Exported from ZestSSH\n# 2026-10-03T00:00:00.000\n\n'));
    expect(text, contains('Host web_01\n  HostName 10.50.0.11\n  Port 22\n\n'));
    expect(text, contains('Host db-01\n  HostName 10.50.0.12\n  Port 2222\n\n'));
  });

  group('on a computer', () {
    Future<ProviderContainer> open(WidgetTester tester, {List<(String, String)> hosts = const [('web 01', '10.50.0.11')]}) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() async {
        for (var i = 0; i < hosts.length; i++) {
          await db.into(db.connections).insert(ConnectionsCompanion.insert(
                id: 'c$i',
                label: hosts[i].$1,
                host: hosts[i].$2,
                port: const Value(22),
                createdAt: at,
                updatedAt: at,
              ));
        }
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
          treeDatabaseProvider.overrideWithValue(db),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => exportSshConfig(context, ref),
                child: const Text('export'),
              ),
            ),
          ),
        ),
      ));
      return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    }

    Future<void> run(WidgetTester tester, bool Function() done) async {
      await tester.tap(find.text('export'));
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    testWidgets('it goes where the person chooses, and where it went is shown', (tester) async {
      final path = '${tmp.path}${Platform.pathSeparator}$sshConfigFileName';
      FilePicker.platform = _Picker(path);
      await open(tester);
      await run(tester, () => find.text(en.sshConfigSavedBody).evaluate().isNotEmpty);
      expect(find.text(en.sshConfigSavedBody), findsOneWidget);
      // A computer's title: the file is saved, nothing is left to choose (it
      // said "choose where to send it", the phone's words before its share
      // sheet).
      expect(find.text(en.sshConfigSavedTitle(1)), findsOneWidget);
      expect(find.text(en.settingsMobExportedConnections(1)), findsNothing);
      expect(find.textContaining('choose where to send it'), findsNothing);
      expect(find.text(path), findsOneWidget);
      expect(File(path).readAsStringSync(), contains('Host web_01\n  HostName 10.50.0.11\n  Port 22\n'));
      expect(tmp.listSync().whereType<File>().map((f) => f.path), [path], reason: 'nothing else left behind');
    });

    testWidgets('a file that cannot be written says so, with what was thrown', (tester) async {
      final blocker = File('${tmp.path}${Platform.pathSeparator}blockerxq')..writeAsStringSync('demo');
      FilePicker.platform = _Picker('${blocker.path}${Platform.pathSeparator}$sshConfigFileName');
      final c = await open(tester);
      await run(tester, () => c.read(notificationCenterProvider).history.isNotEmpty);
      final notice = c.read(notificationCenterProvider).history.first;
      expect(notice.title, en.sshConfigNotSaved);
      expect(notice.details, contains('OS Error'));
      expect(notice.details, isNot(contains('blockerxq')), reason: 'a report names no folder');
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('cancelled, nothing is written or said', (tester) async {
      final picker = _Picker(null);
      FilePicker.platform = picker;
      final c = await open(tester);
      await run(tester, () => picker.asked > 0);
      await tester.pump();
      expect(picker.asked, 1);
      expect(c.read(notificationCenterProvider).history, isEmpty);
      expect(tmp.listSync(), isEmpty);
    });

    testWidgets('no connections, says so and asks nothing', (tester) async {
      final picker = _Picker('${tmp.path}${Platform.pathSeparator}$sshConfigFileName');
      FilePicker.platform = picker;
      final c = await open(tester, hosts: const []);
      await run(tester, () => c.read(notificationCenterProvider).history.isNotEmpty);
      expect(c.read(notificationCenterProvider).history.first.title, en.settingsNoConnectionsToExport);
      expect(picker.asked, 0);
      await tester.pump(const Duration(seconds: 8));
    });
  });

  test('a phone shares it from a folder of its own, deleted after; both screens use the one export', () {
    final source = File('lib/ui/screens/settings/ssh_config_export.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(source, contains('.createTemp(ConnectionShareService.shareFolderPrefix)'));
    expect(source, contains('    } finally {\n      await ConnectionShareService.removeAfterShare(path);\n    }'));
    expect(source, contains('      if (path != null) await ConnectionShareService.removeShareFile(path);\n'));
    for (final rel in ['lib/ui/screens/settings/settings_screen.dart', 'lib/ui/screens/settings/data_settings_screen.dart']) {
      final screen = File(rel).readAsStringSync();
      expect(screen, contains('exportSshConfig(context, ref);'), reason: rel);
      expect(screen, isNot(contains('_exportSshConfig')), reason: rel);
      expect(screen, isNot(contains('zestssh_connections.config')), reason: '$rel: its own copy');
    }
  });

  test('every language says them its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      expect(t.sshConfigNotSaved, isNot(en.sshConfigNotSaved), reason: '$locale');
      expect(t.sshConfigSavedBody, isNot(en.sshConfigSavedBody), reason: '$locale');
      expect(t.sshConfigSavedTitle(3), isNot(en.sshConfigSavedTitle(3)), reason: '$locale');
    }
  });
}
