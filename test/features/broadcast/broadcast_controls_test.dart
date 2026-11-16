// Broadcast's own controls (3.0): the Broadcast button in the session header
// and its pop-over, the switch on each pane's own header, and a pane's
// header that keeps the host's name readable however narrow the pane.
//
// In 2.2.1 there was no visible way to stop broadcasting, no easy way to
// turn certain broadcasts on or off, and with thirteen terminals in one
// group, a pane's header had little room.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/broadcast/broadcast_controls.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/broadcast_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show detachedSessionsProvider;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/name_first_row.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/line_breaks.dart';

import '../../helpers/last_line.dart';
import '../../visual/shots_util.dart';

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

SessionState _state(String id, String label, String host, {SessionStatus status = SessionStatus.connected}) =>
    SessionState(
      status: status,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: host,
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(),
        shell: _Shell(),
        startedAt: DateTime(2026, 10, 3, 9),
      ),
    );

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// [guard] null leaves the risky command check as a new install has it.
  Future<ProviderContainer> pump(WidgetTester tester, Widget child, {bool? guard = true, ThemeData? theme}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      if (guard != null) dangerousCommandProtectionProvider.overrideWith((ref) => guard),
    ]);
    addTearDown(container.dispose);
    // The tabs follow the sessions from the first one on.
    container.read(workTabsProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
      ),
    ));
    await tester.pump();
    return container;
  }

  /// Sessions s1..sN to web-01.. web-N, each in a tab of its own, then the
  /// first [together] joined in one tab, which is in front.
  String tabOf(ProviderContainer c, int n, {int? together}) {
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      for (var i = 1; i <= n; i++) 's$i': _state('s$i', 'web-0$i', '10.50.0.1$i'),
    });
    final tabs = c.read(workTabsProvider.notifier);
    final first = tabs.tabContaining('s1')!.id;
    for (var i = 2; i <= (together ?? n); i++) {
      tabs.mergeTabs(tabs.tabContaining('s$i')!.id, first);
    }
    tabs.setActiveTab(first);
    return first;
  }

  BroadcastModeState st(ProviderContainer c) => c.read(broadcastModeProvider);

  group('The Broadcast button', () {
    testWidgets('says Broadcast, and Broadcasting while the tab in front broadcasts', (tester) async {
      final c = await pump(tester, const BroadcastButton());
      final tab = tabOf(c, 3);
      await tester.pump();
      expect(find.text(l10n.terminalBroadcast), findsOneWidget);
      c.read(broadcastModeProvider.notifier).startTab(tab);
      await tester.pump();
      expect(find.text(l10n.broadcastButtonOn), findsOneWidget);
      expect(find.text(l10n.terminalBroadcast), findsNothing);
    });

    testWidgets('another tab that broadcasts does not light it', (tester) async {
      final c = await pump(tester, const BroadcastButton());
      final tab = tabOf(c, 4, together: 2);
      final tabs = c.read(workTabsProvider.notifier);
      final other = tabs.tabContaining('s3')!.id;
      tabs.mergeTabs(tabs.tabContaining('s4')!.id, other);
      tabs.setActiveTab(tab);
      c.read(broadcastModeProvider.notifier).startTab(other);
      await tester.pump();
      expect(find.text(l10n.terminalBroadcast), findsOneWidget);
      expect(find.text(l10n.broadcastButtonOn), findsNothing);
    });

    testWidgets('its tooltip says what it does, and its key', (tester) async {
      await pump(tester, const BroadcastButton());
      final tooltip = tester.widget<Tooltip>(find.ancestor(of: find.text(l10n.terminalBroadcast), matching: find.byType(Tooltip)).first);
      expect(tooltip.message, startsWith(l10n.broadcastButtonTooltip));
      expect(tooltip.message, contains('B'), reason: 'the key that switches it, from the shortcut list');
    });

    testWidgets('opens the pop-over, which switches it on for the tab in front', (tester) async {
      final c = await pump(tester, const BroadcastButton());
      final tab = tabOf(c, 3);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('broadcast-button')));
      await tester.pumpAndSettle();
      expect(find.byType(BroadcastPopover), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('broadcast-switch')));
      await tester.pumpAndSettle();
      expect(st(c).broadcasts(tab), isTrue);
      expect(st(c).tabs.keys, [tab]);
    });
  });

  group('The pop-over', () {
    testWidgets('a tab with one terminal cannot switch it on, and says why', (tester) async {
      final c = await pump(tester, const BroadcastPopover());
      tabOf(c, 2, together: 1);
      await tester.pump();
      expect(find.text(noOrphan(l10n.bcastPopNeedsSplit)), findsOneWidget);
      expect(tester.widget<ZestSwitch>(find.byKey(const ValueKey('broadcast-switch'))).onChanged, isNull);
      expect(find.byWidgetPredicate((w) => w is ZestSectionHeader && w.label == l10n.broadcastReceiversCaption), findsNothing);
    });

    testWidgets('switched on, it lists the terminals of the tab, each ticked', (tester) async {
      final c = await pump(tester, const BroadcastPopover());
      final tab = tabOf(c, 4, together: 3);
      await tester.pump();
      expect(find.text(noOrphan(l10n.broadcastSwitchHint)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('broadcast-switch')));
      await tester.pump();
      expect(st(c).broadcasts(tab), isTrue);
      expect(find.text(noOrphan(l10n.broadcastSwitchOnHint)), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is ZestSectionHeader && w.label == l10n.broadcastReceiversCaption), findsOneWidget);
      for (final id in ['s1', 's2', 's3']) {
        expect(find.byKey(ValueKey('broadcast-receiver-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('broadcast-receiver-s4')), findsNothing, reason: 'a terminal of another tab');
      expect(find.text('web-01'), findsOneWidget);
      expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).map((b) => b.value), [true, true, true]);
      expect(find.byKey(const ValueKey('broadcast-include-all')), findsNothing, reason: 'nobody is left out');
    });

    testWidgets('another tab that broadcasts leaves this one off', (tester) async {
      final c = await pump(tester, const BroadcastPopover());
      final tab = tabOf(c, 4, together: 2);
      final tabs = c.read(workTabsProvider.notifier);
      final other = tabs.tabContaining('s3')!.id;
      tabs.mergeTabs(tabs.tabContaining('s4')!.id, other);
      tabs.setActiveTab(tab);
      c.read(broadcastModeProvider.notifier).startTab(other);
      await tester.pump();
      expect(tester.widget<ZestSwitch>(find.byKey(const ValueKey('broadcast-switch'))).value, isFalse);
      expect(find.byWidgetPredicate((w) => w is ZestSectionHeader && w.label == l10n.broadcastReceiversCaption), findsNothing);
      expect(find.text(noOrphan(l10n.broadcastSwitchHint)), findsOneWidget);
    });

    testWidgets('a terminal is left out with a click on its row, and taken back the same way', (tester) async {
      final c = await pump(tester, const BroadcastPopover());
      final tab = tabOf(c, 3);
      c.read(broadcastModeProvider.notifier).startTab(tab);
      await tester.pump();
      await tester.tap(find.text('web-02'));
      await tester.pump();
      expect(st(c).leftOut(tab), {'s2'});
      expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).map((b) => b.value), [true, false, true]);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      expect(st(c).leftOut(tab), isEmpty);
    });

    testWidgets('Include all takes every one that was left out back', (tester) async {
      final c = await pump(tester, const BroadcastPopover());
      final tab = tabOf(c, 3);
      c.read(broadcastModeProvider.notifier)
        ..startTab(tab)
        ..setReceiving(tab, 's1', false)
        ..setReceiving(tab, 's3', false);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('broadcast-include-all')));
      await tester.pump();
      expect(st(c).leftOut(tab), isEmpty);
      expect(find.byKey(const ValueKey('broadcast-include-all')), findsNothing);
    });

    testWidgets('switched off, it stops for this tab only', (tester) async {
      final c = await pump(tester, const BroadcastPopover());
      final tab = tabOf(c, 5, together: 3);
      final tabs = c.read(workTabsProvider.notifier);
      final other = tabs.tabContaining('s4')!.id;
      tabs.mergeTabs(tabs.tabContaining('s5')!.id, other);
      tabs.setActiveTab(tab);
      c.read(broadcastModeProvider.notifier)
        ..startTab(tab)
        ..startTab(other);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('broadcast-switch')));
      await tester.pump();
      expect(st(c).broadcasts(tab), isFalse);
      expect(st(c).broadcasts(other), isTrue);
    });

    testWidgets('a terminal in a window of its own is not listed', (tester) async {
      final c = await pump(tester, const BroadcastPopover());
      final tab = tabOf(c, 3);
      c.read(broadcastModeProvider.notifier).startTab(tab);
      c.read(detachedSessionsProvider.notifier).detach('s3');
      await tester.pump();
      expect(find.byKey(const ValueKey('broadcast-receiver-s3')), findsNothing);
      expect(find.byKey(const ValueKey('broadcast-receiver-s1')), findsOneWidget);
    });

    testWidgets('says that risky commands ask first, or that nothing does', (tester) async {
      var c = await pump(tester, const BroadcastPopover());
      tabOf(c, 2);
      await tester.pump();
      expect(find.text(noOrphan(l10n.bcastPopRiskyOn)), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c = await pump(tester, const BroadcastPopover(), guard: false);
      tabOf(c, 2);
      await tester.pump();
      expect(find.text(noOrphan(l10n.bcastPopRiskyOff)), findsOneWidget);
    });

    // As designed, the Broadcast menu has the
    // risky-command toggle built in.
    testWidgets('has the risky command switch, on by default, and turning it off is saved and said', (tester) async {
      final c = await pump(tester, const BroadcastPopover(), guard: null);
      tabOf(c, 2);
      await tester.pump();
      final risky = find.byKey(const ValueKey('broadcast-risky-switch'));
      expect(find.text(l10n.bcastPopRiskyTitle), findsOneWidget);
      expect(tester.widget<ZestSwitch>(risky).value, isTrue, reason: 'on for a new install');
      expect(c.read(dangerousCommandProtectionProvider), isTrue);
      await tester.tap(risky);
      await tester.pump();
      expect(c.read(dangerousCommandProtectionProvider), isFalse);
      expect(prefs.getBool('dangerous_command_protection'), isFalse, reason: 'saved as Settings saves it');
      expect(tester.widget<ZestSwitch>(risky).value, isFalse);
      final line = tester.widget<Text>(find.byKey(const ValueKey('broadcast-risky-line')));
      expect(line.data, noOrphan(l10n.bcastPopRiskyOff));
      expect(line.style?.color, ZestColors.statusWarning, reason: 'off is a warning');
      await tester.tap(risky);
      await tester.pump();
      expect(c.read(dangerousCommandProtectionProvider), isTrue);
      expect(prefs.getBool('dangerous_command_protection'), isTrue);
      expect(find.text(noOrphan(l10n.bcastPopRiskyOn)), findsOneWidget);
    });
  });

  group("A pane's switch", () {
    testWidgets('is not there while the tab does not broadcast', (tester) async {
      final c = await pump(tester, const PaneBroadcastToggle(sessionId: 's1'));
      tabOf(c, 2);
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-broadcast-s1')), findsNothing);
    });

    testWidgets('while it does: lit, and a click leaves the pane out and takes it back', (tester) async {
      final c = await pump(tester, const PaneBroadcastToggle(sessionId: 's2'));
      final tab = tabOf(c, 3);
      c.read(broadcastModeProvider.notifier).startTab(tab);
      await tester.pump();
      final toggle = find.byKey(const ValueKey('pane-broadcast-s2'));
      expect(toggle, findsOneWidget);
      expect(tester.widget<Tooltip>(find.ancestor(of: toggle, matching: find.byType(Tooltip))).message,
          l10n.broadcastPaneReceives);
      await tester.tap(toggle);
      await tester.pump();
      expect(st(c).leftOut(tab), {'s2'});
      expect(tester.widget<Tooltip>(find.ancestor(of: toggle, matching: find.byType(Tooltip))).message,
          l10n.broadcastPaneLeftOut);
      await tester.tap(toggle);
      await tester.pump();
      expect(st(c).leftOut(tab), isEmpty);
    });

    testWidgets('is not there for a terminal of another tab, or one in a window of its own', (tester) async {
      final c = await pump(
        tester,
        const Row(children: [PaneBroadcastToggle(sessionId: 's3'), PaneBroadcastToggle(sessionId: 's2')]),
      );
      final tab = tabOf(c, 3, together: 2);
      c.read(broadcastModeProvider.notifier).startTab(tab);
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-broadcast-s3')), findsNothing);
      expect(find.byKey(const ValueKey('pane-broadcast-s2')), findsOneWidget);
      // s2 goes to a window of its own: the tab is down to one terminal on
      // screen and stops.
      c.read(detachedSessionsProvider.notifier).detach('s2');
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-broadcast-s2')), findsNothing);
      expect(st(c).broadcasts(tab), isFalse);
    });
  });

  group('A name first', () {
    // (Test text is drawn one em to a character: an 11 point name of six
    // characters is 66 wide.)
    // (No letter spacing: the theme's would add a quarter point a letter.)
    const nameStyle = TextStyle(fontSize: 11, letterSpacing: 0);
    const addressStyle = TextStyle(fontSize: 10, letterSpacing: 0);

    Future<void> lay(WidgetTester tester, double width, {String name = 'web-01', String? address = '10.50.0.11'}) async {
      await pump(
        tester,
        SizedBox(
          width: width,
          height: 30,
          // (Loose, as in a pane's header, where it stands in a Flexible.)
          child: Align(
            alignment: Alignment.centerLeft,
            child: NameFirstRow(
              name: Redactable.host(name),
              nameStyle: nameStyle,
              address: address == null ? null : Redactable.address(address),
              addressStyle: addressStyle,
            ),
          ),
        ),
      );
    }

    double widthOf(WidgetTester tester, String text) => tester.getSize(find.text(text)).width;

    testWidgets('with room for both, both are whole', (tester) async {
      await lay(tester, 400);
      expect(widthOf(tester, 'web-01'), 66);
      expect(widthOf(tester, '10.50.0.11'), 100);
    });

    testWidgets('with less room the address gives way first, and the name stays whole', (tester) async {
      await lay(tester, 160);
      expect(widthOf(tester, 'web-01'), 66, reason: 'the two used to share the room as two halves');
      expect(widthOf(tester, '10.50.0.11'), 160 - 66 - 8);
    });

    testWidgets('with too little left for the address, there is none', (tester) async {
      await lay(tester, 66 + 8 + 47);
      expect(find.text('10.50.0.11'), findsNothing);
      expect(widthOf(tester, 'web-01'), 66);
      await tester.pumpWidget(const SizedBox.shrink());
      await lay(tester, 66 + 8 + 48);
      expect(widthOf(tester, '10.50.0.11'), 48);
    });

    testWidgets('a name longer than the room is cut, alone', (tester) async {
      await lay(tester, 40, name: 'database-primary-01');
      expect(find.text('10.50.0.11'), findsNothing);
      expect(widthOf(tester, 'database-primary-01'), 40);
    });

    testWidgets('the name is measured in the style it is drawn in', (tester) async {
      // Drawn at 20 points from the style around it: 120 wide.
      Future<void> at(double width) => pump(
            tester,
            DefaultTextStyle(
              style: const TextStyle(fontSize: 20, letterSpacing: 0),
              child: SizedBox(
                width: width,
                height: 30,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: NameFirstRow(
                    name: Redactable.host('web-01'),
                    nameStyle: const TextStyle(),
                    address: Redactable.address('10.50.0.11'),
                    addressStyle: addressStyle,
                  ),
                ),
              ),
            ),
          );
      await at(120 + 8 + 47);
      expect(find.text('10.50.0.11'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await at(120 + 8 + 48);
      expect(widthOf(tester, '10.50.0.11'), 48);
      expect(widthOf(tester, 'web-01'), 120);
    });

    testWidgets('where there is no end to the room, both are whole', (tester) async {
      await pump(
        tester,
        UnconstrainedBox(
          child: NameFirstRow(
            name: Redactable.host('web-01'),
            nameStyle: nameStyle,
            address: Redactable.address('10.50.0.11'),
            addressStyle: addressStyle,
          ),
        ),
      );
      expect(widthOf(tester, 'web-01'), 66);
      expect(widthOf(tester, '10.50.0.11'), 100);
    });

    testWidgets('without an address it is the name', (tester) async {
      await lay(tester, 400, address: null);
      expect(find.text('web-01'), findsOneWidget);
      expect(find.byType(Row), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await lay(tester, 400, address: '');
      expect(find.text('web-01'), findsOneWidget);
      expect(find.byType(Row), findsNothing);
    });
  });

  // Last in this file: it loads the app's fonts, which every test after it
  // would measure with (the widths above are the test font's).
  testWidgets('the pop-over leaves no word alone on a line, opened as the app opens it, in the app\'s fonts',
      (tester) async {
    // ("below." under what is typed going to the ones ticked, "all" under
    // "Open several hosts side by side and type into" and "asking." under the
    // risky command check turned off, found in a design review.)
    await tester.runAsync(loadShotFonts);
    final c = await pump(tester, const BroadcastButton(),
        guard: false, theme: BuiltInThemes.getById('default_light').toThemeData());
    final tab = tabOf(c, 3);
    c.read(broadcastModeProvider.notifier).startTab(tab);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('broadcast-button')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BroadcastPopover)).width, BroadcastPopover.width);
    for (final words in [l10n.broadcastSwitchOnHint, l10n.bcastPopOpenSeveral, l10n.bcastPopRiskyOff]) {
      expectNoOrphan(tester, findWords(words), reason: words);
    }
  });

  // 4.0 accessibility pass: the pop-over, switched on with its terminals
  // listed, and a pane's toggle each name every control to a screen reader,
  // with readable text.
  group('accessibility', () {
    testWidgets('the pop-over: every control named, its text readable', (tester) async {
      final semantics = tester.ensureSemantics();
      final c = await pump(tester, const BroadcastPopover(), theme: AppTheme.dark());
      tabOf(c, 4, together: 3);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('broadcast-switch')));
      await tester.pump();
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semantics.dispose();
    });

    testWidgets("a pane's toggle says whether the pane is typed into", (tester) async {
      final semantics = tester.ensureSemantics();
      final c = await pump(tester, const PaneBroadcastToggle(sessionId: 's2'));
      final tab = tabOf(c, 3);
      c.read(broadcastModeProvider.notifier).startTab(tab);
      await tester.pump();
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
    });
  });
}
