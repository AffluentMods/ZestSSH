import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/utils/redactor.dart';

import '../helpers/fake_notifications_plugin.dart';

/// A computer's "Also show as system notifications" (4.0): off at first, so
/// nothing reaches the system; on, the app's notices go to Windows' toasts,
/// macOS's Notification Center or a Linux desktop's notifications while
/// ZestSSH's window is not in front, at the system's normal level (its Do
/// not disturb holds them back), silent for an alert that plays its own
/// sound, with no secret in their words, and a click brings the window
/// forward. The system's plugin is a test's.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  tearDown(() {
    NotificationService.debugReset();
    Redactor.instance.enabled = false;
  });

  test('off at first: nothing goes to the system, and the plugin is not even started', () async {
    final fake = FakeNotificationsPlugin();
    NotificationService.debugOs = 'windows';
    NotificationService.debugPlugin = fake;
    NotificationService.debugWindowInFront = () async => false;
    expect(NotificationService.computerSystemNotices, isFalse);
    await NotificationService.onComputer(() => NotificationService.showConnectionLost(connectionLabel: 'web-01'));
    expect(fake.settings, isNull, reason: 'nothing is registered with Windows until its person asks');
    expect(fake.shown, isEmpty);
  });

  test("on: started once for every computer's system, Windows under ZestSSH's own name", () async {
    final fake = await computerWithSystemNotices();
    final settings = fake.settings!;
    expect(settings.windows!.appName, 'ZestSSH');
    expect(settings.windows!.appUserModelId, NotificationService.windowsAppUserModelId);
    expect(settings.windows!.guid, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
    expect(settings.linux, isNotNull);
    // macOS asks when the switch is turned on, not as the app starts.
    expect(settings.macOS!.requestAlertPermission, isFalse);
    expect(settings.android, isNull);
    await NotificationService.setComputerSystemNotices(false);
    await NotificationService.setComputerSystemNotices(true);
    expect(fake.initializations, 1);
  });

  test('shown while the window is in the tray or behind another, not while it is in front', () async {
    var front = true;
    final fake = await computerWithSystemNotices(inFront: () => front);
    await NotificationService.onComputer(() => NotificationService.showConnectionLost(connectionLabel: 'web-01'));
    expect(fake.shown, isEmpty, reason: "the window's own notice is in sight");

    front = false;
    await NotificationService.onComputer(() => NotificationService.showConnectionLost(connectionLabel: 'web-01'));
    expect(fake.shown, hasLength(1));
    final n = fake.shown.single;
    expect((n.title, n.body), (en.connectionLostTitle, en.connectionLostEnded('web-01')));
    // The payload names the session by a number made from its name, never the name.
    expect(n.payload, startsWith('connection_lost:'));
    expect(n.payload, isNot(contains('web-01')));
  });

  test('turned off again: nothing more goes to the system', () async {
    final fake = await computerWithSystemNotices();
    await NotificationService.setComputerSystemNotices(false);
    await NotificationService.onComputer(() => NotificationService.showNotice(title: 'ZestSSH workflows', body: 'Done'));
    expect(fake.shown, isEmpty);
  });

  test("at the system's normal level everywhere, so its Do not disturb holds them back", () async {
    final fake = await computerWithSystemNotices();
    await NotificationService.onComputer(() => NotificationService.showTicketReply(title: 'Support answered', body: 'Ticket 12'));
    final d = fake.shown.single.details!;
    expect(d.windows!.scenario, isNull, reason: 'no alarm, reminder or urgent toast, which Focus lets through');
    expect(d.linux!.urgency, LinuxNotificationUrgency.normal, reason: 'critical passes a Linux desktop\'s Do not disturb');
    expect(d.macOS!.interruptionLevel, InterruptionLevel.active, reason: 'not time sensitive, which a Focus lets through');
    expect(d.android, isNull);
    expect(fake.shown.single.payload, 'ticket_reply');
  });

  test("an alert's notification is silent on a computer: the app plays the system's alert sound itself", () async {
    final fake = await computerWithSystemNotices();
    await NotificationService.onComputer(() => NotificationService.showTriggerSound(triggerName: 'Disk full', silent: true));
    final n = fake.shown.single;
    expect((n.title, n.body), ('Disk full', en.trgPhoneSoundBody));
    expect(n.details!.windows!.audio, isNotNull);
    expect(n.details!.linux!.suppressSound, isTrue);
    expect(n.details!.macOS!.presentSound, isFalse);
    // And one that is not an alert keeps the system's sound.
    await NotificationService.onComputer(() => NotificationService.showNotice(title: 'ZestSSH workflows', body: 'Done'));
    expect(fake.shown.last.details!.linux!.suppressSound, isFalse);
    expect(fake.shown.last.details!.macOS!.presentSound, isTrue);
  });

  test("no secret in a workflow's notice: a password, a token and a private key from a step's output are left out",
      () async {
    final fake = await computerWithSystemNotices(os: 'linux');
    const output = 'DB_PASSWORD=hunter2hunter\n'
        'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n'
        '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n'
        'backup done';
    await NotificationService.onComputer(() => NotificationService.showNotice(title: 'ZestSSH workflows', body: output));
    final body = fake.shown.single.body!;
    for (final secret in ['hunter2hunter', 'ghp_0123456789', 'b3BlbnNzaC1rZXktdjEAAAAA']) {
      expect(body, isNot(contains(secret)), reason: secret);
    }
    expect(body, contains('backup done'));
  });

  test("a host's name is masked as recording mode masks it", () async {
    final fake = await computerWithSystemNotices(os: 'macos');
    Redactor.instance.enabled = true;
    await NotificationService.onComputer(() => NotificationService.showConnectionLost(connectionLabel: 'db-prod-7'));
    final masked = Redactable.host('db-prod-7').display;
    expect(masked, isNot('db-prod-7'));
    expect(fake.shown.single.body, en.connectionLostEnded(masked));
    expect(fake.shown.single.body, isNot(contains('db-prod-7')));
  });

  test('a click is handed to the app with its payload (the window to the front, the place it is about)', () async {
    final fake = await computerWithSystemNotices();
    final clicked = <String?>[];
    NotificationService.onComputerTap = clicked.add;
    fake.onTap!(const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification, payload: 'ticket_reply'));
    NotificationService.debugTap(null);
    expect(clicked, ['ticket_reply', null]);
  });

  test("a phone's are untouched: the computer's switch is nothing there", () async {
    final fake = FakeNotificationsPlugin();
    NotificationService.debugOs = 'android';
    NotificationService.debugPlugin = fake;
    await NotificationService.setComputerSystemNotices(true);
    expect(NotificationService.computerSystemNotices, isFalse);
    expect(fake.settings, isNull);
  });

  test('macOS is asked as the switch is turned on; Windows and Linux ask nothing', () async {
    NotificationService.debugPlugin = FakeNotificationsPlugin();
    NotificationService.debugOs = 'windows';
    expect(await NotificationService.requestComputerPermission(), isTrue);
    NotificationService.debugOs = 'linux';
    expect(await NotificationService.requestComputerPermission(), isTrue);
  });
}
