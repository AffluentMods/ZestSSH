import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/widgets/tab_focus_traversal.dart';

/// Tab inside the docked report form, with the rest of the desktop shell
/// around it the way the real app lays it out: a focusable shell root
/// (the shell's KeyboardListener), a pill bar of buttons on top, a sidebar
/// of rows on the left and a grid of host cards in the middle. Reading-order
/// traversal over the whole window interleaves those with the form's fields,
/// which is what a field test found: Tab left the form after the first
/// multi-line field. The dock must keep Tab inside itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Widget shell(FocusNode shellNode) => ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          helpDockProvider.overrideWith((_) => HelpPage.reportBug),
          cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
          appVersionLabelProvider.overrideWith((_) async => '1.9.7'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => TabMovesFocus(child: child!),
          home: KeyboardListener(
            focusNode: shellNode,
            autofocus: true,
            onKeyEvent: (_) {},
            child: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        for (var i = 0; i < 6; i++)
                          IconButton(
                            icon: const Icon(LucideIcons.circle),
                            onPressed: () {},
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(
                          width: 240,
                          child: ListView(
                            children: [
                              for (var i = 0; i < 12; i++)
                                InkWell(
                                  onTap: () {},
                                  child: SizedBox(
                                      height: 40, child: Text('Sidebar $i')),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Wrap(
                              children: [
                                for (var i = 0; i < 12; i++)
                                  SizedBox(
                                    width: 220,
                                    height: 150,
                                    child: InkWell(
                                      onTap: () {},
                                      child: Text('Card $i'),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        HelpDock(
                          captureScreenshot: ({required bool redacted}) async =>
                              Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]),
                          onCopyRedactedScreenshot: () {},
                          onOpenShortcuts: () {},
                          onAbout: () {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  testWidgets('Tab stays inside the docked report form beside a busy shell',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    final shellNode = FocusNode(debugLabel: 'ShellRoot');
    addTearDown(shellNode.dispose);
    await tester.pumpWidget(shell(shellNode));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(HelpDock)))!;

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(4));
    await tester.tap(fields.at(0));
    await tester.pumpAndSettle();

    String describeFocus() {
      final node = FocusManager.instance.primaryFocus;
      final ctx = node?.context;
      if (node == null || ctx == null) return 'nothing';
      final editable = ctx.findAncestorStateOfType<EditableTextState>() ??
          (ctx.widget is EditableText
              ? (ctx as StatefulElement).state as EditableTextState
              : null);
      if (editable != null) {
        final field = tester.widget<TextField>(find.ancestor(
            of: find.byWidget(editable.widget),
            matching: find.byType(TextField)));
        final all = tester.widgetList<TextField>(fields).toList();
        return 'field:${all.indexOf(field)}';
      }
      final inDock = ctx.findAncestorWidgetOfExactType<HelpDock>() != null;
      return '${node.debugLabel ?? ctx.widget.runtimeType}'
          '${inDock ? ' (dock)' : ' (OUTSIDE)'}';
    }

    final walk = <String>[describeFocus()];
    for (var i = 0; i < 14; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      walk.add(describeFocus());
    }
    debugPrint('WALK: ${walk.join(' -> ')}');

    expect(tester.widget<TextField>(fields.at(0)).decoration?.hintText,
        l10n.reportTitleHint);
    expect(walk[0], 'field:0');
    expect(walk[1], 'field:1', reason: 'title -> what happened');
    expect(walk[2], 'field:2',
        reason: 'what happened (multi-line) -> what you expected');
    expect(walk[3], 'field:3', reason: 'what you expected -> steps');
    for (final step in walk) {
      expect(step, isNot(contains('OUTSIDE')),
          reason: 'Tab left the dock: ${walk.join(' -> ')}');
      expect(step, isNot('nothing'));
    }

    // Shift+Tab walks back the same way.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(describeFocus(), walk[13], reason: 'Shift+Tab walks back');
  });
}
