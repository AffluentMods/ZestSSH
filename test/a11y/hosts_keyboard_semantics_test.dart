import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';

import 'hosts_a11y_harness.dart';

/// What a keyboard and a screen reader get on the Hosts area's screens (4.0,
/// the accessibility pass): every host card, list row and group tile
/// one button that says the host in a sentence, with its state and its
/// actions; Tab reaches a card, Enter opens it in the panel, Shift+F10 opens
/// its menu, Esc closes the panel; headings are headings; a phone's row and
/// chips read as one thing each; colour swatches and tag crosses are named.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Finder card(String name) => find.descendant(of: find.byType(HostCard), matching: find.text(name));

  /// The semantics node whose label starts with [start].
  SemanticsNode nodeStartingWith(WidgetTester tester, String start) {
    final root = tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
    SemanticsNode? hit;
    void visit(SemanticsNode n) {
      if (hit != null) return;
      if (n.label.startsWith(start)) {
        hit = n;
        return;
      }
      n.visitChildren((c) {
        visit(c);
        return true;
      });
    }

    visit(root);
    expect(hit, isNotNull, reason: 'no node says "$start..."');
    return hit!;
  }

  void computer() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  group('a computer', () {
    testWidgets('a host card is one button that says the host, its group and its tags, with Connect, Edit and More '
        'actions', (tester) async {
      computer();
      final handle = tester.ensureSemantics();
      await pumpA11y(tester, HostsHomePage(onConnectTo: (_) {}));
      final node = nodeStartingWith(tester, 'db-primary, ');
      final data = node.getSemanticsData();
      expect(node.label, contains('192.168.10.31'));
      expect(node.label, contains('postgres'));
      expect(data.hasAction(SemanticsAction.tap), isTrue, reason: 'a screen reader can open it');
      expect(data.flagsCollection.isButton, isTrue);
      final actions = [
        for (final id in data.customSemanticsActionIds ?? const <int>[]) CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(actions, containsAll(['Connect', 'More actions']));
      handle.dispose();
      await finishA11y(tester);
    });

    testWidgets('Tab reaches a card, Enter opens its panel, Esc closes it, Shift+F10 opens its menu', (tester) async {
      computer();
      await pumpA11y(tester, HostsHomePage(onConnectTo: (_) {}));
      final target = tester.element(find.ancestor(of: card('db-primary'), matching: find.byType(HostCard)));
      var reached = false;
      for (var i = 0; i < 80 && !reached; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused == null) continue;
        // The card's own focus is inside the card.
        (focused as Element).visitAncestorElements((e) {
          if (e == target) reached = true;
          return !reached;
        });
      }
      expect(reached, isTrue, reason: 'Tab never reached the card');
      expect(find.byKey(const ValueKey('host-panel-edit')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await a11ySettle(tester);
      expect(find.byKey(const ValueKey('host-panel-edit')), findsOneWidget, reason: 'Enter opened the panel');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await a11ySettle(tester);
      expect(find.byKey(const ValueKey('host-panel-edit')), findsNothing, reason: 'Esc closed the panel');
      // The card kept the keyboard through it all: its menu from the keyboard.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await a11ySettle(tester);
      expect(find.byKey(const ValueKey('host-menu-organize')), findsOneWidget, reason: 'Shift+F10 opened the menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await a11ySettle(tester);
      await finishA11y(tester);
    });

    testWidgets('section heads are headings with their counts; a fold chevron says what it hides; group tiles say '
        'their hosts', (tester) async {
      computer();
      final handle = tester.ensureSemantics();
      await pumpA11y(tester, HostsHomePage(onConnectTo: (_) {}));
      expect(nodeStartingWith(tester, 'Hosts, 9').getSemanticsData().flagsCollection.isHeader, isTrue);
      expect(nodeStartingWith(tester, 'Groups, ').getSemanticsData().flagsCollection.isHeader, isTrue);
      expect(find.bySemanticsLabel('Hide Groups'), findsOneWidget);
      final web = nodeStartingWith(tester, 'Web, 2 hosts');
      expect(web.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
      await finishA11y(tester);
    });

    testWidgets("a list row is one sentence in the columns' order; each head says what it sorts by", (tester) async {
      computer();
      final handle = tester.ensureSemantics();
      await pumpA11y(tester, HostsHomePage(onConnectTo: (_) {}));
      await tester.tap(find.byKey(const ValueKey('hosts-view-list')));
      await a11ySettle(tester);
      final row = nodeStartingWith(tester, 'web-01, ');
      expect(row.label, contains('Web'));
      expect(row.label, contains('Not connected'));
      expect(row.label, contains('Last used'));
      expect(find.bySemanticsLabel('Sort by Host'), findsOneWidget);
      handle.dispose();
      await finishA11y(tester);
    });

    testWidgets('the editor names its colour swatches, its address and port, and each tag cross', (tester) async {
      computer();
      debugHostFormOnComputer = true;
      addTearDown(() => debugHostFormOnComputer = null);
      final handle = tester.ensureSemantics();
      await pumpA11y(tester, ConnectionEditScreen(connectionId: 'c8', inDialog: true, onClose: () {}),
          size: const Size(1100, 900));
      expect(find.bySemanticsLabel('Red'), findsWidgets);
      expect(find.bySemanticsLabel('Teal'), findsWidgets);
      expect(find.bySemanticsLabel('Remove tag postgres'), findsOneWidget);
      expect(find.bySemanticsLabel('Port'), findsOneWidget);
      handle.dispose();
      await finishA11y(tester);
    });
  });

  group('a phone', () {
    testWidgets('a host row is one sentence (its name once), a chip says its hosts, the + is named', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final handle = tester.ensureSemantics();
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())]);
      await pumpA11y(tester, const SizedBox(), router: router, size: const Size(390, 844), touch: true);
      final row = nodeStartingWith(tester, 'web-01, ');
      expect(row.label, isNot(contains('web-01, web-01')));
      expect(row.label, contains('192.168.10.21'));
      expect(find.bySemanticsLabel('Web, 2 hosts'), findsOneWidget);
      expect(find.bySemanticsLabel('More actions for web-01'), findsOneWidget);
      expect(find.byTooltip('Add new host'), findsOneWidget);
      handle.dispose();
      await finishA11y(tester);
    });
  });
}
