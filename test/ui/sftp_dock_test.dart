import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/ui/screens/desktop/widgets/sftp_dock.dart';

/// SFTP as a dock (3.0): the terminals lay out without the SFTP leaf, the
/// dock remembers its side and size on this device, and moving it never
/// restarts the browser (or a transfer in it).

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
  void set(Map<String, SessionState> s) => state = s;
}

class _Shell extends ShellService {
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
  bool get isEncryptedSsh => true;
}

class _Health extends ConnectionHealthNotifier {}

SessionState _state(String id, String label) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: '10.0.0.1',
      port: 22,
      username: 'u',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(),
        shell: _Shell(),
        startedAt: DateTime(2026, 9, 24),
      ),
    );

void main() {
  group('the terminals lay out without the SFTP leaf', () {
    final a = PaneLeaf(sessionIds: const ['a'], id: 'la');
    final b = PaneLeaf(sessionIds: const ['b'], id: 'lb');
    final f = PaneLeaf(sessionIds: const ['a'], id: 'lf', type: 'sftp');

    test('a tree with no SFTP comes back untouched', () {
      final t = PaneSplit(first: a, second: b, axis: Axis.horizontal);
      expect(identical(withoutSftp(t), t), isTrue);
      expect(sftpLeafOf(t), isNull);
    });

    test('a terminal beside SFTP becomes that terminal alone', () {
      final t = PaneSplit(first: a, second: f, axis: Axis.horizontal);
      expect(withoutSftp(t), same(a));
      expect(sftpLeafOf(t)!.id, 'lf');
    });

    test('nested: the split around SFTP collapses, the rest keeps its shape',
        () {
      final t = PaneSplit(
        first: a,
        second: PaneSplit(first: f, second: b, axis: Axis.vertical),
        axis: Axis.horizontal,
        ratio: 0.3,
      );
      final out = withoutSftp(t)! as PaneSplit;
      expect(out.first, same(a));
      expect(out.second, same(b));
      expect(out.ratio, 0.3);
      expect(out.axis, Axis.horizontal);
    });

    test('nothing but SFTP leaves nothing to lay out', () {
      expect(withoutSftp(f), isNull);
      expect(withoutSftp(null), isNull);
    });
  });

  group('this device remembers the dock', () {
    test('bottom, 328 by 640 until changed', () async {
      SharedPreferences.setMockInitialValues({});
      final n = SftpDockPrefsNotifier(await SharedPreferences.getInstance());
      expect(n.state.side, SftpDockSide.bottom);
      expect(n.state.height, 328);
      expect(n.state.width, 640);
    });

    test('side and size are saved and read back', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      final n = SftpDockPrefsNotifier(p)
        ..setSide(SftpDockSide.right)
        ..setHeight(400)
        ..setWidth(700)
        ..persist();
      expect(n.state.side, SftpDockSide.right);
      final again = SftpDockPrefsNotifier(p);
      expect(again.state.side, SftpDockSide.right);
      expect(again.state.height, 400);
      expect(again.state.width, 700);
    });

    test('never smaller than its minimum', () async {
      SharedPreferences.setMockInitialValues({});
      final n = SftpDockPrefsNotifier(await SharedPreferences.getInstance())
        ..setHeight(10)
        ..setWidth(10);
      expect(n.state.height, SftpDockPrefs.minHeight);
      expect(n.state.width, SftpDockPrefs.minWidth);
    });
  });

  Future<ProviderContainer> pumpFrame(
    WidgetTester tester, {
    required SftpDockSide side,
    required bool canMoveRight,
    VoidCallback? onClose,
    double maxSize = double.infinity,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 400,
            child: SftpDockFrame(
              sessionState: _state('a', 'db-primary'),
              side: side,
              canMoveRight: canMoveRight,
              onClose: onClose ?? () {},
              maxSize: maxSize,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ));
    return c;
  }

  group('the dock frame', () {
    testWidgets('names the host; moves right; closes', (tester) async {
      var closed = 0;
      final c = await pumpFrame(tester,
          side: SftpDockSide.bottom, canMoveRight: true, onClose: () => closed++);
      expect(find.text('SFTP'), findsOneWidget);
      expect(find.text('db-primary'), findsOneWidget);
      await tester.tap(find.text('Move to the right'));
      await tester.pump();
      expect(c.read(sftpDockPrefsProvider).side, SftpDockSide.right);
      await tester.tap(find.byKey(const ValueKey('sftp-dock-close')));
      expect(closed, 1);
    });

    testWidgets('no room on the right: the button says so and does nothing',
        (tester) async {
      final c = await pumpFrame(tester,
          side: SftpDockSide.bottom, canMoveRight: false);
      await tester.tap(find.text('Move to the right'));
      await tester.pump();
      expect(c.read(sftpDockPrefsProvider).side, SftpDockSide.bottom);
      expect(find.byTooltip('The window is too narrow for SFTP on the right'),
          findsOneWidget);
    });

    testWidgets('on the right it offers the bottom', (tester) async {
      final c = await pumpFrame(tester,
          side: SftpDockSide.right, canMoveRight: true);
      c.read(sftpDockPrefsProvider.notifier).setSide(SftpDockSide.right);
      await tester.tap(find.text('Move to the bottom'));
      await tester.pump();
      expect(c.read(sftpDockPrefsProvider).side, SftpDockSide.bottom);
    });

    testWidgets('dragging the grip resizes, and the size is kept',
        (tester) async {
      final c = await pumpFrame(tester,
          side: SftpDockSide.bottom, canMoveRight: true);
      await tester.drag(
          find.byKey(const ValueKey('sftp-dock-grip')), const Offset(0, -60));
      await tester.pump();
      // Up by the drag, less the gesture's start threshold.
      final h = c.read(sftpDockPrefsProvider).height;
      expect(h, greaterThan(360));
      expect(h, lessThanOrEqualTo(388));
      final prefs = c.read(sharedPreferencesProvider);
      expect(prefs.getDouble('sftp_dock_height'), h, reason: 'kept on release');
    });

    testWidgets(
        'the grip stops at the room there is and comes back at once; '
        'the terminals keep their size until it is let go', (tester) async {
      final c = await pumpFrame(tester,
          side: SftpDockSide.bottom, canMoveRight: true, maxSize: 360);
      final grip = find.byKey(const ValueKey('sftp-dock-grip'));
      final g = await tester.startGesture(tester.getCenter(grip));
      await g.moveBy(const Offset(0, -20));
      await g.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(TerminalResizeHold.held, isTrue, reason: 'held while dragging');
      await g.moveBy(const Offset(0, -300)); // far past the room there is
      await tester.pump();
      expect(c.read(sftpDockPrefsProvider).height, 360);
      await g.moveBy(const Offset(0, 300)); // back: the edge is under it
      await tester.pump();
      expect(c.read(sftpDockPrefsProvider).height, 360,
          reason: 'still past the room: the pointer is 8 beyond it');
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(c.read(sftpDockPrefsProvider).height, 328,
          reason: 'back where it began, as the pointer is');
      await g.up();
      await tester.pump();
      expect(TerminalResizeHold.held, isFalse, reason: 'released on let go');
      expect(c.read(sharedPreferencesProvider).getDouble('sftp_dock_height'), 328);
    });

    testWidgets('a drag the system takes away releases the terminals too',
        (tester) async {
      await pumpFrame(tester, side: SftpDockSide.right, canMoveRight: true);
      final grip = find.byKey(const ValueKey('sftp-dock-grip'));
      final g = await tester.startGesture(tester.getCenter(grip));
      await g.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(TerminalResizeHold.held, isTrue);
      await g.cancel();
      await tester.pump();
      expect(TerminalResizeHold.held, isFalse);
    });
  });

  testWidgets('in a session the dock holds SFTP, and moving it keeps the browser',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(c.dispose);
    // The tabs follow the sessions from the moment they exist.
    final tabs = c.read(workTabsProvider.notifier);
    (c.read(activeSessionsProvider.notifier) as _Sessions)
        .set({'s1': _state('s1', 'db-primary')});
    tabs.setActiveTab(tabs.tabContaining('s1')!.id);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    final tree = c.read(paneTreeProvider.notifier)..initSinglePane('s1');
    tree.splitPaneWithSftp(
        c.read(paneTreeProvider)!.allLeaves.first.id, Axis.horizontal, 's1');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DesktopTerminalArea(
            onConnectTo: (_) {},
            onToggleSftp: (_) {},
            onApplyLayout: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();

    Finder browser() => find.descendant(
          of: find.byType(SftpDockFrame),
          matching: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_SftpLeafPane'),
        );
    expect(find.byType(SftpDockFrame), findsOneWidget);
    expect(browser(), findsOneWidget);
    expect(find.text('Move to the right'), findsOneWidget, reason: 'bottom');
    final before = tester.state(browser());

    c.read(sftpDockPrefsProvider.notifier).setSide(SftpDockSide.right);
    await tester.pump();
    expect(find.text('Move to the bottom'), findsOneWidget, reason: 'right');
    expect(identical(tester.state(browser()), before), isTrue,
        reason: 'the same browser, not a new one');

    // The terminal is laid out alone, not split with an SFTP pane.
    expect(
        find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_TerminalPane'),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
