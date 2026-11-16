import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/ui/widgets/zest_master_detail.dart';

const _listKey = Key('list-pane');
const _detailKey = Key('detail-pane');

/// Pump [child] with the test surface forced to [width] x 800 so the internal
/// LayoutBuilder sees a deterministic total width (independent of the default
/// test window size).
Future<void> _pumpAt(WidgetTester tester, double width, Widget child) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

ZestMasterDetail _shell(String id, {double initialRatio = 0.38}) =>
    ZestMasterDetail(
      screenId: id,
      initialRatio: initialRatio,
      listPane: Container(key: _listKey),
      detailPane: Container(key: _detailKey),
    );

void main() {
  group('ZestMasterDetail', () {
    testWidgets('wide (>=1000px) shows both panes with a draggable divider',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pumpAt(tester, 1400, _shell('wide'));

      expect(find.byKey(_listKey), findsOneWidget);
      expect(find.byKey(_detailKey), findsOneWidget);

      // Dragging the divider (an 8px grab area just right of the list) widens
      // the list - proving the divider is draggable.
      final before = tester.getSize(find.byKey(_listKey)).width;
      // 0.38 * 1400 = 532 → handle centre ~536.
      await tester.dragFrom(const Offset(536, 400), const Offset(120, 0));
      await tester.pumpAndSettle();
      final after = tester.getSize(find.byKey(_listKey)).width;
      expect(after, greaterThan(before));
    });

    testWidgets('narrow (<1000px) shows only the list pane', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pumpAt(tester, 800, _shell('narrow'));

      expect(find.byKey(_listKey), findsOneWidget);
      expect(find.byKey(_detailKey), findsNothing);
    });

    testWidgets('restores a persisted split ratio on build', (tester) async {
      // 0.5 list fraction persisted for this screenId.
      SharedPreferences.setMockInitialValues(
        {ZestMasterDetail.prefsKeyFor('persist'): 0.5},
      );
      await _pumpAt(tester, 1400, _shell('persist', initialRatio: 0.38));

      // 0.5 * 1400 = 700 (within [320, 872]); NOT the 0.38 default (532).
      final width = tester.getSize(find.byKey(_listKey)).width;
      expect(width, closeTo(700, 1));
    });

    testWidgets('persists the split ratio after a drag', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pumpAt(tester, 1400, _shell('save'));

      await tester.dragFrom(const Offset(536, 400), const Offset(120, 0));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(ZestMasterDetail.prefsKeyFor('save')), isNotNull);
    });

    testWidgets('pushDetail pushes a full-screen route with a back affordance',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      late BuildContext ctx;
      await _pumpAt(
        tester,
        800,
        Builder(builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        }),
      );

      ZestMasterDetail.pushDetail(
        ctx,
        Container(key: const Key('pushed-detail')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pushed-detail')), findsOneWidget);
      // Back affordance present.
      expect(find.byType(IconButton), findsOneWidget);
    });
  });
}
