import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';

import '../models/pane_rooms.dart';

/// What the tabs and the pane tree do with the arrangement of a tab when
/// terminals join it, leave it, are split or are arranged by hand.
///
/// A bug in 2.2.1: adding terminals did not resize the others, so a fifth
/// could end up at about 10% of the width while the other four looked
/// normal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late WorkTabsNotifier tabs;
  late PaneTreeNotifier panes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    tabs = container.read(workTabsProvider.notifier);
    panes = container.read(paneTreeProvider.notifier);
  });

  tearDown(() => container.dispose());

  WorkTabsState st() => container.read(workTabsProvider);
  PaneNode treeOf(String tabId) => st().tabs.firstWhere((t) => t.id == tabId).paneTree;

  /// The tree on screen: the active tab's.
  PaneNode? shown() => container.read(paneTreeProvider);

  /// The panes of the tab [tabId], by the session each shows.
  List<String> at(String tabId) => rooms(treeOf(tabId), bySession: true);
  List<String> onScreen() => rooms(shown(), bySession: true);

  /// A tab of [sessions]: each one's own tab joined to the first, one by
  /// one, as pills dragged onto a pill. It is the active tab.
  String joined(List<String> sessions) {
    final first = tabs.createTab(sessions.first);
    for (final s in sessions.skip(1)) {
      tabs.mergeTabs(tabs.createTab(s), first);
    }
    tabs.setActiveTab(first);
    return first;
  }

  List<String> s(int from, int to) => [for (var i = from; i <= to; i++) 's$i'];

  const threeAndTwo = ['s1 0,0 33x50', 's2 33,0 33x50', 's3 67,0 33x50', 's4 0,50 50x50', 's5 50,50 50x50'];

  group('Tabs joined one by one', () {
    test('five stand three on top and two below, and at no step is a pane a sliver', () {
      final first = tabs.createTab('s1');
      final seen = <int, List<String>>{};
      for (var n = 2; n <= 5; n++) {
        tabs.mergeTabs(tabs.createTab('s$n'), first);
        seen[n] = at(first);
      }
      expect(seen[2], ['s1 0,0 50x100', 's2 50,0 50x100']);
      expect(seen[3], ['s1 0,0 33x100', 's2 33,0 33x100', 's3 67,0 33x100']);
      expect(seen[4], ['s1 0,0 50x50', 's2 50,0 50x50', 's3 0,50 50x50', 's4 50,50 50x50']);
      expect(seen[5], threeAndTwo);
      expect(st().tabs, hasLength(1));
      expect(st().activeTabId, first);
      expect(onScreen(), threeAndTwo, reason: 'what is on screen is the tab');
    });

    test('up to eight and beyond, every pane of a row is as wide as the next', () {
      final first = tabs.createTab('s1');
      for (var n = 2; n <= 10; n++) {
        tabs.mergeTabs(tabs.createTab('s$n'), first);
        final rows = <String, Set<String>>{};
        for (final r in at(first)) {
          final parts = r.split(' ');
          rows.putIfAbsent(parts[1].split(',').last, () => {}).add(parts[2]);
        }
        expect(rows.values.every((sizes) => sizes.length == 1), isTrue, reason: '$n: $rows');
        expect(rows.length, tileRows(n).length, reason: '$n');
        expect(treeOf(first).allLeaves.map((l) => l.sessionId), s(1, n), reason: 'in the order they joined');
      }
    });

    test('the group dragged onto the newcomer instead: one grid as well, the newcomer first', () {
      var g = tabs.createTab('s1');
      for (var n = 2; n <= 5; n++) {
        final next = tabs.createTab('s$n');
        tabs.mergeTabs(g, next);
        g = next;
      }
      expect(at(g), ['s5 0,0 33x50', 's4 33,0 33x50', 's3 67,0 33x50', 's2 0,50 50x50', 's1 50,50 50x50']);
      expect(st().tabs, hasLength(1));
    });

    test('two groups joined become one grid, in order', () {
      final g1 = joined(s(1, 2));
      final g2 = joined(s(3, 5));
      tabs.mergeTabs(g2, g1);
      expect(at(g1), threeAndTwo);
      expect(st().activeTabId, g1, reason: 'the tab that was shown went into it');
      expect(onScreen(), threeAndTwo);
    });

    test('a tab that is not shown is joined all the same, and what is on screen stays', () {
      final a = tabs.createTab('s1');
      final b = tabs.createTab('s2');
      final c = tabs.createTab('s3');
      tabs.mergeTabs(b, a);
      expect(at(a), ['s1 0,0 50x100', 's2 50,0 50x100']);
      expect(st().activeTabId, c);
      expect(onScreen(), ['s3 0,0 100x100']);
      // Nothing joins itself, and a tab that is not there joins nothing.
      tabs.mergeTabs(a, a);
      tabs.mergeTabs('nobody', a);
      tabs.mergeTabs(a, 'nobody');
      expect(at(a), ['s1 0,0 50x100', 's2 50,0 50x100']);
      expect(st().tabs, hasLength(2));
    });
  });

  group('A tab someone arranged', () {
    test('keeps its arrangement when a tab joins: beside a large pane the stack grows', () {
      final g = joined(s(1, 3));
      expect(tabs.arrangeTab(g, LayoutPreset.oneAndTwo), ArrangeOutcome.done);
      tabs.mergeTabs(tabs.createTab('s4'), g);
      expect(at(g), ['s1 0,0 67x100', 's2 67,0 33x33', 's3 67,33 33x33', 's4 67,67 33x33']);
    });

    test('a divider someone moved stays when a terminal joins and when one leaves', () {
      final g = joined(s(1, 2));
      panes.setSplitRatio((shown()! as PaneSplit).id, 0.7);
      expect(widths(treeOf(g), bySession: true), {'s1': 70, 's2': 30}, reason: 'kept by the tab');
      tabs.mergeTabs(tabs.createTab('s3'), g);
      expect(widths(treeOf(g), bySession: true), {'s1': 70, 's2': 15, 's3': 15});
      tabs.removeSession('s3');
      expect(widths(treeOf(g), bySession: true), {'s1': 70, 's2': 30});
      expect(widths(shown(), bySession: true), {'s1': 70, 's2': 30});
    });

    test('where a divider was moved to is the tab\'s: it is there when the tab is come back to', () {
      final g = joined(s(1, 2));
      final other = tabs.createTab('s9');
      tabs.setActiveTab(g);
      panes.setSplitRatio((shown()! as PaneSplit).id, 0.3);
      tabs.setActiveTab(other);
      expect(onScreen(), ['s9 0,0 100x100']);
      // A divider of this tab is no divider of that one.
      panes.setSplitRatio((treeOf(g) as PaneSplit).id, 0.9);
      expect(widths(treeOf(g), bySession: true), {'s1': 30, 's2': 70});
      tabs.setActiveTab(g);
      expect(widths(shown(), bySession: true), {'s1': 30, 's2': 70});
      // With no tab shown there is nothing to keep it in.
      tabs.clearAllTabs();
      panes.setSplitRatio('nobody', 0.5);
      expect(shown(), isNull);
    });
  });

  group('A terminal leaves', () {
    test('a tab in its grid stands in the grid for what is left', () {
      final g = joined(s(1, 5));
      tabs.removeSession('s2');
      const four = ['s1 0,0 50x50', 's3 50,0 50x50', 's4 0,50 50x50', 's5 50,50 50x50'];
      expect(at(g), four);
      expect(onScreen(), four);
      tabs.removeSession('s5');
      expect(at(g), ['s1 0,0 33x100', 's3 33,0 33x100', 's4 67,0 33x100']);
      // One that is in no tab changes nothing.
      tabs.removeSession('nobody');
      expect(st().tabs, hasLength(1));
    });

    test('the last terminal of a tab takes the tab with it', () {
      final g = joined(s(1, 2));
      final other = tabs.createTab('s3');
      tabs.removeSession('s3');
      expect(st().tabs.map((t) => t.id), [g]);
      expect(st().tabs.any((t) => t.id == other), isFalse);
      expect(at(g), ['s1 0,0 50x100', 's2 50,0 50x100']);
    });

    test('a tab that is not shown settles as well, and what is on screen stays', () {
      final g = joined(s(1, 4));
      final other = tabs.createTab('s9');
      tabs.removeSession('s4');
      expect(at(g), ['s1 0,0 33x100', 's2 33,0 33x100', 's3 67,0 33x100']);
      expect(st().activeTabId, other);
      expect(onScreen(), ['s9 0,0 100x100']);
    });

    test('moved to another tab: the one it left and the one it joins both settle', () {
      final g1 = joined(s(1, 4));
      final g2 = joined(s(5, 6));
      tabs.moveSessionToTab('s4', g2);
      expect(at(g1), ['s1 0,0 33x100', 's2 33,0 33x100', 's3 67,0 33x100']);
      expect(at(g2), ['s5 0,0 33x100', 's6 33,0 33x100', 's4 67,0 33x100']);
      expect(st().activeTabId, g2);
      expect(onScreen(), at(g2));
      // Into an arrangement someone made: it joins it the way that grows.
      expect(tabs.arrangeTab(g2, LayoutPreset.threeRows), ArrangeOutcome.done);
      tabs.moveSessionToTab('s1', g2);
      expect(at(g2), ['s5 0,0 100x25', 's6 0,25 100x25', 's4 0,50 100x25', 's1 0,75 100x25']);
      expect(at(g1), ['s2 0,0 50x100', 's3 50,0 50x100']);
    });

    test('popped out into a tab of its own: the group it left settles', () {
      final g = joined(s(1, 5));
      // (The last of the lower row: left alone, the one beside it would
      // have the whole row.)
      tabs.splitSessionToNewTab('s5');
      expect(at(g), ['s1 0,0 50x50', 's2 50,0 50x50', 's3 0,50 50x50', 's4 50,50 50x50']);
      expect(st().tabs, hasLength(2));
      expect(onScreen(), ['s5 0,0 100x100']);
    });

    test('sessions that are gone are taken out of every tab, and the tabs settle', () {
      final g = joined(s(1, 5));
      final gone = tabs.createTab('s6');
      final kept = tabs.createTab('s7');
      tabs.purgeStaleSessions({'s1', 's3', 's5', 's7'});
      expect(at(g), ['s1 0,0 33x100', 's3 33,0 33x100', 's5 67,0 33x100']);
      expect(st().tabs.map((t) => t.id), [g, kept]);
      expect(st().tabs.any((t) => t.id == gone), isFalse);
      // With every session still there, nothing is touched.
      final before = treeOf(g);
      tabs.purgeStaleSessions({'s1', 's3', 's5', 's7'});
      expect(identical(treeOf(g), before), isTrue);
    });
  });

  group('Arranging a tab', () {
    test('an arrangement that holds its terminals is made, each pane the pane it was', () {
      final g = joined(s(1, 5));
      final before = treeOf(g).allLeaves.map((l) => l.id).toList();
      expect(tabs.arrangeTab(g, LayoutPreset.twoAndThree), ArrangeOutcome.done);
      const made = ['s1 0,0 50x50', 's2 50,0 50x50', 's3 0,50 33x50', 's4 33,50 33x50', 's5 67,50 33x50'];
      expect(at(g), made);
      expect(treeOf(g).allLeaves.map((l) => l.id), before);
      expect(onScreen(), made);
    });

    test('a tab that is not shown is arranged without touching what is on screen', () {
      final g = joined(s(1, 3));
      final other = tabs.createTab('s9');
      expect(tabs.arrangeTab(g, LayoutPreset.threeRows), ArrangeOutcome.done);
      expect(at(g), ['s1 0,0 100x33', 's2 0,33 100x33', 's3 0,67 100x33']);
      expect(st().activeTabId, other);
      expect(onScreen(), ['s9 0,0 100x100']);
    });

    test('one with panes to spare shows them as places to connect, which the next terminal takes', () {
      final g = joined(s(1, 3));
      expect(tabs.arrangeTab(g, LayoutPreset.grid2x2), ArrangeOutcome.done);
      expect(at(g), ['s1 0,0 50x50', 's2 50,0 50x50', 's3 0,50 50x50', '- 50,50 50x50']);
      expect(tabs.arrangeablePanes(g).map((l) => l.sessionId), s(1, 3), reason: 'an empty place is no terminal');
      tabs.mergeTabs(tabs.createTab('s4'), g);
      expect(at(g), ['s1 0,0 50x50', 's2 50,0 50x50', 's3 0,50 50x50', 's4 50,50 50x50']);
      // Arranged again, places that stand empty are not carried over.
      expect(tabs.arrangeTab(g, LayoutPreset.grid3x2), ArrangeOutcome.done);
      expect(at(g).where((r) => r.startsWith('-')), hasLength(2));
      expect(tabs.arrangeTab(g, null), ArrangeOutcome.done);
      expect(at(g), ['s1 0,0 50x50', 's2 50,0 50x50', 's3 0,50 50x50', 's4 50,50 50x50']);
    });

    test('a pane left with no session in it is no terminal', () {
      final g = joined(s(1, 2));
      // (As a pane stands when its last tab closed and nothing took the pane away yet.)
      final hollow = PaneLeaf(sessionIds: const ['']);
      tabs.replaceTabTree(g, PaneSplit(first: treeOf(g), second: hollow, axis: Axis.horizontal));
      expect(tabs.arrangeablePanes(g).map((l) => l.sessionId), ['s1', 's2']);
      expect(tabs.arrangeTab(g, LayoutPreset.sideBySide), ArrangeOutcome.done);
      expect(at(g), ['s1 0,0 50x100', 's2 50,0 50x100']);
    });

    test('one with fewer panes than the tab has terminals is not made', () {
      final g = joined(s(1, 3));
      final before = treeOf(g);
      expect(tabs.arrangeTab(g, LayoutPreset.sideBySide), ArrangeOutcome.tooSmall);
      expect(tabs.arrangeTab(g, LayoutPreset.single), ArrangeOutcome.tooSmall);
      expect(identical(treeOf(g), before), isTrue, reason: 'nothing was changed');
      expect(st().tabs, hasLength(1), reason: 'no terminal is moved to a tab of its own');
    });

    test('the automatic grid: however the tab came to look, and from then on by itself', () {
      final g = joined(s(1, 5));
      expect(tabs.arrangeTab(g, LayoutPreset.oneAndFour), ArrangeOutcome.done);
      expect(isTiled(treeOf(g)), isFalse);
      expect(tabs.arrangeTab(g, null), ArrangeOutcome.done);
      expect(at(g), threeAndTwo);
      expect(isTiled(treeOf(g)), isTrue);
      tabs.mergeTabs(tabs.createTab('s6'), g);
      expect(at(g).map((r) => r.split(' ').last).toSet(), {'33x50'}, reason: 'three and three');
      // A divider that was moved is put back.
      final root = treeOf(g) as PaneSplit;
      tabs.setActiveTab(g);
      panes.setSplitRatio(root.id, 0.8);
      expect(isTiled(treeOf(g)), isFalse);
      expect(tabs.arrangeTab(g, null), ArrangeOutcome.done);
      expect(at(g).map((r) => r.split(' ').last).toSet(), {'33x50'});
    });

    test('where there is nothing to arrange, nothing is done', () {
      expect(tabs.arrangeTab('no such tab', LayoutPreset.grid2x2), ArrangeOutcome.nothing);
      expect(tabs.arrangeTab('no such tab', null), ArrangeOutcome.nothing);
      expect(tabs.arrangeablePanes('no such tab'), isEmpty);
      // A tab of SFTP alone: no grid, and nothing to make one pane of.
      final g = tabs.createTab('s1');
      final dock = PaneLeaf.single(sessionId: 's1', type: 'sftp');
      tabs.replaceTabTree(g, dock);
      expect(tabs.arrangeablePanes(g), isEmpty);
      expect(tabs.arrangeTab(g, null), ArrangeOutcome.nothing);
      expect(tabs.arrangeTab(g, LayoutPreset.single), ArrangeOutcome.nothing);
      expect(identical(treeOf(g), dock), isTrue);
      // Places to connect beside the dock are something.
      expect(tabs.arrangeTab(g, LayoutPreset.sideBySide), ArrangeOutcome.done);
      expect(sftpLeavesOf(treeOf(g)).map((l) => l.id), [dock.id]);
      expect(rooms(withoutSftp(treeOf(g))), ['- 0,0 50x100', '- 50,0 50x100']);
      // Nothing but places to connect: still nothing to put in a grid, in
      // one pane or in several.
      final empty = tabs.createTab('s2');
      final places = treeOfPreset(LayoutPreset.sideBySide, const [])!;
      tabs.replaceTabTree(empty, places);
      expect(tabs.arrangeTab(empty, null), ArrangeOutcome.nothing);
      expect(tabs.arrangeTab(empty, LayoutPreset.single), ArrangeOutcome.nothing);
      expect(tabs.arrangeTab(empty, LayoutPreset.threeColumns), ArrangeOutcome.nothing);
      expect(identical(treeOf(empty), places), isTrue);
    });

    test('the SFTP dock stays at the side, whatever is chosen', () {
      final g = joined(s(1, 3));
      expect(panes.splitPaneWithSftp(shown()!.allLeaves.first.id, Axis.horizontal, 's1'), isTrue);
      final dock = sftpLeavesOf(treeOf(g)).single.id;
      expect(tabs.arrangeablePanes(g).map((l) => l.sessionId), s(1, 3), reason: 'SFTP is no pane');
      expect(tabs.arrangeTab(g, LayoutPreset.threeRows), ArrangeOutcome.done);
      expect(rooms(withoutSftp(treeOf(g)), bySession: true),
          ['s1 0,0 100x33', 's2 0,33 100x33', 's3 0,67 100x33']);
      expect(sftpLeavesOf(treeOf(g)).map((l) => l.id), [dock]);
      expect(tabs.arrangeTab(g, null), ArrangeOutcome.done);
      expect(rooms(withoutSftp(treeOf(g)), bySession: true),
          ['s1 0,0 33x100', 's2 33,0 33x100', 's3 67,0 33x100']);
      expect(sftpLeavesOf(treeOf(g)).map((l) => l.id), [dock]);
      expect(sftpLeavesOf(shown()).map((l) => l.id), [dock]);
    });

    test('a session that is not shown here is not arranged', () {
      final g = joined(s(1, 3));
      // s2 went to a window of its own.
      bool here(String session) => session != 's2';
      expect(tabs.arrangeablePanes(g, shown: here).map((l) => l.sessionId), ['s1', 's3']);
      expect(tabs.arrangeTab(g, LayoutPreset.sideBySide, shown: here), ArrangeOutcome.done);
      expect(at(g), ['s1 0,0 50x100', 's3 50,0 50x100']);
      // Nothing of the tab is shown here: nothing to arrange.
      expect(tabs.arrangeTab(g, null, shown: (_) => false), ArrangeOutcome.nothing);
      expect(tabs.arrangeTab(g, LayoutPreset.single, shown: (_) => false), ArrangeOutcome.nothing);
    });

    test('a pane that shows two sessions as its tabs stays one pane, with the ones that are here', () {
      final g = joined(s(1, 2));
      final first = shown()!.allLeaves.first;
      panes.addSessionToPane(first.id, 's9');
      expect(treeOf(g).allLeaves.first.sessionIds, ['s1', 's9']);
      expect(treeOf(g).allLeaves.first.activeIndex, 1);

      final all = tabs.arrangeablePanes(g);
      expect(all.map((l) => l.sessionIds), [
        ['s1', 's9'],
        ['s2'],
      ]);
      expect(identical(all.first, treeOf(g).allLeaves.first), isTrue, reason: 'the pane as it is');

      final without9 = tabs.arrangeablePanes(g, shown: (session) => session != 's9').first;
      expect(without9.sessionIds, ['s1']);
      expect(without9.activeIndex, 0, reason: 'the tab that was in front is gone: the one left is');
      expect(without9.id, first.id);
      expect(without9.type, 'terminal');
      final without1 = tabs.arrangeablePanes(g, shown: (session) => session != 's1').first;
      expect(without1.sessionIds, ['s9']);
      expect(without1.activeIndex, 0);

      expect(tabs.arrangeTab(g, LayoutPreset.stacked), ArrangeOutcome.done);
      expect(treeOf(g).allLeaves.map((l) => l.sessionIds), [
        ['s1', 's9'],
        ['s2'],
      ]);
      expect(rooms(treeOf(g)).map((r) => r.split(' ').last), ['100x50', '100x50']);
    });
  });

  group('Splitting a pane', () {
    test('the room nobody arranged is shared again', () {
      final g = joined(s(1, 2));
      expect(panes.splitPane(shown()!.allLeaves.last.id, Axis.horizontal, 's3'), isTrue);
      expect(widths(shown(), bySession: true), {'s1': 33, 's2': 33, 's3': 33});
      expect(widths(treeOf(g), bySession: true), {'s1': 33, 's2': 33, 's3': 33}, reason: 'kept by the tab');
      // Split downwards: a pane beside a stack stays as wide as it was.
      expect(panes.splitPane(shown()!.allLeaves.first.id, Axis.vertical, 's4'), isTrue);
      expect(onScreen(), ['s1 0,0 33x50', 's2 33,0 33x100', 's3 67,0 33x100', 's4 0,50 33x50']);
    });

    test('a divider someone moved stays where it was put', () {
      joined(s(1, 2));
      panes.setSplitRatio((shown()! as PaneSplit).id, 0.7);
      expect(panes.splitPane(shown()!.allLeaves.last.id, Axis.vertical, 's3'), isTrue);
      expect(onScreen(), ['s1 0,0 70x100', 's2 70,0 30x50', 's3 70,50 30x50']);
      expect(panes.splitPane(shown()!.allLeaves.first.id, Axis.horizontal, 's4'), isTrue);
      expect(onScreen(), ['s1 0,0 35x100', 's4 35,0 35x100', 's2 70,0 30x50', 's3 70,50 30x50']);
    });

    test('on the side that was said', () {
      joined(s(1, 2));
      panes.splitPaneDirectional(shown()!.allLeaves.first.id, Axis.horizontal, 's3', true);
      expect(onScreen(), ['s3 0,0 33x100', 's1 33,0 33x100', 's2 67,0 33x100']);
      panes.splitPaneDirectional(shown()!.allLeaves.last.id, Axis.vertical, 's4', false);
      expect(onScreen(), ['s3 0,0 33x100', 's1 33,0 33x100', 's2 67,0 33x50', 's4 67,50 33x50']);
      panes.splitPaneDirectional(shown()!.allLeaves.first.id, Axis.vertical, 's5', true);
      expect(onScreen().take(2), ['s5 0,0 33x50', 's1 33,0 33x100']);
    });

    test('a pane that is not there is not split', () {
      expect(panes.splitPane('nobody', Axis.horizontal, 's9'), isFalse, reason: 'no tab shown');
      expect(panes.splitPaneWithSftp('nobody', Axis.horizontal, 's9'), isFalse);
      panes.splitPaneDirectional('nobody', Axis.horizontal, 's9', true);
      expect(shown(), isNull);
      joined(s(1, 2));
      final before = shown();
      expect(panes.splitPane('nobody', Axis.horizontal, 's9'), isFalse);
      expect(panes.splitPaneWithSftp('nobody', Axis.horizontal, 's1'), isFalse);
      panes.splitPaneDirectional('nobody', Axis.horizontal, 's9', true);
      expect(identical(shown(), before), isTrue);
    });

    test('SFTP opened beside a pane moves no divider, and closing it moves none', () {
      joined(s(1, 2));
      panes.setSplitRatio((shown()! as PaneSplit).id, 0.7);
      expect(panes.splitPaneWithSftp(shown()!.allLeaves.first.id, Axis.horizontal, 's1'), isTrue);
      expect(sftpLeavesOf(shown()).single.sessionId, 's1');
      expect(widths(withoutSftp(shown()), bySession: true), {'s1': 70, 's2': 30});
      panes.closePane(sftpLeavesOf(shown()).single.id);
      expect(sftpLeavesOf(shown()), isEmpty);
      expect(widths(shown(), bySession: true), {'s1': 70, 's2': 30});
    });

    test('the SFTP dock of a tab in its grid closes, and the grid stays', () {
      final g = joined(s(1, 4));
      expect(panes.splitPaneWithSftp(shown()!.allLeaves.first.id, Axis.horizontal, 's1'), isTrue);
      expect(sftpLeavesOf(treeOf(g)), hasLength(1));
      const grid = ['s1 0,0 50x50', 's2 50,0 50x50', 's3 0,50 50x50', 's4 50,50 50x50'];
      expect(rooms(withoutSftp(shown()), bySession: true), grid);
      panes.closePane(sftpLeavesOf(shown()).single.id);
      expect(sftpLeavesOf(shown()), isEmpty, reason: 'closed is closed');
      expect(sftpLeavesOf(treeOf(g)), isEmpty);
      expect(onScreen(), grid);
    });
  });

  group('Closing a pane', () {
    test('a tab in its grid stands in the grid for what is left', () {
      final g = joined(s(1, 5));
      panes.closePane(shown()!.allLeaves[1].id);
      const four = ['s1 0,0 50x50', 's3 50,0 50x50', 's4 0,50 50x50', 's5 50,50 50x50'];
      expect(onScreen(), four);
      expect(at(g), four);
      // A pane that is not there: nothing happens.
      final before = shown();
      panes.closePane('nobody');
      expect(rooms(shown()), rooms(before));
    });

    test('an arrangement someone made is kept, the room nobody arranged shared again', () {
      final g = joined(s(1, 4));
      expect(tabs.arrangeTab(g, LayoutPreset.oneAndThree), ArrangeOutcome.done);
      panes.closePane(shown()!.allLeaves.last.id);
      expect(onScreen(), ['s1 0,0 67x100', 's2 67,0 33x50', 's3 67,50 33x50']);
    });

    test('down to one pane, the tree on screen is cleared and the tab keeps its terminal', () {
      final g = joined(s(1, 2));
      panes.closePane(shown()!.allLeaves.last.id);
      expect(shown(), isNull);
      // (The tab keeps the tree it had: the session that ended takes its
      // pane out of it, see removeSession.)
      tabs.removeSession('s2');
      expect(at(g), ['s1 0,0 100x100']);
      // With no tree there is nothing to close.
      panes.closePane('nobody');
      panes.removeLeafBySessionId('s1');
      panes.closeTabInPane('nobody', 's1');
      expect(shown(), isNull);
    });

    test('by its session: the pane goes when that was its only one', () {
      joined(s(1, 4));
      panes.removeLeafBySessionId('s3');
      expect(onScreen(), ['s1 0,0 33x100', 's2 33,0 33x100', 's4 67,0 33x100']);
      // One of two sessions a pane shows as tabs: the pane stays, and so
      // does everything around it.
      final first = shown()!.allLeaves.first;
      panes.addSessionToPane(first.id, 's9');
      final before = rooms(shown());
      final split = (shown()! as PaneSplit).id;
      expect(before.map((r) => r.split(' ').last), ['33x100', '33x100', '33x100']);
      panes.removeLeafBySessionId('s9');
      expect(shown()!.allLeaves.first.sessionIds, ['s1']);
      expect(rooms(shown()), before);
      expect((shown()! as PaneSplit).id, split, reason: 'no pane went: the grid is not made again');
      // In an arrangement someone made as well.
      panes.addSessionToPane(first.id, 's9');
      panes.setSplitRatio(split, 0.5);
      final mine = rooms(shown());
      expect(mine.map((r) => r.split(' ').last), ['50x100', '25x100', '25x100']);
      panes.removeLeafBySessionId('s9');
      expect(rooms(shown()), mine);
      expect((shown()! as PaneSplit).id, split);
      // A session that is in no pane changes nothing.
      panes.removeLeafBySessionId('nobody');
      expect(rooms(shown()), mine);
    });

    test('a tab inside a pane: the last one takes the pane with it', () {
      joined(s(1, 3));
      final first = shown()!.allLeaves.first;
      panes.addSessionToPane(first.id, 's9');
      panes.closeTabInPane(first.id, 's9');
      expect(shown()!.allLeaves.first.sessionIds, ['s1']);
      expect(onScreen(), ['s1 0,0 33x100', 's2 33,0 33x100', 's3 67,0 33x100']);
      panes.closeTabInPane(first.id, 's1');
      expect(onScreen(), ['s2 0,0 50x100', 's3 50,0 50x100']);
      panes.closeTabInPane('nobody', 's2');
      expect(onScreen(), ['s2 0,0 50x100', 's3 50,0 50x100']);
    });
  });
}
