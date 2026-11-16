import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/settings/widgets/font_picker.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// One of a few picked: a dot radio, the one the dialogs have (Material's
/// Radio in a RadioGroup); a check only where several can be picked. Phone
/// settings drew a check in a circle where the dialogs drew a dot (as a design
/// review found).
final _en = lookupAppLocalizations(const Locale('en'));

/// [home] at a phone's size (412 by 915), drawn as a phone's.
Future<ProviderContainer> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = BuiltInThemes.getById('graphite');
  AppColors.applyTheme(theme.colorScheme);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    recordingModeProvider.overrideWith((ref) => false),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: theme.toThemeData(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: home,
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

/// Runs [body] drawn as a phone's (Android, the touch layout).
void _phone(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    debugTouchLayout = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body(tester);
    } finally {
      debugTouchLayout = null;
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// [f] scrolled to the middle of its list, clear of the app bar.
Future<void> _toMiddle(WidgetTester tester, Finder f) async {
  await Scrollable.ensureVisible(tester.element(f), alignment: 0.5);
  await tester.pumpAndSettle();
}

/// No check in a circle anywhere on screen.
final _checkInCircle = find.byWidgetPredicate((w) => w is Icon && w.icon == LucideIcons.checkCircle2);

void main() {
  _phone('Keyboard row: each pick-one group is dot radios, the picked one checked, a tap on a radio picks it',
      (tester) async {
    final c = await _pump(tester, const KeyboardRowScreen());
    final scrollable = find.byType(Scrollable).first;
    // Every choice of the four groups, with what its page has picked.
    final groups = <String, List<String>>{
      'when a keyboard is plugged in': ['keys-row-hardware-auto', 'keys-row-hardware-always', 'keys-row-hardware-missing'],
      'where it goes': ['keys-row-aboveKeyboard', 'keys-row-aboveTerminal'],
      'size': ['keys-row-size-small', 'keys-row-size-medium', 'keys-row-size-large'],
      'style': ['keys-row-style-grouped', 'keys-row-style-flat'],
    };
    const picked = {'keys-row-hardware-auto', 'keys-row-aboveKeyboard', 'keys-row-size-medium', 'keys-row-style-grouped'};
    for (final MapEntry(key: group, value: rows) in groups.entries) {
      for (final row in rows) {
        final radio = find.byKey(ValueKey('$row-radio'));
        await tester.scrollUntilVisible(radio, 200, scrollable: scrollable);
        await tester.pump();
        expect(find.descendant(of: find.byKey(ValueKey(row)), matching: radio), findsOneWidget, reason: row);
        expect(find.descendant(of: find.byKey(ValueKey(row)), matching: _checkInCircle), findsNothing, reason: row);
        expect(tester.getSemantics(radio),
            isSemantics(isInMutuallyExclusiveGroup: true, isChecked: picked.contains(row)),
            reason: '$group: $row');
      }
    }
    expect(_checkInCircle, findsNothing);

    // The radio itself picks, as its row does (back up the page to it).
    final aboveTerminal = find.byKey(const ValueKey('keys-row-aboveTerminal-radio'));
    await tester.scrollUntilVisible(aboveTerminal, -200, scrollable: scrollable);
    await _toMiddle(tester, aboveTerminal);
    await tester.tap(aboveTerminal);
    await tester.pumpAndSettle();
    expect(c.read(extraKeyboardPositionProvider), 'aboveTerminal');
    expect(tester.getSemantics(aboveTerminal), isSemantics(isChecked: true));
    expect(tester.getSemantics(find.byKey(const ValueKey('keys-row-aboveKeyboard-radio'))),
        isSemantics(isChecked: false));
    final flat = find.byKey(const ValueKey('keys-row-style-flat-radio'));
    await tester.scrollUntilVisible(flat, 200, scrollable: scrollable);
    await _toMiddle(tester, flat);
    await tester.tap(flat);
    await tester.pumpAndSettle();
    expect(c.read(softKeyboardStyleProvider), SoftKeyRowStyle.flat);
    await _finish(tester);
  });

  _phone("Terminal font: the sheet's fonts are dot radios, the one in use checked; one picked is used and the sheet "
      'closes', (tester) async {
    final c = await _pump(
      tester,
      Scaffold(
        body: Builder(
          // The app's dialog (3.4), a phone's sheet, as the settings open it.
          builder: (context) => TextButton(
            onPressed: () => showFontPicker(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(_en.fontPickerTitle), findsOneWidget);
    expect(_checkInCircle, findsNothing);
    final radios = find.byType(Radio<TerminalFontFamily>);
    expect(radios, findsWidgets);
    final jetBrains = find.descendant(
        of: find.byKey(ValueKey('font-picker-${TerminalFontFamily.jetBrainsMono.name}')), matching: radios);
    expect(tester.getSemantics(jetBrains), isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true));
    final fira = find.descendant(of: find.byKey(ValueKey('font-picker-${TerminalFontFamily.firaCode.name}')), matching: radios);
    expect(tester.getSemantics(fira), isSemantics(isChecked: false));
    await tester.tap(fira);
    await tester.pumpAndSettle();
    expect(c.read(terminalFontFamilyProvider), TerminalFontFamily.firaCode);
    expect(find.text(_en.fontPickerTitle), findsNothing, reason: 'picked, the sheet closes');
    await _finish(tester);
  });

  test('no pick-one control anywhere in the app is a check in a circle: the one left is the Sessions tab\'s '
      'selection, where several are picked', () {
    // A check in a circle for the one picked and an empty circle for the
    // others, within a few lines of each other.
    final pair = RegExp(r'LucideIcons\.checkCircle2?\b[\s\S]{0,200}?LucideIcons\.circle\b');
    final found = <String, int>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('${Platform.pathSeparator}generated${Platform.pathSeparator}')) {
        continue;
      }
      final n = pair.allMatches(file.readAsStringSync()).length;
      if (n > 0) found[file.path.replaceAll(r'\', '/')] = n;
    }
    // The one left is the Sessions tab's selection, where several are picked
    // (a pin on the comment that says so passed with the code gone, as a
    // review found).
    expect(found, {'lib/ui/screens/home/home_screen.dart': 1});
  });
}
