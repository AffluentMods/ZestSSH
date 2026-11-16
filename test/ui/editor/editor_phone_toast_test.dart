import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import '../../helpers/code_editor_text.dart';
import '../../visual/shots_util.dart';

/// The app's messages over the editor on a phone (so that
/// they never cover Done). A message
/// stands at the top of a phone's screen, where the editor's own bar holds
/// close and, while typing, Done: over the editor it stands below that bar,
/// so close, Done, the keys row and the bottom bar can always be tapped.
/// Anywhere else it still stands at the top.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  // Measured in the app's own fonts (the test font's letters are boxes).
  setUpAll(loadShotFonts);
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  /// A phone 390 by 844 whose status bar takes 47 and navigation bar 34.
  Future<void> phone(WidgetTester tester, Widget home) async {
    SharedPreferences.setMockInitialValues({});
    final saved = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(saved)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: BuiltInThemes.getById('graphite').toThemeData(),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget editor() => TextEditorScreen(
        fileName: 'config.yaml',
        hostLabel: 'web-01',
        filePath: '/home/deploy/app/config.yaml',
        initialContent: 'app:\n  name: shop\n',
        onSave: (_) async {},
        popOutEnabled: false,
      );

  Rect toastOf(WidgetTester tester, String message) =>
      tester.getRect(find.ancestor(of: find.text(message), matching: find.byType(Dismissible)));

  Rect rectOf(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

  void staysClear(Rect toast, Rect control, String name) {
    expect(toast.overlaps(control), isFalse, reason: 'the message ($toast) covers $name ($control)');
  }

  Future<void> letItGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
  }

  testWidgets('the Saved message stands below the editor\'s bar, clear of close and the bottom bar', (tester) async {
    await phone(tester, editor());
    editorCode(tester).text = 'app:\n  name: store\n';
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-phone-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final toast = toastOf(tester, en.editorSaved('config.yaml'));
    final top = rectOf(tester, 'editor-phone-top');
    expect(toast.top, greaterThanOrEqualTo(top.bottom));
    staysClear(toast, rectOf(tester, 'editor-close'), 'close');
    staysClear(toast, rectOf(tester, 'editor-phone-bar'), 'the bottom bar');
    await letItGo(tester);
  });

  testWidgets('while typing, an error with Copy details stays clear of Done and the keys row', (tester) async {
    await phone(tester, editor());
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-phone-done')), findsOneWidget);
    const message = 'The file was not saved: the connection to web-01 closed while it was being written. '
        'Your changes are still here; try again once the host is back.';
    showTopSnackBar(tester.element(find.byType(CodeEditor)), message, isError: true, details: 'SocketException');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final toast = toastOf(tester, message);
    expect(tester.getSize(find.text('Done')).width, lessThan(50), reason: 'the app font is not loaded');
    expect(toast.top, greaterThanOrEqualTo(rectOf(tester, 'editor-phone-top').bottom));
    staysClear(toast, rectOf(tester, 'editor-phone-done'), 'Done');
    staysClear(toast, rectOf(tester, 'editor-close'), 'close');
    staysClear(toast, rectOf(tester, 'editor-keys-row'), 'the keys row');
    // Done still takes a tap with the message up.
    await tester.tap(find.byKey(const ValueKey('editor-phone-done')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    await letItGo(tester);
  });

  testWidgets('once the editor is closed, a message stands at the top again, below the status bar', (tester) async {
    await phone(tester, editor());
    await phone(tester, Builder(builder: (context) => const Scaffold(body: SizedBox.expand())));
    showTopSnackBar(tester.element(find.byType(Scaffold)), 'Copied');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(toastOf(tester, 'Copied').top, moreOrLessEquals(47 + 8, epsilon: 0.5));
    await letItGo(tester);
  });
}
