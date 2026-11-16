import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/services/local_state_store.dart';

/// Saved workspaces, as the 3.0 docs check found them:
/// saving a tab with an empty "Connect…" place threw; the editor's Save
/// turned every tab into one row of columns; the command palette kept its
/// workspaces in a store of its own, in plain preferences, that the Hosts
/// page never showed.
void main() {
  PaneLeaf leaf(String id, String host, {String type = 'terminal'}) =>
      PaneLeaf(id: id, sessionIds: [host], type: type);

  /// A 2x2 grid: two rows, each of two panes side by side.
  PaneSplit grid(PaneLeaf a, PaneLeaf b, PaneLeaf c, PaneLeaf d) => PaneSplit(
        id: 'rows',
        axis: Axis.vertical,
        ratio: 0.4,
        first: PaneSplit(id: 'top', axis: Axis.horizontal, ratio: 0.3, first: a, second: b),
        second: PaneSplit(id: 'bottom', axis: Axis.horizontal, ratio: 0.7, first: c, second: d),
      );

  /// The shape of a tree: its splits (axis and share) and its leaves' ids.
  String shape(PaneNode n) => switch (n) {
        PaneLeaf l => l.id,
        PaneSplit s => '${s.axis == Axis.vertical ? 'V' : 'H'}${s.ratio.toStringAsFixed(2)}(${shape(s.first)},${shape(s.second)})',
      };

  group('saving a tab with an empty place', () {
    test('it is saved, the empty place kept in the layout; a tab of empty places alone is not', () {
      final tabs = [
        WorkTab(
          customName: 'ops',
          paneTree: PaneSplit(
            axis: Axis.horizontal,
            first: PaneLeaf(id: 'l1', sessionIds: ['s1']),
            second: PaneLeaf.placeholder(id: 'l2'),
          ),
        ),
        WorkTab(paneTree: PaneLeaf.placeholder(id: 'l3')),
      ];
      final snaps = captureTabsAsSnapshots(tabs, (sid) => {'s1': 'web-01'}[sid]);
      expect(snaps, hasLength(1));
      final leaves = snaps!.single.paneTreeOfConnIds.allLeaves;
      expect([for (final l in leaves) l.sessionIds], [['web-01'], <String>[]]);
      expect(leaves.last.isPlaceholder, isTrue);
      expect(leaves.last.id, 'l2');
    });

    test('a place holding an empty id is an empty place too', () {
      final tree = mapPaneTreeIds(PaneLeaf(id: 'l1', sessionIds: ['']), (_) => null, keepIds: true);
      expect(tree, isA<PaneLeaf>());
      expect((tree! as PaneLeaf).isPlaceholder, isTrue);
    });
  });

  group('the editor\'s Save keeps each tab\'s layout', () {
    final a = leaf('a', 'h-a'), b = leaf('b', 'h-b'), c = leaf('c', 'h-c'), d = leaf('d', 'h-d');
    final e = leaf('e', 'h-e', type: 'sftp');
    late SavedTabGroup group;

    setUp(() {
      group = SavedTabGroup(name: 'Main', tabs: [
        TabSnapshot(customName: 'grid', colorIndex: 3, paneTreeOfConnIds: grid(a, b, c, d)),
        TabSnapshot(
          paneTreeOfConnIds: e,
          panePaths: {'e': const SftpPanePaths(remotePath: '/srv/www', connectionId: 'h-e')},
        ),
      ]);
    });

    test('nothing changed: the grid stays a grid, with its shares, its name and its colour', () {
      final out = rebuildWorkspaceTabs(original: group, orderedLeaves: flattenWorkspaceLeaves(group));
      expect(out, hasLength(2));
      expect(shape(out[0].paneTreeOfConnIds), shape(grid(a, b, c, d)));
      expect(shape(out[0].paneTreeOfConnIds), 'V0.40(H0.30(a,b),H0.70(c,d))');
      expect((out[0].customName, out[0].colorIndex), ('grid', 3));
      expect(out[1].panePaths['e']?.remotePath, '/srv/www', reason: 'its folders stay with the pane');
    });

    test('reordered: the panes take each other\'s places in the same grid', () {
      final out = rebuildWorkspaceTabs(original: group, orderedLeaves: [d, c, b, a, e]);
      expect(shape(out[0].paneTreeOfConnIds), 'V0.40(H0.30(d,c),H0.70(b,a))');
    });

    test('a pane removed: its place goes, the split it stood in gives its room to the other side', () {
      final out = rebuildWorkspaceTabs(original: group, orderedLeaves: [a, c, d, e]);
      expect(shape(out[0].paneTreeOfConnIds), 'V0.40(a,H0.70(c,d))');
      expect(shape(out[1].paneTreeOfConnIds), 'e', reason: 'the next tab keeps its own pane');
    });

    test('a tab with every pane removed goes; a host added joins the last tab beside what it had', () {
      final added = leaf('f', 'h-f');
      final out = rebuildWorkspaceTabs(original: group, orderedLeaves: [e, added]);
      expect(out, hasLength(1));
      expect(out.single.paneTreeOfConnIds.allLeaves.map((l) => l.id), ['e', 'f']);
      expect(out.single.panePaths['e']?.remotePath, '/srv/www');
    });

    test('a pane moved from one tab to the other: each tab keeps its count and its shape', () {
      final out = rebuildWorkspaceTabs(original: group, orderedLeaves: [a, b, c, e, d]);
      expect(shape(out[0].paneTreeOfConnIds), 'V0.40(H0.30(a,b),H0.70(c,e))');
      expect(shape(out[1].paneTreeOfConnIds), 'd');
      expect(out[0].panePaths['e']?.remotePath, '/srv/www', reason: 'the folders follow the pane');
    });
  });

  group('the command palette\'s old workspaces', () {
    String old(List<Map<String, Object?>> list) => jsonEncode(list);
    Map<String, Object?> ws(String id, String name, List<String> hosts) => {
          'id': id,
          'name': name,
          'createdAt': '2026-09-01T10:00:00.000',
          'lastUsedAt': '2026-10-01T10:00:00.000',
          'windows': [
            {'left': 0, 'top': 0, 'width': 1280, 'height': 800, 'paneTree': null, 'connectionIds': hosts, 'isMainWindow': true},
          ],
        };

    test('each comes in once, each host in a tab of its own, named apart from those there', () {
      final there = [
        SavedTabGroup(id: 'g1', name: 'Prod', tabs: [TabSnapshot(paneTreeOfConnIds: leaf('x', 'h-x'))]),
      ];
      final out = withPaletteWorkspaces(
          there,
          old([
            ws('w1', 'prod', ['h-1', 'h-2', 'h-1']),
            ws('w2', 'Empty', []),
            ws('g1', 'Already here', ['h-3']),
            ws('w3', 'Staging', ['h-4']),
          ]));
      expect(out.map((g) => g.name), ['Prod', 'prod 2', 'Staging']);
      final prod2 = out[1];
      expect(prod2.id, 'w1');
      expect(prod2.tabs.map((t) => t.paneTreeOfConnIds.allLeaves.single.sessionIds.single), ['h-1', 'h-2']);
      expect(prod2.lastUsedAt, DateTime.parse('2026-10-01T10:00:00.000'));
      expect(withPaletteWorkspaces(there, null), same(there));
      expect(withPaletteWorkspaces(there, 'not json'), same(there));
    });

    test('opening the store brings them in, keeps them encrypted, and takes them out of preferences', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      SharedPreferences.setMockInitialValues({kPaletteWorkspacesKey: old([ws('w1', 'Night shift', ['h-1'])])});
      final prefs = await SharedPreferences.getInstance();
      final store = LocalStateStore(db);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        localStateStoreProvider.overrideWithValue(store),
        dbReadyProvider.overrideWithValue(true),
      ]);
      addTearDown(container.dispose);
      container.read(savedTabGroupsProvider);
      for (var i = 0; i < 20 && container.read(savedTabGroupsProvider).isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(container.read(savedTabGroupsProvider).map((g) => g.name), ['Night shift']);
      expect(prefs.containsKey(kPaletteWorkspacesKey), isFalse, reason: 'no longer kept in plain preferences');
      final kept = jsonDecode((await store.read('desktop_saved_tab_groups'))!) as List;
      expect(kept.single['name'], 'Night shift');
    });
  });
}
