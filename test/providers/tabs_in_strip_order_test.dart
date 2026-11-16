// The keyboard's tab keys (Ctrl+Tab, Ctrl+Shift+Tab, Ctrl and a digit) go by
// the tabs as the strip shows them (3.0). They went by a list of sessions
// kept from before tabs held groups, so the third tab by the keys was the
// third session, wherever it stood.

import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';

SessionState _live(String host) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$host',
      connectionLabel: host,
      host: '10.50.0.1',
      port: 22,
      username: 'deploy',
    );

WorkTab _tab(String id, List<String> sessions, {bool pinned = false, bool pendingClose = false}) {
  PaneNode tree = PaneLeaf.single(sessionId: sessions.first);
  for (final s in sessions.skip(1)) {
    tree = PaneSplit(axis: Axis.horizontal, first: tree, second: PaneLeaf.single(sessionId: s));
  }
  return WorkTab(id: id, paneTree: tree, pinned: pinned, pendingClose: pendingClose);
}

List<String> _ids(List<WorkTab> tabs) => [for (final t in tabs) t.id];

void main() {
  final sessions = {for (final s in ['a', 'b', 'c', 'd', 'e', 'f']) s: _live(s)};

  test('pinned tabs first, then the others, each in the order it stands in', () {
    final tabs = [
      _tab('t1', ['a']),
      _tab('t2', ['b'], pinned: true),
      _tab('t3', ['c', 'd']),
      _tab('t4', ['e'], pinned: true),
      _tab('t5', ['f']),
    ];
    expect(_ids(tabsInStripOrder(tabs, sessions)), ['t2', 't4', 't1', 't3', 't5']);
  });

  test('none that is being closed, pinned or not', () {
    final tabs = [
      _tab('t1', ['a'], pendingClose: true),
      _tab('t2', ['b']),
      _tab('t3', ['c'], pinned: true, pendingClose: true),
      _tab('t4', ['d'], pinned: true),
    ];
    expect(_ids(tabsInStripOrder(tabs, sessions)), ['t4', 't2']);
  });

  test('none with nothing to show: its sessions ended or hidden, pinned or not', () {
    final some = {
      ...sessions,
      'b': _live('b').copyWith(isHidden: true),
    }..remove('c');
    final tabs = [
      _tab('t1', ['a']),
      _tab('t2', ['b']),
      _tab('t3', ['c']),
      _tab('t4', ['b', 'c']),
      _tab('t5', ['c', 'd']),
      _tab('t6', ['b'], pinned: true),
      _tab('t7', ['e'], pinned: true),
    ];
    expect(_ids(tabsInStripOrder(tabs, some)), ['t7', 't1', 't5'],
        reason: 'one session on screen is enough');
  });

  test('a tab is named by its terminals: an SFTP pane alone does not keep it in the strip', () {
    final some = {...sessions, 'a': _live('a').copyWith(isHidden: true)};
    final terminalAndFiles = WorkTab(
      id: 't1',
      paneTree: PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf.single(sessionId: 'a'),
        second: PaneLeaf.single(sessionId: 'b', type: 'sftp'),
      ),
    );
    // A tab of files alone stands in the strip by them.
    final filesAlone = WorkTab(id: 't2', paneTree: PaneLeaf.single(sessionId: 'c', type: 'sftp'));
    expect(_ids(tabsInStripOrder([terminalAndFiles, filesAlone], some)), ['t2']);
    expect(_ids(tabsInStripOrder([terminalAndFiles, filesAlone], sessions)), ['t1', 't2']);
  });

  test('no tabs, no strip', () {
    expect(tabsInStripOrder(const [], sessions), isEmpty);
  });
}
