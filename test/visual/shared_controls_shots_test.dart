import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

import 'shots_util.dart';

/// Pictures of the shared controls (fields, buttons, switches, a hovered row)
/// in Ember, Graphite and Daylight, on a computer and on a phone, with the
/// real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/shared_controls_shots_test.dart
///
/// Pictures land in build/shots/controls-*.png. Everything on them is made up.
const _shots = shotsEnabled;

final _computer = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

class _Gallery extends StatelessWidget {
  const _Gallery({required this.filled, required this.notes, required this.focusSwitch});

  final TextEditingController filled;
  final TextEditingController notes;
  final FocusNode focusSwitch;

  @override
  Widget build(BuildContext context) {
    Widget label(String s) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(s, style: TextStyle(fontSize: 11, color: ZestTokens.textMuted)),
        );
    Widget row(String s, {bool hovered = false}) => Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          color: hovered ? ZestTokens.surfaceHover : Colors.transparent,
          child: Text(s, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary)),
        );
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            label('Fields with a label, empty and filled'),
            const TextField(decoration: InputDecoration(labelText: 'Host name')),
            const SizedBox(height: 12),
            TextField(controller: filled, decoration: const InputDecoration(labelText: 'Host name')),
            const SizedBox(height: 12),
            const TextField(decoration: InputDecoration(hintText: 'A hint only')),
            label('ZestTextField, one line and several'),
            ZestTextField(controller: TextEditingController(text: 'prod-db'), label: 'Name', autofocus: false),
            const SizedBox(height: 12),
            ZestTextField(controller: notes, label: 'Note', autofocus: false, minLines: 3, maxLines: 5),
            label('ZestButton full width, hugging, disabled'),
            ZestButton(label: 'Continue', variant: ZestButtonVariant.primary, onPressed: () {}),
            const SizedBox(height: 8),
            Row(children: [
              ZestButton(label: 'Save', variant: ZestButtonVariant.primary, onPressed: () {}),
              const SizedBox(width: 8),
              const ZestButton(label: 'Save', variant: ZestButtonVariant.primary),
              const SizedBox(width: 8),
              ZestButton(label: 'Cancel', onPressed: () {}),
            ]),
            label('Theme buttons: filled, filled disabled, elevated disabled, outlined'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: () {}, child: const Text('Connect')),
              const FilledButton(onPressed: null, child: Text('Connect')),
              const ElevatedButton(onPressed: null, child: Text('Apply')),
              OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
            ]),
            label('Switches: on, off, off with keyboard focus'),
            Row(children: [
              ZestSwitch(value: true, onChanged: (_) {}),
              const SizedBox(width: 16),
              ZestSwitch(value: false, onChanged: (_) {}),
              const SizedBox(width: 16),
              Focus(focusNode: focusSwitch, skipTraversal: true, child: ZestSwitch(value: false, onChanged: (_) {})),
            ]),
            label('Rows on a card: the middle one hovered'),
            Container(
              decoration: BoxDecoration(
                color: ZestTokens.surfaceElevated,
                border: Border.all(color: ZestTokens.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(children: [row('web-01'), row('web-02', hovered: true), row('db-01')]),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  Future<void> shoot(WidgetTester tester, String themeId, String name, Size size) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    final filled = TextEditingController(text: 'web-01.example.com');
    final notes = TextEditingController(text: 'Rotated the key on Monday.\nAsk before a restart.');
    final focusSwitch = FocusNode();
    addTearDown(filled.dispose);
    addTearDown(notes.dispose);
    addTearDown(focusSwitch.dispose);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Gallery(filled: filled, notes: notes, focusSwitch: focusSwitch),
      ),
    ));
    await tester.pumpAndSettle();
    // The keyboard on the third switch: the focus ring, as Tab would show it.
    final sw = find.byType(ZestSwitch).at(2);
    Focus.of(tester.element(find.descendant(of: sw, matching: find.byType(GestureDetector)).first)).requestFocus();
    await tester.pumpAndSettle();
    await saveShot(tester, key, name);
    plainShadows();
  }

  for (final themeId in const ['default_dark', 'graphite', 'default_light']) {
    testWidgets('shared controls on a computer, $themeId', (tester) async {
      await shoot(tester, themeId, 'controls-desktop-$themeId', const Size(560, 1000));
    }, skip: !_shots, variant: _computer);

    testWidgets('shared controls on a phone, $themeId', (tester) async {
      await shoot(tester, themeId, 'controls-phone-$themeId', const Size(390, 1100));
    }, skip: !_shots, variant: _phone);
  }
}
