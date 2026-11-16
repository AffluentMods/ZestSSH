import 'dart:io';

import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/ui/screens/desktop/maximized_panes.dart';

/// Maximize pane on a computer keeps each tab's own arrangement:
/// it was one arrangement for the whole window, so a pane maximised in one
/// tab and Restore pressed in another put the first tab's terminals into
/// the tab in front.
void main() {
  PaneSplit twoPanes(String a, String b) => PaneSplit(
        first: PaneLeaf(id: 'leaf-$a', sessionId: a),
        second: PaneLeaf(id: 'leaf-$b', sessionId: b),
        axis: Axis.horizontal,
      );

  test('a pane maximised in one tab, and Restore pressed in another, leaves the first tab its own', () {
    final panes = MaximizedPanes();
    final web = twoPanes('web-01', 'web-02');
    final db = twoPanes('db-primary', 'db-replica');

    final alone = panes.toggle('tab-web', web, 'leaf-web-01');
    expect(alone, isA<PaneLeaf>());
    expect((alone! as PaneLeaf).sessionIds, ['web-01']);
    expect(panes.isMaximized('tab-web'), isTrue);
    expect(panes.isMaximized('tab-db'), isFalse, reason: 'the other tab has nothing maximised');

    // In the other tab the same key maximises its own pane: it never gets the
    // first tab's arrangement.
    final dbAlone = panes.toggle('tab-db', db, 'leaf-db-replica');
    expect((dbAlone! as PaneLeaf).sessionIds, ['db-replica']);

    expect(panes.toggle('tab-db', dbAlone, 'leaf-db-replica'), same(db));
    expect(panes.toggle('tab-web', alone, 'leaf-web-01'), same(web));
    expect(panes.isMaximized('tab-web'), isFalse);
  });

  test('nothing changes in a tab with one pane, or with no such pane', () {
    final panes = MaximizedPanes();
    expect(panes.toggle('tab-1', PaneLeaf(id: 'leaf-a', sessionId: 'a'), 'leaf-a'), isNull);
    expect(panes.toggle('tab-1', null, 'leaf-a'), isNull);
    expect(panes.toggle('tab-1', twoPanes('a', 'b'), 'leaf-gone'), isNull);
    expect(panes.isMaximized('tab-1'), isFalse);
    expect(panes.isMaximized(null), isFalse);
  });

  test('a tab arranged anew, or closed, has nothing to restore', () {
    final panes = MaximizedPanes();
    panes.toggle('tab-1', twoPanes('a', 'b'), 'leaf-a');
    panes.toggle('tab-2', twoPanes('c', 'd'), 'leaf-c');
    panes.forget('tab-1');
    expect(panes.isMaximized('tab-1'), isFalse);
    panes.keepOnly(const ['tab-3']);
    expect(panes.isMaximized('tab-2'), isFalse);
  });

  test("the computer's window keeps one arrangement per tab, not one for all", () {
    final shell = File('lib/ui/screens/desktop/desktop_shell.dart').readAsStringSync();
    expect(shell, isNot(contains('_savedTree')), reason: 'one field for every tab');
    expect(shell, contains('final _maximized = MaximizedPanes();'));
    expect(shell, contains('_maximized.toggle(tabId, '));
  });
}
