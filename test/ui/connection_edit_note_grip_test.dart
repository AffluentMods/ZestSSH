import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';

/// The host editor's Note: the grip in its corner sets the box's height (the
/// resize handle could not be dragged before; it was a
/// picture with a resize cursor and nothing behind it).
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    // Short enough that the form scrolls, as it does in use: its scroll view
    // then wants the same vertical drag as the grip.
    tester.view.physicalSize = const Size(1300, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 19);
    await tester.runAsync(() async {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'c1',
            label: 'web-01',
            host: '192.168.10.21',
            note: const Value('rack 4'),
            createdAt: now,
            updatedAt: now,
          ));
    });
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ConnectionEditScreen(connectionId: 'c1', inDialog: true, onClose: () {})),
      ),
    ));
    await settle(tester);
  }

  final note = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'rack 4');
  final grip = find.byKey(const ValueKey('zest-field-grip'));

  Future<void> drag(WidgetTester tester, double dy) async {
    await tester.ensureVisible(grip);
    await tester.pump();
    // By touch, where the form's scroll view wants the same drag (a mouse's
    // drag never scrolls it).
    await tester.drag(grip, Offset(0, dy), kind: PointerDeviceKind.touch);
    await tester.pump();
  }

  testWidgets("the Note's grip drags the box taller and shorter, from one line to about twelve, "
      'with a resize cursor; a resize is no change', (tester) async {
    await pump(tester);
    expect(grip, findsOneWidget);
    expect(
        tester.widget<MouseRegion>(find.ancestor(of: grip, matching: find.byType(MouseRegion)).first).cursor,
        SystemMouseCursors.resizeUpDown);
    final oneLine = tester.getSize(note).height;
    expect(oneLine, lessThan(30), reason: 'one line of words');

    await drag(tester, 80);
    expect(tester.getSize(note).height, moreOrLessEquals(oneLine + 80, epsilon: 2), reason: 'taller by the drag');
    await drag(tester, -30);
    expect(tester.getSize(note).height, moreOrLessEquals(oneLine + 50, epsilon: 3), reason: 'and shorter');
    await drag(tester, -400);
    expect(tester.getSize(note).height, moreOrLessEquals(21, epsilon: 0.5), reason: 'no lower than one line');
    await drag(tester, 1000);
    expect(tester.getSize(note).height, moreOrLessEquals(250, epsilon: 0.5), reason: 'no higher than about twelve');

    expect(tester.widget<TextField>(note).controller!.text, 'rack 4');
    expect(tester.widget<ZestPaneFooter>(find.byType(ZestPaneFooter)).saveEnabled, isFalse,
        reason: 'a resize is no change');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });
}
