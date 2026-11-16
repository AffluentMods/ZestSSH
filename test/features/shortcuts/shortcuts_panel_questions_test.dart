import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/features/shortcuts/widgets/keyboard_shortcuts_panel.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The two questions of Settings > Keyboard shortcuts (3.0:
/// plain dialogs made the app's own): "Reset all shortcuts?" and the one
/// that asks before a key other shortcuts have is given to another.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: KeyboardShortcutsPanel())),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// Presses the key of the Hosts panel's row, types Ctrl+B (the sidebar's
  /// key) into the dialog that records it, and saves: the question follows.
  Future<void> giveTheSidebarsKeyToTheHostsPanel(WidgetTester tester, ProviderContainer c) async {
    final now = c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel;
    await tester.tap(find.text(now).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.keyboardShortcutsRebindTitle(ShortcutAction.toggleHostPanel.label)), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
  }

  testWidgets('a key that another shortcut has: the question names that shortcut and says it loses the key; Cancel '
      'changes nothing, Use anyway gives the key over', (tester) async {
    final c = await pump(tester);
    final sidebar = c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar)!;
    final hostsBefore = c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!;
    expect(sidebar.displayLabel, isNot(hostsBefore.displayLabel));

    await giveTheSidebarsKeyToTheHostsPanel(tester, c);
    // The app's own question, not a plain dialog.
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(l10n.keyboardShortcutsConflictTitle(sidebar.displayLabel)), findsOneWidget);
    expect(find.textContaining(l10n.keyboardShortcutsConflictWarning), findsOneWidget);
    expect(find.textContaining(l10n.keyboardShortcutsConflictBoundTo), findsOneWidget);
    expect(
      find.descendant(of: find.byType(ZestConfirmDialog), matching: find.textContaining(ShortcutAction.toggleSidebar.label)),
      findsOneWidget,
      reason: 'the shortcut that has the key is named',
    );

    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar)!.displayLabel, sidebar.displayLabel);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel,
        hostsBefore.displayLabel);

    await giveTheSidebarsKeyToTheHostsPanel(tester, c);
    await tester.tap(find.text(l10n.keyboardShortcutsUseAnyway));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel,
        sidebar.displayLabel);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar), isNull,
        reason: 'the shortcut that had the key has none now');
  });

  testWidgets("the dialog that records a key is the app's own: nothing is saved before a key was pressed, the key "
      'pressed is shown, Escape closes it and changes nothing, and Escape with Ctrl held is a key like another',
      (tester) async {
    final c = await pump(tester);
    const box = ValueKey('shortcut-capture-key');
    final before = c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel;
    Future<void> openIt() async {
      await tester.tap(find.text(before).first);
      await tester.pumpAndSettle();
    }

    await openIt();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(l10n.keyboardShortcutsRebindTitle(ShortcutAction.toggleHostPanel.label)), findsOneWidget);
    expect(find.text(l10n.keyboardShortcutsPressCombo), findsOneWidget);
    expect(find.descendant(of: find.byKey(box), matching: find.text(l10n.keyboardShortcutsWaitingForInput)),
        findsOneWidget);

    // Save before any key: nothing to save, the dialog stays.
    await tester.tap(find.text(l10n.save), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel, before);

    // A key: it is shown in the box.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final pressed = ShortcutKey(keyId: LogicalKeyboardKey.keyY.keyId, ctrl: true).displayLabel;
    expect(find.descendant(of: find.byKey(box), matching: find.text(pressed)), findsOneWidget);

    // Escape by itself closes the dialog, and nothing is changed.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsNothing);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel, before);

    // Escape with Ctrl held is a key that can be recorded: the dialog stays and shows it.
    await openIt();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    final withEscape = ShortcutKey(keyId: LogicalKeyboardKey.escape.keyId, ctrl: true).displayLabel;
    expect(find.descendant(of: find.byKey(box), matching: find.text(withEscape)), findsOneWidget);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsNothing);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel, before);

    // And Save, once a key was pressed, gives the shortcut that key.
    await openIt();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsNothing);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleHostPanel)!.displayLabel, pressed);
  });

  testWidgets('Reset all asks first: Cancel keeps what was changed, Reset all puts every key back', (tester) async {
    final c = await pump(tester);
    final before = c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar)!.displayLabel;
    await c.read(shortcutBindingsProvider.notifier).unbind(ShortcutAction.toggleSidebar);
    await tester.pumpAndSettle();
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar), isNull);

    // The panel's own button (the question has one of the same name).
    final resetAll = find.text(l10n.keyboardShortcutsResetAll).first;
    await tester.tap(resetAll);
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(l10n.keyboardShortcutsResetAllTitle), findsOneWidget);
    expect(find.text(l10n.keyboardShortcutsResetAllBody), findsOneWidget);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar), isNull);

    await tester.tap(resetAll);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(ZestConfirmDialog), matching: find.text(l10n.keyboardShortcutsResetAll)));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar)!.displayLabel, before);
  });
}
