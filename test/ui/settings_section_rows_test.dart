// The one settings row of a phone's settings pages (3.0):
// what a row does is said in the secondary text under its
// name, a chevron is grey, and rows are divided by a hairline. Found: a list
// tile paints its subtitle with the theme's list text colour wherever one
// is set, so every page's "what it does" line was drawn in the primary text
// colour, whatever the section's style said; and its chevrons took the
// accent.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';

void main() {
  for (final id in ['graphite', 'default_light']) {
    testWidgets('$id: a row says what it does in the secondary text, its chevron grey, a hairline between rows',
        (tester) async {
      final theme = BuiltInThemes.getById(id);
      AppColors.applyTheme(theme.colorScheme);
      await tester.pumpWidget(MaterialApp(
        theme: theme.toThemeData(),
        home: Scaffold(
          body: SettingsSection(
            title: 'Group',
            child: Column(children: [
              ListTile(
                title: const Text('First'),
                subtitle: const Text('What the first does'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () {},
              ),
              SwitchListTile(
                title: const Text('Second'),
                subtitle: const Text('What the second does'),
                value: true,
                onChanged: (_) {},
              ),
            ]),
          ),
        ),
      ));
      Color colorOf(String text) =>
          tester.renderObject<RenderParagraph>(find.descendant(of: find.text(text), matching: find.byType(RichText))).text.style!.color!;
      expect(colorOf('What the first does'), AppColors.textSecondary, reason: 'it was the primary text colour');
      expect(colorOf('What the second does'), AppColors.textSecondary);
      expect(colorOf('First'), isNot(AppColors.textSecondary), reason: 'the name stays the primary text');
      final chevron = tester.widget<RichText>(
          find.descendant(of: find.byIcon(LucideIcons.chevronRight), matching: find.byType(RichText)));
      expect(chevron.text.style!.color, ZestTokens.textTertiary, reason: 'grey, not the accent');
      expect(
          find.descendant(of: find.byKey(const ValueKey('settings-section-card')), matching: find.byType(Divider)),
          findsOneWidget);
    });
  }

  testWidgets('a page of one section has no header of its own', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SettingsSection(title: null, child: ListTile(title: Text('Only')))),
    ));
    expect(find.text('Only'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget, reason: 'no header words');
  });
}
