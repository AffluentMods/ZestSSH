import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' as session;
import 'package:zestssh/ui/screens/desktop/widgets/connection_failed_dialog.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

import '../features/orchards/fake_crate_server.dart';

/// An Orchard database that is asked for and never used here.
class _NoStorage implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) => throw StateError('no database in this test');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

/// The team service as far as these tests go: asked for a request to hand
/// over, it has no account keys to make one with, and says so.
OrchardService serviceWithoutKeys() => OrchardService(
      server: FakeCrateServer(accountUid: 'u-dana').as('u-dana'),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: _NoStorage()),
      author: () async => null,
    );

/// What a computer says when a connection could not be made (3.0):
/// what went wrong and what to try in the app's language, the
/// host, Try again, and the report behind Copy details. It said "Could not
/// connect to host:port" in English and copied the raw details. Names and
/// addresses here are made up.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
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
    ReportScrub.clearFolders();
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = false;
    L10nGlobal.update(en);
    ErrorReport.app = 'ZestSSH 3.0.0 (build 256)';
    ErrorReport.system = () => 'windows 11';
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    Redactor.instance
      ..clearNames()
      ..enabled = false;
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  session.ConnectionError failure({String? connectionId = 'c1', String message = 'TimeoutException after 0:00:10.000000'}) =>
      session.ConnectionError(
        host: 'web-01.northwind.example',
        port: 22,
        errorMessage: message,
        connectionLabel: 'Northwind web',
        username: 'deploy',
        connectionLog: const [
          'Resolving web-01.northwind.example',
          'Connecting to 10.50.0.11:22',
          'No answer after 10 s',
        ],
        connectionId: connectionId,
      );

  /// Opens the dialog for [error] from a button, as the app does. [offers]
  /// is what the session keeps of hosts an owner can sign a certificate for.
  Future<void> open(WidgetTester tester, session.ConnectionError error,
      {VoidCallback? onRetry,
      bool recording = false,
      Map<String, ({String orchardId, String crateId})> offers = const {},
      Map<String, ({String orchardId, String crateId})> passes = const {}}) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      // (A new one each time: a test opens it more than once, with other things kept.)
      key: UniqueKey(),
      overrides: [
        recordingModeProvider.overrideWith((ref) => recording),
        session.certificateFromOwnerOfferProvider.overrideWith((ref) => offers),
        session.offlinePassOfferProvider.overrideWith((ref) => passes),
        orchardServiceProvider.overrideWithValue(serviceWithoutKeys()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showZestModal<void>(
                context: context,
                size: ZestModalSize.standard,
                child: ConnectionFailedDialog(error: error, onRetry: onRetry),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('says what went wrong and what to try, in the app\'s words, with the host', (tester) async {
    final error = failure();
    await open(tester, error, onRetry: () {});
    final friendly = ConnectionError.translate(error.errorMessage, host: error.host, port: error.port, username: error.username);
    expect(friendly.type, ConnectionErrorType.timeout);
    expect(find.text(friendly.title), findsOneWidget);
    expect(find.text(friendly.description), findsOneWidget);
    expect(find.text(friendly.tip!), findsOneWidget);
    expect(find.text('Northwind web'), findsOneWidget);
    expect(find.text('Connection failed'), findsNothing, reason: 'the headline names what went wrong');
    expect(find.textContaining('Could not connect to'), findsNothing);
  });

  testWidgets('what the app itself said is shown as it said it, with nothing guessed in its place', (tester) async {
    // A certificate that waits for an owner: the app wrote the reason, and
    // what to do. It was shown as "An unexpected error occurred while
    // connecting", with the reason only under the details.
    final said = en.teamCertWaitingForOwner;
    await open(tester, failure(message: saidByApp(said)), onRetry: () {});
    expect(tester.widget<Text>(find.byKey(const ValueKey('connection-failed-description'))).data, said);
    expect(find.byKey(const ValueKey('connection-failed-tip')), findsNothing, reason: 'the reason says what to do');
    expect(find.text(en.errConnectionFailedTitle), findsOneWidget);
    expect(find.text(en.errUnknownDesc('web-01.northwind.example')), findsNothing);
    expect(find.text(en.retry), findsOneWidget);
    // The report has the reason, and says who is speaking.
    await tester.tap(find.text(en.desktopShellCopyDetails));
    await tester.pump();
    expect(copied.single, contains('Error: ZestSSH: $said'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a login that could get no certificate offers one from an owner, for the host that failed only',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final said = '${en.teamCertNotAsked} (ZS-1502)';
    // Nothing kept for this host: nothing offered.
    await open(tester, failure(message: saidByApp(said)), onRetry: () {}, offers: const {
      'another-host': (orchardId: 'orchard-1', crateId: 'crate-1'),
    });
    expect(find.text(said), findsOneWidget, reason: 'the reason, with its code');
    expect(find.text(en.certHandButton), findsNothing);
    await tester.tap(find.text(en.close));
    await tester.pumpAndSettle();

    await open(tester, failure(message: saidByApp(said)), onRetry: () {}, offers: const {
      'c1': (orchardId: 'orchard-1', crateId: 'crate-1'),
    });
    expect(find.text(en.certHandButton), findsOneWidget);
    expect(find.text(en.retry), findsOneWidget, reason: 'beside trying again');
    await tester.tap(find.text(en.certHandButton));
    await tester.pumpAndSettle();
    // This dialog goes, and the other opens in its place.
    expect(find.byType(ConnectionFailedDialog), findsNothing);
    expect(find.text(en.certHandButton), findsOneWidget, reason: 'the title of the screen that opened');
    expect(find.byKey(const ValueKey('cert-hand-cannot')), findsOneWidget,
        reason: 'which goes about making a request (with no keys in this test, it says it cannot)');
  });

  testWidgets('a host whose Crate is closed on the device offers an offline pass from an owner, for the host '
      'that failed only', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final said = en.crateClosedOfflineError('Production');
    // Nothing kept for this host: nothing offered.
    await open(tester, failure(message: saidByApp(said)), onRetry: () {}, passes: const {
      'another-host': (orchardId: 'orchard-1', crateId: 'crate-1'),
    });
    expect(find.text(said), findsOneWidget, reason: 'the reason as the app wrote it');
    expect(find.text(en.passAskButton), findsNothing);
    expect(find.text(en.certHandButton), findsNothing);
    await tester.tap(find.text(en.close));
    await tester.pumpAndSettle();

    await open(tester, failure(message: saidByApp(said)), onRetry: () {}, passes: const {
      'c1': (orchardId: 'orchard-1', crateId: 'crate-1'),
    });
    expect(find.text(en.passAskButton), findsOneWidget);
    expect(find.text(en.certHandButton), findsNothing, reason: 'a certificate is not what it lacks');
    expect(find.text(en.retry), findsOneWidget, reason: 'beside trying again');
    await tester.tap(find.text(en.passAskButton));
    await tester.pumpAndSettle();
    // This dialog goes, and the other opens in its place.
    expect(find.byType(ConnectionFailedDialog), findsNothing);
    expect(find.text(en.passAskButton), findsOneWidget, reason: 'the title of the screen that opened');
    expect(tester.widget<Text>(find.byKey(const ValueKey('pass-hand-cannot'))).data, en.passAskNoTeam,
        reason: 'which goes about making a request (the team is not on this device in this test, and it says so)');
  });

  testWidgets('Copy details copies the report, every name and address taken out', (tester) async {
    final error = failure();
    await open(tester, error, onRetry: () {});
    expect(find.byType(ErrorDetailsPanel), findsOneWidget);
    await tester.tap(find.text(en.desktopShellCopyDetails));
    await tester.pump();
    final report = copied.single;
    final title = ConnectionError.translate(error.errorMessage).title;
    expect(report, contains('What: $title'));
    expect(report, contains('Where: Connecting to a host'));
    expect(report, contains('Error: TimeoutException after 0:00:10.000000'));
    expect(report, contains('  Kind: timeout'));
    expect(report, contains('  No answer after 10 s'));
    for (final leak in ['northwind', '10.50.0.11']) {
      expect(report, isNot(contains(leak)), reason: leak);
    }
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the kind in the report is the kind the failure is shown as, whatever was thrown', (tester) async {
    // (It was what the program calls the type of what was thrown, which is another name in a build made for
    // release, and never the kind the reports of the other screens have.)
    final error = failure(message: 'SSHAuthFailError(All authentication methods failed)');
    await open(tester, error, onRetry: () {});
    await tester.tap(find.text(en.desktopShellCopyDetails));
    await tester.pump();
    final report = copied.single;
    expect(ConnectionError.translate(error.errorMessage).type, ConnectionErrorType.authFailed);
    expect(report.split('\n').where((line) => line.contains('Kind:')), ['  Kind: authFailed']);
    // (But for when each was made: a report says the time to the second, and the second can turn between the
    // two, which failed this test now and then.)
    String butForItsTime(String made) => made.split('\n').where((line) => !line.startsWith('Time: ')).join('\n');
    expect(report.split('\n').where((line) => line.startsWith('Time: ')), hasLength(1));
    expect(butForItsTime(report),
        butForItsTime(ConnectionFailedDialog.reportOf(error, ConnectionError.translate(error.errorMessage))));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Try again closes it and connects again; Close only closes it', (tester) async {
    var retried = 0;
    await open(tester, failure(), onRetry: () => retried++);
    await tester.tap(find.text(en.retry));
    await tester.pumpAndSettle();
    expect(retried, 1);
    expect(find.byType(ConnectionFailedDialog), findsNothing);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.close));
    await tester.pumpAndSettle();
    expect(retried, 1);
    expect(find.byType(ConnectionFailedDialog), findsNothing);
  });

  testWidgets('with nothing to connect to again, there is no Try again', (tester) async {
    await open(tester, failure(connectionId: null));
    expect(find.text(en.retry), findsNothing);
    expect(find.text(en.close), findsOneWidget);
  });

  testWidgets('a host with no name of its own is named by its address and port', (tester) async {
    final error = session.ConnectionError(host: '10.50.0.11', port: 2222, errorMessage: 'Connection refused');
    await open(tester, error);
    expect(find.text('10.50.0.11:2222'), findsOneWidget);
  });

  testWidgets('in recording mode the host and the user are masked in what it says', (tester) async {
    Redactor.instance.enabled = true;
    final error = failure(message: 'SSHAuthFailError(All authentication methods failed for publickey)');
    await open(tester, error, onRetry: () {}, recording: true);
    final shown = tester.widget<Text>(find.byKey(const ValueKey('connection-failed-description'))).data!;
    expect(shown, isNot(contains('deploy')));
    expect(shown, isNot(contains('northwind')));
    expect(find.text('Northwind web'), findsNothing);
  });
}
