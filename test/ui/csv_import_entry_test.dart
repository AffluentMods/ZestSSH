import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_view.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The ways into the CSV import (3.0): Import hosts' "CSV file" source and
/// the phone's Import data sheet (a computer's command palette has it too:
/// test/visual/shell_shots_test.dart). What it imported is said as an
/// import is.

final l10n = lookupAppLocalizations(const Locale('en'));

class _Picker extends FilePicker {
  _Picker(this.path);

  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([PlatformFile(path: path, name: 'picked', size: 0)]);
}

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // The message as a phone shows it, on screen.
    debugTopSnackBarOnPhone = true;
  });

  tearDown(() async {
    debugTopSnackBarOnPhone = null;
    await db.close();
  });

  /// The app's router with [home] as its only page.
  Future<void> pumpApp(WidgetTester tester, Widget Function(BuildContext, WidgetRef) home) async {
    tester.view.physicalSize = const Size(1400, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'host,user\nweb-01.example.com,deploy\n'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => Scaffold(body: Consumer(builder: (c, ref, _) => home(c, ref)))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Pastes the host on the clipboard into the CSV import open now, imports
  /// it, and checks what is said and written.
  Future<void> pasteAndImport(WidgetTester tester) async {
    expect(find.byType(CsvImportDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('csv-paste')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.cloudImpImportN(1)));
    await tester.pumpAndSettle();
    expect(find.byType(CsvImportDialog), findsNothing);
    expect(find.text(l10n.cloudImpDone(l10n.csvImpPasted, 1)), findsOneWidget);
    expect([for (final c in await db.connectionsDao.getAll()) c.host], ['web-01.example.com']);
    // (The message goes by itself.)
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  testWidgets('Import hosts: the CSV file source opens the CSV import, and what it imported is said', (tester) async {
    await pumpApp(tester, (context, ref) => TextButton(onPressed: () => openImportHosts(context), child: const Text('go')));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.cloudImpCsvDesc), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-source-csv')));
    await tester.pumpAndSettle();
    await pasteAndImport(tester);
  });

  testWidgets("the phone's Import data sheet offers a CSV file, which opens the CSV import", (tester) async {
    await pumpApp(tester, (context, ref) => const DataSettingsScreen());
    // What it does is behind its More (4.0).
    expect(find.text(l10n.settingsMobImportDataDesc), findsNothing);
    await tester.tap(find.byKey(ValueKey('settings-row-more-${l10n.settingsMobImportData}')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsMobImportDataDesc), findsOneWidget);
    await tester.tap(find.text(l10n.settingsMobImportData));
    await tester.pumpAndSettle();
    final csv = find.byKey(const ValueKey('import-data-csv'));
    expect(find.descendant(of: csv, matching: find.text(l10n.cloudImpCsv)), findsOneWidget);
    await tester.tap(csv);
    await tester.pumpAndSettle();
    await pasteAndImport(tester);
  });

  testWidgets("the phone's Import data sheet has Import a file first: it asks which file, and says what it is", (tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('zest_import_sheet_')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}northwind.zest';
    File(path).writeAsBytesSync([...'ZEST'.codeUnits, 3, 1, 2, 3]);
    FilePicker.platform = _Picker(path);
    await pumpApp(tester, (context, ref) => const DataSettingsScreen());
    await tester.tap(find.text(l10n.settingsMobImportData));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('import-data-file'));
    expect(find.descendant(of: row, matching: find.text(l10n.importFileAction)), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(l10n.importFileDesc)), findsOneWidget);
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.text(l10n.settingsMobRestoreFromBackup)).dy));
    await tester.tap(row);
    // The file is read off the test's clock.
    for (var i = 0; i < 200 && find.byKey(const ValueKey('import-found')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text(l10n.importFoundBackup), findsOneWidget);
    expect(find.text('northwind.zest'), findsOneWidget);
  });

  testWidgets("a computer's Settings has it in its Import data sheet too", (tester) async {
    await pumpApp(tester, (context, ref) => const SettingsScreen());
    await tester.ensureVisible(find.text(l10n.settingsMobImportData));
    await tester.tap(find.text(l10n.settingsMobImportData));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-data-csv')));
    await tester.pumpAndSettle();
    await pasteAndImport(tester);
  });
}
