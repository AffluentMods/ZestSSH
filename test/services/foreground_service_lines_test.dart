import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/foreground_service.dart';

/// The sessions notification on Android lists the open hosts when pulled down
/// this way: each host once, with its count when it has
/// several sessions, and only the count on the lock screen.
void main() {
  test('each host once, in the order opened, with a count past one', () {
    expect(notificationSessionLines(['web-02', 'db-primary', 'web-02', ' ', 'web-02']),
        ['web-02 (3)', 'db-primary']);
    expect(notificationSessionLines(const []), isEmpty);
  });

  test('the notification lists them pulled down, and the lock screen sees only the count', () {
    final service = File('android/app/src/main/kotlin/com/affluentlabs/zestssh/SshForegroundService.kt')
        .readAsStringSync();
    expect(service, contains('Notification.InboxStyle().setBigContentTitle(label)'));
    expect(service, contains('names.forEach { style.addLine(it) }'));
    expect(service, contains('.setVisibility(Notification.VISIBILITY_PRIVATE)'));
    expect(service, contains('.setPublicVersion(public)'));
    final activity = File('android/app/src/main/kotlin/com/affluentlabs/zestssh/MainActivity.kt').readAsStringSync();
    expect(activity, contains('putStringArrayListExtra(SshForegroundService.EXTRA_NAMES, names)'));
  });
}
