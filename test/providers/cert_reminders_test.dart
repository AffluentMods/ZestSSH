// The reminders of certificates that run out (3.0). Held here: when a
// reminder comes, how often, and what it says.
//
// As they were, they came from a provider that the app read once when it
// started, before any key had been read from the database, and that nothing
// listened to: it found no key, and was not built again when the keys came.
// It was read again at each unlock, and raised its notices then from within
// its own build, which a build of the app made for testing refuses and a
// released one lets through. So a released app reminded nobody at a plain
// start, and everybody again at each unlock after the saved keys changed;
// in English, in every language.
//
// (testWidgets for its clock, which the test moves: no widget is drawn.)

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/cert_reminder_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

/// A saved key; with a certificate that runs out at [runsOut] where one is
/// given, issued [issuedFor] before that where that is known.
Identity key(String id, String label, {DateTime? runsOut, Duration? issuedFor}) => Identity(
      id: id,
      label: label,
      username: 'deploy',
      authMethod: runsOut == null ? 'publicKey' : 'certificate',
      colorIndex: 0,
      isDefault: false,
      usesAgent: false,
      allowUnattended: false,
      passwordAfterKey: false,
      certValidAfter: runsOut == null || issuedFor == null ? null : runsOut.subtract(issuedFor),
      certValidBefore: runsOut,
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2026),
    );

final _unlocked = StateProvider<bool>((ref) => true);

/// The reminders, with what they are raised from played by the test: the
/// saved keys as the database gives them, whether the app is locked, and
/// the clock.
class Reminders {
  Reminders(this.tester, SharedPreferences prefs) {
    CertReminders.clock = () => now;
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      identitiesProvider.overrideWith((ref) => _keys.stream),
      dbReadyProvider.overrideWith((ref) => ref.watch(_unlocked)),
    ]);
  }

  final WidgetTester tester;
  late final ProviderContainer container;
  final _keys = StreamController<List<Identity>>.broadcast();

  /// What time it is: moved with the test's clock. A Saturday in December, at noon: the weeks from there have
  /// no day of 23 or 25 hours anywhere, which a day on which the clocks are changed is.
  var now = DateTime(2026, 12, 5, 12);

  /// The app starts the reminders, as it does when it starts.
  void start() => container.read(certRemindersProvider);

  /// The database gives the saved keys: when they are first read, and again
  /// whenever one of them changes.
  Future<void> keys(List<Identity> saved) async {
    _keys.add(saved);
    await settle();
  }

  /// Lets what was set in motion be looked at (the reminders wait a moment, so that a burst of changes is one
  /// look).
  Future<void> settle() => tester.pump(const Duration(milliseconds: 400));

  /// Time passes, an hour at a time at most, as it does for a clock that is looked at once an hour.
  Future<void> pass(Duration time) async {
    var left = time;
    while (left > Duration.zero) {
      final step = left > const Duration(hours: 1) ? const Duration(hours: 1) : left;
      now = now.add(step);
      await tester.pump(step);
      left -= step;
    }
  }

  /// The setting "Security alerts", as the settings set it.
  Future<void> telling(bool on) async {
    await container.read(settingsUpdaterProvider).setNotifySecurityAlerts(on);
    await settle();
  }

  /// The app locks itself, or is unlocked.
  void unlocked(bool open) => container.read(_unlocked.notifier).state = open;

  /// The notices so far, oldest first: how grave, the title, and what is under it. One that was raised again
  /// while it stood, and was counted on it, is there as often as it was raised.
  List<(NotificationSeverity, String, String?)> get notices => [
        for (final n in container.read(notificationCenterProvider).history.reversed)
          for (var i = 0; i < n.repeats; i++) (n.severity, n.title, n.body),
      ];

  List<String> get titles => [for (final n in notices) n.$2];
}

