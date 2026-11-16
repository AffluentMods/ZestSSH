import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/pane_tree.dart';

/// Round-trip helper: serialize → deserialize → assert equal-ish.
PaneNode? _roundTrip(PaneNode node) {
  final json = node.toJson();
  return PaneNode.fromJson(json);
}

void main() {
  group('PaneLeaf.isPlaceholder', () {
    test('placeholder factory produces isPlaceholder == true', () {
      final leaf = PaneLeaf.placeholder();
      expect(leaf.isPlaceholder, isTrue);
      expect(leaf.sessionIds, isEmpty);
      expect(leaf.type, 'terminal');
    });

    test('placeholder factory respects custom type', () {
      final leaf = PaneLeaf.placeholder(type: 'sftp');
      expect(leaf.isPlaceholder, isTrue);
      expect(leaf.type, 'sftp');
    });

    test('placeholder factory with explicit id keeps that id', () {
      final leaf = PaneLeaf.placeholder(id: 'fixed-id');
      expect(leaf.id, 'fixed-id');
      expect(leaf.isPlaceholder, isTrue);
    });

    test('leaf with only an empty-string session id is also a placeholder',
        () {
      // PaneLeaf.withRemovedSession returns this shape when the last
      // session is removed; we treat it as a placeholder so the renderer
      // shows the "Connect…" card instead of crashing.
      final leaf = PaneLeaf(sessionIds: const ['']);
      expect(leaf.isPlaceholder, isTrue);
    });

    test('populated leaf is NOT a placeholder', () {
      final leaf = PaneLeaf.single(sessionId: 'sess-1');
      expect(leaf.isPlaceholder, isFalse);
      expect(leaf.sessionId, 'sess-1');
    });

    test('sessionIdOrNull returns null on placeholder, sessionId otherwise',
        () {
      final placeholder = PaneLeaf.placeholder();
      final real = PaneLeaf.single(sessionId: 'sess-real');
      expect(placeholder.sessionIdOrNull, isNull);
      expect(real.sessionIdOrNull, 'sess-real');
    });
  });

  group('PaneNode JSON round-trip', () {
    test('placeholder leaf survives toJson → fromJson and stays a placeholder',
        () {
      final original = PaneLeaf.placeholder(id: 'placeholder-1');
      final restored = _roundTrip(original);

      expect(restored, isA<PaneLeaf>());
      final leaf = restored as PaneLeaf;
      expect(leaf.id, 'placeholder-1');
      expect(leaf.isPlaceholder, isTrue);
      expect(leaf.sessionIds, isEmpty);
      expect(leaf.type, 'terminal');
    });

    test('placeholder SFTP leaf preserves its paneType', () {
      final original = PaneLeaf.placeholder(id: 'sftp-empty', type: 'sftp');
      final restored = _roundTrip(original) as PaneLeaf;

      expect(restored.isPlaceholder, isTrue);
      expect(restored.type, 'sftp');
    });

    test('populated leaf round-trips with sessionIds and activeIndex', () {
      final original = PaneLeaf(
        sessionIds: const ['s1', 's2', 's3'],
        activeIndex: 2,
        id: 'leaf-multi',
      );
      final restored = _roundTrip(original) as PaneLeaf;

      expect(restored.id, 'leaf-multi');
      expect(restored.sessionIds, ['s1', 's2', 's3']);
      expect(restored.activeIndex, 2);
      expect(restored.isPlaceholder, isFalse);
      expect(restored.sessionId, 's3');
    });

    test('split with one placeholder + one populated leaf round-trips', () {
      final original = PaneSplit(
        axis: Axis.horizontal,
        ratio: 0.6,
        first: PaneLeaf.single(sessionId: 'real-1', id: 'L'),
        second: PaneLeaf.placeholder(id: 'R'),
      );
      final restored = _roundTrip(original);

      expect(restored, isA<PaneSplit>());
      final split = restored as PaneSplit;
      expect(split.axis, Axis.horizontal);
      expect(split.ratio, closeTo(0.6, 1e-9));

      final left = split.first as PaneLeaf;
      final right = split.second as PaneLeaf;
      expect(left.id, 'L');
      expect(left.isPlaceholder, isFalse);
      expect(left.sessionId, 'real-1');
      expect(right.id, 'R');
      expect(right.isPlaceholder, isTrue);
    });

    test('nested split-of-splits with mixed placeholders round-trips', () {
      // Four-quadrant grid where the bottom-right slot is empty - what the
      // sort-layout 4-grid preset produces when there are only 3 active
      // sessions.
      final original = PaneSplit(
        axis: Axis.vertical,
        ratio: 0.5,
        first: PaneSplit(
          axis: Axis.horizontal,
          ratio: 0.5,
          first: PaneLeaf.single(sessionId: 's1', id: 'tl'),
          second: PaneLeaf.single(sessionId: 's2', id: 'tr'),
        ),
        second: PaneSplit(
          axis: Axis.horizontal,
          ratio: 0.5,
          first: PaneLeaf.single(sessionId: 's3', id: 'bl'),
          second: PaneLeaf.placeholder(id: 'br'),
        ),
      );

      final restored = _roundTrip(original) as PaneSplit;

      // Drill down to verify each leaf came back correctly.
      final top = restored.first as PaneSplit;
      final bottom = restored.second as PaneSplit;
      final tl = top.first as PaneLeaf;
      final tr = top.second as PaneLeaf;
      final bl = bottom.first as PaneLeaf;
      final br = bottom.second as PaneLeaf;

      expect(tl.id, 'tl');
      expect(tl.sessionId, 's1');
      expect(tr.id, 'tr');
      expect(tr.sessionId, 's2');
      expect(bl.id, 'bl');
      expect(bl.sessionId, 's3');
      expect(br.id, 'br');
      expect(br.isPlaceholder, isTrue);

      // allLeaves spans the whole tree (3 real + 1 placeholder).
      expect(restored.allLeaves.length, 4);
      expect(
        restored.allLeaves.where((l) => l.isPlaceholder).length,
        1,
      );
    });

    test('legacy single-sessionId JSON shape still deserializes', () {
      // Older saved-state payloads stored just `sessionId` (not the
      // `sessionIds` list). PaneNode.fromJson should still rehydrate them.
      final json = {
        'type': 'leaf',
        'id': 'legacy',
        'sessionId': 'old-session',
      };
      final restored = PaneNode.fromJson(json) as PaneLeaf;

      expect(restored.id, 'legacy');
      expect(restored.sessionIds, ['old-session']);
      expect(restored.activeIndex, 0);
      expect(restored.isPlaceholder, isFalse);
    });

    test('null JSON returns null', () {
      expect(PaneNode.fromJson(null), isNull);
    });

    test('unknown type returns null instead of throwing', () {
      final json = {'type': 'something-else'};
      expect(PaneNode.fromJson(json), isNull);
    });
  });

  group('findLeaf and allLeaves with placeholders', () {
    test('findLeaf locates a placeholder leaf inside a split', () {
      final tree = PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf.single(sessionId: 'a', id: 'left'),
        second: PaneLeaf.placeholder(id: 'right-empty'),
      );

      final found = tree.findLeaf('right-empty');
      expect(found, isNotNull);
      expect(found!.isPlaceholder, isTrue);
    });

    test('allLeaves includes placeholder leaves', () {
      final tree = PaneSplit(
        axis: Axis.vertical,
        first: PaneLeaf.placeholder(),
        second: PaneLeaf.single(sessionId: 'real'),
      );

      expect(tree.allLeaves.length, 2);
      expect(tree.allLeaves.where((l) => l.isPlaceholder).length, 1);
    });
  });
}
