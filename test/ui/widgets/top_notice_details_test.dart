import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/needs_you.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/notification_permission_provider.dart';
import 'package:zestssh/features/notifications/widgets/notification_bell.dart';
import 'package:zestssh/features/notifications/widgets/notification_toast_overlay.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/notifications/notifications_screen.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

import '../../visual/shots_util.dart';

/// What stands behind an error is there to be copied: beside the message at
/// the top, in the bell's history, and under an error wherever the button
/// is put. What is copied is the report of the failure, in English, with
/// every name and secret taken out. Names and addresses here are made up.
void main() {
  final copied = <String>[];

  setUp(() {
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      },
    );
    AppLogger.forget();
    ReportScrub.clearFolders();
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..enabled = false;
    ErrorReport.app = 'ZestSSH 3.0.0 (build 256)';
    ErrorReport.system = () => 'windows 11';
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    debugTopSnackBarOnPhone = null;
    Redactor.instance.clearNames();
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  Future<BuildContext> app(WidgetTester tester, {Locale locale = const Locale('en'), bool toasts = false}) async {
    late BuildContext inner;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            inner = context;
            const page = Center(child: Text('page'));
            return toasts ? const NotificationToastOverlay(child: page) : page;
          }),
        ),
      ),
    ));
    await tester.pump();
    return inner;
  }

  List<AppNotification> shown(BuildContext context) =>
      ProviderScope.containerOf(context).read(notificationCenterProvider).history;

  group('The button', () {
    testWidgets('says "Copy details" in the app\'s language, copies what it was given, and says it did',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: CopyDetailsButton(detail: 'what happened')),
      ));
      await tester.pump();
      expect(find.text('Details kopieren'), findsOneWidget);
      await tester.tap(find.byType(CopyDetailsButton));
      await tester.pump();
      expect(copied, ['what happened']);
      expect(find.text('Kopiert'), findsOneWidget);
      expect(find.text('Details kopieren'), findsNothing);
      // After a moment it offers itself again.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Details kopieren'), findsOneWidget);
    });

    testWidgets('a label of the caller\'s own stands, and where the app has no words yet it says it in English',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            CopyDetailsButton(detail: 'a'),
            CopyDetailsButton(detail: 'b', label: 'Copy the plan'),
          ]),
        ),
      ));
      expect(find.text('Copy details'), findsOneWidget);
      expect(find.text('Copy the plan'), findsOneWidget);
      await tester.tap(find.text('Copy the plan'));
      await tester.pump();
      expect(copied, ['b']);
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('A message at the top, on a computer', () {
    testWidgets('with details: they are a report of the failure, scrubbed, and no action is made up for them',
        (tester) async {
      Redactor.instance.registerNames(['web-01']);
      AppLogger.remember(_line('Connecting to web-01'));
      final context = await app(tester);
      showTopSnackBar(context, 'Could not connect to web-01.',
          isError: true, details: 'SocketException: Connection refused, address = 10.50.0.11, port = 22');
      final n = shown(context).single;
      expect(n.severity, NotificationSeverity.error);
      expect(n.actionLabel, isNull);
      expect(n.onAction, isNull);
      final report = n.details!;
      expect(report, startsWith('ZestSSH error details\nWhat: Could not connect to '));
      expect(report, contains('Details:\n  SocketException: Connection refused, address = 192.0.2.'));
      expect(report, contains('App: ZestSSH 3.0.0 (build 256)'));
      expect(report, contains('INFO: Connecting to '));
      expect(report, endsWith(ErrorReport.kNotice));
      for (final leak in ['web-01', '10.50.0.11']) {
        expect(report, isNot(contains(leak)), reason: leak);
      }
      // (What is on screen is the message as it was written.)
      expect(n.title, 'Could not connect to web-01.');
    });

    testWidgets('an action of the caller\'s own stands beside the details, and neither takes the other\'s place',
        (tester) async {
      final context = await app(tester);
      var retried = 0;
      showTopSnackBar(context, 'Sync did not finish.',
          isError: true, actionLabel: 'Try again', onAction: () => retried++, details: 'HTTP 503');
      final n = shown(context).single;
      expect(n.actionLabel, 'Try again');
      expect(n.details, contains('Details:\n  HTTP 503'));
      n.onAction!();
      expect(retried, 1);
    });

    testWidgets('a message that is no error has nothing to copy; every error has its report, details or not '
        '(found in a review)', (tester) async {
      final context = await app(tester);
      showTopSnackBar(context, 'Saved', isSuccess: true);
      showTopSnackBar(context, 'Failed', isError: true, details: '  \n ');
      showTopSnackBar(context, 'Failed too', isError: true);
      final details = {for (final n in shown(context)) n.title: n.details};
      expect(details['Saved'], isNull);
      expect(details['Failed'], allOf(contains('ZestSSH error details'), contains('What: Failed')));
      expect(details['Failed too'], allOf(contains('ZestSSH error details'), contains('What: Failed too')));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the toast offers the details to copy, and stays when they are', (tester) async {
      final context = await app(tester, toasts: true);
      showTopSnackBar(context, 'Sync did not finish.', isError: true, details: 'HTTP 503');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final button = find.byKey(const ValueKey('toast-copy-details'));
      expect(button, findsOneWidget);
      expect(find.descendant(of: button, matching: find.text('Copy details')), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(copied.single, shown(context).single.details);
      expect(copied.single, contains('What: Sync did not finish.'));
      expect(find.text('Sync did not finish.'), findsOneWidget, reason: 'an error stays until it is closed');
      expect(find.descendant(of: button, matching: find.text('Copied')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      // A message without details has no such button.
      showTopSnackBar(context, 'Rules saved', isSuccess: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('toast-copy-details')), findsOneWidget, reason: 'only the first one\'s');
      await tester.pump(const Duration(seconds: 5));
    });

    test('what is kept with the history of a phone holds no details: nothing of the log goes to disk', () {
      final n = AppNotification(id: 'n-1', title: 'Failed', severity: NotificationSeverity.error, details: 'a report');
      expect(n.toJson().values, isNot(contains('a report')));
      expect(n.toJson().containsKey('details'), isFalse);
      expect(AppNotification.fromJson(n.toJson()).details, isNull);
      // While the app runs, a changed entry keeps them.
      expect(n.copyWith(isRead: true).details, 'a report');
    });
  });

  // A notice that says more than a toast should hold (the offline closing
  // notice: a paragraph cut at "This devi…" with Show more, found in a design
  // review): the toast says its summary, a line each, and the bell
  // keeps the whole.
  group('A notice with a summary', () {
    testWidgets('the toast shows its lines, not its paragraph, which history keeps', (tester) async {
      final context = await app(tester, toasts: true);
      final body = List.filled(12, 'One more sentence of a long paragraph.').join(' ');
      const lines = ['Production: 7:30 PM · +2', 'Connecting to the internet before then keeps everything open.'];
      ProviderScope.containerOf(context).read(notificationCenterProvider.notifier).show(AppNotification(
            id: 'closing',
            title: 'Platform team: closing on this device soon',
            body: body,
            summary: lines,
            severity: NotificationSeverity.warning,
            dismissAfter: Duration.zero,
          ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final summary = find.byKey(const ValueKey('toast-summary'));
      for (final line in lines) {
        expect(find.descendant(of: summary, matching: find.text(line)), findsOneWidget, reason: line);
      }
      expect(find.text(body), findsNothing, reason: 'the paragraph is the bell\'s');
      expect(find.byKey(const ValueKey('toast-show-more')), findsNothing);
      expect(shown(context).single.body, body);
      expect(shown(context).single.summary, lines);
    });
  });

  group('A message at the top, on a phone', () {
    setUp(() => debugTopSnackBarOnPhone = true);

    testWidgets('with details: "Copy details" stands beside it, in the app\'s language, and copies the report',
        (tester) async {
      final context = await app(tester, locale: const Locale('fr'));
      showTopSnackBar(context, 'Sync did not finish.', isError: true, details: 'HTTP 503 from 10.50.0.11');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Sync did not finish.'), findsOneWidget);
      final button = find.byKey(const ValueKey('toast-copy-details'));
      expect(find.descendant(of: button, matching: find.text('Copier les détails')), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(copied.single, startsWith('ZestSSH error details\nWhat: Sync did not finish.'));
      expect(copied.single, contains('  HTTP 503 from 192.0.2.'));
      expect(copied.single, isNot(contains('10.50.0.11')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Sync did not finish.'), findsNothing, reason: 'it leaves once its button was tapped');
    });

    testWidgets('an action of the caller\'s own and the details both have their button', (tester) async {
      final context = await app(tester);
      var retried = 0;
      showTopSnackBar(context, 'Sync did not finish.',
          isError: true, actionLabel: 'Try again', onAction: () => retried++, details: 'HTTP 503');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Copy details'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retried, 1);
      expect(copied, isEmpty);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('an action of the caller\'s own alone stands beside it, and keeps it there as long as details would',
        (tester) async {
      final context = await app(tester);
      var retried = 0;
      showTopSnackBar(context, 'Sync did not finish.', isWarning: true, actionLabel: 'Try again', onAction: () => retried++);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('toast-copy-details')), findsNothing);
      await tester.pump(const Duration(seconds: 8));
      // (One that left at its time takes a moment to slide away.)
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Sync did not finish.'), findsOneWidget, reason: 'something to tap: it stays ten seconds');
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retried, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Sync did not finish.'), findsNothing);
    });

    testWidgets('an error stays long enough to be read, and longer where there is something to tap',
        (tester) async {
      final context = await app(tester);
      Future<bool> stillThereAfter(Duration time, String message) async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(time - const Duration(milliseconds: 300));
        // (One that left at its time takes a moment to slide away.)
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        final there = find.text(message).evaluate().isNotEmpty;
        // (Let it finish leaving, or stay out its time.)
        await tester.pump(const Duration(seconds: 12));
        await tester.pump(const Duration(seconds: 1));
        return there;
      }

      showTopSnackBar(context, 'Saved', isSuccess: true);
      expect(await stillThereAfter(const Duration(seconds: 4), 'Saved'), isFalse);
      // Every error has Copy details now: something to tap, ten seconds.
      showTopSnackBar(context, 'It failed', isError: true);
      expect(await stillThereAfter(const Duration(seconds: 8), 'It failed'), isTrue);
      showTopSnackBar(context, 'It failed', isError: true);
      expect(await stillThereAfter(const Duration(seconds: 11), 'It failed'), isFalse);
      showTopSnackBar(context, 'It failed again', isError: true, details: 'why');
      expect(await stillThereAfter(const Duration(seconds: 8), 'It failed again'), isTrue);
      showTopSnackBar(context, 'It failed again', isError: true, details: 'why');
      expect(await stillThereAfter(const Duration(seconds: 11), 'It failed again'), isFalse);
      // A time the caller set is the time it stays.
      showTopSnackBar(context, 'Briefly', isError: true, duration: const Duration(seconds: 1));
      expect(await stillThereAfter(const Duration(seconds: 2), 'Briefly'), isFalse);
    });
  });

  group('The history of notifications', () {
    testWidgets('the bell\'s list offers what stands behind an error to copy, and only where there is some',
        (tester) async {
      // Its header is as wide as the list: measured in the app's own font
      // (the test font draws every letter as a square).
      await tester.runAsync(loadShotFonts);
      late BuildContext inner;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(builder: (context) {
              inner = context;
              return const Align(alignment: Alignment.topRight, child: NotificationBell());
            }),
          ),
        ),
      ));
      await tester.pump();
      showTopSnackBar(inner, 'Sync did not finish.', isError: true, details: 'HTTP 503');
      showTopSnackBar(inner, 'Rules saved', isSuccess: true);
      await tester.pump();
      await tester.tap(find.byType(NotificationBell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Rules saved'), findsOneWidget);
      expect(find.byType(CopyDetailsButton), findsOneWidget);
      await tester.tap(find.byType(CopyDetailsButton));
      await tester.pump();
      final withDetails = shown(inner).where((n) => n.details != null).single;
      expect(copied, [withDetails.details]);
      expect(copied.single, contains('What: Sync did not finish.'));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('so does the page of notifications on a phone', (tester) async {
      late BuildContext inner;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
          notificationsEnabledProvider.overrideWith((ref) async => true),
          // (The history is what is looked at here; what needs the person
          // now is needs_you_test's.)
          needsYouProvider.overrideWith((ref) => const []),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(builder: (context) {
            inner = context;
            return const NotificationsScreen();
          }),
        ),
      ));
      await tester.pump();
      showTopSnackBar(inner, 'Sync did not finish.', isError: true, details: 'HTTP 503');
      showTopSnackBar(inner, 'Rules saved', isSuccess: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Rules saved'), findsOneWidget);
      expect(find.byType(CopyDetailsButton), findsOneWidget);
      await tester.tap(find.byType(CopyDetailsButton));
      await tester.pump();
      expect(copied.single, contains('What: Sync did not finish.'));
      await tester.pump(const Duration(seconds: 3));
    });
  });

  test('how long a message stays when nobody says', () {
    expect(toastDurationFor(isError: false, tappable: false), const Duration(seconds: 3));
    // Something to press: ten seconds to find it (the 4.0 accessibility
    // pass; it was three).
    expect(toastDurationFor(isError: false, tappable: true), const Duration(seconds: 10));
    expect(toastDurationFor(isError: true, tappable: false), const Duration(seconds: 6));
    expect(toastDurationFor(isError: true, tappable: true), const Duration(seconds: 10));
    expect(kToastDuration, const Duration(seconds: 3));
  });
}

LogRecord _line(String message) => LogRecord(Level.INFO, message, 'ZestSSH');