Future<void> withReminders(WidgetTester tester, Future<void> Function(Reminders a) body) async {
  SharedPreferences.setMockInitialValues({});
  final a = Reminders(tester, await SharedPreferences.getInstance());
  try {
    await body(a);
  } finally {
    await tester.pump(const Duration(seconds: 30));
    a.container.dispose();
    await a._keys.close();
    CertReminders.clock = DateTime.now;
  }
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  const year = Duration(days: 365);
  const where = "in the key's editor on a phone, or on a computer's Keys page with Import certificate or "
      'Generate certificate.';
  const ranOutTitle = 'The certificate of prod certificate has run out';
  const soonTitle = 'The certificate of staging certificate runs out soon';

  // As the clock stands at the start: one that ran out the day before yesterday, one with five days to go, a
  // key with no certificate, and one whose certificate has months to go.
  final start = DateTime(2026, 12, 5, 12);
  final gone = key('k1', 'prod certificate', runsOut: start.subtract(const Duration(days: 2)), issuedFor: year);
  final soon = key('k2', 'staging certificate', runsOut: start.add(const Duration(days: 5, hours: 3)), issuedFor: year);
  final plain = key('k3', 'laptop key');
  final far = key('k4', 'build certificate', runsOut: start.add(const Duration(days: 200)), issuedFor: year);

  testWidgets('when the app has started and the saved keys have been read, each certificate that has run out or '
      'runs out soon is told of, once', (tester) => withReminders(tester, (a) async {
    a.start();
    await a.settle();
    expect(a.notices, isEmpty, reason: 'no key has been read yet');

    await a.keys([gone, soon, plain, far]);
    expect(a.notices, [
      (
        NotificationSeverity.error,
        ranOutTitle,
        'Signing in with this key will not work until it has a new certificate. Add one $where',
      ),
      (
        NotificationSeverity.warning,
        soonTitle,
        'Certificate runs out in 5 days. To renew it before then, add a new one $where',
      ),
    ]);

    // A key is saved that has nothing to do with them, and the hours go by.
    await a.keys([gone, soon, plain, far, key('k5', 'new key')]);
    await a.keys([gone, soon, far]);
    await a.pass(const Duration(hours: 5));
    expect(a.titles, [ranOutTitle, soonTitle]);
  }));

  testWidgets('where the keys had been read before the reminders were started, they are told of all the same, and '
      'not from within the start itself', (tester) => withReminders(tester, (a) async {
    a.container.listen(identitiesProvider, (_, _) {});
    await a.keys([gone, soon]);
    a.start();
    expect(a.notices, isEmpty);
    await a.settle();
    expect(a.titles, [ranOutTitle, soonTitle]);
    // Started a second time, as it is at each unlock: nothing more.
    a.start();
    await a.settle();
    expect(a.titles, [ranOutTitle, soonTitle]);
  }));

  testWidgets('a certificate runs out while the app runs: its key is told of when it runs out soon, within the '
      'hour, and once more when it has run out', (tester) => withReminders(tester, (a) async {
    // Fourteen days and ninety minutes to go.
    final runsOut = start.add(const Duration(days: 14, minutes: 90));
    a.start();
    await a.keys([key('k2', 'staging certificate', runsOut: runsOut, issuedFor: year)]);
    expect(a.notices, isEmpty);
    await a.pass(const Duration(hours: 1));
    expect(a.notices, isEmpty, reason: 'fourteen days and half an hour');
    await a.pass(const Duration(hours: 1));
    expect(a.notices, [
      (NotificationSeverity.warning, soonTitle, 'Certificate runs out in 14 days. To renew it before then, add a new one $where'),
    ]);

    // To half an hour before its end, looked at every hour: nothing more.
    await a.pass(const Duration(days: 13, hours: 23));
    expect(a.now, runsOut.subtract(const Duration(minutes: 30)));
    expect(a.titles, [soonTitle]);
    await a.pass(const Duration(hours: 1));
    expect(a.titles, [soonTitle, 'The certificate of staging certificate has run out']);
    expect(a.notices.last.$1, NotificationSeverity.error);

    // And from there no more, for as long as the app runs.
    await a.pass(const Duration(days: 20));
    expect(a.titles, hasLength(2));
  }));

  testWidgets('a certificate that was renewed is told of again when the new one\'s time comes', (tester) =>
      withReminders(tester, (a) async {
    a.start();
    await a.keys([gone, soon]);
    expect(a.titles, [ranOutTitle, soonTitle]);

    // Both are renewed, for thirty days each: in its last quarter, seven days and a half, such a one runs out
    // soon.
    const month = Duration(days: 30);
    final renewed = a.now.add(month);
    await a.keys([
      key('k1', 'prod certificate', runsOut: renewed, issuedFor: month),
      key('k2', 'staging certificate', runsOut: renewed, issuedFor: month),
    ]);
    await a.pass(const Duration(days: 22));
    expect(a.titles, [ranOutTitle, soonTitle], reason: 'eight days to go');
    await a.pass(const Duration(days: 1));
    expect(a.titles, [ranOutTitle, soonTitle, 'The certificate of prod certificate runs out soon', soonTitle]);
    expect(a.notices.last.$3, startsWith('Certificate runs out in 7 days. '));
  }));

  testWidgets('they follow the setting "Security alerts": nothing is told while it is off, and what stands is told '
      'when it is turned on', (tester) => withReminders(tester, (a) async {
    await a.telling(false);
    a.start();
    await a.keys([gone, soon]);
    await a.pass(const Duration(hours: 3));
    expect(a.notices, isEmpty);

    await a.telling(true);
    expect(a.titles, [ranOutTitle, soonTitle]);

    // Off again: a certificate that runs out meanwhile is told of by nothing.
    await a.telling(false);
    await a.pass(const Duration(days: 6));
    expect(a.titles, [ranOutTitle, soonTitle]);
    // And on: the one that has run out since is told of as that.
    await a.telling(true);
    expect(a.titles, [ranOutTitle, soonTitle, 'The certificate of staging certificate has run out']);
  }));

  testWidgets('nothing is looked at while the app is locked', (tester) => withReminders(tester, (a) async {
    final runsOut = start.add(const Duration(days: 14, minutes: 90));
    final waiting = key('k2', 'staging certificate', runsOut: runsOut, issuedFor: year);
    a.start();
    await a.keys([waiting]);
    a.unlocked(false);
    await a.pass(const Duration(hours: 6));
    expect(a.notices, isEmpty);
    // (The keys the app held before it locked: a change of them is no reason to look either.)
    await a.keys([waiting, plain]);
    expect(a.notices, isEmpty);

    // Unlocked, the keys are read again.
    a.unlocked(true);
    await a.keys([waiting, plain]);
    expect(a.titles, [soonTitle]);
  }));

  testWidgets('while recording, the name of the key is masked', (tester) => withReminders(tester, (a) async {
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerNames(['prod certificate', 'staging certificate']);
    addTearDown(() => Redactor.instance
      ..clearNames()
      ..enabled = false);
    a.start();
    await a.keys([gone, soon]);
    expect(a.notices, hasLength(2));
    for (final (_, title, body) in a.notices) {
      expect('$title $body', isNot(contains('prod certificate')));
      expect('$title $body', isNot(contains('staging certificate')));
    }
    expect(a.titles.first, startsWith('The certificate of '));
    expect(a.titles.first, endsWith(' has run out'));
  }));

  testWidgets('an app that is closed at once leaves nothing behind', (tester) => withReminders(tester, (a) async {
    a.container.listen(identitiesProvider, (_, _) {});
    await a.keys([gone]);
    a.start();
    // The keys change at once, which asks for a look in the place of the one that is waiting.
    a._keys.add([gone, soon]);
    await tester.pump();
    a.container.dispose();
    // (The looks that were waiting, and the hourly one, are gone with it: the test would end on any of them.)
    await tester.pump(const Duration(hours: 2));
    expect(tester.takeException(), isNull);
  }));

  test('the app starts them when it starts, and what was there before is gone', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('ref.read(certRemindersProvider);'));
    expect(app, isNot(contains('certExpiryReminderProvider')));
    expect(File('lib/providers/monitor_alert_providers.dart').readAsStringSync(), isNot(contains('certExpir')));
  });

  test('a reminder names its key and says when, in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final when = l.certSaidRunsOutInDays(5);
      final titles = [l.certReminderRanOutTitle('prod'), l.certReminderSoonTitle('prod')];
      expect(titles.toSet(), hasLength(2), reason: '$locale');
      for (final title in titles) {
        expect(title, contains('prod'), reason: '$locale');
      }
      expect(l.certReminderSoonBody(when), startsWith(when), reason: '$locale');
      expect(l.certReminderSoonBody(when).length, greaterThan(when.length + 20), reason: '$locale');
      expect(l.certReminderRanOutBody.length, greaterThan(30), reason: '$locale');
      // Where it is renewed is named as the keys page names it.
      for (final body in [l.certReminderRanOutBody, l.certReminderSoonBody(when)]) {
        expect(body, contains(l.zestKeysImportCertificate), reason: '$locale');
        expect(body, contains(l.zestKeysGenerateCertificate), reason: '$locale');
      }
      if (locale.languageCode == 'en') continue;
      expect(titles, isNot(contains(en.certReminderRanOutTitle('prod'))), reason: '$locale');
      expect(titles, isNot(contains(en.certReminderSoonTitle('prod'))), reason: '$locale');
      expect(l.certReminderRanOutBody, isNot(en.certReminderRanOutBody), reason: '$locale');
      expect(l.certReminderSoonBody('x'), isNot(en.certReminderSoonBody('x')), reason: '$locale');
    }
  });

  test('the setting says that it is for them as well, in every language and in the search of the settings', () {
    expect(en.notifPrefsSecurityAlertsDesc,
        "When a server's host key changes, or the certificate of one of your keys is about to run out");
    // (The search of the settings on a computer finds a setting by the setting's own words.)
    expect(File('lib/ui/screens/desktop/widgets/settings_inline_view.dart').readAsStringSync(),
        contains('(l) => l.notifPrefsSecurityAlerts, (l) => l.notifPrefsSecurityAlertsDesc'));
    final others = <String>{};
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final said = lookupAppLocalizations(locale).notifPrefsSecurityAlertsDesc;
      expect(said, isNot(en.notifPrefsSecurityAlertsDesc), reason: '$locale');
      expect(said.length, greaterThan(15), reason: '$locale');
      others.add(said);
    }
    expect(others, hasLength(AppLocalizations.supportedLocales.length - 1));
  });
}
