import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The bell's count: it counted every notice, so each
/// "Connected" and "Saved" made it grow, though an info notice is said to
/// show no unread dot. It counts the warnings and errors not yet seen; the
/// others are in the list, unseen there, and Mark all read still reaches them.
void main() {
  test('the bell counts the warnings and errors not yet seen, not info or success', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final nc = container.read(notificationCenterProvider.notifier);
    nc.show(AppNotification(id: 'i', title: 'Connected', severity: NotificationSeverity.info));
    nc.show(AppNotification(id: 's', title: 'Saved', severity: NotificationSeverity.success));
    var state = container.read(notificationCenterProvider);
    expect(state.unreadCount, 0);
    expect(state.hasUnread, isFalse);
    expect(state.anyUnseen, isTrue, reason: 'still unseen in the list');

    nc.show(AppNotification(id: 'w', title: 'Disk almost full', severity: NotificationSeverity.warning));
    nc.show(AppNotification(id: 'e', title: 'Upload failed', severity: NotificationSeverity.error));
    state = container.read(notificationCenterProvider);
    expect(state.unreadCount, 2);

    nc.markAllRead();
    state = container.read(notificationCenterProvider);
    expect(state.unreadCount, 0);
    expect(state.anyUnseen, isFalse);
  });

  test("the bell's words are in every language, and say what it counts", () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.notifBellUnreadTooltip(1), 'Notifications: one warning or error not yet seen');
    expect(en.notifBellUnreadTooltip(3), contains('3'));
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      expect(lookupAppLocalizations(locale).notifBellUnreadTooltip(3), isNot(en.notifBellUnreadTooltip(3)),
          reason: '$locale');
    }
  });

  // The Monitor page counted a reading out of date from the background
  // check and the hosts' chips and the alerts from an open session's
  // refresh: a host could be both at once.
  test('one rule for when a reading is out of date: the longer of the check and the refresh', () {
    expect(monitorStaleAfter(checkIntervalMinutes: 5, refreshIntervalSeconds: 30), const Duration(minutes: 15));
    expect(monitorStaleAfter(checkIntervalMinutes: 0, refreshIntervalSeconds: 30), const Duration(seconds: 90));
    expect(monitorStaleAfter(checkIntervalMinutes: 0, refreshIntervalSeconds: 10), const Duration(seconds: 60));
  });
}
