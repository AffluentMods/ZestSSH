import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/hosts/widgets/host_grid_area.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';

ConnectionWithDetails _conn(String id, {int sizeTier = 1}) {
  final now = DateTime(2024, 1, 1);
  return ConnectionWithDetails(
    connection: Connection(
      id: id,
      label: 'host-$id',
      host: '10.0.0.$id',
      port: 22,
      colorIndex: 0,
      protocol: 'ssh',
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: sizeTier,
      pinned: false,
      monitored: false,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

({HostCardData data, ConnectionWithDetails connectionWithDetails}) _entry(
    String id,
    {int sizeTier = 1}) {
  return (
    data: HostCardData(
      id: id,
      name: 'host-$id',
      subtitle: 'me@10.0.0.$id',
      osId: null,
      status: HostStatus.offline,
      hasActiveSession: false,
    ),
    connectionWithDetails: _conn(id, sizeTier: sizeTier),
  );
}

Widget _harness(
  List<({HostCardData data, ConnectionWithDetails connectionWithDetails})> hostCards,
  SharedPreferences prefs, {
  VoidCallback? onNewConnection,
  void Function(String draggedId, String targetId)? onReorder,
}) {
  // HostCard reads hostCardSettingsProvider, which reads
  // sharedPreferencesProvider - without the override the provider
  // throws on read.
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
    child: MaterialApp(
      // The New Connection tile resolves its label via AppLocalizations.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: HostGridArea(
            hostCards: hostCards,
            itemWidth: 300,
            onConnect: (_) {},
            onShowContextMenu: (_, _) {},
            onNewConnection: onNewConnection,
            onReorder: onReorder,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  testWidgets('rubber-band fires on drag from empty space', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final cards = [
      _entry('1'),
      _entry('2'),
      _entry('3'),
      _entry('4'),
    ];
    await tester.pumpWidget(_harness(cards, prefs));
    await tester.pumpAndSettle();

    // Find the ProviderScope's container so we can check provider state.
    final element = tester.element(find.byType(HostGridArea));
    final container = ProviderScope.containerOf(element);

    expect(container.read(hostMultiSelectProvider).active, isFalse,
        reason: 'precondition: not in selection mode');

    // 4 cards each 300 wide with 12 spacing - at width 800 we get 2
    // columns. The Wrap is left-aligned, so cards live at x in
    // [0..300] and [312..612]. Pick a point in the gutter at x≈306,
    // somewhere between the rows so we're not on any card.
    final grid = tester.getRect(find.byType(HostGridArea));
    final empty = grid.topLeft + const Offset(306, 40);

    // Sanity check: getRect for the first SizedBox-keyed card should
    // not contain `empty`.
    final firstCardRect = tester.getRect(find.byType(HostCard).first);
    expect(firstCardRect.contains(empty), isFalse,
        reason: 'precondition: drag start point is outside any card');

    final gesture = await tester.startGesture(empty, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    // Past kPanSlop (18 logical px). Move 60 px diagonally.
    await gesture.moveBy(const Offset(60, 60));
    await tester.pump();

    expect(container.read(hostMultiSelectProvider).active, isTrue,
        reason: 'rubber-band recognizer should have entered selection mode');

    // Overlay rect is rendered as a Positioned inside the HostGridArea.
    // While the band is in flight there should be a Positioned whose
    // child is an IgnorePointer wrapping a DecoratedBox.
    expect(
      find.descendant(
        of: find.byType(HostGridArea),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
      reason: 'rubber-band overlay should be painted while drag is in flight',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('rubber-band does NOT fire on drag from a card', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final cards = [
      _entry('1'),
      _entry('2'),
      _entry('3'),
      _entry('4'),
    ];
    await tester.pumpWidget(_harness(cards, prefs));
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(HostGridArea));
    final container = ProviderScope.containerOf(element);

    expect(container.read(hostMultiSelectProvider).active, isFalse);

    // Start the drag from inside the first card.
    final cardRect = tester.getRect(find.byType(HostCard).first);
    final cardCenter = cardRect.center;

    final gesture = await tester.startGesture(cardCenter,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await gesture.moveBy(const Offset(60, 60));
    await tester.pump();

    expect(container.read(hostMultiSelectProvider).active, isFalse,
        reason: 'recognizer should refuse pointers landing on a card');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  // No per-host size. A size a host saved before
  // (0 the old row, 3 the old square) is not read: every card is the full
  // card, one column wide, one height.
  testWidgets('every host is one card, whatever size it saved before', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    await tester.pumpWidget(_harness([
      _entry('1', sizeTier: 3),
      _entry('2', sizeTier: 0),
      _entry('3', sizeTier: 1),
    ], prefs));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final sizes = [for (var i = 0; i < 3; i++) tester.getSize(find.byType(HostCard).at(i))];
    expect(sizes.map((s) => s.width).toSet(), {300.0});
    expect(sizes.map((s) => s.height).toSet(), hasLength(1));
    // Each shows its name and its address, as the full card does.
    for (final id in ['1', '2', '3']) {
      expect(find.text('host-$id'), findsOneWidget);
      expect(find.text('me@10.0.0.$id'), findsOneWidget);
    }
  });

  testWidgets('New Connection tile trails the grid and fires its callback',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    var taps = 0;
    // Two cards of 300 to a row of 800: three hosts leave a free place in
    // the last row, which the tile takes.
    await tester.pumpWidget(_harness(
      [_entry('1'), _entry('2'), _entry('3')],
      prefs,
      onNewConnection: () => taps++,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Shown once, after the host cards, beside the last, and a tap fires
    // the callback.
    expect(find.text('New host'), findsOneWidget);
    expect(tester.getTopLeft(find.text('New host')).dy,
        greaterThan(tester.getTopLeft(find.byType(HostCard).at(2)).dy - 1),
        reason: 'in the last row');
    await tester.tap(find.text('New host'));
    expect(taps, 1);

    // Two hosts fill the row: the tile starts the next row, at its left
    // (it was hidden there, and came back only once
    // the host panel narrowed the grid).
    await tester.pumpWidget(_harness(
      [_entry('1'), _entry('2')],
      prefs,
      onNewConnection: () => taps++,
    ));
    await tester.pumpAndSettle();
    expect(find.text('New host'), findsOneWidget);
    final first = tester.getTopLeft(find.byType(HostCard).first);
    final tile = tester.getTopLeft(find.ancestor(of: find.text('New host'), matching: find.byType(GestureDetector)).first);
    expect(tile.dy, greaterThan(first.dy), reason: 'on the next row');
    expect((tile.dx - first.dx).abs(), lessThan(1), reason: 'at the left, where the next card would go');
  });

  testWidgets('New Connection tile is hidden without a callback', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_harness([_entry('1')], prefs));
    await tester.pumpAndSettle();
    expect(find.text('New host'), findsNothing);
  });

  testWidgets('dragging one card onto another fires onReorder(dragged, target)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    String? dragged, target;
    await tester.pumpWidget(_harness(
      [_entry('1'), _entry('2'), _entry('3')],
      prefs,
      onReorder: (d, t) {
        dragged = d;
        target = t;
      },
    ));
    await tester.pumpAndSettle();

    // Grab card '1' and drop it on card '3'.
    final from = tester.getCenter(find.byType(HostCard).at(0));
    final to = tester.getCenter(find.byType(HostCard).at(2));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dragged, '1');
    expect(target, '3');
  });

  testWidgets('cards are not reorder targets when onReorder is null',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_harness([_entry('1'), _entry('2')], prefs));
    await tester.pumpAndSettle();
    // No DragTarget wrappers when reordering is off (only drag-to-group,
    // which lives on the sidebar, not here).
    expect(find.byType(DragTarget<ConnectionWithDetails>), findsNothing);
  });

  // In a code review, the cards of a last row that is not full
  // were said to be drawn wider or narrower than the rows above.
  testWidgets('every card is one width, the last row not full too, with or without reordering',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    for (final reorder in [false, true]) {
      await tester.pumpWidget(_harness(
        [for (var i = 1; i <= 3; i++) _entry('$i')],
        prefs,
        onNewConnection: () {},
        onReorder: reorder ? (_, _) {} : null,
      ));
      await tester.pumpAndSettle();
      final widths = [for (final e in find.byType(HostCard).evaluate()) tester.getSize(find.byWidget(e.widget)).width];
      expect(widths, hasLength(3));
      expect(widths.toSet(), {300.0}, reason: 'reordering $reorder: $widths');
      final rows = {for (final e in find.byType(HostCard).evaluate()) tester.getTopLeft(find.byWidget(e.widget)).dy};
      expect(rows, hasLength(2), reason: 'two at 800 wide, then one with the New host tile');
    }
  });
}
