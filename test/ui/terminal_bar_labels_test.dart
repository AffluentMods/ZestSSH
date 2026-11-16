import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

// The timer's figures and its words: 12 minutes and 7 seconds when drawn,
// a second or two more by the time a test reads them.
final _figures = RegExp(r'^12:(0[7-9]|1\d)$');
final _words = RegExp(r'^Connected for 12m (7|8|9|1\d)s$');
final _spoken = RegExp(r'^Session: web-01\nConnected for 12m (7|8|9|1\d)s$');

/// The terminal's bar on a phone says what its timer is and what each of its
/// buttons does (in a 4.0 review, "12:07" sat beside the
/// host's name with nothing saying it was how long the session had been
/// connected, and the bar's icons had no words in sight).
void main() {
  /// Runs [body] drawn as a phone's ([touch]) or a computer's.
  void drawn(String name, Future<void> Function(WidgetTester tester) body, {bool touch = true}) {
    testWidgets(name, (tester) async {
      debugTouchLayout = touch;
      debugDefaultTargetPlatformOverride = touch ? TargetPlatform.android : TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> pumpBar(WidgetTester tester, {double width = 393}) async {
    tester.view.physicalSize = Size(width, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: TerminalToolbar(
            sessionId: 's1',
            status: SessionStatus.connected,
            connectionLabel: 'web-01',
            host: '192.168.10.21',
            port: 22,
            connectedAt: DateTime.now().subtract(const Duration(minutes: 12, seconds: 7)),
            onDisconnect: () {},
            onBack: () {},
            onSettings: () {},
            onSnippets: () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unpump(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  drawn('on a phone the timer has a stopwatch, and says in words what it counts', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester);
    final duration = find.byKey(const ValueKey('terminal-bar-duration'));
    expect(tester.widget<Text>(duration).data, matches(_figures));
    expect(tester.widget<Text>(duration).style?.fontSize, 13);
    final tip = find.byKey(const ValueKey('terminal-bar-duration-tip'));
    expect(tester.widget<Tooltip>(tip).message, matches(_words));
    expect(find.descendant(of: tip, matching: find.byIcon(LucideIcons.timer)), findsOneWidget);
    // A screen reader hears the session and the words, each once, not the
    // bare figures (it heard "Session: web-01, 12:07, web-01").
    expect(find.bySemanticsLabel(_spoken), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(_spoken)).tooltip, isEmpty,
        reason: 'the tooltip would say it a second time');
    // A tap on it shows the words (a phone has no hover).
    await tester.tap(tip);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(_words), findsOneWidget);
    semantics.dispose();
    await unpump(tester);
  });

  drawn("on a phone each button is named by a tooltip and to a screen reader, as a phone's bar has them",
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester);
    // A phone's bar: Terminal settings, More actions and Disconnect (Snippets
    // is in More; it showed in the picture only as a test drew a computer's
    // buttons in a phone's bar).
    expect(find.byIcon(LucideIcons.code), findsNothing);
    for (final (icon, tip, spoken) in [
      (LucideIcons.settings, 'Terminal settings', 'Terminal settings'),
      (LucideIcons.moreVertical, 'More actions', 'More actions'),
      (LucideIcons.power, 'Disconnect', 'Disconnect session'),
      (LucideIcons.arrowLeft, 'Back', 'Go back'),
    ]) {
      final button = find.ancestor(of: find.byIcon(icon), matching: find.byType(Tooltip)).first;
      expect(tester.widget<Tooltip>(button).message, tip, reason: '$icon');
      // Its one name for a screen reader, as a button (a label over a
      // tooltip said it twice: "Terminal settings, Terminal settings").
      final data = tester.getSemantics(find.byIcon(icon)).getSemanticsData();
      expect([data.label, data.tooltip].where((s) => s.isNotEmpty).toList(), [spoken], reason: '$icon');
      expect(data.flagsCollection.isButton, isTrue, reason: '$icon');
      expect(data.hasAction(SemanticsAction.tap), isTrue, reason: '$icon');
    }
    // A long press shows a button's name.
    await tester.longPress(find.byIcon(LucideIcons.power));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Disconnect'), findsOneWidget);
    semantics.dispose();
    await unpump(tester);
  });

  drawn("a computer's timer chip says the same words on hover and to a screen reader", (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester, width: 1280);
    expect(find.byKey(const ValueKey('terminal-bar-duration')), findsNothing, reason: 'a computer keeps its chip');
    final figures = find.textContaining(_figures);
    expect(figures, findsOneWidget);
    expect(
        find.ancestor(of: figures, matching: find.byType(Tooltip)).evaluate().map((e) => (e.widget as Tooltip).message),
        contains(matches(_words)));
    expect(find.bySemanticsLabel(_spoken), findsOneWidget);
    // A computer's bar keeps its buttons in sight.
    expect(find.byIcon(LucideIcons.code), findsOneWidget);
    semantics.dispose();
    await unpump(tester);
  }, touch: false);
}
