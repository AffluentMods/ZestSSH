import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/prometheus_secure_settings.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/monitoring/prometheus_config_sheet.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../visual/shots_util.dart';

/// A file the person picks, counted.
class _Picker extends FilePicker {
  _Picker(this.path);

  final String path;
  var asked = 0;

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
    asked++;
    return FilePickerResult([PlatformFile(path: path, name: 'ca.pem', size: 0)]);
  }
}

/// A Prometheus connection's own certificate authority comes from a file or
/// is pasted, and the question that asks which is the app's own dialog (3.0):
/// it was a plain Material one, the last of that shape in
/// the app. Its first answer opens a file, its other asks for the text, and
/// closed without either it asks for nothing and keeps nothing.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const pem = '-----BEGIN CERTIFICATE-----\nMIIBfakeCAfortests\n-----END CERTIFICATE-----';
  late Directory dir;
  late _Picker picker;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zest_prom_ca_');
    final file = File('${dir.path}${Platform.pathSeparator}ca.pem')..writeAsStringSync('$pem\n');
    picker = _Picker(file.path);
    FilePicker.platform = picker;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// The sheet with its TLS settings unfolded, on a computer's window or a
  /// phone's screen; and where the certificate is kept.
  Future<PrometheusSecureSettings> pump(WidgetTester tester, {bool phone = false}) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secure = PrometheusSecureSettings(const FlutterSecureStorage());
    tester.view.physicalSize = phone ? const Size(400, 860) : const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        prometheusSecureSettingsProvider.overrideWithValue(secure),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: PrometheusConfigSheet()),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(en.monitorPrometheusTlsSettings));
    await tester.tap(find.text(en.monitorPrometheusTlsSettings));
    await tester.pumpAndSettle();
    return secure;
  }

  // The Custom DNS server field was saved and
  // never used; it is gone.
  testWidgets('it asks for no DNS server', (tester) async {
    await pump(tester);
    expect(find.byIcon(LucideIcons.server), findsNothing);
    expect(find.textContaining('DNS'), findsNothing);
  });

  Future<void> ask(WidgetTester tester) async {
    final import = find.text(en.monitorPrometheusCaCertImport);
    await tester.ensureVisible(import);
    await tester.tap(import);
    await tester.pumpAndSettle();
  }

  Finder answer(String label) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(label));

  Future<String?> kept(WidgetTester tester, PrometheusSecureSettings secure) async =>
      tester.runAsync<String?>(secure.getCaPem);

  testWidgets("the question is the app's own, with a file as its first answer and a paste as its other",
      (tester) async {
    await pump(tester);
    await ask(tester);
    final question = tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog));
    expect(find.byType(AlertDialog), findsNothing);
    expect(question.title, en.monitorPrometheusCaCert);
    expect(question.body, en.monitorPrometheusCaCertDesc);
    expect(answer(en.monitorPrometheusCaCertImport), findsOneWidget);
    expect(answer(en.monitorPrometheusCaCertPaste), findsOneWidget);
  });

  testWidgets('Paste asks for the text and keeps it without the space around it', (tester) async {
    final secure = await pump(tester);
    await ask(tester);
    await tester.tap(answer(en.monitorPrometheusCaCertPaste));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    // The shell's dialog, its field of several lines (the dialog rules, 3.4).
    final field = find.byKey(const ValueKey('prometheus-ca-paste'));
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: field), findsOneWidget);
    await tester.enterText(field, '  $pem\n\n');
    // The paste's own Save (the settings are the shell too, with theirs).
    await tester.tap(find.descendant(
        of: find.ancestor(of: field, matching: find.byType(ZestDialogShell)).first, matching: find.text(en.save)));
    await tester.pumpAndSettle();
    expect(await kept(tester, secure), pem);
    expect(picker.asked, 0, reason: 'a paste opens no file');
    expect(find.text(en.monitorPrometheusCaCertLoaded), findsOneWidget);
  });

  testWidgets('a file: what it holds is kept', (tester) async {
    final secure = await pump(tester);
    await ask(tester);
    await tester.tap(answer(en.monitorPrometheusCaCertImport));
    // The file is read from the disk, a step at a time.
    final loaded = find.text(en.monitorPrometheusCaCertLoaded);
    for (var i = 0; i < 100 && loaded.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(picker.asked, 1);
    expect(find.byKey(const ValueKey('prometheus-ca-paste')), findsNothing, reason: 'a file asks for no text');
    expect(await kept(tester, secure), '$pem\n');
    expect(find.text(en.monitorPrometheusCaCertLoaded), findsOneWidget);
  });

  testWidgets('closed without an answer: no file, no text asked for, nothing kept', (tester) async {
    final secure = await pump(tester);
    await ask(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(find.byKey(const ValueKey('prometheus-ca-paste')), findsNothing);
    expect(picker.asked, 0);
    expect(await kept(tester, secure), isNull);
    expect(find.text(en.monitorPrometheusCaCertLoaded), findsNothing);
  });

  testWidgets('on a phone the question is a sheet with the same answers, and Paste asks for the text',
      (tester) async {
    await pump(tester, phone: true);
    await ask(tester);
    expect(answer(en.monitorPrometheusCaCertImport), findsOneWidget);
    await tester.tap(answer(en.monitorPrometheusCaCertPaste));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.byKey(const ValueKey('prometheus-ca-paste'))),
        findsOneWidget);
  });
}
