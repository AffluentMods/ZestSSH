import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/main.dart' as app;
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

/// A text editor popped out into a window of its own (3.4.1). On 3.4.0 the
/// window drew "Something went wrong" where it named the file's host: the
/// editor's widgets read providers (the host's name reads recording mode)
/// and the window, an engine of its own, had no ProviderScope, so each of
/// them threw "No ProviderScope found" as it was built (the tab, the toolbar
/// and the status bar), and the window's error widget took its place. The
/// window is started here as desktop_multi_window starts it: the app's main
/// with "multi_window", its id and what the main window handed it.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const events = MethodChannel('mixin.one/flutter_multi_window_channel');

  testWidgets('a popped-out editor builds as the app starts it, naming its host, with no "Something went wrong"',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final errorWidget = ErrorWidget.builder;
    addTearDown(() => ErrorWidget.builder = errorWidget);
    // What the main window answers the window's first call with: the file's
    // tab, its text in it.
    const text = 'user www-data;\n';
    final tab = {
      'v': 1,
      'editKey': 'k1',
      'fileName': 'nginx.conf',
      'path': '/etc/nginx/nginx.conf',
      'hostLabel': 'web-01',
      'identity': 'host\u0000\u0000id-web-01\u0000\u0000/etc/nginx/nginx.conf',
      'hostKey': 'host\u0000\u0000id-web-01\u0000',
      'team': null,
      'hostKnown': true,
      'savedText': text,
      'text': text,
      'encoding': 'utf8',
      'lineBreak': 'lf',
      'language': 'nginx',
      'indentTabs': false,
      'indentSize': 4,
      'canSave': true,
      'canReload': true,
    };
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(events, (call) async {
      switch (call.method) {
        case 'editorInit':
          return jsonEncode(tab);
        case 'appLockState':
          return '0';
      }
      return '';
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null));
    app.main([
      'multi_window',
      '2',
      jsonEncode({
        'type': 'editor',
        'editKey': 'k1',
        'number': 2,
        'fileName': 'nginx.conf',
        'filePath': '/etc/nginx/nginx.conf',
        'hostLabel': 'web-01',
        'canSave': true,
        'canReload': true,
        'locale': 'en',
      }),
    ]);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text(en.mainAppSomethingWentWrong), findsNothing);
    expect(find.byType(TextEditorScreen), findsOneWidget);
    expect(find.text('web-01'), findsWidgets, reason: 'its host named on its tab, toolbar and status bar');
    expect(find.text('nginx.conf'), findsWidgets);
    // The window's start sets how a build failure is drawn: put back. Its
    // tree is the app's own, taken down here (the code's caret let go first,
    // as its blinking outlives it).
    ErrorWidget.builder = errorWidget;
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
  });
}
