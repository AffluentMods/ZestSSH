import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/terminal/mobile_split_terminal.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';

import '../video/scenes_mobile.dart';
import '../video/video_util.dart';
import '../video/video_world.dart';

/// The tablet's split of two sessions (the iPad layout, portrait and
/// landscape, real fonts, the demo fleet), with two and with three
/// sessions open. The lower pane has one header, its terminal's own
/// toolbar, with the split's controls at its end (the session in it where
/// there is a choice, swap, close), right under the divider, as the upper
/// pane has its toolbar; it had the split's strip AND the toolbar, with an
/// empty band between them. Everything sits on the app's Material (the
/// strip drew in Flutter's no-Material style, a yellow double underline,
/// and its picker had no ink), and every control still works.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  stubPlugins();
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<MobileWorld> split(WidgetTester tester, List<String> hosts, {required bool landscape}) async {
    final world = await pumpMobile(Shot(tester, fmtIpad, 'split_test'), Touch());
    if (landscape) {
      final s = tester.view.physicalSize;
      tester.view.physicalSize = Size(s.height, s.width);
    }
    final ids = [for (final h in hosts) world.sessions.open(h)];
    await settleMobile(tester);
    world.router.go('/terminal/${ids.first}');
    await settleMobile(tester);
    world.container.read(mobileSplitActiveProvider.notifier).state = true;
    world.container.read(mobileSplitSecondarySessionProvider.notifier).state = ids[1];
    await settleMobile(tester);
    await settleMobile(tester);
    return world;
  }

  // Every place a session's name is drawn sits on Material, never in the
  // no-Material error style.
  void expectOnMaterial(WidgetTester tester, String label) {
    for (final e in find.text(label).evaluate()) {
      final text = find.byElementPredicate((x) => x == e);
      expect(find.ancestor(of: text, matching: find.byType(Material)), findsWidgets, reason: '$label sits on Material');
      final style = tester.widget<RichText>(find.descendant(of: text, matching: find.byType(RichText))).text.style!;
      expect(style.decoration, isNot(TextDecoration.underline), reason: 'not the no-Material error style');
      expect(style.decorationStyle, isNot(TextDecorationStyle.double));
    }
  }

  for (final landscape in [false, true]) {
    for (final hosts in [
      ['web-01', 'db-primary'],
      ['web-01', 'db-primary', 'api-01'],
    ]) {
      final name = '${landscape ? 'landscape' : 'portrait'}, ${hosts.length} sessions';
      testWidgets('$name: the lower pane has one header, right under the divider, and its controls work',
          (tester) async {
        final world = await split(tester, hosts, landscape: landscape);
        expect(tester.takeException(), isNull);

        final screens = find.byType(TerminalScreen);
        expect(screens, findsNWidgets(2));
        final toolbars = find.byType(TerminalToolbar);
        expect(toolbars, findsNWidgets(2), reason: 'one toolbar a pane');
        // The lower pane's toolbar is its top: nothing over it, no band.
        final lower = tester.getRect(screens.at(1));
        expect(tester.getRect(toolbars.at(1)).top, moreOrLessEquals(lower.top, epsilon: 0.5),
            reason: 'the lower pane starts with its toolbar');
        // Its pane's controls, in that toolbar, once.
        final controls = find.byKey(const ValueKey('split-pane-controls'));
        expect(controls, findsOneWidget);
        expect(find.descendant(of: toolbars.at(1), matching: controls), findsOneWidget);
        expect(find.byTooltip(l10n.mobileSplitTerminalSwapPanes), findsOneWidget);
        expect(find.byTooltip(l10n.mobileSplitTerminalCloseSplit), findsOneWidget);
        expect(find.byKey(const ValueKey('split-pane-pick')), hosts.length > 2 ? findsOneWidget : findsNothing);
        expectOnMaterial(tester, 'db-primary');

        // The picker shows the other session in the lower pane.
        if (hosts.length > 2) {
          await tester.tap(find.byKey(const ValueKey('split-pane-pick')));
          await settleMobile(tester);
          await tester.tap(find.text('api-01').last);
          await settleMobile(tester);
          final shown = world.container.read(mobileSplitSecondarySessionProvider)!;
          expect(world.sessions.state[shown]!.connectionLabel, 'api-01');
          expect(tester.takeException(), isNull);
        }
        // Close ends the split.
        await tester.tap(find.byKey(const ValueKey('split-pane-close')));
        await settleMobile(tester);
        expect(world.container.read(mobileSplitActiveProvider), isFalse);
        expect(find.byType(TerminalScreen), findsOneWidget);
        await tearDownWorld(tester);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}
