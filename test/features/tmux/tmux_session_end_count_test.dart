import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/providers/terminal_providers.dart';

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
  void set(Map<String, SessionState> s) => state = s;
}

/// A bug: after Close window on a session's only window,
/// tmux ended and the tab was the shell again, but the tab still showed tmux
/// with one session. When tmux ends in a tab the host is asked again how
/// many sessions it has, and the tab's count follows.
void main() {
  Future<Map<String, int>> endIn(
      (int?, String) said, {int before = 1, Future<void> Function(TmuxController c)? end}) async {
    var asked = 0;
    final container = ProviderContainer(overrides: [activeSessionsProvider.overrideWith(_Sessions.new)]);
    addTearDown(container.dispose);
    (container.read(activeSessionsProvider.notifier) as _Sessions).set({
      's1': const SessionState(
        status: SessionStatus.connected,
        connectionId: 'h-1',
        connectionLabel: 'web-01',
        host: '192.168.10.21',
        port: 22,
        username: 'deploy',
      ),
    });
    await container.read(tmuxSessionCountsProvider.notifier).set('h-1', before);
    final host = container.read(Provider((ref) => TmuxSessionHost(ref, 's1', listSessionsForTest: () async {
          asked++;
          return said;
        })));
    final c = TmuxController(sendBytes: (_) {}, expectMarker: false);
    addTearDown(c.dispose);
    host.attachInband(c, forceExit: () {});
    // Two windows, so that one can be picked after the end.
    c.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
    c.onData(utf8.encode('%layout-change @2 bc63,80x24,0,0,1 bc63,80x24,0,0,1 -\n'));
    await pumpEventQueue();
    final askedBefore = asked;
    await (end ?? (c) async => c.onData(utf8.encode('%exit\n')))(c);
    await pumpEventQueue();
    expect(asked - askedBefore, 1, reason: 'asked once, as tmux ended');
    // The controller tells of a change after its end (a window picked): the
    // same end is not counted again.
    c.selectWindow(c.windows.firstWhere((w) => w.id != c.activeWindowId).id);
    await pumpEventQueue();
    expect(asked - askedBefore, 1, reason: 'and not again for the same end');
    return container.read(tmuxSessionCountsProvider);
  }

  test('its only session killed (the last window closed): the tab shows no tmux', () async {
    final counts = await endIn((1, 'no server running on /tmp/tmux-1000/default\n'));
    expect(counts['h-1'], isNull);
  });

  test('another session left on the host: the tab shows that one', () async {
    final counts = await endIn((0, '\$2 1 0 1760000000 1760000000 other\n'), before: 2);
    expect(counts['h-1'], 1);
  });

  test('a detach: the session is still there, and so is the count', () async {
    final counts = await endIn((0, '\$0 1 0 1760000000 1760000000 main\n'),
        end: (c) async => c.onData(utf8.encode('%exit detached\n')));
    expect(counts['h-1'], 1);
  });
}
