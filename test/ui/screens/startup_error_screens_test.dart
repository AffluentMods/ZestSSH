import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/linux_keyring.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/profiles/profile_move.dart' show ProfileMoveFailed;
import 'package:zestssh/ui/screens/error/database_error_screen.dart';
import 'package:zestssh/ui/screens/error/migration_error_screen.dart';
import 'package:zestssh/ui/screens/error/startup_error_screen.dart';
import 'package:zestssh/ui/widgets/broken_widget_notice.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';
import 'package:zestssh/database/database.dart' show DatabaseNewerThanApp;

/// The screens that stand alone when the app cannot start, cannot open its
/// database or could not update it (3.0). What stands behind the
/// failure is the report of it, scrubbed (the raw error named the database's
/// path, the account's folder in it), to read, copy and send to support.
/// Names and paths here are made up.
void main() {
  final copied = <String>[];
  final opened = <Uri>[];
  final revealed = <String>[];
  var mailOpens = true;

  Future<bool> launch(Uri uri) async {
    opened.add(uri);
    return mailOpens;
  }

  Future<void> reveal(String path) async => revealed.add(path);

  setUp(() {
    copied.clear();
    opened.clear();
    revealed.clear();
    mailOpens = true;
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
    ReportScrub.clearFolders();
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  // On a kiosk, a locked login keyring on Linux showed
  // "ZestSSH could not start" behind GNOME's own box asking for its password.
  group('a Linux keyring', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    // What the plugin's read answers with whatever is wrong (Secret.hpp: a read
    // warms the keyring up first, and any failure of that throws this): its
    // words cannot tell a locked keyring from none at all.
    final readFailed = PlatformException(code: 'Libsecret error', message: 'Failed to unlock the keyring');

    Future<KeyringState> Function() answers(KeyringState state) => () async => state;

    test('what stopped it is told by asking the system: locked, nothing there, or not said at all', () async {
      expect(await keyringProblemOf(readFailed, state: answers(KeyringState.locked)), KeyringProblem.locked);
      expect(await keyringProblemOf(readFailed, state: answers(KeyringState.absent)), KeyringProblem.missing,
          reason: 'a computer with no Secret Service was told its keyring is locked');
      expect(await keyringProblemOf(readFailed, state: answers(KeyringState.unlocked)), isNull,
          reason: 'open, and the store fails: the real error, not a claim that it is locked');
      expect(await keyringProblemOf(readFailed, state: answers(KeyringState.unknown)), isNull);
    });

    test('anything else is no keyring failure, and the system is not asked', () async {
      var asked = 0;
      Future<KeyringState> ask() async {
        asked++;
        return KeyringState.locked;
      }

      expect(await keyringProblemOf(PlatformException(code: 'other', message: 'Failed to unlock the keyring'), state: ask), isNull);
      expect(await keyringProblemOf(StateError('Libsecret error'), state: ask), isNull);
      expect(asked, 0);
    });

    test("gdbus's answer is read: the Locked property, and why there was none", () {
      expect(keyringStateFromGdbus(0, '(<false>,)\n', ''), KeyringState.unlocked);
      expect(keyringStateFromGdbus(0, '(<true>,)\n', ''), KeyringState.locked);
      expect(keyringStateFromGdbus(0, '', ''), KeyringState.unknown);
      expect(
        keyringStateFromGdbus(1, '', 'Error: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name org.freedesktop.secrets was not provided by any .service files\n'),
        KeyringState.absent,
      );
      expect(keyringStateFromGdbus(1, '', 'Error connecting: Cannot autolaunch D-Bus without X11 \$DISPLAY\n'), KeyringState.absent);
      expect(keyringStateFromGdbus(1, '', 'Error: Timeout was reached\n'), KeyringState.unknown);
    });

    group('the start of the app', () {
      setUp(() {
        PackageInfo.setMockInitialValues(
            appName: 'ZestSSH', packageName: 'zestssh', version: '3.3.0', buildNumber: '340', buildSignature: '');
      });

      testWidgets('the screen goes by what the system says, and the real error is behind Copy details', (tester) async {
        final app = await tester.runAsync(() => startupErrorAppFor(readFailed, StackTrace.empty,
            onRetry: () {}, state: answers(KeyringState.unlocked)));
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app!);
        await tester.pump();
        expect(find.text(l10n.startupErrorTitle), findsOneWidget);
        expect(find.text(l10n.keyringLockedTitle), findsNothing);
        expect(app.report, contains('Failed to unlock the keyring'));
        expect(app.keyring, isNull);

        final none = await tester.runAsync(() => startupErrorAppFor(readFailed, StackTrace.empty,
            onRetry: () {}, state: answers(KeyringState.absent)));
        expect(none!.keyring, KeyringProblem.missing);
        expect(none.report, contains('Failed to unlock the keyring'));
      });

      testWidgets('a Try again that fails again is said again; it was only logged, and the screen kept its promise',
          (tester) async {
        final shown = <Widget>[];
        var starts = 0;
        final window = StartupWindow(
          show: shown.add,
          start: () => starts++,
          state: answers(KeyringState.locked),
        );
        await tester.runAsync(() => window.failed(readFailed, StackTrace.empty));
        expect(shown, hasLength(1));
        expect((shown.single as StartupErrorApp).keyring, KeyringProblem.locked);

        // The look at the keyring finds it unlocked, and starts again.
        (shown.single as StartupErrorApp).onRetry();
        expect(starts, 1);
        await tester.runAsync(() => window.failed(StateError('the store itself'), StackTrace.empty));
        expect(shown, hasLength(2), reason: 'the second failure has a screen of its own');
        expect((shown.last as StartupErrorApp).keyring, isNull);
        expect((shown.last as StartupErrorApp).report, contains('the store itself'));

        // A failure with a window up is no failure of the start.
        window.showApp(const SizedBox());
        final before = shown.length;
        await tester.runAsync(() => window.failed(StateError('later'), StackTrace.empty));
        expect(shown, hasLength(before));
      });
    });

    Future<void> pumpIt(
      WidgetTester tester, {
      required KeyringProblem keyring,
      required VoidCallback onRetry,
      Future<bool?> Function()? unlocked,
    }) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(StartupErrorApp(
        report: 'the report',
        onRetry: onRetry,
        keyring: keyring,
        keyringUnlocked: unlocked ?? () async => false,
      ));
      await tester.pump();
    }

    testWidgets('locked: says so with what to do, and no word of a failure to start', (tester) async {
      var retried = 0;
      await pumpIt(tester, keyring: KeyringProblem.locked, onRetry: () => retried++);
      expect(find.text(l10n.keyringLockedTitle), findsOneWidget);
      expect(find.text(l10n.keyringLockedBody), findsOneWidget);
      expect(find.text(l10n.keyringLockedHowTo), findsOneWidget);
      expect(find.text(l10n.startupErrorTitle), findsNothing);
      expect(find.byType(ErrorDetailsPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('startup-error-retry')));
      expect(retried, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('locked: goes on by itself once the keyring is unlocked, and only then', (tester) async {
      var retried = 0;
      bool? answer = false;
      await pumpIt(tester, keyring: KeyringProblem.locked, onRetry: () => retried++, unlocked: () async => answer);
      await tester.pump(const Duration(seconds: 5));
      expect(retried, 0, reason: 'still locked');
      answer = null;
      await tester.pump(const Duration(seconds: 5));
      expect(retried, 0, reason: 'cannot be told: the person says, by Try again');
      answer = true;
      await tester.pump(const Duration(seconds: 3));
      expect(retried, 1);
      await tester.pump(const Duration(seconds: 10));
      expect(retried, 1, reason: 'once');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nothing there: says what to install, and looks at nothing', (tester) async {
      var asked = 0;
      await pumpIt(tester, keyring: KeyringProblem.missing, onRetry: () {}, unlocked: () async {
        asked++;
        return true;
      });
      expect(find.text(l10n.keyringMissingTitle), findsOneWidget);
      expect(find.text(l10n.keyringMissingBody), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(asked, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the app says it for what the plugin answered', (tester) async {
      final app = await tester.runAsync(() => startupErrorAppFor(
            PlatformException(code: 'Libsecret error', message: 'Failed to unlock the keyring'),
            StackTrace.current,
            onRetry: () {},
            state: () async => KeyringState.locked,
          ));
      expect(app!.keyring, KeyringProblem.locked);
      expect(app.report, contains('Failed to unlock the keyring'));
      final other = await tester.runAsync(() => startupErrorAppFor(StateError('no'), StackTrace.current, onRetry: () {}));
      expect(other!.keyring, isNull);
    });
  });

  /// A report as the app makes one when the database fails to open.
  String report() {
    ReportScrub.registerFolder('C:/Users/demo/AppData/Roaming/ZestSSH', '<app data>');
    return ErrorReport.build(
      what: 'Database Error',
      where: 'Opening the database at start',
      error: 'SqliteException(26): file is not a database, C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db',
      details: 'Database: C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db',
      logLines: 0,
    );
  }

  Future<void> big(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('The details panel', () {
    testWidgets('is closed at first, opens to the report, and copies it', (tester) async {
      await big(tester);
      final text = report();
      expect(text, isNot(contains('demo')));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ErrorDetailsPanel(report: text))));
      expect(find.byKey(const ValueKey('error-details-text')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
      await tester.pump();
      expect(tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data, text);
      await tester.tap(find.text('Copy details'));
      await tester.pump();
      expect(copied, [text]);
      await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('error-details-text')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('The app could not start', () {
    testWidgets('says so, starts again, and writes to support with the details copied first', (tester) async {
      await big(tester);
      final text = report();
      var retried = 0;
      await tester.pumpWidget(StartupErrorApp(report: text, onRetry: () => retried++, launch: launch));
      await tester.pump();
      expect(find.text('ZestSSH could not start'), findsOneWidget);
      expect(find.byType(ErrorDetailsPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('startup-error-retry')));
      expect(retried, 1);

      await tester.tap(find.byKey(const ValueKey('startup-error-support')));
      await tester.pump();
      expect(copied, [text]);
      final mail = opened.single;
      expect(mail.scheme, 'mailto');
      expect(mail.path, 'support@zestssh.com');
      expect(mail.query, startsWith('subject=ZestSSH%20error&body=Hi%2C'));
      expect(mail.query, isNot(contains('+')), reason: 'a mail app reads a + as a plus');
      expect(mail.toString(), isNot(contains('Database')), reason: 'the report is pasted, not put in the link');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('The details are copied: paste them into the message.'), findsOneWidget);

      // No mail app: where to write instead is said.
      mailOpens = false;
      await tester.tap(find.byKey(const ValueKey('startup-error-support')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('No mail app opened. Write to support@zestssh.com: the details are copied, ready to paste.'),
          findsOneWidget);
      expect(copied, [text, text]);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a link that fails to open is no mail app either', (tester) async {
      await big(tester);
      await tester.pumpWidget(StartupErrorApp(
        report: 'r',
        onRetry: () {},
        launch: (_) async => throw PlatformException(code: 'none'),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('startup-error-support')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('No mail app opened.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('The database could not be opened', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    Future<void> show(WidgetTester tester, {String? path = 'C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db',
        required Future<void> Function() onReset, VoidCallback? onRetry}) async {
      await big(tester);
      await tester.pumpWidget(DatabaseErrorApp(
        report: report(),
        databasePath: path,
        onRetry: onRetry ?? () {},
        onReset: onReset,
        launch: launch,
        reveal: reveal,
      ));
      await tester.pump();
    }

    testWidgets('its folder is shown on a computer, and support is written to with the report', (tester) async {
      var retried = 0;
      await show(tester, onReset: () async {}, onRetry: () => retried++);
      expect(find.byType(ErrorDetailsPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('database-error-retry')));
      expect(retried, 1);
      await tester.tap(find.byKey(const ValueKey('database-error-folder')));
      expect(revealed, ['C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db']);
      await tester.tap(find.byKey(const ValueKey('database-error-support')));
      await tester.pump();
      expect(copied.single, contains('What: Database Error'));
      expect(copied.single, isNot(contains('demo')));
      expect(opened, hasLength(1));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('the guidance never calls Reset a last resort that erases the data (3.3.3)', (tester) async {
      await show(tester, onReset: () async {});
      expect(find.text(l10n.databaseErrorGuidance), findsOneWidget);
      expect(l10n.databaseErrorGuidance, isNot(contains('Reset')));
      expect(l10n.databaseErrorGuidance, isNot(contains('erases')));
      expect(l10n.databaseErrorGuidance, contains('sets it aside'));
    });

    testWidgets('with no path known, no folder to show', (tester) async {
      await show(tester, path: null, onReset: () async {});
      expect(find.byKey(const ValueKey('database-error-folder')), findsNothing);
      expect(find.byKey(const ValueKey('database-error-support')), findsOneWidget);
    });

    testWidgets('a reset is asked about first, and Cancel keeps everything', (tester) async {
      var resets = 0;
      await show(tester, onReset: () async => resets++);
      await tester.tap(find.byKey(const ValueKey('database-error-reset')));
      await tester.pumpAndSettle();
      expect(find.text('Reset database?'), findsOneWidget);
      // 3.3.3: Reset sets the files aside with their key (AppDatabase.setAsideAndRecreate),
      // so the question no longer says it deletes everything for good.
      expect(find.text(l10n.databaseErrorResetBody), findsOneWidget);
      expect(l10n.databaseErrorResetBody, contains('nothing is deleted'));
      expect(l10n.databaseErrorResetBody, isNot(contains('permanently')));
      expect(l10n.databaseErrorResetBody, isNot(contains('cannot be undone')));
      expect(find.text('Delete everything'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(resets, 0);
      await tester.tap(find.byKey(const ValueKey('database-error-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set aside and start fresh'));
      await tester.pumpAndSettle();
      expect(resets, 1);
      expect(find.byKey(const ValueKey('database-error-reset-failed')), findsNothing);
    });

    testWidgets('a reset that fails says so, with its own details, until one does not', (tester) async {
      var attempts = 0;
      await show(tester, onReset: () async {
        if (++attempts == 1) throw const FileSystemExceptionStandIn('The file is in use');
      });
      await tester.tap(find.byKey(const ValueKey('database-error-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set aside and start fresh'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('database-error-reset-failed')), findsOneWidget);
      final panel = find.byKey(const ValueKey('database-error-reset-details'));
      expect(panel, findsOneWidget);
      await tester.tap(find.descendant(of: panel, matching: find.text('Copy details')));
      await tester.pump();
      expect(copied.single, contains('What: The saved data could not be set aside, and nothing was deleted.'));
      expect(copied.single, contains('Where: Setting the database aside to start again'));
      expect(copied.single, contains('The file is in use'));
      // The buttons work again, and the next reset, which works, says no failure.
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('database-error-retry'))).onPressed, isNotNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.byKey(const ValueKey('database-error-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set aside and start fresh'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.byKey(const ValueKey('database-error-reset-failed')), findsNothing);
    });
  });

  group('An update of the database failed', () {
    testWidgets('says whether the data was put back, goes on, shows the copy, and writes to support', (tester) async {
      await big(tester);
      var continued = 0;
      await tester.pumpWidget(MigrationErrorApp(
        report: report(),
        backupRestored: false,
        backupPath: 'C:/Users/demo/AppData/Roaming/ZestSSH/backups/zestssh-before-update.db',
        onContinue: () => continued++,
        launch: launch,
        reveal: reveal,
      ));
      await tester.pump();
      expect(find.text('Update failed'), findsOneWidget);
      expect(find.textContaining('A backup could not be restored.'), findsOneWidget);
      expect(find.textContaining('Your data may be affected.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('migration-error-continue')));
      expect(continued, 1);
      await tester.tap(find.byKey(const ValueKey('migration-error-backup')));
      expect(revealed, ['C:/Users/demo/AppData/Roaming/ZestSSH/backups/zestssh-before-update.db']);
      await tester.tap(find.byKey(const ValueKey('migration-error-support')));
      await tester.pump();
      expect(copied.single, contains('What: Database Error'));
      expect(copied.single, isNot(contains('demo')));
      expect(find.byType(ErrorDetailsPanel), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('with no copy, none to show', (tester) async {
      await big(tester);
      await tester.pumpWidget(MigrationErrorApp(report: 'r', backupRestored: true, onContinue: () {}));
      await tester.pump();
      expect(find.byKey(const ValueKey('migration-error-backup')), findsNothing);
      expect(find.textContaining('Your previous data has been restored'), findsOneWidget);
      expect(find.textContaining('Your data is safe.'), findsOneWidget);
    });
  });

  group('The reports of a failure at start', () {
    test('of the app that could not start', () async {
      var retried = 0;
      final app = await startupErrorAppFor(
        StateError('no keychain'),
        StackTrace.fromString('#0      main (package:zestssh/main.dart:3:1)'),
        onRetry: () => retried++,
      );
      expect(
        app.report.split('\n').take(4),
        ['ZestSSH error details', 'What: ZestSSH could not start', 'Where: Starting the app', 'Error: Bad state: no keychain'],
      );
      expect(app.report, contains('  #0      main (package:zestssh/main.dart:3:1)'));
      app.onRetry();
      expect(retried, 1);
    });

    test('of a move to profiles that stopped: its code says it goes on at the next start', () async {
      final app = await startupErrorAppFor(const ProfileMoveFailed('keys', 'read back'), StackTrace.empty, onRetry: () {});
      expect(app.report, contains('Code: ${ErrorCodes.profileMoveStopped.code} (${ErrorCodes.profileMoveStopped.title})'));
    });

    test('of a database that could not be opened, or updated, with its path said by what it is', () async {
      ReportScrub.registerFolder('C:/Users/demo/AppData/Roaming/ZestSSH', '<app data>');
      const path = 'C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db';
      List<String> lines(String report) => report.split('\n');

      final opened = await databaseFailureReport(migration: false, error: 'file is not a database', databasePath: path);
      expect(lines(opened).sublist(1, 6), [
        'What: Database error',
        'Where: Opening the database at start',
        'Error: file is not a database',
        'Details:',
        '  Database: <app data>/zestssh.db',
      ]);
      expect(opened, isNot(contains('Backup restored')));
      expect(opened, isNot(contains('demo')));

      final updated = await databaseFailureReport(
        migration: true,
        error: 'no such column',
        databasePath: path,
        backupRestored: true,
      );
      expect(lines(updated).sublist(1, 7), [
        'What: Update failed',
        'Where: Updating the database at start',
        'Error: no such column',
        'Details:',
        '  Backup restored: yes',
        '  Database: <app data>/zestssh.db',
      ]);

      final notBack = await databaseFailureReport(migration: true, error: 'x');
      expect(lines(notBack).sublist(4, 7), ['Details:', '  Backup restored: no', '  Database: unknown']);
    });
  });

  // On a Mac, macOS asked again and again whether ZestSSH
  // may use what it saved in its keychain. A no at the start was "Database error"
  // with Reset, which deletes the data that was only waiting for a yes (3.3.2).
  group('macOS did not let ZestSSH read its saved keys', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final denied = KeychainAccessDenied(-128);

    testWidgets('at the start: says so and what to do, with its code, Try again, and nothing set aside', (tester) async {
      var asked = 0;
      final app = await tester.runAsync(() => startupErrorAppFor(denied, StackTrace.empty, onRetry: () {}, state: () async {
            asked++;
            return KeyringState.unknown;
          }));
      expect(app!.keyring, KeyringProblem.macDenied);
      expect(asked, 0, reason: 'nothing of a Linux keyring is asked');
      expect(app.onSetAside, isNull);
      expect(app.report, contains('Code: ZS-1913'));
      expect(app.report, contains('KeychainAccessDenied(-128)'));
      await big(tester);
      await tester.pumpWidget(app);
      await tester.pump();
      expect(find.text(l10n.macKeychainDeniedTitle), findsOneWidget);
      expect(find.text('${l10n.macKeychainDeniedBody} (ZS-1913)'), findsOneWidget);
      expect(find.text(l10n.macKeychainDeniedWhy), findsOneWidget);
      expect(find.text(l10n.startupErrorTitle), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('startup-error-retry')), matching: find.text(l10n.macKeychainTryAgain)), findsOneWidget);
      expect(find.byKey(const ValueKey('startup-error-set-aside')), findsNothing);
    });

    test('Try again asks macOS again: what it said no to in this run is forgotten', () async {
      final before = FlutterSecureStoragePlatform.instance;
      final store = MacKeychain(_SaysNo());
      FlutterSecureStoragePlatform.instance = store;
      addTearDown(() => FlutterSecureStoragePlatform.instance = before);
      await expectLater(store.read(key: 'profiles_v1', options: const {}), throwsA(isA<KeychainAccessDenied>()));
      expect(store.denials.any, isTrue);

      var starts = 0;
      final window = StartupWindow(show: (_) {}, start: () => starts++);
      await window.failed(store.denials.last!, StackTrace.empty);
      window.retry();
      expect(starts, 1);
      expect(store.denials.any, isFalse);
    });

    testWidgets('the database\'s key: no Reset, whatever was passed, and Try again with what to do', (tester) async {
      var resets = 0;
      var retried = 0;
      await big(tester);
      await tester.pumpWidget(DatabaseErrorApp(
        report: await tester.runAsync(() => databaseFailureReport(migration: false, error: denied)) ?? '',
        databasePath: 'C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db',
        onRetry: () => retried++,
        onReset: () async => resets++,
        keychainDenied: true,
        launch: launch,
        reveal: reveal,
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('database-error-reset')), findsNothing);
      expect(find.text(l10n.databaseErrorResetButton), findsNothing);
      expect(find.text(l10n.macKeychainDeniedTitle), findsOneWidget);
      expect(find.text('${l10n.macKeychainDeniedBody} (ZS-1913)'), findsOneWidget);
      expect(find.text(l10n.macKeychainDeniedWhy), findsOneWidget);
      expect(find.text(l10n.databaseErrorGuidance), findsNothing, reason: 'it called Reset a last resort');
      await tester.tap(find.byKey(const ValueKey('database-error-retry')));
      expect(retried, 1);
      expect(find.descendant(of: find.byKey(const ValueKey('database-error-retry')), matching: find.text(l10n.macKeychainTryAgain)), findsOneWidget);
      expect(resets, 0);

      // Its report names the code.
      await tester.tap(find.byKey(const ValueKey('database-error-support')));
      await tester.pump();
      expect(copied.single, contains('Code: ZS-1913'));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('data from a newer ZestSSH: says to update it, no Reset whatever was passed (found in a '
        'review)', (tester) async {
      var resets = 0;
      await big(tester);
      const newer = DatabaseNewerThanApp(56, 55);
      await tester.pumpWidget(DatabaseErrorApp(
        report: await tester.runAsync(() => databaseFailureReport(migration: false, error: newer)) ?? '',
        databasePath: 'C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db',
        onRetry: () {},
        onReset: () async => resets++,
        newerData: true,
        launch: launch,
        reveal: reveal,
      ));
      await tester.pump();
      expect(find.text(l10n.databaseNewerTitle), findsOneWidget);
      expect(find.text(l10n.databaseNewerBody), findsOneWidget);
      expect(find.text(l10n.databaseNewerGuidance), findsOneWidget);
      expect(find.byKey(const ValueKey('database-error-reset')), findsNothing);
      expect(find.text(l10n.databaseErrorResetButton), findsNothing);
      expect(resets, 0);
      await tester.tap(find.byKey(const ValueKey('database-error-support')));
      await tester.pump();
      expect(copied.single, contains('What: ${l10n.databaseNewerTitle}'));
      expect(copied.single, contains('DatabaseNewerThanApp'));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('any other failure keeps Reset, as before', (tester) async {
      await big(tester);
      await tester.pumpWidget(DatabaseErrorApp(report: report(), onRetry: () {}, onReset: () async {}));
      await tester.pump();
      expect(find.byKey(const ValueKey('database-error-reset')), findsOneWidget);
    });

    test('main.dart passes it on, and offers no Reset for it (3.3.3: nor for any that may pass, nor on a computer)', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('final keychainDenied = e is KeychainAccessDenied;'));
      expect(main, contains('keychainDenied: keychainDenied,'));
      expect(main, contains('onReset: resetOffered(e, moving: moving, computer: ProfileManager.instance != null)'));
      expect(main, isNot(contains('deleteAndRecreate')));
    });
  });

  group('A part of a screen that failed to build, in a build made for release', () {
    testWidgets('says so with the details to copy, even with nothing of the app around it', (tester) async {
      final details = FlutterErrorDetails(
        exception: StateError('a list had no rows'),
        stack: StackTrace.fromString('#0      HostsList.build (package:zestssh/features/hosts/hosts_list.dart:42:7)'),
      );
      await tester.pumpWidget(BrokenWidgetNotice(details));
      expect(find.text('Something went wrong'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('broken-widget-copy')));
      await tester.pump();
      expect(copied.single, contains('What: Something went wrong'));
      expect(copied.single, contains('Where: Building a part of a screen'));
      expect(copied.single, contains('Error: Bad state: a list had no rows'));
      expect(copied.single, contains('hosts_list.dart:42:7'));
      expect(find.text('Copied'), findsOneWidget);
    });
  });
}

/// The plugin on a Mac where the person said no to macOS's question.
class _SaysNo extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async =>
      throw PlatformException(code: 'Unexpected security result code', message: 'Code: -128, Message: made up', details: -128);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A failure to delete a file, as the system words one.
class FileSystemExceptionStandIn implements Exception {
  const FileSystemExceptionStandIn(this.message);
  final String message;

  @override
  String toString() => 'FileSystemException: $message';
}
