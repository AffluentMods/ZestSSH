import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';
import 'package:zestssh/ui/widgets/drag_ghost.dart';
import 'package:zestssh/ui/widgets/layout_preset_picker.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// The 3.0 session chrome: one header over the tab, its status chip and
/// menu, the Layout popover, and a split pane's slim header.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final ended = <String>[];

  void set(Map<String, SessionState> s) => state = s;

  @override
  Future<void> endSession(String sessionId, {bool byThePerson = true}) async => ended.add(sessionId);
}

class _Shell extends ShellService {
  _Shell({this.ssh = true});
  final bool ssh;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => ssh;
}

/// A fixed Free or Squeezed account, without RevenueCat or the backend.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Health extends ConnectionHealthNotifier {
  void set(Map<String, HealthCheckResult> m) => state = m;
}

SessionState _state(String id, String label, String host,
        {int port = 22,
        SessionStatus status = SessionStatus.connected,
        bool ssh = true}) =>
    SessionState(
      status: status,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: host,
      port: port,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(),
        shell: _Shell(ssh: ssh),
        startedAt: DateTime(2026, 9, 24, 20),
      ),
    );

void main() {
  const locked = 'More layouts with Squeezed';
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child, {
    bool pro = false,
    bool guard = true,
  }) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      isProProvider.overrideWith((ref) => _Pro(pro)),
      dangerousCommandProtectionProvider.overrideWith((ref) => guard),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ));
    return container;
  }

  _Sessions sessionsOf(ProviderContainer c) =>
      c.read(activeSessionsProvider.notifier) as _Sessions;

  group('session header', () {
    testWidgets('names the session, its address and what was checked',
        (tester) async {
      final s = _state('s1', 'db-primary', '10.50.0.21');
      final c = await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: s,
          onToggleSftp: (_) {},
          onApplyLayout: (_) {},
        ),
      );
      (c.read(connectionHealthProvider.notifier) as _Health).set({
        'c-s1': HealthCheckResult(
            status: ConnectionHealth.online,
            latencyMs: 24,
            checkedAt: DateTime(2026, 9, 24)),
      });
      await tester.pump();
      expect(find.text('db-primary'), findsOneWidget);
      expect(find.text('10.50.0.21'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('24ms'), findsOneWidget);
      expect(find.text('Host key known'), findsOneWidget);
      for (final b in ['tmux', 'SFTP', 'Layout', 'Inspector']) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
    });

    testWidgets('a non-SSH shell makes no host key claim, and a port shows',
        (tester) async {
      final s = _state('s1', 'Router', '10.0.0.1', port: 2222, ssh: false);
      await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: s,
          onToggleSftp: (_) {},
          onApplyLayout: (_) {},
        ),
      );
      expect(find.text('Host key known'), findsNothing);
      expect(find.text('10.0.0.1:2222'), findsOneWidget);
    });

    testWidgets('a session still connecting says so and claims nothing',
        (tester) async {
      final s = _state('s1', 'db-primary', '10.50.0.21',
          status: SessionStatus.connecting);
      await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: s,
          onToggleSftp: (_) {},
          onApplyLayout: (_) {},
        ),
      );
      expect(find.text('Connecting'), findsOneWidget);
      expect(find.text('Host key known'), findsNothing);
    });

    testWidgets('SFTP asks the shell for this session; Inspector toggles',
        (tester) async {
      final asked = <String>[];
      final c = await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: _state('s1', 'db-primary', '10.50.0.21'),
          onToggleSftp: asked.add,
          onApplyLayout: (_) {},
        ),
      );
      await tester.tap(find.text('SFTP'));
      expect(asked, ['s1']);
      expect(c.read(sessionSlidePanelVisibleProvider), isFalse);
      await tester.tap(find.text('Inspector'));
      await tester.pump();
      expect(c.read(sessionSlidePanelVisibleProvider), isTrue);
      await tester.tap(find.text('Inspector'));
      await tester.pump();
      expect(c.read(sessionSlidePanelVisibleProvider), isFalse);
    });

    // A review found that on a local shell they led to a
    // full page saying tmux needs a live SSH session, and a toast that SFTP
    // does. Shown where the tab has an SSH session, whichever pane has focus.
    group('tmux and SFTP run over SSH', () {
      Future<(ProviderContainer, List<String>)> tabOf(
        WidgetTester tester,
        Map<String, SessionState> sessions,
        String focused,
      ) async {
        final asked = <String>[];
        final c = await pump(
          tester,
          SessionHeaderBar(
            sessionId: focused,
            sessionState: sessions[focused]!,
            onToggleSftp: asked.add,
            onApplyLayout: (_) {},
          ),
        );
        sessionsOf(c).set(sessions);
        final tabs = c.read(workTabsProvider.notifier);
        final tab = tabs.createTab(sessions.keys.first);
        tabs.replaceTabTree(
          tab,
          sessions.length == 1
              ? PaneLeaf(sessionIds: [sessions.keys.first])
              : PaneSplit(
                  axis: Axis.horizontal,
                  first: PaneLeaf(sessionIds: [sessions.keys.first]),
                  second: PaneLeaf(sessionIds: [sessions.keys.last]),
                ),
        );
        await tester.pump();
        return (c, asked);
      }

      Future<void> rebuildFor(WidgetTester tester, ProviderContainer c, String focused, List<String> asked) async {
        await tester.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SessionHeaderBar(
                sessionId: focused,
                sessionState: c.read(activeSessionsProvider)[focused]!,
                onToggleSftp: asked.add,
                onApplyLayout: (_) {},
              ),
            ),
          ),
        ));
      }

      testWidgets('a local shell has neither, and no way to the dead end', (tester) async {
        await tabOf(tester, {'l1': _state('l1', 'Local shell', 'localhost', ssh: false)}, 'l1');
        expect(find.byKey(const ValueKey('session-header-tmux')), findsNothing);
        expect(find.byKey(const ValueKey('session-header-sftp')), findsNothing);
        expect(find.text('SFTP'), findsNothing);
      });

      testWidgets('nor does Telnet or anything else that is not SSH', (tester) async {
        await tabOf(tester, {'t1': _state('t1', 'old-switch', '192.0.2.8', port: 23, ssh: false)}, 't1');
        expect(find.byKey(const ValueKey('session-header-sftp')), findsNothing);
      });

      testWidgets('an SSH tab has both, on its session, with the tooltips it always had', (tester) async {
        final (_, asked) = await tabOf(tester, {'s1': _state('s1', 'web-01', '192.0.2.1')}, 's1');
        await tester.tap(find.byKey(const ValueKey('session-header-sftp')));
        expect(asked, ['s1']);
        final l10n = AppLocalizations.of(tester.element(find.byType(SessionHeaderBar)))!;
        expect(find.byTooltip(l10n.sessionHeaderSftpTooltip), findsOneWidget);
      });

      testWidgets('a tab of a local pane and an SSH one: both show with either focused, and act on the SSH one, named',
          (tester) async {
        final sessions = {
          's1': _state('s1', 'web-01', '192.0.2.1'),
          'l1': _state('l1', 'Local shell', 'localhost', ssh: false),
        };
        final (c, asked) = await tabOf(tester, sessions, 'l1');
        final l10n = AppLocalizations.of(tester.element(find.byType(SessionHeaderBar)))!;
        expect(find.byKey(const ValueKey('session-header-tmux')), findsOneWidget);
        expect(find.byTooltip(l10n.sessionHeaderToolOn(l10n.pillSftp, 'web-01')), findsOneWidget);
        expect(find.byTooltip(l10n.sessionHeaderToolOn(l10n.sessionInfoTmux, 'web-01')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('session-header-sftp')));
        expect(asked, ['s1'], reason: 'the SSH pane, not the one with the focus');
        // The focus moves to the SSH pane: they stay, with their own tooltips.
        await rebuildFor(tester, c, 's1', asked);
        await tester.pump();
        expect(find.byKey(const ValueKey('session-header-sftp')), findsOneWidget);
        expect(find.byTooltip(l10n.sessionHeaderSftpTooltip), findsOneWidget);
      });

      testWidgets('with two SSH panes and a local one in front they act on the SSH pane last in front', (tester) async {
        final sessions = {
          's1': _state('s1', 'web-01', '192.0.2.1'),
          's2': _state('s2', 'web-02', '192.0.2.2'),
          'l1': _state('l1', 'Local shell', 'localhost', ssh: false),
        };
        final asked = <String>[];
        final c = await pump(
          tester,
          SessionHeaderBar(
            sessionId: 's1',
            sessionState: sessions['s1']!,
            onToggleSftp: asked.add,
            onApplyLayout: (_) {},
          ),
        );
        sessionsOf(c).set(sessions);
        final tabs = c.read(workTabsProvider.notifier);
        final tab = tabs.createTab('s1');
        tabs.replaceTabTree(
          tab,
          PaneSplit(
            axis: Axis.horizontal,
            first: PaneLeaf(sessionIds: const ['s1']),
            second: PaneSplit(
              axis: Axis.vertical,
              first: PaneLeaf(sessionIds: const ['s2']),
              second: PaneLeaf(sessionIds: const ['l1']),
            ),
          ),
        );
        await rebuildFor(tester, c, 's2', asked);
        await tester.pump();
        await rebuildFor(tester, c, 'l1', asked);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('session-header-sftp')));
        expect(asked, ['s2']);
      });
    });

    test('sshToolsSessionOf: the focused one, else the one last in front, else the first; none in a local tab', () {
      final sessions = {
        's1': _state('s1', 'web-01', '192.0.2.1'),
        's2': _state('s2', 'web-02', '192.0.2.2'),
        'l1': _state('l1', 'Local shell', 'localhost', ssh: false),
      };
      final mixed = WorkTab(
        paneTree: PaneSplit(
          axis: Axis.horizontal,
          first: PaneLeaf(sessionIds: const ['l1']),
          second: PaneSplit(
            axis: Axis.vertical,
            first: PaneLeaf(sessionIds: const ['s1']),
            second: PaneLeaf(sessionIds: const ['s2']),
          ),
        ),
      );
      expect(sshToolsSessionOf(mixed, sessions, focused: 's2'), 's2');
      expect(sshToolsSessionOf(mixed, sessions, focused: 'l1', lastInFront: 's2'), 's2');
      expect(sshToolsSessionOf(mixed, sessions, focused: 'l1'), 's1');
      expect(sshToolsSessionOf(mixed, sessions, focused: 'l1', lastInFront: 'gone'), 's1');
      final local = WorkTab(paneTree: PaneLeaf(sessionIds: const ['l1']));
      expect(sshToolsSessionOf(local, sessions, focused: 'l1'), isNull);
    });

    test('still connecting, nothing says a session speaks SSH: a saved local shell has an id like any host\'s', () {
      expect(const SessionState(status: SessionStatus.connecting, connectionId: 'local_1').speaksSsh, isFalse);
      expect(const SessionState(status: SessionStatus.connecting, connectionId: 'h-1').speaksSsh, isFalse);
    });

    testWidgets('SFTP reads as on while this session has an SFTP pane',
        (tester) async {
      final c = await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: _state('s1', 'db-primary', '10.50.0.21'),
          onToggleSftp: (_) {},
          onApplyLayout: (_) {},
        ),
      );
      Color? fillOf(String label) {
        final box = tester.widget<Container>(find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first);
        return (box.decoration as BoxDecoration?)?.color;
      }

      expect(fillOf('SFTP'), Colors.transparent);
      c.read(paneTreeProvider.notifier).setTree(PaneSplit(
            first: PaneLeaf(sessionIds: const ['s1']),
            second: PaneLeaf(sessionIds: const ['s1'], type: 'sftp'),
            axis: Axis.horizontal,
          ));
      await tester.pump();
      expect(fillOf('SFTP'), isNot(Colors.transparent));
    });

    testWidgets('Disconnect in the status menu asks first, then ends it',
        (tester) async {
      final s = _state('s1', 'db-primary', '10.50.0.21');
      final c = await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: s,
          onToggleSftp: (_) {},
          onApplyLayout: (_) {},
        ),
      );
      sessionsOf(c).set({'s1': s});
      await tester.tap(find.text('Connected'));
      await tester.pumpAndSettle();
      expect(find.text('Reconnect'), findsOneWidget);
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      // Asked, not done.
      expect(sessionsOf(c).ended, isEmpty);
      expect(find.text('Disconnect "db-primary"?'), findsOneWidget);
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(sessionsOf(c).ended, ['s1']);
    });

    testWidgets('cancelling the Disconnect question ends nothing',
        (tester) async {
      final s = _state('s1', 'db-primary', '10.50.0.21');
      final c = await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: s,
          onToggleSftp: (_) {},
          onApplyLayout: (_) {},
        ),
      );
      await tester.tap(find.text('Connected'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sessionsOf(c).ended, isEmpty);
    });
  });

  group('layout popover', () {
    // In 2.2.1 there was no layout for five panes nor any quick way
    // to make one, and the arranged layout did not change with how many
    // terminals were open in that group.

    /// The popover over a tab of [n] terminals, each in a pane of its own
    /// (as tabs joined one by one leave it). With none, there is no tab.
    Future<ProviderContainer> popover(
      WidgetTester tester,
      int n, {
      bool pro = true,
      ValueChanged<LayoutPreset?>? onApply,
      VoidCallback? onUpgrade,
    }) async {
      // (A popover shown before, with tabs of its own, is taken down first.)
      await tester.pumpWidget(const SizedBox.shrink());
      final c = await pump(
        tester,
        SingleChildScrollView(
          child: LayoutPopover(onApply: onApply ?? (_) {}, onUpgrade: onUpgrade),
        ),
        pro: pro,
      );
      if (n == 0) return c;
      sessionsOf(c).set({
        for (var i = 1; i <= n; i++) 's$i': _state('s$i', 'web-0$i', '10.50.0.1$i'),
      });
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      final dest = tabs.tabContaining('s1')!.id;
      for (var i = 2; i <= n; i++) {
        tabs.mergeTabs(tabs.tabContaining('s$i')!.id, dest);
      }
      tabs.setActiveTab(dest);
      await tester.pump();
      return c;
    }

    /// The arrangements shown under [section], by name, in reading order.
    List<String> offered(WidgetTester tester, String section) {
      final cards = find.descendant(
        of: find.byKey(ValueKey(section)),
        matching: find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('layout-')),
      );
      final named = [
        for (final e in cards.evaluate())
          (
            name: (e.widget.key! as ValueKey<String>).value.substring('layout-'.length),
            at: tester.getTopLeft(find.byWidget(e.widget)),
          ),
      ]..sort((a, b) => a.at.dy != b.at.dy ? a.at.dy.compareTo(b.at.dy) : a.at.dx.compareTo(b.at.dx));
      return [for (final c in named) c.name];
    }

    bool marked(WidgetTester tester, String name) {
      final label = find.descendant(of: find.byKey(ValueKey('layout-$name')), matching: find.byType(Text));
      return tester.widget<Text>(label).style!.fontWeight == FontWeight.w600;
    }

    testWidgets('five terminals: the grid and what else holds five, then what has room for more, nothing smaller',
        (tester) async {
      await popover(tester, 5);
      // (The grid of five is three and two: "3 + 2" is not offered again
      // under its own name.)
      expect(offered(tester, 'layout-fits'), ['automatic', 'twoAndThree', 'oneAndFour']);
      expect(offered(tester, 'layout-roomier'),
          ['grid3x2', 'grid2x3', 'fourAndThree', 'threeAndFour', 'grid4x2', 'grid2x4']);
      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('2 + 3'), findsOneWidget);
      expect(find.text('3 + 2'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is ZestSectionHeader && w.label == 'With room for more'), findsOneWidget);
      expect(find.byTooltip('The terminals share this tab evenly, and keep doing so as more are added'),
          findsOneWidget);
      for (final small in ['single', 'sideBySide', 'stacked', 'threeColumns', 'grid2x2', 'fourColumns']) {
        expect(find.byKey(ValueKey('layout-$small')), findsNothing, reason: small);
      }
    });

    testWidgets('three terminals: what holds three, then room for up to three more', (tester) async {
      await popover(tester, 3);
      expect(offered(tester, 'layout-fits'), ['automatic', 'threeRows', 'oneAndTwo', 'twoAndOne']);
      expect(offered(tester, 'layout-roomier'), [
        'grid2x2', 'fourColumns', 'oneAndThree', 'threeAndTwo', 'twoAndThree', //
        'oneAndFour', 'grid3x2', 'grid2x3',
      ]);
      expect(find.byKey(const ValueKey('layout-fourAndThree')), findsNothing, reason: 'room for four more');
      expect(find.byKey(const ValueKey('layout-sideBySide')), findsNothing);
      expect(find.byKey(const ValueKey('layout-threeColumns')), findsNothing, reason: 'that is the grid');
    });

    testWidgets('one terminal, or none yet: itself and room for more; nothing to arrange by itself',
        (tester) async {
      for (final n in [1, 0]) {
        await popover(tester, n);
        expect(offered(tester, 'layout-fits'), ['single'], reason: '$n');
        expect(offered(tester, 'layout-roomier'), [
          'sideBySide', 'stacked', 'threeColumns', 'threeRows', 'oneAndTwo', //
          'twoAndOne', 'grid2x2', 'fourColumns', 'oneAndThree',
        ], reason: '$n');
        expect(find.byKey(const ValueKey('layout-automatic')), findsNothing, reason: '$n');
      }
    });

    testWidgets('eight terminals and more: what holds them, and no word about room', (tester) async {
      await popover(tester, 8);
      expect(offered(tester, 'layout-fits'), ['automatic', 'grid2x4']);
      expect(find.byKey(const ValueKey('layout-roomier')), findsNothing);
      expect(find.byWidgetPredicate((w) => w is ZestSectionHeader && w.label == 'With room for more'), findsNothing);
      await popover(tester, 9);
      expect(offered(tester, 'layout-fits'), ['automatic'], reason: 'the grid holds any number');
      expect(find.byKey(const ValueKey('layout-roomier')), findsNothing);
    });

    testWidgets('the arrangement the tab stands in is marked', (tester) async {
      final c = await popover(tester, 5);
      // Joined one by one, five stand in their grid.
      expect(marked(tester, 'automatic'), isTrue);
      expect(marked(tester, 'twoAndThree'), isFalse);
      expect(marked(tester, 'grid3x2'), isFalse);
      final tabs = c.read(workTabsProvider.notifier);
      final id = c.read(workTabsProvider).activeTabId!;
      expect(tabs.arrangeTab(id, LayoutPreset.twoAndThree), ArrangeOutcome.done);
      await tester.pump();
      expect(marked(tester, 'twoAndThree'), isTrue);
      expect(marked(tester, 'automatic'), isFalse);
      // One with room to spare: marked where it stands, among the roomier
      // ones. A place to connect is no terminal: the tab still has five.
      expect(tabs.arrangeTab(id, LayoutPreset.grid3x2), ArrangeOutcome.done);
      await tester.pump();
      expect(marked(tester, 'grid3x2'), isTrue);
      expect(marked(tester, 'twoAndThree'), isFalse);
      expect(marked(tester, 'automatic'), isFalse);
      expect(offered(tester, 'layout-fits'), ['automatic', 'twoAndThree', 'oneAndFour']);
    });

    testWidgets('the automatic grid is marked only while it is what the tab stands in', (tester) async {
      final c = await popover(tester, 4);
      expect(marked(tester, 'automatic'), isTrue);
      // A divider was moved: the tab is its owner's now.
      final root = c.read(paneTreeProvider)! as PaneSplit;
      c.read(paneTreeProvider.notifier).setSplitRatio(root.id, 0.7);
      await tester.pump();
      expect(marked(tester, 'automatic'), isFalse);
      expect(offered(tester, 'layout-fits').where((name) => marked(tester, name)), isEmpty);
      // Put back by choosing it.
      final tabs = c.read(workTabsProvider.notifier);
      final id = c.read(workTabsProvider).activeTabId!;
      expect(tabs.arrangeTab(id, null), ArrangeOutcome.done);
      await tester.pump();
      expect(marked(tester, 'automatic'), isTrue);
      // A grid with a place left empty is the grid of one more: the
      // arrangement with room is marked, the automatic one is not.
      tabs.removeSession('s4');
      await tester.pump();
      expect(marked(tester, 'automatic'), isTrue, reason: 'three, side by side');
      expect(tabs.arrangeTab(id, LayoutPreset.grid2x2), ArrangeOutcome.done);
      await tester.pump();
      expect(marked(tester, 'automatic'), isFalse);
      expect(marked(tester, 'grid2x2'), isTrue);
    });

    testWidgets('choosing one applies it and closes; the automatic one says so with no arrangement',
        (tester) async {
      final applied = <LayoutPreset?>[];
      final c = await pump(
        tester,
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showLayoutPopover(ctx, onApply: applied.add),
            child: const Text('open'),
          ),
        ),
        pro: true,
      );
      c.read(workTabsProvider);
      sessionsOf(c).set({
        for (var i = 1; i <= 4; i++) 's$i': _state('s$i', 'web-0$i', '10.50.0.1$i'),
      });
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      final dest = tabs.tabContaining('s1')!.id;
      for (var i = 2; i <= 4; i++) {
        tabs.mergeTabs(tabs.tabContaining('s$i')!.id, dest);
      }
      tabs.setActiveTab(dest);
      await tester.pump();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('1 + 3'), findsOneWidget);
      await tester.tap(find.text('4 columns'));
      await tester.pumpAndSettle();
      expect(applied, [LayoutPreset.fourColumns]);
      expect(find.text('1 + 3'), findsNothing, reason: 'closed');

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();
      expect(applied, [LayoutPreset.fourColumns, null]);
      expect(find.text('Automatic'), findsNothing, reason: 'closed');
    });

    testWidgets('a free account is shown the next size up, locked, and no further', (tester) async {
      final applied = <LayoutPreset?>[];
      // Four terminals of the five a free account opens on a computer (4.0):
      // what holds five can be chosen, what holds six is locked, what holds
      // seven is not shown.
      expect(freeSessionLimit, 5, reason: 'the arrangements below are counted for 5');
      await popover(tester, 4, pro: false, onApply: applied.add);
      expect(offered(tester, 'layout-roomier'), ['threeAndTwo', 'twoAndThree', 'oneAndFour', 'grid3x2', 'grid2x3']);
      // A locked one keeps its name, greyed with a small lock, and tells the
      // pointer what unlocks it; that is said once under the cards as well.
      expect(find.byTooltip(locked), findsNWidgets(2));
      expect(find.text('3 + 2'), findsOneWidget);
      expect(find.text('3×2 grid'), findsOneWidget, reason: 'a locked one is named as it is');
      expect(find.byTooltip('3 + 2'), findsNothing);
      expect(find.byKey(const ValueKey('layout-more-with-squeezed')), findsOneWidget);
      expect(find.text(locked), findsOneWidget, reason: 'said once, not on every card');
      await tester.tap(find.byKey(const ValueKey('layout-grid3x2')));
      await tester.pump();
      expect(applied, isEmpty, reason: 'a locked arrangement is not applied');
      // With all five open, and with one: the same two, or none at all.
      await popover(tester, 5, pro: false);
      expect(offered(tester, 'layout-fits'), ['automatic', 'twoAndThree', 'oneAndFour']);
      expect(offered(tester, 'layout-roomier'), ['grid3x2', 'grid2x3']);
      expect(find.byTooltip(locked), findsNWidgets(2));
      await popover(tester, 1, pro: false);
      expect(find.byTooltip(locked), findsNothing);
      expect(find.byKey(const ValueKey('layout-more-with-squeezed')), findsNothing);
      expect(offered(tester, 'layout-roomier').last, 'oneAndThree');
    });

    testWidgets('a locked arrangement opens what unlocks it, and closes the popover', (tester) async {
      final applied = <LayoutPreset?>[];
      var upgrades = 0;
      final c = await pump(
        tester,
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showLayoutPopover(ctx, onApply: applied.add, onUpgrade: () => upgrades++),
            child: const Text('open'),
          ),
        ),
      );
      c.read(workTabsProvider);
      sessionsOf(c).set({
        for (var i = 1; i <= 3; i++) 's$i': _state('s$i', 'web-0$i', '10.50.0.1$i'),
      });
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      final dest = tabs.tabContaining('s1')!.id;
      tabs.mergeTabs(tabs.tabContaining('s2')!.id, dest);
      tabs.mergeTabs(tabs.tabContaining('s3')!.id, dest);
      tabs.setActiveTab(dest);
      await tester.pump();

      // Three terminals: the arrangements for six are locked on a computer's 5.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byTooltip(locked), findsNWidgets(2));
      await tester.tap(find.byTooltip(locked).first);
      await tester.pumpAndSettle();
      expect(upgrades, 1);
      expect(applied, isEmpty);
      expect(find.byTooltip(locked), findsNothing, reason: 'closed');
      // The line under the cards opens it too.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('layout-more-with-squeezed')));
      await tester.pumpAndSettle();
      expect(upgrades, 2);
      expect(find.byTooltip(locked), findsNothing, reason: 'closed');
      // One that is not locked does not.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2×2 grid'));
      await tester.pumpAndSettle();
      expect(upgrades, 2);
      expect(applied, [LayoutPreset.grid2x2]);
    });

    testWidgets('with Squeezed every arrangement that is offered can be chosen', (tester) async {
      var upgrades = 0;
      await popover(tester, 3, onUpgrade: () => upgrades++);
      expect(find.byTooltip(locked), findsNothing);
      expect(find.byKey(const ValueKey('layout-more-with-squeezed')), findsNothing);
      expect(find.text('3 + 2'), findsOneWidget);
      expect(find.text('3×2 grid'), findsOneWidget);
      expect(find.text('2×3 grid'), findsOneWidget);
      expect(find.byTooltip('3 + 2'), findsNothing, reason: 'its name is its label');
    });

    testWidgets('broadcast is no part of it: it has a button of its own beside it', (tester) async {
      final c = await pump(tester, LayoutPopover(onApply: (_) {}));
      sessionsOf(c).set({
        's1': _state('s1', 'A', '10.0.0.1'),
        's2': _state('s2', 'B', '10.0.0.2'),
      });
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      final dest = tabs.tabContaining('s1')!.id;
      tabs.mergeTabs(tabs.tabContaining('s2')!.id, dest);
      tabs.setActiveTab(dest);
      await tester.pump();
      expect(find.byType(ZestSwitch), findsNothing);
      expect(find.text('Needs two or more terminals in this tab'), findsNothing);
      expect(find.text('Risky commands ask first, before they reach every pane'), findsNothing);
    });

    testWidgets('the header has the Broadcast button beside Layout', (tester) async {
      final c = await pump(
        tester,
        SessionHeaderBar(
          sessionId: 's1',
          sessionState: _state('s1', 'A', '10.0.0.1'),
          onToggleSftp: (_) {},
          onApplyLayout: (_) {},
        ),
      );
      sessionsOf(c).set({'s1': _state('s1', 'A', '10.0.0.1')});
      await tester.pump();
      final layout = tester.getTopLeft(find.text('Layout')).dx;
      final broadcast = tester.getTopLeft(find.byKey(const ValueKey('broadcast-button'))).dx;
      expect(broadcast, greaterThan(layout), reason: 'right after it');
    });

    test('how many terminals a tab has for an arrangement to hold', () {
      PaneLeaf t(String id) => PaneLeaf.single(sessionId: id);
      PaneSplit h(PaneNode a, PaneNode b) => PaneSplit(first: a, second: b, axis: Axis.horizontal);
      expect(layoutPaneCount(null), 0);
      expect(layoutPaneCount(t('a')), 1);
      expect(layoutPaneCount(h(t('a'), h(t('b'), t('c')))), 3);
      // Neither the SFTP dock nor a place to connect that stands empty is one.
      expect(layoutPaneCount(h(h(t('a'), PaneLeaf.placeholder()), PaneLeaf.single(sessionId: 'f', type: 'sftp'))), 1);
      // A pane with two sessions as its tabs is one pane.
      expect(layoutPaneCount(h(PaneLeaf(sessionIds: const ['a', 'b']), t('c'))), 2);
    });

    testWidgets('every arrangement has a name in every language', (tester) async {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        final names = [for (final p in LayoutPreset.values) layoutPresetLabel(l10n, p)];
        expect(names.every((n) => n.trim().isNotEmpty), isTrue, reason: '$locale');
        expect(names.toSet(), hasLength(names.length), reason: '$locale: no two share a name');
        for (final text in [l10n.layoutAutomatic, l10n.layoutAutomaticHint, l10n.layoutRoomForMore, l10n.layoutTooSmall]) {
          expect(text.trim(), isNotEmpty, reason: '$locale');
        }
      }
      final en = lookupAppLocalizations(const Locale('en'));
      expect({for (final p in LayoutPreset.values) p.name: layoutPresetLabel(en, p)}, {
        'single': 'Single',
        'sideBySide': 'Side by side',
        'stacked': 'Stacked',
        'threeColumns': '3 columns',
        'threeRows': '3 rows',
        'oneAndTwo': '1 + 2',
        'twoAndOne': '2 + 1',
        'grid2x2': '2×2 grid',
        'fourColumns': '4 columns',
        'oneAndThree': '1 + 3',
        'threeAndTwo': '3 + 2',
        'twoAndThree': '2 + 3',
        'oneAndFour': '1 + 4',
        'grid3x2': '3×2 grid',
        'grid2x3': '2×3 grid',
        'fourAndThree': '4 + 3',
        'threeAndFour': '3 + 4',
        'grid4x2': '4×2 grid',
        'grid2x4': '2×4 grid',
      });
    });
  });

  group('slim pane header', () {
    testWidgets('dragged, a see-through copy of it hangs under the pointer, wherever along the header it was grabbed',
        (tester) async {
      // (The copy was solid and hid what it was dragged over, and it stood
      // as far left of the pointer as the header was grabbed from its left.)
      final a = _state('s1', 'db-primary', '10.50.0.21');
      await pump(
        tester,
        SlimPaneHeader(
          leafId: 'leaf-1',
          sessions: [MapEntry('s1', a)],
          activeIndex: 0,
          isFocused: true,
        ),
      );
      final copy = find.byWidgetPredicate((w) => w is Opacity && w.opacity == kDragGhostOpacity);
      expect(copy, findsNothing);
      final name = tester.getRect(find.text('db-primary'));

      Future<Rect> heldAt(Offset from, Offset where) async {
        final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 50));
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();
        await gesture.moveTo(where);
        await tester.pump();
        expect(copy, findsOneWidget);
        final rect = tester.getRect(copy);
        await gesture.up();
        await tester.pump();
        expect(copy, findsNothing, reason: 'gone once it is let go');
        return rect;
      }

      // Grabbed far to the right of the name: the header is the handle over
      // its whole width.
      var rect = await heldAt(Offset(name.right + 600, name.center.dy), const Offset(700, 300));
      expect(rect.top, 300 + kDragGhostDrop, reason: 'under the pointer, not on it');
      expect(rect.left, 700 - 24, reason: 'at the pointer');
      expect(rect.right, greaterThan(700));

      // Grabbed at its very start: as far to the side as it was grabbed.
      final start = tester.getRect(find.byType(SlimPaneHeader)).left + 10;
      rect = await heldAt(Offset(start + 6, name.center.dy), const Offset(700, 300));
      expect(rect.left, 700 - 6);
      expect(rect.top, 300 + kDragGhostDrop);
    });

    testWidgets('its close asks, then disconnects that pane only',
        (tester) async {
      final a = _state('s1', 'db-primary', '10.50.0.21');
      final c = await pump(
        tester,
        SlimPaneHeader(
          leafId: 'leaf-1',
          sessions: [MapEntry('s1', a)],
          activeIndex: 0,
          isFocused: true,
        ),
      );
      expect(find.text('db-primary'), findsOneWidget);
      expect(find.text('10.50.0.21'), findsOneWidget);
      await tester.tap(find.byTooltip('Disconnect'));
      await tester.pumpAndSettle();
      expect(sessionsOf(c).ended, isEmpty);
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(sessionsOf(c).ended, ['s1']);
    });

    testWidgets('with two sessions in the pane, close ends the one on screen',
        (tester) async {
      final a = _state('s1', 'db-primary', '10.50.0.21');
      final b = _state('s2', 'web-01', '10.50.0.13');
      final c = await pump(
        tester,
        SlimPaneHeader(
          leafId: 'leaf-1',
          sessions: [MapEntry('s1', a), MapEntry('s2', b)],
          activeIndex: 1,
          isFocused: true,
        ),
      );
      await tester.tap(find.byTooltip('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect "web-01"?'), findsOneWidget);
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(sessionsOf(c).ended, ['s2']);
    });

    testWidgets('a pane holding two sessions shows both and switches',
        (tester) async {
      final a = _state('s1', 'db-primary', '10.50.0.21');
      final b = _state('s2', 'web-01', '10.50.0.13');
      final c = await pump(
        tester,
        SlimPaneHeader(
          leafId: 'leaf-1',
          sessions: [MapEntry('s1', a), MapEntry('s2', b)],
          activeIndex: 0,
          isFocused: false,
        ),
      );
      final leaf = PaneLeaf(sessionIds: const ['s1', 's2']);
      c.read(paneTreeProvider.notifier).setTree(PaneSplit(
            first: leaf,
            second: PaneLeaf(sessionIds: const ['s3']),
            axis: Axis.horizontal,
          ));
      final realLeafId = c.read(paneTreeProvider)!.allLeaves.first.id;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SlimPaneHeader(
              leafId: realLeafId,
              sessions: [MapEntry('s1', a), MapEntry('s2', b)],
              activeIndex: 0,
              isFocused: false,
            ),
          ),
        ),
      ));
      expect(find.text('db-primary'), findsOneWidget);
      expect(find.text('web-01'), findsOneWidget);
      await tester.tap(find.text('web-01'));
      await tester.pump();
      expect(c.read(paneTreeProvider)!.findLeaf(realLeafId)!.activeIndex, 1);
      expect(c.read(focusedPaneProvider), realLeafId);
    });
  });
}
