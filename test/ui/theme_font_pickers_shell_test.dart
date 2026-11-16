import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/widgets/font_picker.dart';
import 'package:zestssh/ui/screens/settings/widgets/theme_picker.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The terminal's theme and font pickers are the app's dialog (the dialog
/// rules of 3.4): on a computer the shell (they were a Material dialog
/// of their own, with no title of the shell's and no way out but outside it),
/// on a phone the shell's sheet (a sheet of its own). Create custom theme is
/// the footer's side link (a button under the tiles), Close the footer's.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  for (final onPhone in [false, true]) {
    final where = onPhone ? 'a phone' : 'a computer';

    Future<(BuildContext, WidgetRef, ProviderContainer)> pump(WidgetTester tester) async {
      tester.view.physicalSize = onPhone ? const Size(390, 844) : const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(container.dispose);
      late BuildContext context;
      late WidgetRef ref;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Consumer(builder: (ctx, r, _) {
            context = ctx;
            ref = r;
            return const Scaffold();
          }),
        ),
      ));
      await tester.pumpAndSettle();
      return (context, ref, container);
    }

    final variant = TargetPlatformVariant.only(onPhone ? TargetPlatform.android : TargetPlatform.windows);

    testWidgets('the theme picker on $where: the shell, Create custom theme its side link, Close', variant: variant,
        (tester) async {
      final (context, ref, _) = await pump(tester);
      showThemePicker(context, ref);
      await tester.pumpAndSettle();
      final shell = tester.widget<ZestDialogShell>(find.byKey(const ValueKey('theme-picker')));
      expect(shell.title, l10n.themePickerTitle);
      expect(shell.tertiaryAction?.label, anyOf(l10n.themePickerCreateCustomTheme, l10n.themePickerCreateCustomThemePro));
      expect(shell.secondaryAction?.label, l10n.close);
      expect(find.byType(OutlinedButton), findsNothing, reason: 'no button under the tiles');
      expect(find.byKey(const ValueKey('zest-sheet')), onPhone ? findsOneWidget : findsNothing);
      await tester.tap(find.text(l10n.close));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('theme-picker')), findsNothing);
    });

    testWidgets('the font picker on $where: the shell, a dot radio each; a font picked is used and it closes',
        variant: variant, (tester) async {
      final (context, _, container) = await pump(tester);
      showFontPicker(context);
      await tester.pumpAndSettle();
      final shell = tester.widget<ZestDialogShell>(find.byKey(const ValueKey('font-picker')));
      expect(shell.title, l10n.fontPickerTitle);
      // Nerd Font icons come with every font (4.0), said under the title.
      expect(shell.subtitle, l10n.settingsTerminalFontNerdIcons);
      expect(find.text(l10n.settingsTerminalFontNerdIcons), findsOneWidget);
      expect(shell.secondaryAction?.label, l10n.close);
      expect(find.byKey(const ValueKey('zest-sheet')), onPhone ? findsOneWidget : findsNothing);
      final fira = find.byKey(ValueKey('font-picker-${TerminalFontFamily.firaCode.name}'));
      await tester.ensureVisible(fira);
      await tester.pumpAndSettle();
      await tester.tap(fira);
      await tester.pumpAndSettle();
      expect(container.read(terminalFontFamilyProvider), TerminalFontFamily.firaCode);
      expect(find.byKey(const ValueKey('font-picker')), findsNothing);
    });
  }
}
