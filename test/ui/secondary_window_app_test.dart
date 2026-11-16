import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart';

/// The popped-out editor came up as a blank grey window because its
/// MaterialApp carried no localizations and TextEditorScreen builds with
/// `AppLocalizations.of(context)!`. These pin the secondary-window app shape.
void main() {
  testWidgets('the editor builds inside the secondary window app',
      (tester) async {
    // An editor window runs in a ProviderScope of its own (3.4.1,
    // lib/ui/windows/editor_window.dart): the editor reads providers.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: secondaryWindowApp(
        title: 'ZestSSH Editor',
        localeName: 'de',
        home: const TextEditorScreen(
          fileName: 'notes.txt',
          initialContent: 'hello',
          popOutEnabled: false,
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextEditorScreen), findsOneWidget);
    // The main window's locale is applied, and gl10n follows it.
    expect(Localizations.localeOf(tester.element(find.byType(TextEditorScreen))),
        const Locale('de'));
    expect(gl10n.localeName, 'de');
    // Past the code editor's caret start (it waits 100 ms on a phone, which
    // a test is).
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('a null locale follows the system without throwing',
      (tester) async {
    await tester.pumpWidget(secondaryWindowApp(
      title: 't',
      localeName: null,
      home: const Scaffold(body: Text('ok')),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('ok'), findsOneWidget);
  });

  test('locale names round-trip', () {
    expect(localeFromName(null), isNull);
    expect(localeFromName(''), isNull);
    expect(localeFromName('en'), const Locale('en'));
    expect(localeFromName('pt_BR'), const Locale('pt', 'BR'));
    expect(localeFromName('zh-TW'), const Locale('zh', 'TW'));
    expect(
        localeFromName('zh_Hant'),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    expect(
        localeFromName('zh_Hant_TW'),
        const Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'));
  });

  // 3.0: it showed the raw error (which can name a path or a
  // host) and nothing to copy.
  testWidgets('a build error says so in the app\'s words, not a grey box, with its report to copy',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
      home: SecondaryWindowError(
        FlutterErrorDetails(exception: StateError('no delegates at C:/Users/demo/notes.txt')),
      ),
    ));
    expect(find.text(gl10n.mainAppSomethingWentWrong), findsOneWidget);
    expect(find.textContaining('no delegates'), findsNothing, reason: 'the raw error is not shown');
    await tester.tap(find.byKey(const ValueKey('broken-widget-copy')));
    await tester.pump();
    expect(copied, contains('no delegates'));
    expect(copied, isNot(contains('C:/Users/demo')), reason: 'the report is scrubbed');
  });

  // A popped-out window drew the old dark theme whatever the main window
  // showed (found in a code review): it now carries the main window's
  // theme and accent in its payload.
  testWidgets('a window shows the theme and accent its payload carries; the default where it carries none', (tester) async {
    final light = BuiltInThemes.getById('default_light');
    mainWindowTheme = light;
    mainWindowAccent = const Color(0xFF3B82F6);
    final payload = windowThemePayload();
    await tester.pumpWidget(secondaryWindowApp(
      title: 'ZestSSH',
      theme: payload['theme'],
      accent: payload['accent'] as int?,
      home: const SizedBox(),
    ));
    final shown = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
    expect(shown.brightness, Brightness.light);
    expect(shown.colorScheme.primary, const Color(0xFF3B82F6));
    expect(windowThemeFrom(payload['theme']).id, 'default_light');
    expect(windowThemeFrom(null).id, 'graphite');
    expect(windowThemeFrom('nonsense').id, 'graphite');
    mainWindowTheme = null;
    mainWindowAccent = null;
  });
}
