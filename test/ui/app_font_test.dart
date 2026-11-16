import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

import '../helpers/dart_calls.dart';

/// The app's words in the app's font (3.0). A dropdown
/// given a style draws the value it shows in that style alone, not added to
/// the page's, so one whose style named no font family drew in the system's
/// (Roboto, Segoe UI, San Francisco) where every other word is in GeistSans:
/// twenty of them, the host editor's six among them, a network's, the
/// Orchards' roles and invites, a workflow's steps, a trigger's, Settings'
/// and the Monitor's thresholds; and the recording card of a computer's pill
/// bar, by a text style set over it the same way. And a part of a page drawn
/// with a RichText takes neither the page's font nor the person's text size:
/// the automation guide's parameters and troubleshooting, a port forward's
/// explanation and a dangerous command's preview were in the system's font,
/// at the size the app is drawn at whatever the person's (Text.rich takes
/// both).
void main() {
  final dropdown = RegExp(r'\b(DropdownButton|DropdownButtonFormField)\s*(<[^>(]*(?:<[^>]*>)?[^>(]*>)?\s*\(');
  final textStyleOver = RegExp(r'\bDefaultTextStyle\(');
  final name = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  /// Whether a style expression in [text] names a font family or takes the
  /// theme's, itself or where its name is set in the file.
  bool hasFont(String text, String style) {
    bool says(String s) => s.contains('fontFamily') || s.contains('Theme.of(');
    if (says(style)) return true;
    if (!name.hasMatch(style)) return false;
    final set = RegExp('\\b${RegExp.escape(style)}\\s*=').firstMatch(text);
    if (set == null) return false;
    final end = text.indexOf(';', set.end);
    return says(text.substring(set.end, end < 0 ? text.length : end));
  }

  /// "file:line" of each dropdown in [files] given a style without the font,
  /// and of each DefaultTextStyle given a TextStyle without it.
  List<String> withoutTheFont(Map<String, String> files) {
    final found = <String>[];
    for (final MapEntry(key: path, value: text) in files.entries) {
      for (final call in callsIn(text, dropdown)) {
        final style = namedArg(call.args, 'style');
        if (style != null && !hasFont(text, style)) found.add('$path:${call.line}');
      }
      for (final call in callsIn(text, textStyleOver)) {
        final style = namedArg(call.args, 'style');
        if (style != null && RegExp(r'^(const\s+)?TextStyle\(').hasMatch(style) && !hasFont(text, style)) {
          found.add('$path:${call.line}');
        }
      }
    }
    return found..sort();
  }

  test("every dropdown given a style, and every text style set over a part of a page, names the app's font or takes "
      "the theme's", () {
    final files = {
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && !file.path.replaceAll('\\', '/').contains('/generated/'))
          file.path.replaceAll('\\', '/'): file.readAsStringSync(),
    };
    expect(files.length, greaterThan(500));
    expect(withoutTheFont(files), isEmpty, reason: "fontFamily: 'GeistSans', or the theme's text style");
  });

  test("no part of a page is drawn with a RichText, which takes neither the page's font nor the person's text size",
      () {
    final richText = RegExp(r'\bRichText\s*\(');
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      for (final call in callsIn(file.readAsStringSync(), richText)) {
        found.add('$path:${call.line}');
      }
    }
    expect(found, isEmpty, reason: 'Text.rich(TextSpan(...)) in its place');
    expect(callsIn('// RichText(text: x)\nfinal y = RichText(text: TextSpan());', richText).map((c) => c.line), [2],
        reason: 'the check finds one where it is written, past comments');
  });

  test('the check finds them where they are written, past comments and strings, and not where the font is named', () {
    expect(
      withoutTheFont({
        'a.dart': "DropdownButton<int>(\n  // it's the value's style\n  style: TextStyle(fontSize: 13),\n  items: [],\n)",
        'b.dart': 'x\nDefaultTextStyle(style: const TextStyle(fontSize: 13), child: y)',
        'c.dart': "final s = TextStyle(fontSize: 13);\nDropdownButtonFormField<String?>(style: s, items: ['(', ')'])",
      }),
      ['a.dart:1', 'b.dart:2', 'c.dart:2'],
    );
    expect(
      withoutTheFont({
        'd.dart': "final s = TextStyle(fontFamily: 'GeistSans');\nDropdownButton(style: s, items: [])",
        'e.dart': 'DropdownButton(style: Theme.of(context).textTheme.bodyMedium, items: [])',
        'f.dart': 'DefaultTextStyle.merge(style: TextStyle(fontSize: 13), child: x)',
        'g.dart': "// DropdownButton(style: TextStyle(fontSize: 13))\nfinal t = 'DropdownButton(style: TextStyle())';",
        'h.dart': 'DropdownButton(items: [], onChanged: null)',
      }),
      isEmpty,
    );
  });

  testWidgets("the host editor's choices show their value in the app's font", (tester) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    ConnectionEditScreen.debugDesktopShell = false;
    addTearDown(() => ConnectionEditScreen.debugDesktopShell = null);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(theme.colorScheme);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 17);
    await tester.runAsync(() => db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'c1', label: 'web-01', host: '192.168.10.21', port: const Value(22), createdAt: now, updatedAt: now)));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const ConnectionEditScreen(connectionId: 'c1'),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    final en = lookupAppLocalizations(const Locale('en'));
    // A phone's form: the advanced options open from their row.
    await tester.ensureVisible(find.byKey(const ValueKey('host-form-advanced')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('host-form-advanced')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final chosen = tester.renderObject<RenderParagraph>(find.text(en.connectionEditKeepAliveGlobal));
    expect(chosen.text.style?.fontFamily, 'GeistSans', reason: "the keepalive's chosen value");
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });
}
