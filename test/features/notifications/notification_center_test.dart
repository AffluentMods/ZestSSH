import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/providers/core_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 3.0 UI: what stands behind a warning or an error goes with it,
  // for its Copy details (the port forward notices give theirs this way).
  test('a warning and an error keep their details', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final nc = container.read(notificationCenterProvider.notifier);
    nc.warning("Couldn't start db tunnel", body: 'Port 15432 is in use.', details: 'ZestSSH error details\nWhat: a');
    expect(container.read(notificationCenterProvider).history.first.details, 'ZestSSH error details\nWhat: a');
    nc.error("Couldn't start db tunnel", details: 'ZestSSH error details\nWhat: b');
    final last = container.read(notificationCenterProvider).history.first;
    expect(last.details, 'ZestSSH error details\nWhat: b');
    expect(last.severity, NotificationSeverity.error);
    nc.warning('No details');
    expect(container.read(notificationCenterProvider).history.first.details, isNull);
  });

  group('NotificationCenter - transient notifications (A5)', () {
    test('a transient notification is removed from history on dismiss', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final nc = container.read(notificationCenterProvider.notifier);

      final id = nc.show(AppNotification(
        id: 'testing-1',
        title: 'Testing connection…',
        transient: true,
      ));

      // Present while the toast is visible.
      expect(
        container.read(notificationCenterProvider).history.any((n) => n.id == id),
        isTrue,
        reason: 'transient entry is in history while its toast shows',
      );

      nc.dismissToast(id);

      // Gone entirely once dismissed - no lingering bell row.
      expect(
        container.read(notificationCenterProvider).history.any((n) => n.id == id),
        isFalse,
        reason: 'transient entry leaves no trace after dismissal',
      );
    });

    test('a normal notification stays in history (as read) on dismiss', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final nc = container.read(notificationCenterProvider.notifier);

      final id = nc.show(AppNotification(id: 'kept-1', title: 'Saved identity'));
      nc.dismissToast(id);

      final entry = container
          .read(notificationCenterProvider)
          .history
          .firstWhere((n) => n.id == id);
      expect(entry.isRead, isTrue,
          reason: 'a normal notification persists as a read bell row');
    });
  });

  group('NotificationCenter - mobile mark-read (notifications screen)', () {
    bool isRead(ProviderContainer c, String id) => c
        .read(notificationCenterProvider)
        .history
        .firstWhere((n) => n.id == id)
        .isRead;

    test('markRead marks a single entry read, leaves others alone', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final nc = container.read(notificationCenterProvider.notifier);

      nc.show(AppNotification(
          id: 'a', title: 'Upload failed', severity: NotificationSeverity.error));
      nc.show(AppNotification(
          id: 'b', title: 'Disk almost full',
          severity: NotificationSeverity.warning));

      nc.markRead('a');

      expect(isRead(container, 'a'), isTrue);
      expect(isRead(container, 'b'), isFalse);
      expect(container.read(notificationCenterProvider).unreadCount, 1);
    });

    test('markReadWhere marks only matching entries', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final nc = container.read(notificationCenterProvider.notifier);

      nc.show(AppNotification(
          id: 'warn', title: 'Disk almost full',
          severity: NotificationSeverity.warning));
      nc.show(AppNotification(
          id: 'err', title: 'Upload failed',
          severity: NotificationSeverity.error));

      // e.g. a group "Mark read" that only targets warnings.
      nc.markReadWhere((n) => n.severity == NotificationSeverity.warning);

      expect(isRead(container, 'warn'), isTrue);
      expect(isRead(container, 'err'), isFalse);
    });
  });

  group('NotificationCenter - persistence (mobile history)', () {
    test('non-transient history survives a restart; transient does not',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final overrides = [sharedPreferencesProvider.overrideWithValue(prefs)];

      // Session 1: push a real error + a transient toast, then mark the error
      // read, then tear the container down (app "closes").
      final c1 = ProviderContainer(overrides: overrides);
      final nc1 = c1.read(notificationCenterProvider.notifier);
      nc1.show(AppNotification(
          id: 'kept', title: 'Upload failed',
          severity: NotificationSeverity.error));
      nc1.show(AppNotification(
          id: 'ghost', title: 'Testing…', transient: true));
      nc1.markRead('kept');
      await Future<void>.delayed(Duration.zero); // let the async write settle
      c1.dispose();

      // Session 2: a fresh container on the SAME prefs restores history.
      final c2 = ProviderContainer(overrides: overrides);
      addTearDown(c2.dispose);
      final restored = c2.read(notificationCenterProvider).history;

      final kept = restored.where((n) => n.id == 'kept');
      expect(kept, hasLength(1), reason: 'the real notification persisted');
      expect(kept.first.isRead, isTrue, reason: 'its read state persisted');
      expect(restored.any((n) => n.id == 'ghost'), isFalse,
          reason: 'transient notifications are never persisted');
    });

    test('a corrupt row is dropped (not the whole history); ids de-dup',
        () async {
      final now = DateTime.now().toIso8601String();
      final blob = jsonEncode([
        {'id': 'g', 'title': 'Good', 'severity': 2, 'createdAt': now},
        {'title': 'no id here'}, // missing id -> dropped, not fatal
        {'id': 'g', 'title': 'Dup', 'severity': 0, 'createdAt': now}, // dup id
        {'id': 'b', 'title': 'Bad date', 'createdAt': 'not-a-date'}, // dropped
      ]);
      SharedPreferences.setMockInitialValues({'notification_history': blob});
      final prefs = await SharedPreferences.getInstance();

      final c = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      final h = c.read(notificationCenterProvider).history;

      expect(h.where((n) => n.id == 'g'), hasLength(1),
          reason: 'good row kept, duplicate id dropped');
      expect(h.firstWhere((n) => n.id == 'g').title, 'Good',
          reason: 'first-seen wins on a duplicate id');
      expect(h.any((n) => n.title == 'no id here'), isFalse,
          reason: 'a row missing its id is skipped, not fatal');
      expect(h.any((n) => n.id == 'b'), isFalse,
          reason: 'a row with an unparseable date is skipped, not re-dated');
    });
  });
}
