import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show v3ActiveSessionTabProvider;
import 'package:zestssh/providers/pane_tree_provider.dart' show focusedPaneProvider;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';

/// A tab dragged along the strip is put beside the tab it was dropped on,
/// and a terminal dragged out of its group becomes a tab beside the one it
/// was dropped on (3.0, a reported bug). The tabs are
/// named by their ids: the strip shows pinned tabs first and leaves out a
/// tab being closed, so a place in the strip is not a place in the list.
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

  /// A tab by the sessions in it.
  String named(WorkTab t) => (t.sessionIds.toList()..sort()).join('+');

  /// The sessions of each tab, in the order of the list of tabs.
  List<String> listed() => [for (final t in st().tabs) named(t)];

  /// The same in the order the strip shows them.
  List<String> shown() {
    final sessions = <String, SessionState>{
      for (final t in st().tabs)
        for (final id in t.sessionIds)
          id: SessionState(
            status: SessionStatus.connected,
            connectionId: 'c-$id',
            connectionLabel: id,
            host: '10.50.0.5',
            port: 22,
            username: 'deploy',
          ),
    };
    return [for (final t in tabsInStripOrder(st().tabs, sessions)) named(t)];
  }

  group('a tab moved beside another', () {
    test('stands right before it, or right after it', () {
      final a = tabs.createTab('a');
      final b = tabs.createTab('b');
      final c = tabs.createTab('c');
      final d = tabs.createTab('d');
      expect(listed(), ['a', 'b', 'c', 'd']);

      tabs.moveTabBeside(a, c, after: true);
      expect(listed(), ['b', 'c', 'a', 'd'], reason: 'to the right: after the one it was dropped on');

      tabs.moveTabBeside(d, b, after: false);
      expect(listed(), ['d', 'b', 'c', 'a'], reason: 'to the left: before it');

      tabs.moveTabBeside(d, c, after: false);
      expect(listed(), ['b', 'd', 'c', 'a'], reason: 'to the right, before the one named');

      tabs.moveTabBeside(a, b, after: true);
      expect(listed(), ['b', 'a', 'd', 'c'], reason: 'to the left, after the one named');
    });

    test('where it already stands: nothing changes', () {
      final a = tabs.createTab('a');
      final b = tabs.createTab('b');
      tabs.createTab('c');
      tabs.moveTabBeside(b, a, after: true);
      expect(listed(), ['a', 'b', 'c']);
      tabs.moveTabBeside(a, b, after: false);
      expect(listed(), ['a', 'b', 'c']);
    });

    test('itself, or a tab that is not there: nothing changes', () {
      tabs.createTab('a');
      final b = tabs.createTab('b');
      final c = tabs.createTab('c');
      tabs.moveTabBeside(b, b, after: true);
      expect(listed(), ['a', 'b', 'c']);
      tabs.moveTabBeside(b, b, after: false);
      expect(listed(), ['a', 'b', 'c']);
      tabs.moveTabBeside(c, 'no-such-tab', after: true);
      expect(listed(), ['a', 'b', 'c']);
      tabs.moveTabBeside(c, 'no-such-tab', after: false);
      expect(listed(), ['a', 'b', 'c']);
      tabs.moveTabBeside('no-such-tab', b, after: false);
      expect(listed(), ['a', 'b', 'c']);
    });

    test('with a pinned tab that is not first in the list, the tab dragged is the one moved', () {
      final a = tabs.createTab('a');
      final b = tabs.createTab('b');
      final c = tabs.createTab('c');
      final d = tabs.createTab('d');
      tabs.togglePin(c);
      // The strip shows the pinned tab first: its third place in the list is
      // the strip's first, and every place after it is off by one.
      expect(listed(), ['a', 'b', 'c', 'd']);
      expect(shown(), ['c', 'a', 'b', 'd']);

      // 'd' (the strip's last) dropped before 'a' (the strip's second).
      tabs.moveTabBeside(d, a, after: false);
      expect(shown(), ['c', 'd', 'a', 'b'], reason: 'the tab dragged, to where it was dropped');

      tabs.moveTabBeside(a, b, after: true);
      expect(shown(), ['c', 'd', 'b', 'a']);
      expect(st().tabs.firstWhere((t) => t.id == c).pinned, isTrue, reason: 'pinned as it was');
    });

    test('with a tab being closed in the list, the tab dragged is the one moved', () {
      final a = tabs.createTab('a');
      final x = tabs.createTab('x');
      final b = tabs.createTab('b');
      final c = tabs.createTab('c');
      tabs.markPendingClose(x);
      expect(shown(), ['a', 'b', 'c'], reason: 'a tab being closed is not in the strip');

      tabs.moveTabBeside(c, b, after: false);
      expect(shown(), ['a', 'c', 'b']);
      tabs.moveTabBeside(a, b, after: true);
      expect(shown(), ['c', 'b', 'a']);
      expect(st().tabs.any((t) => t.id == a), isTrue);
    });

    test('the tab in front stays in front', () {
      final a = tabs.createTab('a');
      final b = tabs.createTab('b');
      final c = tabs.createTab('c');
      tabs.setActiveTab(b);
      tabs.moveTabBeside(b, c, after: true);
      expect(st().activeTabId, b);
      tabs.moveTabBeside(a, c, after: true);
      expect(st().activeTabId, b);
    });
  });

  group('a terminal dragged out of its group', () {
    /// A tab of [sessions], each in a pane of its own.
    String joined(List<String> sessions) {
      final first = tabs.createTab(sessions.first);
      for (final s in sessions.skip(1)) {
        tabs.mergeTabs(tabs.createTab(s), first);
      }
      return first;
    }

    test('dropped on a tab\'s edge, it becomes a tab right before that one, or right after it', () {
      final a = tabs.createTab('a');
      final b = tabs.createTab('b');
      final g = joined(['s1', 's2', 's3']);
      expect(listed(), ['a', 'b', 's1+s2+s3']);

      tabs.splitSessionToNewTab('s2', besideTabId: b, after: false);
      expect(listed(), ['a', 's2', 'b', 's1+s3']);
      expect(st().activeTabId, st().tabs[1].id, reason: 'the new tab is the one in front');

      tabs.splitSessionToNewTab('s3', besideTabId: a, after: true);
      expect(listed(), ['a', 's3', 's2', 'b', 's1']);
      expect(st().tabs.last.id, g, reason: 'the group it left is the tab it was');
    });

    test('dropped on the edge of the group it leaves, it stands beside that group', () {
      final g = joined(['s1', 's2', 's3']);
      tabs.createTab('z');
      tabs.splitSessionToNewTab('s1', besideTabId: g, after: false);
      expect(listed(), ['s1', 's2+s3', 'z']);
      tabs.splitSessionToNewTab('s3', besideTabId: g, after: true);
      expect(listed(), ['s1', 's2', 's3', 'z']);
    });

    test('with no tab named, or one that is not there, it goes to the end', () {
      joined(['s1', 's2', 's3']);
      tabs.createTab('z');
      tabs.splitSessionToNewTab('s1');
      expect(listed(), ['s2+s3', 'z', 's1']);
      tabs.splitSessionToNewTab('s2', besideTabId: 'no-such-tab', after: false);
      expect(listed(), ['s3', 'z', 's1', 's2']);
    });

    test('the selection and the focus go with it', () {
      final a = tabs.createTab('a');
      final g = joined(['s1', 's2']);
      tabs.setActiveTab(g);
      expect(container.read(v3ActiveSessionTabProvider), 's1');
      container.read(focusedPaneProvider.notifier).state = 'a-pane-of-the-group';

      tabs.splitSessionToNewTab('s2', besideTabId: a, after: false);
      expect(listed(), ['s2', 'a', 's1']);
      expect(container.read(focusedPaneProvider), isNull);
      expect(container.read(v3ActiveSessionTabProvider), 's2');
    });

    test('alone in its tab already: its tab is what moves, and only when a place is named', () {
      final a = tabs.createTab('a');
      final b = tabs.createTab('b');
      tabs.createTab('c');
      tabs.splitSessionToNewTab('c', besideTabId: a, after: false);
      expect(listed(), ['c', 'a', 'b'], reason: 'no new tab: the one it has moved');
      tabs.splitSessionToNewTab('c', besideTabId: b, after: true);
      expect(listed(), ['a', 'b', 'c']);
      tabs.splitSessionToNewTab('a');
      expect(listed(), ['a', 'b', 'c']);
    });
  });
}
