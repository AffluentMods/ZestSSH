import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/generated/app_localizations_en.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/editor_language.dart';
import 'package:zestssh/ui/screens/editor/editor_look.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_minimap.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// The file editor's minimap (3.4): off by
/// default, a switch in the editor's menu on computers, never on phones (nor
/// on a tablet); a click on it scrolls the code; the switch is kept, and a
/// reset of the settings turns it off again. It stays cheap on a file at the
/// size cap.
void main() {
  final en = AppLocalizationsEn();
  final minimap = find.byKey(const ValueKey('editor-minimap'));

  tearDown(() => debugTouchLayout = null);

  String lines(int n) => [for (var i = 1; i <= n; i++) i.isEven ? '  listen $i;' : 'server_name host-$i.example.com;'].join('\n');

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  Future<void> open(WidgetTester tester, SharedPreferences prefs,
      {Size size = const Size(1200, 800), String? text, Key? key}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: key,
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: TextEditorScreen(fileName: 'nginx.conf', initialContent: text ?? lines(40), popOutEnabled: false),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('editor-more')));
    await tester.pumpAndSettle();
  }

  ScrollController scroller(WidgetTester tester) =>
      tester.widget<CodeEditor>(find.byType(CodeEditor)).scrollController!.verticalScroller;

  testWidgets('off by default on a computer, with its switch in the menu, unticked', (tester) async {
    await open(tester, await prefsWith({}));
    expect(minimap, findsNothing);
    await openMenu(tester);
    final item = tester.widget<CheckedPopupMenuItem<String>>(find.byKey(const ValueKey('editor-more-minimap')));
    expect(item.checked, isFalse);
    expect(find.text(en.editorMinimap), findsOneWidget);
  });

  testWidgets('switched on in the menu, it shows at the right of the code, and the choice is kept', (tester) async {
    final prefs = await prefsWith({});
    await open(tester, prefs);
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('editor-more-minimap')));
    await tester.pumpAndSettle();
    expect(minimap, findsOneWidget);
    expect(prefs.getBool('editor_minimap'), isTrue);
    final code = tester.getRect(find.byType(CodeEditor));
    final map = tester.getRect(minimap);
    expect(map.width, EditorMinimap.width);
    expect(map.left, closeTo(code.right, 0.5), reason: 'beside the code, at its right');
    expect(map.right, closeTo(tester.view.physicalSize.width, 0.5));

    // And off again.
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('editor-more-minimap')));
    await tester.pumpAndSettle();
    expect(minimap, findsNothing);
    expect(prefs.getBool('editor_minimap'), isFalse);
  });

  testWidgets('switching it keeps where the code stands', (tester) async {
    final prefs = await prefsWith({});
    await open(tester, prefs, text: lines(400));
    scroller(tester).jumpTo(900);
    await tester.pumpAndSettle();
    final editor = tester.state(find.byType(CodeEditor));
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('editor-more-minimap')));
    await tester.pumpAndSettle();
    expect(minimap, findsOneWidget);
    expect(tester.state(find.byType(CodeEditor)), same(editor), reason: 'the same code editor');
    expect(scroller(tester).offset, 900);
  });

  testWidgets('the choice outlives the screen: open again, it is there', (tester) async {
    final prefs = await prefsWith({});
    await open(tester, prefs);
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('editor-more-minimap')));
    await tester.pumpAndSettle();
    expect(minimap, findsOneWidget);

    // The screen gone, and a new one.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await open(tester, prefs, key: UniqueKey());
    expect(minimap, findsOneWidget);
    await openMenu(tester);
    expect(tester.widget<CheckedPopupMenuItem<String>>(find.byKey(const ValueKey('editor-more-minimap'))).checked, isTrue);
  });

  testWidgets('a reset of the settings turns it off again', (tester) async {
    expect(SettingsService.resetKeys, contains('editor_minimap'));
    final prefs = await prefsWith({'editor_minimap': true});
    await SettingsService(prefs).resetAllToDefaults();
    expect(prefs.containsKey('editor_minimap'), isFalse);
    await open(tester, prefs);
    expect(minimap, findsNothing);
  });

  testWidgets('never on a phone, even switched on', (tester) async {
    await open(tester, await prefsWith({'editor_minimap': true}), size: const Size(400, 800));
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(minimap, findsNothing);
  });

  testWidgets('never on a tablet, even switched on, and its menu has no switch', (tester) async {
    debugTouchLayout = true;
    await open(tester, await prefsWith({'editor_minimap': true}), size: const Size(1100, 800));
    expect(find.byKey(const ValueKey('editor-more')), findsOneWidget, reason: "a tablet wears the computer's layout");
    expect(minimap, findsNothing);
    await openMenu(tester);
    expect(find.byKey(const ValueKey('editor-more-minimap')), findsNothing);
    expect(find.text(en.editorMinimap), findsNothing);
  });

  testWidgets('a click on it scrolls the code there; a drag moves it along', (tester) async {
    await open(tester, await prefsWith({'editor_minimap': true}), text: lines(600));
    expect(minimap, findsOneWidget);
    final s = scroller(tester);
    expect(s.offset, 0);
    expect(s.position.maxScrollExtent, greaterThan(0));
    final map = tester.getRect(minimap);

    // Near the bottom: the code goes to its end.
    await tester.tapAt(Offset(map.center.dx, map.bottom - 10));
    await tester.pumpAndSettle();
    expect(s.offset, greaterThan(s.position.maxScrollExtent * 0.8));

    // Halfway: the code shows its middle.
    await tester.tapAt(map.center);
    await tester.pumpAndSettle();
    final total = s.position.maxScrollExtent + s.position.viewportDimension;
    final middle = s.offset + s.position.viewportDimension / 2;
    expect(middle / total, closeTo(0.5, 0.05));

    // Back to the top.
    await tester.tapAt(Offset(map.center.dx, map.top + 2));
    await tester.pumpAndSettle();
    expect(s.offset, 0);

    // A drag down from the top scrolls the code down with it.
    await tester.dragFrom(Offset(map.center.dx, map.top + 12), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(s.offset, greaterThan(0));

    // The box follows the code.
    final box = tester.widget<CustomPaint>(
        find.descendant(of: minimap, matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MinimapBoxPainter)));
    final painted = (box.painter! as MinimapBoxPainter).painted!;
    final g = MinimapGeometry.of(lineCount: 600, height: map.height, scroller: s);
    expect(painted.top, closeTo(g.boxTop, 0.01));
    expect(painted.top, greaterThan(MinimapGeometry.inset));
  });

  testWidgets('it follows an edit: a line added is drawn', (tester) async {
    await open(tester, await prefsWith({'editor_minimap': true}), text: lines(10));
    MinimapLinesPainter painter() => tester
        .widget<CustomPaint>(find.descendant(
            of: minimap, matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MinimapLinesPainter)))
        .painter! as MinimapLinesPainter;
    expect(painter().paintedRows, 10);
    final c = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    c.text = '${c.text}\nlisten 443 ssl;';
    await tester.pumpAndSettle();
    expect(painter().paintedRows, 11);
  });

  group('drawing', () {
    final look = EditorLook.app(fontSize: 13);

    test('its colours come from the editor look', () {
      final colours = MinimapColours.of(look);
      expect(colours.keyword.withValues(alpha: 1), look.syntax['keyword']!.color!.withValues(alpha: 1));
      expect(colours.comment.withValues(alpha: 1), look.syntax['comment']!.color!.withValues(alpha: 1));
      expect(colours.text.withValues(alpha: 1), AppColors.v3TextPrimary.withValues(alpha: 1));
    });

    test('every line while they fit; a sample of them, one per pixel, when they do not', () {
      final few = MinimapGeometry.of(lineCount: 100, height: 800);
      expect(few.rows, 100);
      expect(few.rowHeight, MinimapGeometry.fullRow);
      final many = MinimapGeometry.of(lineCount: 100000, height: 800);
      expect(many.rows, 800 - MinimapGeometry.inset * 2);
      expect(many.drawnHeight, closeTo(800 - MinimapGeometry.inset * 2, 0.001));
      expect(many.lineOfRow(many.rows - 1, 100000), lessThan(100000));
      expect(many.lineOfRow(0, 100000), 0);
    });

    test('a file at the size cap draws only what fits, and quickly', () {
      // 4 MB of nginx lines.
      final buffer = StringBuffer();
      var i = 0;
      while (buffer.length < kMaxInlineEditBytes) {
        buffer.writeln(i.isEven ? '    proxy_set_header X-Real-IP \$remote_addr; # $i' : 'location /static/$i { root "/srv/www"; }');
        i++;
      }
      final codeLines = CodeLines.fromText(buffer.toString());
      expect(codeLines.length, greaterThan(50000));
      final painter = MinimapLinesPainter(
        lines: ValueNotifier(codeLines),
        colours: MinimapColours.of(look),
        comments: MinimapComments.of(EditorLanguage.nginx),
      );
      final recorder = ui.PictureRecorder();
      final watch = Stopwatch()..start();
      painter.paint(Canvas(recorder), const Size(EditorMinimap.width, 900));
      watch.stop();
      recorder.endRecording().dispose();
      expect(painter.paintedRows, 900 - MinimapGeometry.inset * 2);
      expect(watch.elapsedMilliseconds, lessThan(250), reason: 'one paint of the whole file took ${watch.elapsedMilliseconds} ms');
    });
  });
}
