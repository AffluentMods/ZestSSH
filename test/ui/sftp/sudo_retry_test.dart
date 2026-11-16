import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SftpStatusCode, SftpStatusError;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_service.dart' show SftpWrittenInPlaceException;
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/ui/screens/sftp/sudo_retry.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;

import '../../helpers/fake_sudo_host.dart';

/// Retry with sudo (3.4): what the host refused
/// with "Permission denied" says "Not allowed" with Retry with sudo beside
/// it; the dialog shows what will run, takes the password once for all of
/// it, and says each way sudo refuses with its code, instead of hanging.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  // The notice as a phone shows it, a card on the screen (a computer's goes
  // to the notification center: the pane's test reads it there).
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late BuildContext ctx;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> typePassword(WidgetTester tester, String password) async {
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('sftp-sudo-password')), matching: find.byType(TextField)),
      password,
    );
    await tester.tap(find.byKey(const ValueKey('sftp-sudo-run')));
    await tester.pumpAndSettle();
  }

  Future<void> retry(WidgetTester tester) async {
    await tester.tap(find.text(en.sftpSudoRetry));
    await tester.pumpAndSettle();
  }

  test('Permission denied is what offers it, a file written in place that ended so too', () {
    final denied = SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');
    expect(isPermissionDenied(denied), isTrue);
    expect(isPermissionDenied(SftpWrittenInPlaceException('/etc/x', denied)), isTrue);
    expect(isPermissionDenied(SftpStatusError(SftpStatusCode.noSuchFile, 'No such file')), isFalse);
    expect(isPermissionDenied(Exception('Permission denied')), isFalse, reason: 'only what the host said as SFTP');
  });

  testWidgets('the notice says Not allowed, and Retry with sudo asks once, shows the command, and runs it', (
    tester,
  ) async {
    await open(tester);
    final host = FakeSudoHost();
    var refreshed = 0;
    offerSudoRetry(
      ctx,
      sudo: host.ops(),
      host: 'web-01',
      ops: const [SudoMove('/etc/nginx/a.conf', '/etc/nginx/b.conf')],
      shownPath: '/etc/nginx/a.conf',
      onDone: () => refreshed++,
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text("Not allowed: you don't have permission for /etc/nginx/a.conf."), findsOneWidget);
    await retry(tester);
    expect(find.text(en.sftpSudoTitle), findsOneWidget);
    expect(find.text('sudo mv /etc/nginx/a.conf /etc/nginx/b.conf'), findsOneWidget);
    expect(find.text(en.sftpSudoPasswordHelp), findsOneWidget);
    expect(host.commands, isEmpty, reason: 'nothing runs before the password is typed');

    await typePassword(tester, 'hunter2');
    expect(host.commands.single, contains('exec mv -- "\$1" "\$2"'));
    expect(host.commands.single, isNot(contains('hunter2')));
    expect(host.stdins.single, 'hunter2\n');
    expect(find.text(en.sftpSudoTitle), findsNothing);
    expect(find.text(en.sftpSudoDone(en.sftpItemCount(1))), findsOneWidget);
    expect(refreshed, 1);
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('a wrong password is said with its code in the dialog, which stays; the next one runs', (tester) async {
    await open(tester);
    final host = FakeSudoHost();
    unawaitedRetry(ctx, host, const [SudoMkdir('/opt/app')]);
    await tester.pumpAndSettle();
    await typePassword(tester, 'wrong');
    expect(find.text('${en.editorSudoWrongPassword} (ZS-1601)'), findsOneWidget);
    expect(find.text(en.sftpSudoTitle), findsOneWidget);
    await typePassword(tester, 'hunter2');
    expect(host.commands, hasLength(2));
    expect(find.text(en.sftpSudoTitle), findsNothing);
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('what failed together takes one password, and each runs with it', (tester) async {
    await open(tester);
    final host = FakeSudoHost();
    unawaitedRetry(ctx, host, const [
      SudoDelete('/var/log/a.log'),
      SudoDelete('/var/log/old', folder: true),
      SudoMove('/srv/x', '/srv/in/x'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('sudo rm /var/log/a.log'), findsOneWidget);
    expect(find.text('sudo rm -r /var/log/old'), findsOneWidget);
    await typePassword(tester, 'hunter2');
    expect(host.commands, hasLength(3));
    expect(host.stdins, everyElement('hunter2\n'));
    expect(find.text(en.sftpSudoDone(en.sftpItemCount(3))), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('one that fails as root is said once the rest ran, with what the host said', (tester) async {
    await open(tester);
    final host = FakeSudoHost()..failing["'/srv/b'"] = "rm: cannot remove '/srv/b': Read-only file system";
    unawaitedRetry(ctx, host, const [SudoDelete('/srv/a'), SudoDelete('/srv/b'), SudoDelete('/srv/c')]);
    await tester.pumpAndSettle();
    await typePassword(tester, 'hunter2');
    expect(host.commands, hasLength(3));
    expect(find.text(en.sftpSudoSomeFailed(2, 3)), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
  });

  for (final (what, refuses, said) in [
    ('a host without sudo', (exitCode: 127, said: "env: 'sudo': No such file or directory"), 'ZS-1603'),
    ('sudo that wants a terminal', (exitCode: 1, said: 'sudo: sorry, you must have a tty to run sudo'), 'ZS-1604'),
    ('an account that may not', (exitCode: 1, said: 'deploy is not in the sudoers file.'), 'ZS-1602'),
  ]) {
    testWidgets('$what is said clearly, with its code, and nothing waits', (tester) async {
      await open(tester);
      final host = FakeSudoHost()..refuses = refuses;
      unawaitedRetry(ctx, host, const [SudoMkdir('/opt/app')]);
      await tester.pumpAndSettle();
      await typePassword(tester, 'hunter2');
      expect(find.textContaining('($said)'), findsOneWidget);
      expect(find.text(en.sftpSudoTitle), findsOneWidget, reason: 'the dialog stays, to cancel');
    });
  }

  testWidgets('a path that may not stand in a command line is said, with no Retry with sudo', (tester) async {
    await open(tester);
    final host = FakeSudoHost();
    offerSudoRetry(
      ctx,
      sudo: host.ops(),
      host: 'web-01',
      ops: const [SudoDelete('/srv/a & calc')],
      shownPath: '/srv/a & calc',
    );
    await tester.pump();
    expect(find.text("Not allowed: you don't have permission for /srv/a & calc."), findsOneWidget);
    expect(find.text(en.sftpSudoRetry), findsNothing);
    // (Nor where there is no host to run sudo on.)
    await tester.pump(const Duration(seconds: 15));
    offerSudoRetry(ctx, sudo: null, host: 'web-01', ops: const [SudoDelete('/srv/a')], shownPath: '/srv/a');
    await tester.pump();
    expect(find.text(en.sftpSudoRetry), findsNothing);
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('several say how many', (tester) async {
    await open(tester);
    offerSudoRetry(
      ctx,
      sudo: FakeSudoHost().ops(),
      host: 'web-01',
      ops: const [SudoDelete('/srv/a'), SudoDelete('/srv/b')],
      shownPath: '/srv/a',
    );
    await tester.pump();
    expect(find.text("Not allowed: you don't have permission for 2 items."), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
  });
}

void unawaitedRetry(BuildContext ctx, FakeSudoHost host, List<SudoFileOp> ops) {
  runSudoRetry(ctx, sudo: host.ops(), host: 'web-01', ops: ops);
}
