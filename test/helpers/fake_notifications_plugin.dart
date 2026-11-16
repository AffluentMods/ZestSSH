import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zestssh/services/notification_service.dart';

/// The system's notification plugin as a test plays it: what the app
/// started it with and every notification it was asked to show, kept.
class FakeNotificationsPlugin implements FlutterLocalNotificationsPlugin {
  InitializationSettings? settings;
  DidReceiveNotificationResponseCallback? onTap;
  int initializations = 0;

  /// What [resolvePlatformSpecificImplementation] gives where it is of the
  /// type asked for (macOS's, to ask for permission): none otherwise.
  FlutterLocalNotificationsPlatform? platform;
  final shown = <({int id, String? title, String? body, NotificationDetails? details, String? payload})>[];

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback? onDidReceiveBackgroundNotificationResponse,
  }) async {
    this.settings = settings;
    initializations++;
    onTap = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async =>
      shown.add((id: id, title: title, body: body, details: notificationDetails, payload: payload));

  @override
  T? resolvePlatformSpecificImplementation<T extends FlutterLocalNotificationsPlatform>() {
    final p = platform;
    return p is T ? p : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer ([os]) whose person turned on "Also show as system
/// notifications", with [plugin] in place of the system's and ZestSSH's
/// window in front where [inFront] says. [NotificationService.debugReset]
/// puts it all back.
Future<FakeNotificationsPlugin> computerWithSystemNotices({
  String os = 'windows',
  bool Function()? inFront,
  FakeNotificationsPlugin? plugin,
}) async {
  final fake = plugin ?? FakeNotificationsPlugin();
  NotificationService.debugOs = os;
  NotificationService.debugPlugin = fake;
  NotificationService.debugWindowInFront = () async => inFront?.call() ?? false;
  await NotificationService.setComputerSystemNotices(true);
  return fake;
}
