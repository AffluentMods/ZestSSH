import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart' show kCsvMaxBytes;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker extends FilePicker {
  _Picker(this.path);

  final String path;
  bool? askedForData;

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
  }) async {
    askedForData = withData;
    return FilePickerResult([PlatformFile(path: path, name: 'picked.json', size: 0)]);
  }
}

/// A file chosen to import can be anything, of any size: a theme's and a snippets
/// file were read whole, on the screen's thread (a security audit, 30 October
/// 2026), where every other import stops at a size and says so.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late Directory dir;

  setUp(() async {
    debugTopSnackBarOnPhone = true;
    dir = await Directory.systemTemp.createTemp('zest_caps_');
  });
  tearDown(() async {
    debugTopSnackBarOnPhone = null;
    await dir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<_Picker> chosen(int bytes) async {
    final file = File('${dir.path}/picked.json')..writeAsBytesSync(List<int>.filled(bytes, 0x20));
    final picker = _Picker(file.path);
    FilePicker.platform = picker;
    return picker;
  }

  Future<ProviderContainer> app(WidgetTester tester, Widget screen, AppDatabase? db) async {
    tester.view.physicalSize = const Size(420, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan()),
      if (db != null) databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => screen)]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await settle(tester);
    return container;
  }

  testWidgets('a theme file over 1 MB is not read: it is said to be too large', (tester) async {
    await tester.runAsync(() => chosen(kMaxThemeFileBytes + 1));
    await app(tester, const AppearanceScreen(), null);
    await tester.ensureVisible(find.text(l10n.appearanceImportTheme));
    await tester.pump();
    await tester.tap(find.text(l10n.appearanceImportTheme));
    await settle(tester);
    expect(find.text(l10n.csvImpTooLarge(1)), findsOneWidget);
  });

  testWidgets('a snippets file over the size any import takes is not read: it is said to be too large', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final picker = (await tester.runAsync(() => chosen(kCsvMaxBytes + 1)))!;
    await app(tester, const SnippetsScreen(), db);
    await tester.tap(find.byKey(const ValueKey('snippets-menu')));
    await settle(tester);
    await tester.tap(find.text(l10n.snippetsImportSnippets));
    final said = find.text(l10n.csvImpTooLarge(kCsvMaxBytes ~/ (1024 * 1024)));
    for (var i = 0; i < 40 && said.evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(said, findsOneWidget);
    expect(picker.askedForData, isFalse, reason: 'the picker does not read it whole first');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
