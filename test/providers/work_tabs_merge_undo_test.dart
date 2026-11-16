import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/tab_merge_undo.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;

/// Combining two tabs can be undone for a few seconds, as closing one can
/// (so combining two groups by accident does not leave you
/// stuck): Undo puts both back as they were, and once the notice is gone
/// nothing changes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late WorkTabsNotifier tabs;

  Future<void> setUpContainer() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    tabs = container.read(workTabsProvider.notifier);
  }

  WorkTabsState st() => container.read(workTabsProvider);
  WorkTab tab(String id) => st().tabs.firstWhere((t) => t.id == id);
  String json(PaneNode tree) => jsonEncode(tree.toJson());

  /// Three tabs: A with a1 over a2 (an arrangement of its own, 30/70), B
  /// with b1, C with c1; B in front with b1's pane focused.
  ({String a, String b, String c, String focus}) three() {
    final a = tabs.createTab('a1');
    tabs.mergeTabs(tabs.createTab('a2'), a);
    tabs.setActiveTab(a);
    container.read(paneTreeProvider.notifier).setTree(PaneSplit(
          first: PaneLeaf(sessionId: 'a1'),
          second: PaneLeaf(sessionId: 'a2'),
          axis: Axis.vertical,
          ratio: 0.3,
        ));
    final b = tabs.createTab('b1');
    final c = tabs.createTab('c1');
    tabs.setActiveTab(b);
    final focus = tab(b).paneTree.allLeaves.single.id;
    container.read(focusedPaneProvider.notifier).state = focus;
    return (a: a, b: b, c: c, focus: focus);
  }

  group('Undo of combined tabs', () {
    setUp(setUpContainer);
    tearDown(() => container.dispose());

    test('puts both back as they were: panes, arrangement, order, the tab in front and its focused pane', () {
      final t = three();
      final before = [for (final x in st().tabs) (x.id, json(x.paneTree))];
      final undo = tabs.mergeTabs(t.b, t.a)!;
      expect(st().tabs.map((x) => x.id), [t.a, t.c], reason: 'combined');
      expect(tab(t.a).sessionIds.toSet(), {'a1', 'a2', 'b1'});

      expect(tabs.undoMerge(undo), isTrue);
      expect([for (final x in st().tabs) (x.id, json(x.paneTree))], before);
      expect(st().activeTabId, t.b);
      expect(json(container.read(paneTreeProvider)!), json(tab(t.b).paneTree), reason: 'its panes are on screen');
      expect(container.read(focusedPaneProvider), t.focus);
    });

    test('a tab combined while another was in front leaves that one in front', () {
      final t = three();
      tabs.setActiveTab(t.c);
      final undo = tabs.mergeTabs(t.b, t.a)!;
      expect(tabs.undoMerge(undo), isTrue);
      expect(st().tabs.map((x) => x.id), [t.a, t.b, t.c]);
      expect(st().activeTabId, t.c);
    });

    test('several combined one after another come apart, the last first', () {
      final t = three();
      final before = [for (final x in st().tabs) (x.id, json(x.paneTree))];
      final undos = [tabs.mergeTabs(t.b, t.a)!, tabs.mergeTabs(t.c, t.a)!];
      expect(st().tabs, hasLength(1));
      for (final u in undos.reversed) {
        expect(tabs.undoMerge(u), isTrue);
      }
      expect([for (final x in st().tabs) (x.id, json(x.paneTree))], before);
    });

    test('once a terminal left the combined tab there is nothing to undo, and nothing changes', () {
      final t = three();
      final undo = tabs.mergeTabs(t.b, t.a)!;
      tabs.removeSession('a2');
      final now = [for (final x in st().tabs) (x.id, json(x.paneTree))];
      expect(tabs.undoMerge(undo), isFalse);
      expect([for (final x in st().tabs) (x.id, json(x.paneTree))], now);
    });
  });

  group('The notice', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    setUp(() async {
      await setUpContainer();
      // The notice as a phone shows it: this rig has no notification centre.
      debugTopSnackBarOnPhone = true;
    });
    tearDown(() {
      debugTopSnackBarOnPhone = null;
      container.dispose();
    });

    Future<({String a, String b, String c, String focus})> pumpAndCombine(WidgetTester tester) async {
      final t = three();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => offerTabMergeUndo(context, ref, [tabs.mergeTabs(t.b, t.a)!]),
                child: const Text('combine'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('combine'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return t;
    }

    testWidgets('says the tabs were combined, and its Undo puts them back', (tester) async {
      final t = await pumpAndCombine(tester);
      expect(find.text(l10n.tabMergeCombined), findsOneWidget);
      expect(st().tabs.map((x) => x.id), [t.a, t.c]);
      await tester.tap(find.text(l10n.desktopShellUndo));
      await tester.pump();
      expect(st().tabs.map((x) => x.id), [t.a, t.b, t.c]);
      expect(tab(t.b).sessionIds, ['b1']);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('after its few seconds it is gone, and the tabs stay combined', (tester) async {
      final t = await pumpAndCombine(tester);
      await tester.pump(kTabMergeUndoWindow + const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(l10n.tabMergeCombined), findsNothing);
      expect(st().tabs.map((x) => x.id), [t.a, t.c]);
      expect(tab(t.a).sessionIds.toSet(), {'a1', 'a2', 'b1'});
    });
  });
}
