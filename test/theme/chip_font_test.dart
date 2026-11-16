import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

/// A chip's label is drawn in the app's own font, in every theme. A chip
/// does not take its font from the text theme: with none named for it, its
/// label was drawn in whatever the system's default font is, beside text in
/// the app's.

void main() {
  /// The style text gets inside a chip, a button and plain, under [theme].
  Future<({TextStyle chip, TextStyle choice, TextStyle button, TextStyle plain})> styles(
      WidgetTester tester, ThemeData theme) async {
    late TextStyle chip, choice, button, plain;
    Widget probe(void Function(TextStyle) note) => Builder(builder: (context) {
          note(DefaultTextStyle.of(context).style);
          return const Text('x');
        });
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Column(
          children: [
            probe((s) => plain = s),
            Chip(label: probe((s) => chip = s)),
            ChoiceChip(label: probe((s) => choice = s), selected: true, onSelected: (_) {}),
            FilledButton(onPressed: () {}, child: probe((s) => button = s)),
          ],
        ),
      ),
    ));
    return (chip: chip, choice: choice, button: button, plain: plain);
  }

  testWidgets("every theme draws a chip's label in the app's font, as it does everything else", (tester) async {
    for (final theme in BuiltInThemes.all) {
      final s = await styles(tester, theme.toThemeData());
      expect(s.plain.fontFamily, 'GeistSans', reason: theme.id);
      expect(s.button.fontFamily, 'GeistSans', reason: theme.id);
      expect(s.chip.fontFamily, 'GeistSans', reason: '${theme.id}: a chip');
      expect(s.choice.fontFamily, 'GeistSans', reason: '${theme.id}: a chip that is picked');
      // Its colour is still the theme's, whatever the font.
      expect(s.chip.color, isNotNull, reason: theme.id);
    }
    final legacy = await styles(tester, AppTheme.dark());
    expect((legacy.chip.fontFamily, legacy.choice.fontFamily), ('GeistSans', 'GeistSans'));
  });
}
