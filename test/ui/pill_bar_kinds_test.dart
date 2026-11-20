import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';

SessionState _state(String label, {SessionStatus status = SessionStatus.connected}) => SessionState(
      status: status,
      connectionId: 'c-$label',
      connectionLabel: label,
      host: '10.50.0.5',
      port: 22,
      username: 'deploy',
    );

/// Every tab says what it holds first (a terminal, a remote screen, files
/// only, a split), its status on that tile's corner; a remote screen's tab
/// is a cooler blue; the tabs a workspace opened sit behind its chip, which
/// folds them away and back.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(
    WidgetTester tester, {
    String? active = 't1',
    Map<String, ({String id, String name})> workspaces = const {},
    ({int files, int unsaved, bool front})? editorTab,
    VoidCallback? onEditorTab,
    VoidCallback? onEditorClose,
  }) async {
    tester.view.physicalSize = const Size(1800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
        screenSessionsProvider.overrideWith((ref) => {'t2'}),
        filesOnlySessionsProvider.overrideWith((ref) => {'t4'}),
        tabWorkspacesProvider.overrideWith((ref) => workspaces),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PillBar(
              activeNav: NavSection.hosts,
              activeSessionId: active,
              sessions: [
                MapEntry('t1', _state('web-01')),
                MapEntry('t2', _state('Design PC')),
                MapEntry('t3', _state('db-01', status: SessionStatus.connecting)),
                MapEntry('t4', _state('backups')),
                MapEntry('t5', _state('api-01')),
              ],
              tabGroupSizes: const {'t3': 2},
              editorTab: editorTab,
              onEditorTab: onEditorTab,
              onEditorClose: onEditorClose,
              onNavChanged: (_) {},
              onSessionSelected: (_) {},
              onSessionClosed: (_) {},
              onNewSession: () {},
              onCommandPalette: () {},
              onHelp: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Finder tab(String id) => find.byKey(ValueKey(id));

  testWidgets('each tab starts with what it holds, with its status on the corner, and says it to a screen reader',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester);
    // The tile is the first thing in each tab, before its name.
    for (final (id, name) in const [('t1', 'web-01'), ('t2', 'Design PC'), ('t3', 'db-01'), ('t4', 'backups')]) {
      final tile = find.descendant(of: tab(id), matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
          RegExp(r'^tab-(kind|screen|files-only)-').hasMatch((w.key! as ValueKey<String>).value)));
      expect(tile, findsOneWidget, reason: id);
      expect(tester.getRect(tile).right, lessThan(tester.getRect(find.descendant(of: tab(id), matching: find.text(name))).left),
          reason: '$id: before the name');
    }
    expect(find.byKey(const ValueKey('tab-screen-t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-files-only-t4')), findsOneWidget);
    // The old tags at the end are gone.
    expect(find.text('VNC'), findsNothing);
    expect(find.text('SFTP'), findsNothing);
    // A split says how many it holds; the status keeps its shapes.
    expect(find.byKey(const ValueKey('tab-split-count-t3')), findsOneWidget);
    expect(find.descendant(of: tab('t3'), matching: find.byKey(const ValueKey('status-mark-connecting'))), findsOneWidget);
    expect(find.descendant(of: tab('t1'), matching: find.byKey(const ValueKey('status-mark-connected'))), findsOneWidget);

    String said(String id) => tester.getSemantics(tab(id)).label;
    expect(said('t1'), isNot(contains(l10n.a11yTabScreen)), reason: 'a terminal says nothing more');
    expect(said('t2'), contains(l10n.a11yTabScreen));
    expect(said('t3'), contains(l10n.a11yTabSplit(2)));
    expect(said('t4'), contains(l10n.pillSftp));
    semantics.dispose();
  });

  testWidgets("a remote screen's tab is its own colour, apart from a terminal's", (tester) async {
    await pump(tester, active: 'x');
    Color surface(String id) => (tester
            .widgetList<Container>(find.descendant(of: tab(id), matching: find.byType(Container)))
            .map((c) => c.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((d) => d.border != null)
            .color)!;
    expect(surface('t2'), isNot(surface('t1')));
    expect(surface('t4'), surface('t1'));
  });

  testWidgets("a workspace's tabs: its chip before them and its line under them; the chip folds them and shows them "
      'again, the tab in front staying', (tester) async {
    final semantics = tester.ensureSemantics();
    const ws = (id: 'w1', name: 'API stack');
    await pump(tester, workspaces: const {'t4': ws, 't5': ws});
    final chip = find.byKey(const ValueKey('tab-workspace-w1'));
    expect(chip, findsOneWidget);
    expect(tester.getRect(chip).right, lessThanOrEqualTo(tester.getRect(tab('t4')).left), reason: 'before its first tab');
    expect(tester.getRect(chip).left, greaterThanOrEqualTo(tester.getRect(tab('t3')).right));
    expect(find.byKey(const ValueKey('tab-workspace-line-t4')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-workspace-line-t5')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-workspace-line-t1')), findsNothing);
    expect(find.bySemanticsLabel(l10n.tabWorkspaceChip('API stack')), findsOneWidget);

    await tester.tap(chip);
    await tester.pump();
    expect(tab('t4'), findsNothing);
    expect(tab('t5'), findsNothing);
    expect(chip, findsOneWidget, reason: 'the chip stays, to open them again');
    expect(find.bySemanticsLabel(l10n.tabWorkspaceChipFolded('API stack', 2)), findsOneWidget);
    expect(tab('t1'), findsOneWidget);

    await tester.tap(chip);
    await tester.pump();
    expect(tab('t4'), findsOneWidget);
    expect(tab('t5'), findsOneWidget);

    // The tab in front stays, folded or not.
    await pump(tester, active: 't5', workspaces: const {'t4': ws, 't5': ws});
    await tester.tap(chip);
    await tester.pump();
    expect(tab('t4'), findsNothing);
    expect(tab('t5'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets("the file editor's tab after the session tabs: how many files, a dot while one is unsaved, in front "
      "while it shows, its close the editor's", (tester) async {
    final semantics = tester.ensureSemantics();
    var shown = 0, closed = 0;
    await pump(tester,
        active: null,
        editorTab: (files: 3, unsaved: 1, front: true),
        onEditorTab: () => shown++,
        onEditorClose: () => closed++);
    final editor = find.byKey(const ValueKey('tab-editor'));
    expect(editor, findsOneWidget);
    expect(find.descendant(of: editor, matching: find.text(l10n.editorMinimizedFiles(3))), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-editor-unsaved')), findsOneWidget);
    // After the session tabs (the last ones go to the overflow menu where the strip is full).
    for (final id in const ['t1', 't2', 't3']) {
      expect(tester.getRect(editor).left, greaterThan(tester.getRect(tab(id)).right), reason: 'after $id');
    }
    final said = '${l10n.editorMinimizedFiles(3)}, ${l10n.editorMinimizedUnsaved(1)}';
    expect(tester.getSemantics(find.bySemanticsLabel(said)), matchesSemantics(
      label: said,
      isButton: true,
      isSelected: true,
      hasSelectedState: true,
      hasTapAction: true,
    ));
    await tester.tap(editor);
    expect(shown, 1);
    await tester.tap(find.byKey(const ValueKey('tab-editor-close')));
    expect(closed, 1);
    expect(shown, 1, reason: 'the close is not a tap on the tab');
    // No editor files: no tab.
    await pump(tester);
    expect(find.byKey(const ValueKey('tab-editor')), findsNothing);
    semantics.dispose();
  });

  testWidgets("a tab's kind is its session's: a tab's id is not its session's (a remote screen's tab showed a "
      "terminal's tile)", (tester) async {
    tester.view.physicalSize = const Size(1800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      screenSessionsProvider.overrideWith((ref) => {'conn-b_2'}),
      filesOnlySessionsProvider.overrideWith((ref) => {'conn-c_3'}),
      tabWorkspacesProvider.overrideWith((ref) => const {}),
    ]);
    addTearDown(container.dispose);
    final tabs = container.read(workTabsProvider.notifier);
    final terminal = tabs.createTab('conn-a_1');
    final screen = tabs.createTab('conn-b_2');
    final files = tabs.createTab('conn-c_3');
    expect({terminal, screen, files}.intersection({'conn-a_1', 'conn-b_2', 'conn-c_3'}), isEmpty);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PillBar(
              activeNav: NavSection.hosts,
              activeSessionId: terminal,
              sessions: [
                MapEntry(terminal, _state('web-01')),
                MapEntry(screen, _state('Kiosk VNC')),
                MapEntry(files, _state('backups')),
              ],
              onNavChanged: (_) {},
              onSessionSelected: (_) {},
              onSessionClosed: (_) {},
              onNewSession: () {},
              onCommandPalette: () {},
              onHelp: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(ValueKey('tab-screen-$screen')), findsOneWidget);
    expect(find.byKey(ValueKey('tab-files-only-$files')), findsOneWidget);
    expect(find.byKey(ValueKey('tab-kind-$terminal')), findsOneWidget);
  });
}
