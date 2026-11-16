// "Broadcast to hosts" (3.0): the sessions of the hosts picked stand
// together in one tab, in the grid a tab nobody arranged stands in, whether
// they were opened for it or were open already, alone or in a group.
//
// A bug in 2.2.1: to broadcast, every session had to be opened by hand and
// dragged to the same group, which left them in an odd arrangement.

import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';

import '../models/pane_rooms.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late WorkTabsNotifier tabs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    tabs = container.read(workTabsProvider.notifier);
  });

  tearDown(() => container.dispose());

  WorkTabsState st() => container.read(workTabsProvider);
  WorkTab tab(String id) => st().tabs.firstWhere((t) => t.id == id);
  List<String> sessionsOf(String id) => tab(id).paneTree.allLeaves.map((l) => l.sessionId).toList();

  String joined(List<String> sessions) {
    final first = tabs.createTab(sessions.first);
    for (final s in sessions.skip(1)) {
      tabs.mergeTabs(tabs.createTab(s), first);
    }
    return first;
  }

  test('sessions each in a tab of their own stand together in the first one, in its grid, in front', () {
    for (final s in ['a', 'b', 'c', 'd', 'e']) {
      tabs.createTab(s);
    }
    tabs.createTab('z');
    final gathered = tabs.gatherInTab(['a', 'b', 'c', 'd', 'e'])!;
    expect(sessionsOf(gathered), ['a', 'b', 'c', 'd', 'e']);
    expect(rooms(tab(gathered).paneTree, bySession: true),
        ['a 0,0 33x50', 'b 33,0 33x50', 'c 67,0 33x50', 'd 0,50 50x50', 'e 50,50 50x50']);
    expect(isTiled(tab(gathered).paneTree), isTrue);
    expect(st().activeTabId, gathered);
    expect(st().tabs, hasLength(2), reason: 'the tabs they left were empty and went; z stays');
    expect(sessionsOf(st().tabs.firstWhere((t) => t.id != gathered).id), ['z']);
  });

  test('a tab arranged by hand, with a place to connect, is made the grid', () {
    final mine = tabs.createTab('a');
    // a above an empty place: an arrangement someone chose.
    tabs.replaceTabTree(
      mine,
      PaneSplit(axis: Axis.vertical, first: PaneLeaf.single(sessionId: 'a'), second: PaneLeaf.placeholder()),
    );
    tabs.createTab('b');
    tabs.createTab('c');
    final gathered = tabs.gatherInTab(['a', 'b', 'c'])!;
    expect(gathered, mine);
    expect(tab(gathered).paneTree.allLeaves.where((l) => l.isPlaceholder), isEmpty);
    expect(isTiled(tab(gathered).paneTree), isTrue);
    expect(rooms(tab(gathered).paneTree, bySession: true), ['a 0,0 33x100', 'b 33,0 33x100', 'c 67,0 33x100']);
  });

  test('in the order given, not the order the tabs stood in', () {
    for (final s in ['a', 'b', 'c']) {
      tabs.createTab(s);
    }
    final gathered = tabs.gatherInTab(['c', 'a', 'b'])!;
    expect(sessionsOf(gathered), ['c', 'a', 'b']);
  });

  test('one that is in a group comes out of it alone, and the group keeps the rest', () {
    final group = joined(['a', 'g1', 'g2']);
    tabs.createTab('b');
    final gathered = tabs.gatherInTab(['a', 'b'])!;
    expect(gathered, isNot(group), reason: 'the group is not the broadcast tab');
    expect(sessionsOf(gathered), ['a', 'b']);
    expect(sessionsOf(group), ['g1', 'g2']);
  });

  test('a group whose sessions are all picked stands as one tab of them', () {
    joined(['a', 'b']);
    tabs.createTab('c');
    final gathered = tabs.gatherInTab(['a', 'b', 'c'])!;
    expect(sessionsOf(gathered), ['a', 'b', 'c']);
    expect(st().tabs.where((t) => t.contains('a') || t.contains('b') || t.contains('c')), hasLength(1));
  });

  test('a session named twice is gathered once, and one in no tab is passed over', () {
    tabs.createTab('a');
    tabs.createTab('b');
    final gathered = tabs.gatherInTab(['a', 'b', 'a', 'ghost'])!;
    expect(sessionsOf(gathered), ['a', 'b']);
  });

  test('nothing to gather is nothing', () {
    tabs.createTab('a');
    final before = st();
    expect(tabs.gatherInTab(['ghost']), isNull);
    expect(tabs.gatherInTab(const []), isNull);
    expect(identical(st(), before), isTrue);
  });

  test('a tab of its own that the first one had is kept, with its name', () {
    final mine = tabs.createTab('a');
    tabs.renameTab(mine, 'Web servers');
    tabs.createTab('b');
    final gathered = tabs.gatherInTab(['a', 'b'])!;
    expect(gathered, mine);
    expect(tab(gathered).customName, 'Web servers');
  });
}
