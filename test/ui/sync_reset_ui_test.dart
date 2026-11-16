import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/account/sync_reset_flow.dart';
import 'package:zestssh/ui/screens/sync/sync_reset_ui.dart';

/// What the person sees of resetting cloud sync (3.0): the question with
/// what goes and what stays, the typed email, the progress line, how it
/// ended, and what a device says that finds the cloud copy gone.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// A screen with a button that runs [onPressed], and the container the
  /// notices go to. Returns what [onPressed] gave back, in a list (empty
  /// until it has).
  Future<(ProviderContainer, List<T>)> press<T>(
    WidgetTester tester,
    Future<T> Function(BuildContext context, WidgetRef ref) onPressed, {
    Locale locale = const Locale('en'),
    bool recording = false,
  }) async {
    final container = ProviderContainer(overrides: [recordingModeProvider.overrideWith((ref) => recording)]);
    addTearDown(container.dispose);
    final came = <T>[];
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: TextButton(
                onPressed: () async => came.add(await onPressed(context, ref)),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return (container, came);
  }

  group('the question', () {
    testWidgets('says what goes and what stays, and waits for the answer', (tester) async {
      final (_, came) = await press(tester, (context, ref) => askToResetCloudSync(context, keysElsewhere: false));
      expect(came, isEmpty);
      expect(find.text(l10n.syncResetAskTitle), findsOneWidget);
      expect(find.text(l10n.syncResetAskBody), findsOneWidget);
      expect(find.text(l10n.syncResetAskStays), findsOneWidget, reason: 'the data on the devices stays');
      expect(find.text(l10n.syncResetAskOff), findsOneWidget, reason: 'sync turns off until it is set up again');
      expect(find.text(l10n.syncResetAskKept), findsOneWidget, reason: 'the copy is set aside, not destroyed at once');
      expect(find.text(l10n.syncResetAskTeamKeys), findsNothing, reason: 'this device holds the keys for teams');

      await tester.tap(find.text(l10n.profileContinue));
      await tester.pumpAndSettle();
      expect(came, [true]);
    });

    testWidgets('on a device without the keys for teams it says what that means', (tester) async {
      await press(tester, (context, ref) => askToResetCloudSync(context, keysElsewhere: true));
      expect(find.text(l10n.syncResetAskTeamKeys), findsOneWidget);
    });

    testWidgets('Cancel, and its X, are a no', (tester) async {
      final (_, came) = await press(tester, (context, ref) => askToResetCloudSync(context, keysElsewhere: false));
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(came, [false]);

      final (_, again) = await press(tester, (context, ref) => askToResetCloudSync(context, keysElsewhere: false));
      Navigator.of(tester.element(find.text(l10n.syncResetAskTitle))).pop();
      await tester.pumpAndSettle();
      expect(again, [false]);
    });
  });

  group('the typed email', () {
    testWidgets('another address is refused where it is typed; the account\'s own, in any case, is a yes',
        (tester) async {
      final (_, came) =
          await press(tester, (context, ref) => confirmSyncResetByEmail(context, ref, 'You@Example.com'));
      expect(find.text(l10n.syncResetConfirmSubtitle('You@Example.com')), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'someone@example.com');
      await tester.tap(find.text(l10n.syncResetRowAction));
      await tester.pumpAndSettle();
      expect(find.text(l10n.accountDeleteEmailMismatch), findsOneWidget);
      expect(came, isEmpty, reason: 'still asking');

      await tester.enterText(find.byType(TextField), '  you@example.COM ');
      await tester.tap(find.text(l10n.syncResetRowAction));
      await tester.pumpAndSettle();
      expect(came, [true]);
    });

    testWidgets('backing out is a no', (tester) async {
      final (_, came) = await press(tester, (context, ref) => confirmSyncResetByEmail(context, ref, 'you@example.com'));
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(came, [false]);
    });

    testWidgets('while the screen is being recorded the address is not shown: recording is turned off first, or not',
        (tester) async {
      final (_, came) = await press(
        tester,
        (context, ref) => confirmSyncResetByEmail(context, ref, 'you@example.com'),
        recording: true,
      );
      expect(find.text(l10n.recModeRevealTitle), findsOneWidget);
      expect(find.text(l10n.syncResetConfirmSubtitle('you@example.com')), findsNothing);
      expect(find.byType(TextField), findsNothing);
      // Closed without turning recording off: nothing was shown, and it is a no.
      Navigator.of(tester.element(find.text(l10n.recModeRevealTitle))).pop();
      await tester.pumpAndSettle();
      expect(came, [false]);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('an account without an email has answered the question already: it is not asked again',
        (tester) async {
      for (final email in [null, '']) {
        final (_, came) = await press(tester, (context, ref) => confirmSyncResetByEmail(context, ref, email));
        expect(came, [true]);
        expect(find.byType(TextField), findsNothing);
      }
    });
  });

  test('the progress line says each step, and where the sign-in happens', () {
    String line(SyncResetStage stage, {bool inBrowser = false}) =>
        syncResetStageText(l10n, stage, inBrowser: inBrowser);
    expect(line(SyncResetStage.signingIn), l10n.accountDeleteStepSignIn);
    expect(line(SyncResetStage.signingIn, inBrowser: true), l10n.accountDeleteStepSignInBrowser);
    expect(line(SyncResetStage.stoppingSync), l10n.accountDeleteStepStoppingSync);
    expect(line(SyncResetStage.resetting), l10n.syncResetStepResetting);
    expect(line(SyncResetStage.turningOffHere), l10n.syncResetStepTurningOff);
    expect({for (final stage in SyncResetStage.values) line(stage)}, hasLength(SyncResetStage.values.length));
  });

  test('why nothing was reset is said for what it was', () {
    expect(syncResetFailureText(l10n, 'sign-in-failed'), l10n.syncResetFailedSignIn);
    expect(syncResetFailureText(l10n, 'recent-sign-in-required'), l10n.syncResetFailedSignIn);
    expect(syncResetFailureText(l10n, 'account-mismatch'), l10n.syncResetWrongAccount);
    expect(syncResetFailureText(l10n, 'server-outdated'), l10n.syncResetFailedOutdated);
    expect(syncResetFailureText(l10n, 'network'), l10n.syncResetFailedNetwork);
    expect(syncResetFailureText(l10n, 'server-error'), l10n.syncResetFailedServer);
    expect(syncResetFailureText(l10n, 'something-new'), l10n.syncResetFailedServer);
    for (final said in [
      l10n.syncResetFailedSignIn,
      l10n.syncResetWrongAccount,
      l10n.syncResetFailedOutdated,
      l10n.syncResetFailedNetwork,
      l10n.syncResetFailedServer,
    ]) {
      expect(said, contains('othing was changed'), reason: 'each says that nothing was changed');
    }
  });

  test('where ZestSSH Cloud or the way to it stopped the reset, how it stands is said, after "Nothing was changed."',
      () {
    const refused = SocketException('Connection refused');
    expect(syncResetFailureText(l10n, 'network', cause: refused),
        '${l10n.syncResetNothingChanged} ${l10n.cloudNotResponding} (ZS-1101)');
    expect(syncResetFailureText(l10n, 'server-error', cause: 'HTTP 503: unavailable'),
        '${l10n.syncResetNothingChanged} ${l10n.cloudFault(503)} (ZS-1103)');
    // A code this app does not know, on an answer that is a fault of the
    // service: said as the fault.
    expect(syncResetFailureText(l10n, 'something-new', cause: 'HTTP 502: bad gateway'),
        '${l10n.syncResetNothingChanged} ${l10n.cloudFault(502)} (ZS-1103)');
    // An answer that is no fault of the service, or something that was no
    // failure to get an answer: the sentences there were.
    expect(syncResetFailureText(l10n, 'server-error', cause: 'HTTP 400: bad request'), l10n.syncResetFailedServer);
    expect(syncResetFailureText(l10n, 'network', cause: 'something else'), l10n.syncResetFailedNetwork);
    expect(syncResetFailureText(l10n, 'network', cause: const FormatException('not an address')),
        l10n.syncResetFailedNetwork);
    // What the server said in so many words is what is said, whatever came
    // with it.
    expect(syncResetFailureText(l10n, 'recent-sign-in-required', cause: 'HTTP 503: x'), l10n.syncResetFailedSignIn);
    expect(syncResetFailureText(l10n, 'sign-in-failed', cause: refused), l10n.syncResetFailedSignIn);
    expect(syncResetFailureText(l10n, 'account-mismatch', cause: refused), l10n.syncResetWrongAccount);
    expect(syncResetFailureText(l10n, 'server-outdated', cause: refused), l10n.syncResetFailedOutdated);
  });

  group('how it ended', () {
    AppNotification notice(ProviderContainer c) => c.read(notificationCenterProvider).history.single;
    String said(AppNotification n) => [n.title, if (n.body != null) n.body].join(' ');

    testWidgets('backed out: nothing was changed, said in passing', (tester) async {
      final (c, came) = await press(tester, (context, ref) => showSyncResetOutcome(context, const SyncResetCancelled()));
      expect(came, [false]);
      expect(said(notice(c)), l10n.syncResetNothingChanged);
      expect(notice(c).severity, isNot(NotificationSeverity.error));
      // (It closes by itself: let it.)
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('signed in to another account: said as the mistake it is', (tester) async {
      final (c, came) =
          await press(tester, (context, ref) => showSyncResetOutcome(context, const SyncResetWrongAccount()));
      expect(came, [false]);
      expect(said(notice(c)), l10n.syncResetWrongAccount);
      expect(notice(c).severity, NotificationSeverity.error);
    });

    testWidgets('refused: why, with what the server answered to copy', (tester) async {
      final (c, came) = await press(
        tester,
        (context, ref) => showSyncResetOutcome(
            context, const SyncResetFailed(code: 'network', detail: 'SocketException: Connection refused')),
      );
      expect(came, [false]);
      expect(said(notice(c)), l10n.syncResetFailedNetwork);
      expect(notice(c).severity, NotificationSeverity.error);
      expect(notice(c).details, contains('SocketException: Connection refused'));
      expect(find.text(l10n.syncResetDoneTitle), findsNothing);
    });

    testWidgets('refused because the service gave no answer: that is what is said, with its code', (tester) async {
      final (c, came) = await press(
        tester,
        (context, ref) => showSyncResetOutcome(
            context,
            const SyncResetFailed(
              code: 'network',
              detail: 'SocketException: Connection refused',
              cause: SocketException('Connection refused'),
            )),
      );
      expect(came, [false]);
      expect(said(notice(c)), '${l10n.syncResetNothingChanged} ${l10n.cloudNotResponding} (ZS-1101)');
      expect(notice(c).severity, NotificationSeverity.error);
      expect(notice(c).details, contains('SocketException: Connection refused'));
    });

    testWidgets('reset: what happened, until when the copy is kept, what to do next, and setting up at once',
        (tester) async {
      final now = DateTime(2026, 10, 8, 15, 30);
      final (c, came) = await press(
        tester,
        (context, ref) =>
            showSyncResetOutcome(context, const SyncResetDone(hadData: true, keptDays: 30), now: now),
      );
      expect(came, isEmpty, reason: 'waiting for the answer');
      expect(find.text(l10n.syncResetDoneTitle), findsOneWidget);
      expect(find.text(l10n.syncResetDoneBody), findsOneWidget);
      final until = DateFormat.yMMMd('en').format(DateTime(2026, 11, 7, 15, 30));
      expect(until, 'Nov 7, 2026');
      expect(find.text(l10n.syncResetDoneKept(until)), findsOneWidget, reason: 'thirty days on, as a date');
      expect(find.text(l10n.syncResetDoneNext), findsOneWidget);
      expect(c.read(notificationCenterProvider).history, isEmpty, reason: 'said once, in the dialog');

      await tester.tap(find.text(l10n.accountSyncSetUp));
      await tester.pumpAndSettle();
      expect(came, [true], reason: 'set up again now');
    });

    testWidgets('reset, and not now: sync is set up again later', (tester) async {
      final (_, came) = await press(
        tester,
        (context, ref) => showSyncResetOutcome(context, const SyncResetDone(hadData: true, keptDays: 30)),
      );
      await tester.tap(find.text(l10n.notNow));
      await tester.pumpAndSettle();
      expect(came, [false]);
    });

    testWidgets('nothing was there to reset: said so, with no date of a copy that does not exist', (tester) async {
      await press(
        tester,
        (context, ref) => showSyncResetOutcome(context, const SyncResetDone(hadData: false, keptDays: 30)),
      );
      expect(find.text(l10n.syncResetDoneNothing), findsOneWidget);
      expect(find.text(l10n.syncResetDoneBody), findsNothing);
      expect(find.textContaining('kept until'), findsNothing);
      expect(find.text(l10n.syncResetDoneNext), findsOneWidget);
    });

    testWidgets('a server that does not say for how long it keeps the copy: no date is made up', (tester) async {
      await press(
        tester,
        (context, ref) => showSyncResetOutcome(context, const SyncResetDone(hadData: true, keptDays: 0)),
      );
      expect(find.text(l10n.syncResetDoneBody), findsOneWidget);
      expect(find.textContaining('kept until'), findsNothing);
    });

    testWidgets('the date is written the way the app\'s language writes dates', (tester) async {
      final de = lookupAppLocalizations(const Locale('de'));
      await press(
        tester,
        // (Midday: thirty days on is the same day whatever the clocks did in between.)
        (context, ref) => showSyncResetOutcome(context, const SyncResetDone(hadData: true, keptDays: 30),
            now: DateTime(2026, 10, 8, 12)),
        locale: const Locale('de'),
      );
      expect(find.text(de.syncResetDoneTitle), findsOneWidget);
      expect(find.text(de.syncResetDoneKept(DateFormat.yMMMd('de').format(DateTime(2026, 11, 7)))), findsOneWidget);
      expect(DateFormat.yMMMd('de').format(DateTime(2026, 11, 7)), isNot('Nov 7, 2026'));
    });
  });

  group('a device that finds the cloud copy gone', () {
    testWidgets('says what happened and what stays, and asks before it sets sync up again', (tester) async {
      final (_, came) = await press(tester, (context, ref) => askToSetUpSyncAgain(context));
      expect(came, isEmpty);
      expect(find.text(l10n.syncGoneTitle), findsOneWidget);
      expect(find.text(l10n.syncGoneBody), findsOneWidget);
      expect(find.text(l10n.syncGoneHere), findsOneWidget);
      expect(find.text(l10n.syncGoneOthers), findsOneWidget);
      await tester.tap(find.text(l10n.syncSetUpAgain));
      await tester.pumpAndSettle();
      expect(came, [true]);
    });

    testWidgets('not now leaves everything as it is', (tester) async {
      final (_, came) = await press(tester, (context, ref) => askToSetUpSyncAgain(context));
      await tester.tap(find.text(l10n.notNow));
      await tester.pumpAndSettle();
      expect(came, [false]);
    });
  });

  test('every language says all of it, in its own words', () {
    final texts = <String Function(AppLocalizations)>[
      (x) => x.syncResetTitle,
      (x) => x.syncResetRowDesc,
      (x) => x.syncResetRowAction,
      (x) => x.syncResetAskTitle,
      (x) => x.syncResetAskBody,
      (x) => x.syncResetAskStays,
      (x) => x.syncResetAskOff,
      (x) => x.syncResetAskKept,
      (x) => x.syncResetAskTeamKeys,
      (x) => x.syncResetConfirmSubtitle('you@example.com'),
      (x) => x.syncResetStepResetting,
      (x) => x.syncResetStepTurningOff,
      (x) => x.syncResetNothingChanged,
      (x) => x.syncResetWrongAccount,
      (x) => x.syncResetFailedSignIn,
      (x) => x.syncResetFailedOutdated,
      (x) => x.syncResetFailedNetwork,
      (x) => x.syncResetFailedServer,
      (x) => x.syncResetDoneTitle,
      (x) => x.syncResetDoneBody,
      (x) => x.syncResetDoneNothing,
      (x) => x.syncResetDoneKept('2026-11-07'),
      (x) => x.syncResetDoneNext,
      (x) => x.syncGoneTitle,
      (x) => x.syncGoneBody,
      (x) => x.syncGoneHere,
      (x) => x.syncGoneOthers,
      (x) => x.syncSetUpAgain,
      (x) => x.syncWasReset,
    ];
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final (i, say) in texts.indexed) {
        expect(say(l).trim(), isNotEmpty, reason: '$locale, text $i');
        if (locale.languageCode != 'en') expect(say(l), isNot(say(l10n)), reason: '$locale, text $i');
      }
      expect(l.syncResetConfirmSubtitle('you@example.com'), contains('you@example.com'), reason: '$locale');
      expect(l.syncResetDoneKept('2026-11-07'), contains('2026-11-07'), reason: '$locale');
    }
  });

  // Found in a security review.
  test('deleting the account while a team it alone owns can still be brought back names the team and its day, in every language',
      () async {
    final until = DateTime(2026, 11, 12, 16);
    expect(accountDeleteTeamBeingDeletedText(l10n, 'Acme', until), l10n.accountDeleteTeamBeingDeleted('Acme', 'Nov 12, 2026'));
    expect(accountDeleteTeamBeingDeletedText(l10n, 'Acme', null), l10n.accountDeleteTeamBeingDeletedNoDate('Acme'));
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      await initializeDateFormatting(l.localeName);
      final day = DateFormat.yMMMd(l.localeName).format(until);
      expect(accountDeleteTeamBeingDeletedText(l, 'Acme', until), allOf(contains('Acme'), contains(day)), reason: '$locale');
      expect(accountDeleteTeamBeingDeletedText(l, 'Acme', null), contains('Acme'), reason: '$locale');
      expect(l.orchardErrorRestoreNoOwner.trim(), isNotEmpty, reason: '$locale');
    }
  });

  test('deleting the account while a reset copy is kept says from which day it can be deleted, in every language', () async {
    final until = DateTime(2026, 11, 19, 12);
    expect(accountDeleteResetKeptText(l10n, until), l10n.accountDeleteResetKept(DateFormat.yMMMd('en').format(until)));
    expect(accountDeleteResetKeptText(l10n, until), contains('Nov 19, 2026'));
    expect(accountDeleteResetKeptText(l10n, null), l10n.accountDeleteResetKeptNoDate);
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      await initializeDateFormatting(l.localeName);
      final day = DateFormat.yMMMd(l.localeName).format(until);
      expect(accountDeleteResetKeptText(l, until), contains(day), reason: '$locale');
      expect(l.accountDeleteResetKeptNoDate, contains('30'), reason: '$locale');
    }
  });
}
