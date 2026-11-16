import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/widgets/notification_bell.dart';
import 'package:zestssh/features/notifications/widgets/notification_toast_overlay.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The same notice said again while it still stands on screen is counted on
/// it (3.0: "Sync now" pressed four times
/// against a server that refused it left four identical notices, one under
/// the other).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => NotificationCenter.debugToastsDrawn = null);

  const said = "Couldn't reach the sync server. Check your connection and try again.";

  NotificationsState stateOf(ProviderContainer c) => c.read(notificationCenterProvider);

  ProviderContainer center() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('on a computer', () {
    setUp(() => NotificationCenter.debugToastsDrawn = true);

    test('said again while it stands: one notice, counted, the newest, unread, with the latest details', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      final first = nc.error(said, details: 'the first time');
      nc.info('Something else in between');
      nc.markAllRead();
      final again = nc.error(said, details: 'the second time');
      expect(again, first, reason: 'the notice that stands is the one that stands for it');
      final third = nc.error(said, details: 'the third time');
      expect(third, first);

      final history = stateOf(c).history;
      expect(history.where((n) => n.title == said), hasLength(1));
      expect(history, hasLength(2));
      final notice = history.first;
      expect(notice.id, first, reason: 'the newest: in front of what was said in between');
      expect(notice.repeats, 3);
      expect(notice.isRead, isFalse, reason: 'it happened again');
      expect(notice.details, 'the third time');
      expect(stateOf(c).visibleToasts.where((n) => n.title == said), hasLength(1));
      expect(stateOf(c).unreadCount, 1);
    });

    test('its time is the last time it was said', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      nc.show(AppNotification(id: 'a', title: said, severity: NotificationSeverity.error, createdAt: DateTime(2026, 10, 6, 9)), countRepeats: true);
      nc.show(AppNotification(id: 'b', title: said, severity: NotificationSeverity.error, createdAt: DateTime(2026, 10, 6, 9, 5)), countRepeats: true);
      final notice = stateOf(c).history.single;
      expect(notice.id, 'a');
      expect(notice.createdAt, DateTime(2026, 10, 6, 9, 5));
    });

    test('the latest time with nothing behind it keeps what the time before had', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      nc.error(said, details: 'what was thrown');
      nc.error(said);
      expect(stateOf(c).history.single.details, 'what was thrown');
      expect(stateOf(c).history.single.repeats, 2);
    });

    test('another kind, another title or another text is another notice', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      nc.error(said, body: 'web-01');
      nc.warning(said, body: 'web-01');
      nc.error('$said.', body: 'web-01');
      nc.error(said, body: 'db-01');
      nc.error(said);
      expect(stateOf(c).history, hasLength(5));
      expect(stateOf(c).history.every((n) => n.repeats == 1), isTrue);
    });

    test('once it is closed, the same thing said again is a notice of its own', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      final first = nc.error(said);
      nc.error(said);
      nc.dismissToast(first);
      expect(stateOf(c).visibleToasts, isEmpty);
      final later = nc.error(said);
      expect(later, isNot(first));
      final history = stateOf(c).history;
      expect(history, hasLength(2));
      expect(history.first.id, later);
      expect(history.first.repeats, 1);
      expect(history.last.repeats, 2, reason: 'what was counted stays counted');
      expect(history.last.isRead, isTrue);
      expect(stateOf(c).visibleToasts.single.id, later);
    });

    test('a notice with an action of its own is never counted on another: each keeps its action', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      final undone = <String>[];
      nc.show(AppNotification(id: 'u1', title: 'Closed web-01', actionLabel: 'Undo', onAction: () => undone.add('first')), countRepeats: true);
      nc.show(AppNotification(id: 'u2', title: 'Closed web-01', actionLabel: 'Undo', onAction: () => undone.add('second')), countRepeats: true);
      // One without an action is not counted on one with, nor the other way.
      nc.show(AppNotification(id: 'u3', title: 'Closed web-01', actionLabel: 'Undo'), countRepeats: true);
      nc.show(AppNotification(id: 'u4', title: 'Closed web-01', actionLabel: 'Undo', onAction: () => undone.add('fourth')), countRepeats: true);
      final history = stateOf(c).history;
      expect(history.map((n) => n.id), ['u4', 'u3', 'u2', 'u1']);
      for (final n in history.reversed) {
        n.onAction?.call();
      }
      expect(undone, ['first', 'second', 'fourth']);
    });

    test('a notice that names what its button does is counted only on one that names the same', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      nc.show(AppNotification(id: 'a', title: said, actionLabel: 'Details'), countRepeats: true);
      nc.show(AppNotification(id: 'b', title: said), countRepeats: true);
      nc.show(AppNotification(id: 'c', title: said, actionLabel: 'Details'), countRepeats: true);
      final history = stateOf(c).history;
      expect(history.map((n) => n.id), ['a', 'b']);
      expect(history.first.repeats, 2);
    });

    test('a notice that leaves no trace is not counted, and nothing is counted on it', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      nc.show(AppNotification(id: 't1', title: 'Testing the connection', transient: true), countRepeats: true);
      nc.show(AppNotification(id: 't2', title: 'Testing the connection', transient: true), countRepeats: true);
      nc.show(AppNotification(id: 't3', title: 'Testing the connection'), countRepeats: true);
      expect(stateOf(c).history.map((n) => n.id), ['t3', 't2', 't1']);
      nc.show(AppNotification(id: 't4', title: 'Testing the connection', transient: true), countRepeats: true);
      expect(stateOf(c).history, hasLength(4));
      expect(stateOf(c).history.every((n) => n.repeats == 1), isTrue);
    });

    test('sent again under its own id it replaces itself, as before', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      nc.show(AppNotification(id: 'progress', title: 'Uploading', body: '1 of 3'), countRepeats: true);
      nc.show(AppNotification(id: 'other', title: 'Uploading', body: '2 of 3'), countRepeats: true);
      nc.show(AppNotification(id: 'progress', title: 'Uploading', body: '2 of 3'), countRepeats: true);
      final history = stateOf(c).history;
      expect(history.map((n) => n.id), ['progress', 'other']);
      expect(history.first.body, '2 of 3');
      expect(history.every((n) => n.repeats == 1), isTrue);
    });

    test('a notice shown under an id of its own is its own notice: not counted on another, nor another on it', () {
      // (One "typing is held" for each session that is held: counted
      // together, taking one back would have taken them all.)
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      const held = 'Nobody is watching your session, so typing is held.';
      AppNotification of(String session) =>
          AppNotification(id: 'watch-held-$session', title: held, severity: NotificationSeverity.warning);
      nc.show(of('s1'));
      nc.show(of('s2'));
      expect(stateOf(c).history.map((n) => n.id), ['watch-held-s2', 'watch-held-s1']);

      // A plain message of the same words is not counted on them.
      final plain = nc.warning(held);
      expect(stateOf(c).history, hasLength(3));
      // It is counted on itself.
      expect(nc.warning(held), plain);
      expect(stateOf(c).history, hasLength(3));
      expect(stateOf(c).history.first.repeats, 2);
      // And one with an id of its own is not counted on the plain one.
      nc.show(of('s3'));
      expect(stateOf(c).history.map((n) => n.id), ['watch-held-s3', plain, 'watch-held-s2', 'watch-held-s1']);
      expect(stateOf(c).history.where((n) => n.id.startsWith('watch-held')).every((n) => n.repeats == 1), isTrue);

      // Each is taken back by itself.
      nc.remove('watch-held-s1');
      expect(stateOf(c).history.map((n) => n.id), ['watch-held-s3', plain, 'watch-held-s2']);
    });

    test('every kind of plain message is counted: information, success, a warning, an error', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      final ids = [
        for (var round = 0; round < 2; round++) ...[
          nc.info('Copied'),
          nc.success('Saved'),
          nc.warning('The clock looks wrong'),
          nc.error(said),
        ],
      ];
      expect(ids.sublist(4), ids.sublist(0, 4), reason: 'the second time each is the notice that stands');
      expect(stateOf(c).history, hasLength(4));
      expect(stateOf(c).history.every((n) => n.repeats == 2), isTrue);
    });

    test('a plain message that was taken away is not counted on any more', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      final first = nc.error(said);
      nc.remove(first);
      final again = nc.error(said);
      expect(again, isNot(first));
      expect(stateOf(c).history.single.repeats, 1);
      nc.clearAll();
      final after = nc.error(said);
      expect(after, isNot(again));
      expect(stateOf(c).history.single.repeats, 1);
    });

    test('one that waits for room on screen is counted on too', () {
      final c = center();
      final nc = c.read(notificationCenterProvider.notifier);
      for (var i = 1; i <= 4; i++) {
        nc.info('Saved key $i');
      }
      expect(stateOf(c).visibleToasts, hasLength(4));
      final waiting = nc.info('Saved key 5');
      expect(stateOf(c).visibleToastIds.contains(waiting), isFalse, reason: 'no room yet');
      expect(nc.info('Saved key 5'), waiting);
      expect(stateOf(c).history, hasLength(5));
      expect(stateOf(c).history.first.repeats, 2);
      // When there is room it is shown, with its count.
      nc.dismissToast(stateOf(c).visibleToasts.first.id);
      final shown = stateOf(c).visibleToasts.singleWhere((n) => n.id == waiting);
      expect(shown.repeats, 2);
    });

    testWidgets('a notice that closes by itself stays as long again from the last time it was said', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final nc = c.read(notificationCenterProvider.notifier);
      final id = nc.info('Copied', dismissAfter: const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 3));
      expect(nc.info('Copied', dismissAfter: const Duration(seconds: 4)), id);
      await tester.pump(const Duration(seconds: 3));
      expect(stateOf(c).visibleToastIds, {id}, reason: 'six seconds after the first, two after the second');
      await tester.pump(const Duration(seconds: 2));
      expect(stateOf(c).visibleToastIds, isEmpty);
      expect(stateOf(c).history.single.repeats, 2);
      expect(stateOf(c).history.single.isRead, isTrue);
    });
  });

  test('on a phone nothing stands on screen to be the same as: each is its own entry', () {
    NotificationCenter.debugToastsDrawn = false;
    final c = center();
    final nc = c.read(notificationCenterProvider.notifier);
    final first = nc.error(said);
    final second = nc.error(said);
    expect(second, isNot(first));
    expect(stateOf(c).history, hasLength(2));
    expect(stateOf(c).history.every((n) => n.repeats == 1), isTrue);
  });

  group('kept with the history', () {
    test('the count is written and read back; a notice said once writes none', () {
      final counted = AppNotification(id: 'a', title: said, repeats: 4, createdAt: DateTime(2026, 10, 6, 9));
      expect(counted.toJson()['repeats'], 4);
      expect(AppNotification.fromJson(counted.toJson()).repeats, 4);
      final once = AppNotification(id: 'b', title: said, createdAt: DateTime(2026, 10, 6, 9));
      expect(once.toJson().containsKey('repeats'), isFalse);
      expect(AppNotification.fromJson(once.toJson()).repeats, 1);
    });

    test('a saved count that is no count reads as once', () {
      Map<String, dynamic> row(Object? repeats) => {
            'id': 'a',
            'title': said,
            'createdAt': DateTime(2026, 10, 6, 9).toIso8601String(),
            'repeats': repeats,
          };
      expect(AppNotification.fromJson(row('many')).repeats, 1);
      expect(AppNotification.fromJson(row(0)).repeats, 1);
      expect(AppNotification.fromJson(row(-3)).repeats, 1);
      expect(AppNotification.fromJson(row(null)).repeats, 1);
      expect(AppNotification.fromJson(row(2.0)).repeats, 2);
    });

    test('a notice counted on screen is saved with its count', () async {
      NotificationCenter.debugToastsDrawn = true;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      final nc = c.read(notificationCenterProvider.notifier);
      nc.error(said);
      // (Saved once here, so the count below is saved by the counting.)
      await Future<void>.delayed(Duration.zero);
      List<dynamic> saved() => jsonDecode(c.read(settingsServiceProvider).notificationHistory!) as List;
      expect((saved().single as Map).containsKey('repeats'), isFalse);
      nc.error(said);
      await Future<void>.delayed(Duration.zero);
      expect(saved(), hasLength(1));
      expect((saved().single as Map)['repeats'], 2);
    });
  });

  group('shown', () {
    setUp(() => NotificationCenter.debugToastsDrawn = true);

    Future<ProviderContainer> pump(WidgetTester tester, Widget child) async {
      // The app's own font: the test font's glyphs are squares as wide as
      // they are tall, and the bell's heading does not fit in them.
      await tester.runAsync(() async {
        final loader = FontLoader('GeistSans');
        for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf']) {
          final bytes = File('assets/fonts/$f').readAsBytesSync();
          loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
        }
        await loader.load().timeout(const Duration(seconds: 30));
      });
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      ));
      return c;
    }

    // As designed: all of them at the top right,
    // under the bell, the count kept.
    testWidgets('the cards stand at the top right, under the bell, the first said on top', (tester) async {
      final c = await pump(tester, const NotificationToastOverlay(child: SizedBox.expand()));
      final nc = c.read(notificationCenterProvider.notifier);
      nc.error('The first thing said');
      await tester.pump(const Duration(milliseconds: 300));
      nc.error('The second thing said');
      await tester.pump(const Duration(milliseconds: 300));
      final window = tester.getSize(find.byType(NotificationToastOverlay));
      final first = tester.getRect(find.ancestor(of: find.text('The first thing said'), matching: find.byType(Material)).first);
      final second = tester.getRect(find.ancestor(of: find.text('The second thing said'), matching: find.byType(Material)).first);
      expect(first.top, greaterThanOrEqualTo(DesktopDimensions.pillBarHeight), reason: 'under the title bar with the bell');
      expect(first.top, lessThan(DesktopDimensions.pillBarHeight + 24));
      expect(window.width - first.right, lessThan(24), reason: 'at the right');
      expect(second.top, greaterThan(first.bottom - 1), reason: 'the next under it: none moves while it is read');
    });

    testWidgets('in a language written right to left they stand on the left, where the bell is', (tester) async {
      final c = await pump(
        tester,
        const Directionality(textDirection: TextDirection.rtl, child: NotificationToastOverlay(child: SizedBox.expand())),
      );
      c.read(notificationCenterProvider.notifier).error('The first thing said');
      await tester.pump();
      Rect card() => tester.getRect(find.ancestor(of: find.text('The first thing said'), matching: find.byType(Material)).first);
      expect(card().right, lessThanOrEqualTo(0), reason: 'it comes in from that edge');
      await tester.pump(const Duration(milliseconds: 600));
      expect(card().left, lessThan(24), reason: 'at the left');
      expect(card().left, greaterThanOrEqualTo(0));
    });

    testWidgets('one card with how many times it was said; a notice said once shows no count', (tester) async {
      final c = await pump(tester, const NotificationToastOverlay(child: SizedBox.expand()));
      final nc = c.read(notificationCenterProvider.notifier);
      nc.error(said);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(said), findsOneWidget);
      expect(find.byKey(const ValueKey('toast-count')), findsNothing);

      nc.error(said);
      nc.error(said);
      nc.error(said);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(said), findsOneWidget, reason: 'one card, not four');
      expect(
        find.descendant(of: find.byKey(const ValueKey('toast-count')), matching: find.text('×4')),
        findsOneWidget,
      );
    });

    testWidgets('what a pressed button answers is counted: the same failure four times is one notice', (tester) async {
      late BuildContext context;
      final c = await pump(tester, Builder(builder: (ctx) {
        context = ctx;
        return const SizedBox.expand();
      }));
      for (var i = 0; i < 4; i++) {
        showTopSnackBar(context, said, isError: true, details: 'refused, try $i');
      }
      final history = stateOf(c).history;
      expect(history, hasLength(1));
      expect(history.single.repeats, 4);
      expect(history.single.details, contains('refused, try 3'));

      // With a button of its own it is not: each "Undo" undoes its own thing.
      final undone = <int>[];
      for (var i = 0; i < 2; i++) {
        showTopSnackBar(context, 'Closed web-01', actionLabel: 'Undo', onAction: () => undone.add(i));
      }
      expect(stateOf(c).history.where((n) => n.title == 'Closed web-01'), hasLength(2));
      for (final n in stateOf(c).history.where((n) => n.title == 'Closed web-01')) {
        n.onAction!();
      }
      expect(undone, unorderedEquals([0, 1]));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('the bell counts every time it was said, on screen and after', (tester) async {
      final c = await pump(tester, const Align(alignment: Alignment.topRight, child: NotificationBell()));
      final nc = c.read(notificationCenterProvider.notifier);
      final first = nc.error(said);
      nc.error(said);
      nc.dismissToast(first);
      nc.error(said);
      nc.error(said);
      nc.error('Something else');
      await tester.pump();
      await tester.tap(find.byType(NotificationBell));
      await tester.pump();
      expect(find.text(said), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('bell-count')), matching: find.text('×4')),
        findsOneWidget,
        reason: 'twice while it stood, twice more after it was closed',
      );
      expect(find.byKey(const ValueKey('bell-count')), findsOneWidget, reason: 'none on what was said once');
    });
  });
}
