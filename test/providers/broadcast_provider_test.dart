// Who types together: broadcast belongs to a tab, and follows it.
//
// A bug in 2.2.1: a session moved out of the group kept receiving what
// was broadcast, with no way on screen to stop it.
// Broadcast was one switch for the app with a list of
// sessions taken when it was switched on: a session that left its group
// stayed in the list, so it kept receiving, and typing into it still went
// to every pane of the group it had left.

import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/broadcast_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show detachedSessionsProvider;
import 'package:zestssh/providers/terminal_providers.dart' show ActiveSessionsNotifier, activeSessionsProvider;
import 'package:zestssh/providers/work_tabs_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late WorkTabsNotifier tabs;
  late BroadcastModeNotifier broadcast;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    tabs = container.read(workTabsProvider.notifier);
    broadcast = container.read(broadcastModeProvider.notifier);
  });

  tearDown(() => container.dispose());

  BroadcastModeState st() => container.read(broadcastModeProvider);
  WorkTabsState work() => container.read(workTabsProvider);
  WorkTab tab(String id) => work().tabs.firstWhere((t) => t.id == id);

  /// A tab of [sessions], each in a pane of its own. It is the active tab.
  String joined(List<String> sessions) {
    final first = tabs.createTab(sessions.first);
    for (final s in sessions.skip(1)) {
      tabs.mergeTabs(tabs.createTab(s), first);
    }
    tabs.setActiveTab(first);
    return first;
  }

  /// Who gets what is typed into [session].
  Set<String> peers(String session) =>
      broadcastPeers(st(), work(), session, away: container.read(detachedSessionsProvider));

  PaneLeaf leaf(String session) => PaneLeaf.single(sessionId: session);
  PaneNode beside(PaneNode a, PaneNode b) => PaneSplit(axis: Axis.horizontal, first: a, second: b);

  group('The terminals of a tab', () {
    test('are the ones on screen in it, in its order, each once', () {
      final t = WorkTab(
        id: 't',
        paneTree: beside(
          beside(leaf('a'), PaneLeaf(sessionIds: const ['b', 'c'], activeIndex: 1)),
          beside(leaf('d'), leaf('a')),
        ),
      );
      expect(terminalsOf(t), ['a', 'c', 'd'], reason: 'c is in front of b in their pane; a is there once');
    });

    test('are no SFTP pane, and no empty place to connect', () {
      final t = WorkTab(
        id: 't',
        paneTree: beside(
          beside(leaf('a'), PaneLeaf.single(sessionId: 'f', type: 'sftp')),
          beside(PaneLeaf.placeholder(), leaf('b')),
        ),
      );
      expect(terminalsOf(t), ['a', 'b']);
    });

    test('are none of the sessions shown in a window of their own', () {
      final t = WorkTab(id: 't', paneTree: beside(beside(leaf('a'), leaf('b')), leaf('c')));
      expect(terminalsOf(t, away: {'b'}), ['a', 'c']);
      expect(terminalsOf(t, away: {'a', 'b', 'c'}), isEmpty);
    });

    test('a pane with an empty name in front is no terminal', () {
      final t = WorkTab(id: 't', paneTree: beside(leaf('a'), PaneLeaf(sessionIds: const ['', 'b'])));
      expect(terminalsOf(t), ['a']);
    });
  });

  group('A tab that does not broadcast', () {
    test('types to nobody', () {
      final g = joined(['a', 'b', 'c']);
      expect(st().broadcasts(g), isFalse);
      expect(st().any, isFalse);
      expect(broadcastReceivers(st(), tab(g)), isEmpty);
      for (final s in ['a', 'b', 'c']) {
        expect(peers(s), isEmpty, reason: s);
      }
    });

    test('is untouched by another tab that does', () {
      final g1 = joined(['a', 'b']);
      final g2 = joined(['c', 'd']);
      expect(broadcast.startTab(g1), isTrue);
      expect(peers('a'), {'b'});
      expect(peers('c'), isEmpty);
      expect(peers('d'), isEmpty);
      expect(st().broadcasts(g2), isFalse);
    });
  });

  group('Starting and stopping', () {
    test('a tab that broadcasts types to its other terminals, each way', () {
      final g = joined(['a', 'b', 'c']);
      expect(broadcast.startTab(g), isTrue);
      expect(st().broadcasts(g), isTrue);
      expect(st().any, isTrue);
      expect(broadcastReceivers(st(), tab(g)), ['a', 'b', 'c']);
      expect(peers('a'), {'b', 'c'});
      expect(peers('b'), {'a', 'c'});
      expect(peers('c'), {'a', 'b'});
      expect(peers('z'), isEmpty, reason: 'a session of no tab');
    });

    test('a tab with one terminal cannot start: there is nobody to type to', () {
      final one = tabs.createTab('a');
      expect(broadcast.startTab(one), isFalse);
      expect(st().broadcasts(one), isFalse);
      expect(st().any, isFalse);
    });

    test('nor one whose second pane is SFTP, an empty place, or a session behind another', () {
      final sftp = tabs.createTab('a');
      tabs.replaceTabTree(sftp, beside(leaf('a'), PaneLeaf.single(sessionId: 'f', type: 'sftp')));
      expect(broadcast.startTab(sftp), isFalse);

      final empty = tabs.createTab('b');
      tabs.replaceTabTree(empty, beside(leaf('b'), PaneLeaf.placeholder()));
      expect(broadcast.startTab(empty), isFalse);

      final behind = tabs.createTab('c');
      tabs.replaceTabTree(behind, PaneLeaf(sessionIds: const ['c', 'd']));
      expect(broadcast.startTab(behind), isFalse);
      expect(st().any, isFalse);
    });

    test('nor one that is being closed, or is not there', () {
      final g = joined(['a', 'b']);
      tabs.markPendingClose(g);
      expect(broadcast.startTab(g), isFalse);
      expect(broadcast.startTab('no such tab'), isFalse);
      expect(st().any, isFalse);
    });

    test('nor one with all but one of its terminals in windows of their own', () {
      final g = joined(['a', 'b']);
      container.read(detachedSessionsProvider.notifier).detach('b');
      expect(broadcast.startTab(g), isFalse);
      container.read(detachedSessionsProvider.notifier).reattach('b');
      expect(broadcast.startTab(g), isTrue);
    });

    test('starting twice changes nothing, and keeps who is left out', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      broadcast.setReceiving(g, 'c', false);
      final before = st();
      expect(broadcast.startTab(g), isTrue);
      expect(identical(st(), before), isTrue);
      expect(st().leftOut(g), {'c'});
    });

    test('a tab can start with terminals left out, and only its own count', () {
      final g = joined(['a', 'b', 'c']);
      expect(broadcast.startTab(g, leftOut: {'c', 'z'}), isTrue);
      expect(st().leftOut(g), {'c'});
      expect(peers('a'), {'b'});
    });

    test('stopping ends it for that tab only', () {
      final g1 = joined(['a', 'b']);
      final g2 = joined(['c', 'd']);
      broadcast.startTab(g1);
      broadcast.startTab(g2);
      broadcast.stopTab(g1);
      expect(st().broadcasts(g1), isFalse);
      expect(st().broadcasts(g2), isTrue);
      expect(peers('a'), isEmpty);
      expect(peers('c'), {'d'});
      expect(st().any, isTrue);
      broadcast.stopTab(g2);
      expect(st().any, isFalse);
    });

    test('stopping a tab that does not broadcast changes nothing', () {
      final g = joined(['a', 'b']);
      final before = st();
      broadcast.stopTab(g);
      expect(identical(st(), before), isTrue);
    });

    test('everything can be stopped at once', () {
      final g1 = joined(['a', 'b']);
      final g2 = joined(['c', 'd']);
      broadcast.startTab(g1);
      broadcast.startTab(g2);
      broadcast.disable();
      expect(st().any, isFalse);
      expect(peers('a'), isEmpty);
      expect(peers('c'), isEmpty);
    });
  });

  group('A terminal that is left out', () {
    test('gets nothing, and what is typed into it goes nowhere', () {
      final g = joined(['a', 'b', 'c', 'd']);
      broadcast.startTab(g);
      broadcast.setReceiving(g, 'c', false);
      expect(st().leftOut(g), {'c'});
      expect(broadcastReceivers(st(), tab(g)), ['a', 'b', 'd']);
      expect(peers('a'), {'b', 'd'});
      expect(peers('c'), isEmpty);
    });

    test('takes part again when it is put back', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      broadcast.setReceiving(g, 'c', false);
      broadcast.setReceiving(g, 'c', true);
      expect(st().leftOut(g), isEmpty);
      expect(peers('c'), {'a', 'b'});
    });

    test('saying again what already holds changes nothing', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      var before = st();
      broadcast.setReceiving(g, 'c', true);
      expect(identical(st(), before), isTrue);
      broadcast.setReceiving(g, 'c', false);
      before = st();
      broadcast.setReceiving(g, 'c', false);
      expect(identical(st(), before), isTrue);
    });

    test('nothing is left out of a tab that does not broadcast', () {
      final g = joined(['a', 'b']);
      final before = st();
      broadcast.setReceiving(g, 'a', false);
      broadcast.receiveAll(g);
      expect(identical(st(), before), isTrue);
      expect(st().leftOut(g), isEmpty);
    });

    test('all of them take part again at once', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      broadcast.setReceiving(g, 'a', false);
      broadcast.setReceiving(g, 'b', false);
      broadcast.receiveAll(g);
      expect(st().leftOut(g), isEmpty);
      expect(st().broadcasts(g), isTrue);
      final before = st();
      broadcast.receiveAll(g);
      expect(identical(st(), before), isTrue, reason: 'nothing was left out');
    });

    test('with all but one left out the tab still broadcasts, to nobody', () {
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      broadcast.setReceiving(g, 'b', false);
      expect(st().broadcasts(g), isTrue);
      expect(peers('a'), isEmpty);
      expect(peers('b'), isEmpty);
    });
  });

  group('Who receives follows the tab', () {
    test('a session moved out of the tab gets nothing more, and sends nothing more', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      tabs.splitSessionToNewTab('c');
      expect(tab(g).contains('c'), isFalse);
      expect(peers('a'), {'b'});
      expect(peers('c'), isEmpty, reason: 'it used to go on typing into the group it had left');
      expect(st().broadcasts(g), isTrue);
    });

    test('moved to another tab, it types with that one only if that one broadcasts', () {
      final g1 = joined(['a', 'b', 'c']);
      final g2 = joined(['d', 'e']);
      broadcast.startTab(g1);
      tabs.moveSessionToTab('c', g2);
      expect(peers('c'), isEmpty);
      expect(peers('d'), isEmpty);
      broadcast.startTab(g2);
      expect(peers('c'), {'d', 'e'});
      expect(peers('a'), {'b'});
    });

    test('a session that joins the tab receives', () {
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      tabs.mergeTabs(tabs.createTab('c'), g);
      expect(peers('a'), {'b', 'c'});
      expect(peers('c'), {'a', 'b'});
    });

    test('a session that ended is gone from it', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      tabs.removeSession('b');
      expect(peers('a'), {'c'});
      expect(st().broadcasts(g), isTrue);
    });

    test('a tab that comes down to one terminal stops, and does not start again by itself', () {
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      tabs.splitSessionToNewTab('b');
      expect(st().broadcasts(g), isFalse);
      expect(st().any, isFalse);
      // Terminals join it again: it does not broadcast until someone says so.
      tabs.mergeTabs(work().tabs.firstWhere((t) => t.contains('b')).id, g);
      tabs.mergeTabs(tabs.createTab('c'), g);
      expect(terminalsOf(tab(g)), hasLength(3));
      expect(st().broadcasts(g), isFalse);
      expect(peers('a'), isEmpty);
    });

    test('a tab that is closed stops', () {
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      tabs.closeTab(g);
      expect(st().broadcasts(g), isFalse);
      expect(st().tabs, isEmpty);
    });

    test('a tab that is being closed stops, and stays stopped when the close is taken back', () {
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      tabs.markPendingClose(g);
      expect(st().broadcasts(g), isFalse);
      expect(peers('a'), isEmpty);
      tabs.cancelPendingClose(g);
      expect(tab(g).pendingClose, isFalse);
      expect(st().broadcasts(g), isFalse);
      expect(peers('a'), isEmpty);
    });

    test('one tab stopping this way leaves another that broadcasts alone', () {
      final g1 = joined(['a', 'b']);
      final g2 = joined(['c', 'd', 'e']);
      broadcast.startTab(g1);
      broadcast.startTab(g2);
      broadcast.setReceiving(g2, 'e', false);
      tabs.closeTab(g1);
      expect(st().broadcasts(g2), isTrue);
      expect(st().leftOut(g2), {'e'});
      expect(peers('c'), {'d'});
    });

    test('a session that left is no longer remembered as left out', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      broadcast.setReceiving(g, 'c', false);
      tabs.splitSessionToNewTab('c');
      expect(st().leftOut(g), isEmpty);
      // Back in the tab it is a terminal like the others.
      tabs.mergeTabs(work().tabs.firstWhere((t) => t.contains('c')).id, g);
      expect(peers('a'), {'b', 'c'});
    });

    test('a change of the tabs that changes nothing for a broadcast leaves it as it is', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      broadcast.setReceiving(g, 'c', false);
      final before = st();
      tabs.renameTab(g, 'Web servers');
      tabs.createTab('z');
      expect(identical(st(), before), isTrue);
    });

    test('a session behind another in its pane gets nothing, and is still left out when it comes to the front', () {
      final g = joined(['a', 'b']);
      tabs.replaceTabTree(g, beside(leaf('a'), PaneLeaf(sessionIds: const ['b', 'c'], activeIndex: 0)));
      broadcast.startTab(g);
      expect(peers('a'), {'b'});
      expect(peers('c'), isEmpty, reason: 'nothing is typed into a terminal nobody sees');
      broadcast.setReceiving(g, 'b', false);
      // c comes to the front of that pane, b goes behind it.
      tabs.replaceTabTree(g, beside(leaf('a'), PaneLeaf(sessionIds: const ['b', 'c'], activeIndex: 1)));
      expect(peers('a'), {'c'});
      expect(peers('b'), isEmpty);
      expect(st().leftOut(g), {'b'}, reason: 'it is still in the tab');
      tabs.replaceTabTree(g, beside(leaf('a'), PaneLeaf(sessionIds: const ['b', 'c'], activeIndex: 0)));
      expect(peers('a'), isEmpty, reason: 'b is in front again, and still left out');
    });

    test('a session shown in a window of its own gets nothing, and sends nothing', () {
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      final windows = container.read(detachedSessionsProvider.notifier);
      windows.detach('c');
      expect(peers('a'), {'b'});
      expect(peers('c'), isEmpty);
      expect(st().broadcasts(g), isTrue);
      windows.reattach('c');
      expect(peers('a'), {'b', 'c'});
    });

    test('a tab left with one terminal on screen because the others went to windows stops', () {
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      final windows = container.read(detachedSessionsProvider.notifier);
      windows.detach('b');
      expect(st().broadcasts(g), isFalse);
      windows.reattach('b');
      expect(st().broadcasts(g), isFalse, reason: 'it does not start again by itself');
    });
  });

  group('Stopping by itself', () {
    test('is said for a tab that is still there with one terminal on screen', () async {
      final said = <String>[];
      final sub = broadcast.stoppedByItself.listen(said.add);
      addTearDown(sub.cancel);
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      tabs.splitSessionToNewTab('c');
      await Future<void>.delayed(Duration.zero);
      expect(said, isEmpty, reason: 'two are left');
      tabs.splitSessionToNewTab('b');
      await Future<void>.delayed(Duration.zero);
      expect(said, [g]);
      expect(st().broadcasts(g), isFalse, reason: 'said once it has stopped');
    });

    test('is not said for a tab that is closed, or being closed', () async {
      final said = <String>[];
      final sub = broadcast.stoppedByItself.listen(said.add);
      addTearDown(sub.cancel);
      final g1 = joined(['a', 'b']);
      final g2 = joined(['c', 'd']);
      broadcast.startTab(g1);
      broadcast.startTab(g2);
      tabs.markPendingClose(g1);
      tabs.closeTab(g2);
      await Future<void>.delayed(Duration.zero);
      expect(said, isEmpty);
      expect(st().any, isFalse);
    });

    // The picture of a tab of sixteen (in a UI review) showed
    // "this tab has one terminal on screen" over sixteen panes: the four
    // sessions of the tab before ended together, and on its way out that tab
    // passed through one terminal left.
    test('is not said for a tab whose sessions all ended together', () async {
      final said = <String>[];
      final sub = broadcast.stoppedByItself.listen(said.add);
      addTearDown(sub.cancel);
      final g = joined(['a', 'b', 'c', 'd']);
      broadcast.startTab(g);
      for (final s in ['a', 'b', 'c', 'd']) {
        tabs.removeSession(s);
      }
      await Future<void>.delayed(Duration.zero);
      expect(work().tabs.where((t) => t.id == g), isEmpty, reason: 'the tab is gone');
      expect(said, isEmpty);
      expect(st().any, isFalse);
    });

    test('is said when all but one of its sessions ended together', () async {
      final said = <String>[];
      final sub = broadcast.stoppedByItself.listen(said.add);
      addTearDown(sub.cancel);
      final g = joined(['a', 'b', 'c']);
      broadcast.startTab(g);
      tabs.removeSession('b');
      tabs.removeSession('c');
      await Future<void>.delayed(Duration.zero);
      expect(said, [g]);
    });

    test('is not said when the person stops it', () async {
      final said = <String>[];
      final sub = broadcast.stoppedByItself.listen(said.add);
      addTearDown(sub.cancel);
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      broadcast.stopTab(g);
      await Future<void>.delayed(Duration.zero);
      expect(said, isEmpty);
    });
  });

  group('The tab in front', () {
    test('says who types together in it', () {
      final g1 = joined(['a', 'b', 'c']);
      final g2 = joined(['d', 'e']);
      expect(container.read(activeTabBroadcastProvider), isEmpty);
      broadcast.startTab(g1);
      expect(container.read(activeTabBroadcastProvider), isEmpty, reason: 'the tab in front is the other one');
      tabs.setActiveTab(g1);
      expect(container.read(activeTabBroadcastProvider), ['a', 'b', 'c']);
      broadcast.setReceiving(g1, 'b', false);
      expect(container.read(activeTabBroadcastProvider), ['a', 'c']);
      container.read(detachedSessionsProvider.notifier).detach('c');
      expect(container.read(activeTabBroadcastProvider), ['a']);
      tabs.setActiveTab(g2);
      expect(container.read(activeTabBroadcastProvider), isEmpty);
    });

    test('with no tab at all it is nobody', () {
      expect(container.read(activeTabBroadcastProvider), isEmpty);
    });
  });

  group('A phone: the sessions that were picked', () {
    test('type together while it is on', () {
      broadcast.enable({'a', 'b', 'c'});
      expect(st().enabled, isTrue);
      expect(st().any, isTrue);
      expect(peers('a'), {'b', 'c'});
      expect(peers('z'), isEmpty, reason: 'one that was not picked types alone');
      broadcast.toggle();
      expect(st().enabled, isFalse);
      expect(peers('a'), isEmpty);
      expect(st().targetSessionIds, {'a', 'b', 'c'}, reason: 'they are still picked');
      broadcast.toggle();
      expect(peers('a'), {'b', 'c'});
    });

    test('one is added, taken out and switched', () {
      broadcast.enable({'a', 'b'});
      broadcast.addTarget('c');
      expect(peers('a'), {'b', 'c'});
      broadcast.removeTarget('b');
      expect(peers('a'), {'c'});
      expect(peers('b'), isEmpty);
      broadcast.toggleTarget('b');
      broadcast.toggleTarget('c');
      expect(st().targetSessionIds, {'a', 'b'});
      broadcast.disable();
      expect(st().enabled, isFalse);
      expect(st().targetSessionIds, isEmpty);
    });

    test('never asks for the tabs of a computer', () {
      final seen = <String>[];
      final phone = ProviderContainer(overrides: [
        workTabsProvider.overrideWith((ref) {
          seen.add('tabs');
          return WorkTabsNotifier(ref);
        }),
      ]);
      addTearDown(phone.dispose);
      final n = phone.read(broadcastModeProvider.notifier);
      n.enable({'a', 'b'});
      n.toggleTarget('c');
      n.settle();
      n.stopTab('t');
      n.setReceiving('t', 'a', false);
      n.receiveAll('t');
      n.disable();
      expect(seen, isEmpty);
    });

    test('they type together also where they stand in tabs that do not broadcast', () {
      joined(['a', 'b']);
      joined(['c', 'd']);
      broadcast.enable({'a', 'c'});
      expect(peers('a'), {'c'});
      expect(peers('c'), {'a'});
      expect(peers('b'), isEmpty, reason: 'its tab does not broadcast, and it was not picked');
    });

    test('in a tab that broadcasts, the tab decides and the picked sessions do not', () {
      final g = joined(['a', 'b']);
      broadcast.startTab(g);
      broadcast.enable({'a', 'z'});
      expect(peers('a'), {'b'});
      broadcast.setReceiving(g, 'a', false);
      expect(peers('a'), isEmpty, reason: 'left out of its tab, it types alone');
    });
  });

  // A session that is files only (an SFTP-only host) has no shell: a tab's
  // broadcast passes it over, as one in a window of its own.
  group('A session that is files only', () {
    late ProviderContainer files;

    setUp(() async {
      final prefs = await SharedPreferences.getInstance();
      files = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(_FilesOnly.new),
      ]);
    });

    tearDown(() => files.dispose());

    String joinedIn(List<String> sessions) {
      final t = files.read(workTabsProvider.notifier);
      final first = t.createTab(sessions.first);
      for (final s in sessions.skip(1)) {
        t.mergeTabs(t.createTab(s), first);
      }
      t.setActiveTab(first);
      return first;
    }

    test('is no terminal of its tab: beside one terminal, the tab does not broadcast', () {
      final g = joinedIn(['a', 'f']);
      expect(files.read(broadcastModeProvider.notifier).startTab(g), isFalse);
    });

    test('gets nothing, and what is typed elsewhere in the tab goes to the terminals alone', () {
      final g = joinedIn(['a', 'b', 'f']);
      expect(files.read(broadcastModeProvider.notifier).startTab(g), isTrue);
      final tab = files.read(workTabsProvider).tabs.firstWhere((t) => t.id == g);
      expect(broadcastReceivers(files.read(broadcastModeProvider), tab, away: files.read(broadcastAwayProvider)),
          ['a', 'b']);
      expect(
          broadcastPeers(files.read(broadcastModeProvider), files.read(workTabsProvider), 'a',
              away: files.read(broadcastAwayProvider)),
          {'b'});
    });
  });
}

/// Sessions of which `f` is files only.
class _FilesOnly extends ActiveSessionsNotifier {
  _FilesOnly(super.ref);

  @override
  Set<String> get filesOnlySessionIds => const {'f'};
}
