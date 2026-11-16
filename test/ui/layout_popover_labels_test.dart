import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';

/// The names under the pictures of the Layout popover are read whole: none
/// is cut off, in any language the app's own font writes. (The test font
/// draws every letter as a square as wide as the text is high, so this is
/// measured with the font the app ships.)
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _loadGeistSans() async {
  final loader = FontLoader('GeistSans');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/GeistSans-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load().timeout(const Duration(seconds: 30));
}

void main() {
  /// Whether the app's font writes [text] itself: what it has no letters for
  /// falls to the test font, whose every letter is as wide as the text is
  /// high.
  bool written(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final squares = text.runes.length * (style.fontSize ?? 14);
    return (painter.width - squares).abs() > 0.5;
  }

  testWidgets('no name of an arrangement is cut off', (tester) async {
    await tester.runAsync(_loadGeistSans);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final judged = <String>{};
    final cut = <String>[];
    for (final locale in AppLocalizations.supportedLocales) {
      // One terminal, three and five: between them every arrangement is shown.
      for (final (terminals, pro) in [(1, true), (3, true), (5, true), (3, false)]) {
        await tester.pumpWidget(const SizedBox.shrink());
        final container = ProviderContainer(overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          isProProvider.overrideWith((ref) => _Pro(pro)),
          dangerousCommandProtectionProvider.overrideWith((ref) => true),
        ]);
        addTearDown(container.dispose);
        final tabs = container.read(workTabsProvider.notifier);
        final tab = tabs.createTab('s1');
        tabs.replaceTabTree(tab, tilePanes([for (var i = 1; i <= terminals; i++) PaneLeaf.single(sessionId: 's$i')]));
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: LayoutPopover.width,
                  child: SingleChildScrollView(child: LayoutPopover(onApply: (_) {})),
                ),
              ),
            ),
          ),
        ));
        await tester.pump();

        final cards = find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('layout-'));
        final names = find.descendant(of: cards, matching: find.byType(Text));
        expect(names, findsWidgets);
        for (final element in names.evaluate()) {
          final text = (element.widget as Text).data!;
          final paragraph = element.renderObject! as RenderParagraph;
          final style = paragraph.text.style!;
          if (!written(text, style)) continue;
          judged.add('$locale');
          if (paragraph.getMaxIntrinsicWidth(double.infinity) > paragraph.size.width + 0.5) {
            cut.add('$locale "$text" as it is shown');
          }
          // As the arrangement the tab stands in: its name is in heavier
          // letters, inside a border that is a little thicker.
          final marked = TextPainter(
            text: TextSpan(text: text, style: style.copyWith(fontWeight: FontWeight.w600)),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          final room = tester.getSize(find.ancestor(of: find.byWidget(element.widget), matching: cards).first).width;
          // (The card's padding, and the border of a marked one.)
          final forName = room - 8 - 2 * 1.4;
          final locked = find.descendant(
            of: find.ancestor(of: find.byWidget(element.widget), matching: cards).first,
            matching: find.byType(Icon),
          );
          if (locked.evaluate().isEmpty && marked.width > forName + 0.5) {
            cut.add('$locale "$text" when marked: ${marked.width.toStringAsFixed(1)} in ${forName.toStringAsFixed(1)}');
          }
        }
      }
    }
    expect(cut.toSet(), isEmpty);
    // Guards the test itself: with the font not loaded nothing would be judged.
    expect(judged, containsAll(['en', 'de', 'es', 'fr', 'it', 'pt', 'ru']));
  });
}
