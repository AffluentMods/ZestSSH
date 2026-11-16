import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show v3ActiveSessionTabProvider;
import 'package:zestssh/providers/pane_tree_provider.dart' show focusedPaneProvider;
import 'package:zestssh/providers/work_tabs_provider.dart';

/// Tests the drag-a-terminal-to-the-header group edits: moving a session into
/// another group, and popping one out into its own group. Both must reflow the
/// trees they touch and keep exactly the right sessions in each tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late WorkTabsNotifier tabs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    tabs = container.read(workTabsProvider.notifier);
  });

  tearDown(() => container.dispose());

  WorkTabsState st() => container.read(workTabsProvider);
  Set<String> sessionsIn(String tabId) =>
      st().tabs.firstWhere((t) => t.id == tabId).sessionIds.toSet();
  String tabOf(String sessionId) =>
      st().tabs.firstWhere((t) => t.contains(sessionId)).id;

  /// Build a two-session group and return its tab id.
  String makeGroup(String a, String b) {
    final t1 = tabs.createTab(a);
    final t2 = tabs.createTab(b);
    tabs.mergeTabs(t2, t1); // t2 merged into t1 -> group [a, b]
    return t1;
  }

  test('moveSessionToTab moves a session between existing groups', () {
    final g1 = makeGroup('s1', 's2'); // [s1, s2]
    final g2 = tabs.createTab('s3'); // [s3]
    expect(st().tabs.length, 2);

    tabs.moveSessionToTab('s2', g2);

    expect(st().tabs.length, 2, reason: 'no tab created or dropped');
    expect(sessionsIn(g1), {'s1'}, reason: 's2 left the source group');
    expect(sessionsIn(g2), {'s3', 's2'}, reason: 's2 joined the destination');
    expect(tabOf('s2'), g2);
  });

  test('moveSessionToTab drops the source tab when it empties', () {
    final ta = tabs.createTab('a'); // [a]
    final tb = tabs.createTab('b'); // [b], active
    expect(st().tabs.length, 2);

    tabs.moveSessionToTab('a', tb); // a's tab had only a -> emptied

    expect(st().tabs.length, 1, reason: 'the emptied source tab is gone');
    expect(st().tabs.any((t) => t.id == ta), isFalse);
    expect(sessionsIn(tb), {'b', 'a'});
    expect(st().activeTabId, tb);
  });

  test('moveSessionToTab is a no-op when already in the destination', () {
    final g1 = makeGroup('x', 'y'); // [x, y]
    final before = sessionsIn(g1);
    tabs.moveSessionToTab('x', g1); // already there
    expect(sessionsIn(g1), before);
    expect(st().tabs.length, 1);
  });

  test('splitSessionToNewTab pops a session out into its own active group', () {
    final g1 = makeGroup('s1', 's2');
    // Fold a third session in so the group has 3.
    final t3 = tabs.createTab('s3');
    tabs.mergeTabs(t3, g1); // group [s1, s2, s3]
    expect(st().tabs.length, 1);
    expect(sessionsIn(g1).length, 3);

    tabs.splitSessionToNewTab('s2');

    expect(st().tabs.length, 2, reason: 'a new standalone tab appeared');
    expect(sessionsIn(g1), {'s1', 's3'}, reason: 's2 left the group');
    final newTab = tabOf('s2');
    expect(newTab, isNot(g1));
    expect(sessionsIn(newTab), {'s2'});
    expect(st().activeTabId, newTab, reason: 'the popped-out session focuses');
  });

  test('popping a session out brings the selection and the focus with it', () {
    // (2.2.1 highlighted the new tab while a session of the group that was
    // left stayed selected and was shown full size.)
    final g1 = makeGroup('s1', 's2');
    tabs.mergeTabs(tabs.createTab('s3'), g1);
    tabs.setActiveTab(g1);
    expect(container.read(v3ActiveSessionTabProvider), 's1');
    container.read(focusedPaneProvider.notifier).state = 'a-pane-of-the-old-group';

    tabs.splitSessionToNewTab('s2');

    expect(st().activeTabId, tabOf('s2'));
    expect(container.read(v3ActiveSessionTabProvider), 's2', reason: 'the session selected is the one moved');
    expect(container.read(focusedPaneProvider), isNull, reason: 'no pane of the old group stays focused');
  });

  test('a move that takes the view along brings the selection and the focus too; one that does not leaves them', () {
    final ta = tabs.createTab('a');
    final tb = tabs.createTab('b');
    final tc = tabs.createTab('c');
    // The view stays on c while b moves into a: nothing about c changes.
    tabs.setActiveTab(tc);
    container.read(focusedPaneProvider.notifier).state = 'kept';
    tabs.moveSessionToTab('b', ta);
    expect(st().activeTabId, tc);
    expect(container.read(v3ActiveSessionTabProvider), 'c');
    expect(container.read(focusedPaneProvider), 'kept');
    expect(st().tabs.any((t) => t.id == tb), isFalse);

    // c is in front and moves into a: its tab is gone, so the view follows.
    tabs.moveSessionToTab('c', ta);
    expect(st().activeTabId, ta);
    expect(container.read(v3ActiveSessionTabProvider), st().activeTab!.sessionIds.first);
    expect(container.read(focusedPaneProvider), isNull);
  });

  // A bug in 2.2.1: a group that had an empty
  // tile got a whole new tile when a host was merged into it. Master fills
  // the empty place first (withTreeAdded); this pins it for the two ways a
  // host joins a group from the header.
  test('a tab merged into a group takes the group\'s empty place, where it stands', () {
    final g = makeGroup('s1', 's2');
    expect(tabs.arrangeTab(g, LayoutPreset.grid2x2), ArrangeOutcome.done);
    PaneNode tree() => st().tabs.firstWhere((t) => t.id == g).paneTree;
    expect(tree().allLeaves.map((l) => l.sessionIdOrNull), ['s1', 's2', null, null]);

    tabs.mergeTabs(tabs.createTab('s3'), g);
    expect(tree().allLeaves.map((l) => l.sessionIdOrNull), ['s1', 's2', 's3', null],
        reason: 'no fifth tile: the first empty one took it');
    expect(st().tabs, hasLength(1));

    // A terminal dragged from another group onto this one's tab: the same.
    final other = makeGroup('s4', 's5');
    tabs.moveSessionToTab('s5', g);
    expect(tree().allLeaves.map((l) => l.sessionIdOrNull), ['s1', 's2', 's3', 's5']);
    expect(sessionsIn(other), {'s4'});

    // With no empty place left, the next one gets a tile of its own.
    tabs.mergeTabs(other, g);
    expect(tree().allLeaves.map((l) => l.sessionIdOrNull), containsAll(['s1', 's2', 's3', 's4', 's5']));
    expect(tree().allLeaves, hasLength(5));
  });

  test('splitSessionToNewTab is a no-op for an already standalone session', () {
    final tx = tabs.createTab('x'); // [x] alone
    tabs.splitSessionToNewTab('x');
    expect(st().tabs.length, 1);
    expect(tabOf('x'), tx);
  });

  test('rebalancePaneTree gives every leaf an equal share', () {
    // A left-nested 3-leaf tree with default 0.5 ratios is uneven
    // (0.5 / 0.25 / 0.25); rebalancing sets the outer split to 1:2.
    final tree = PaneSplit(
      axis: Axis.horizontal,
      first: PaneLeaf.single(sessionId: 'a'),
      second: PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf.single(sessionId: 'b'),
        second: PaneLeaf.single(sessionId: 'c'),
      ),
    );
    final balanced = rebalancePaneTree(tree) as PaneSplit;
    // first has 1 leaf, second has 2 -> ratio 1/3.
    expect(balanced.ratio, closeTo(1 / 3, 0.0001));
    expect(balanced.allLeaves.length, 3);
  });
}
