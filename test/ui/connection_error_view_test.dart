import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/terminal_providers.dart'
    show certificateFromOwnerOfferProvider, offlinePassOfferProvider;

import '../features/orchards/fake_crate_server.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// What a phone shows when a connection could not be made (3.0):
/// its details are the report of the failure, to read, select and
/// copy (the raw error and the log stood behind a gesture, and could be
/// neither selected nor copied). Names and addresses here are made up.
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
      ..enabled = false;
    L10nGlobal.update(en);
    ErrorReport.app = 'ZestSSH 3.0.0 (build 256)';
    ErrorReport.system = () => 'android 14';
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  testWidgets('the details are the report of the failure, with the log, to read and copy', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var retried = 0;
    const message = 'TimeoutException after 0:00:10.000000';
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ConnectionErrorView(
            errorMessage: message,
            connectionLabel: 'Northwind web',
            host: 'web-01.northwind.example',
            port: 22,
            username: 'deploy',
            connectionLog: const ['Resolving web-01.northwind.example', 'Connecting to 10.50.0.11:22', 'No answer after 10 s'],
            onRetry: () => retried++,
            onEditConnection: () {},
            onGoBack: () {},
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(ErrorDetailsPanel), findsOneWidget);
    await tester.tap(find.text(en.retry));
    expect(retried, 1);

    // Opened by a button, as text that can be selected.
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pump();
    final shown = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(shown, contains('  No answer after 10 s'));

    await tester.tap(find.text(en.desktopShellCopyDetails));
    await tester.pump();
    final report = copied.single;
    expect(report, shown);
    final title = ConnectionError.translate(message).title;
    expect(report.split('\n').take(4), [
      'ZestSSH error details',
      'What: $title',
      'Where: Connecting to a host',
      'Error: $message',
    ]);
    expect(report, contains('  Kind: timeout'));
    for (final leak in ['northwind', '10.50.0.11']) {
      expect(report, isNot(contains(leak)), reason: leak);
    }
    await tester.pump(const Duration(seconds: 3));
  });

  /// The view for a failure the app worded itself ([said]), with what the
  /// session keeps of the hosts an owner can sign a certificate for
  /// ([offers]) and of those an owner can sign an offline pass for
  /// ([passes]).
  Future<void> showSaid(WidgetTester tester, SharedPreferences prefs, String said,
      {Map<String, ({String orchardId, String crateId})> offers = const {},
      Map<String, ({String orchardId, String crateId})> passes = const {}}) async {
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        certificateFromOwnerOfferProvider.overrideWith((ref) => offers),
        offlinePassOfferProvider.overrideWith((ref) => passes),
        orchardServiceProvider.overrideWithValue(OrchardService(
          server: FakeCrateServer(accountUid: 'u-dana').as('u-dana'),
          databases:
              OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: _NoStorage()),
          author: () async => null,
        )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ConnectionErrorView(
            errorMessage: saidByApp(said),
            connectionLabel: 'Northwind web',
            connectionId: 'c1',
            host: 'web-01.northwind.example',
            port: 22,
            username: 'deploy',
            connectionLog: const ['Resolving web-01.northwind.example'],
            onRetry: () {},
            onEditConnection: () {},
            onGoBack: () {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('what the app itself said is shown as it said it, and a certificate from an owner is offered for its host',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final said = en.teamCertWaitingForOwner;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Future<void> show(Map<String, ({String orchardId, String crateId})> offers) =>
        showSaid(tester, prefs, said, offers: offers);

    await show(const {});
    expect(find.text(said), findsOneWidget);
    expect(find.text(en.errUnknownDesc('web-01.northwind.example')), findsNothing);
    expect(find.text(en.errUnknownTip), findsNothing, reason: 'nothing guessed under it');
    expect(find.byKey(const ValueKey('connection-error-certificate-from-owner')), findsNothing);
    // Kept for another host: not this one's to offer.
    await show(const {'c2': (orchardId: 'orchard-1', crateId: 'crate-1')});
    expect(find.byKey(const ValueKey('connection-error-certificate-from-owner')), findsNothing);
    await show(const {'c1': (orchardId: 'orchard-1', crateId: 'crate-1')});
    expect(find.byKey(const ValueKey('connection-error-certificate-from-owner')), findsOneWidget);
    expect(find.text(en.certHandButton), findsOneWidget);
    // It opens the screen that goes about making a request.
    await tester.tap(find.byKey(const ValueKey('connection-error-certificate-from-owner')));
    await tester.pumpAndSettle();
    expect(find.text(en.certHandButton), findsNWidgets(2), reason: 'the button, and the title of what it opened');
    expect(find.byKey(const ValueKey('cert-hand-cannot')), findsOneWidget,
        reason: 'with no account keys in this test, it says it cannot make one');
  });

  testWidgets('a host whose Crate is closed on the device offers an offline pass from an owner, for its host only',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final said = en.crateClosedOfflineError('Production');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const offer = ValueKey('connection-error-offline-pass');

    await showSaid(tester, prefs, said);
    expect(find.text(said), findsOneWidget, reason: 'the reason as the app wrote it');
    expect(find.byKey(offer), findsNothing);
    // Kept for another host: not this one's to offer.
    await showSaid(tester, prefs, said, passes: const {'c2': (orchardId: 'orchard-1', crateId: 'crate-1')});
    expect(find.byKey(offer), findsNothing);
    await showSaid(tester, prefs, said, passes: const {'c1': (orchardId: 'orchard-1', crateId: 'crate-1')});
    expect(find.byKey(offer), findsOneWidget);
    expect(find.text(en.passAskButton), findsOneWidget);
    expect(find.byKey(const ValueKey('connection-error-certificate-from-owner')), findsNothing,
        reason: 'a certificate is not what it lacks');
    // It opens the screen that goes about making a request.
    await tester.tap(find.byKey(offer));
    await tester.pumpAndSettle();
    expect(find.text(en.passAskButton), findsNWidgets(2), reason: 'the button, and the title of what it opened');
    expect(tester.widget<Text>(find.byKey(const ValueKey('pass-hand-cannot'))).data, en.passAskNoTeam,
        reason: 'the team is not on this device in this test, and it says so');
  });

  test('the report of a connection is the same on a phone and on a computer', () {
    final report = connectionFailureReport(title: 'Host unreachable', error: 'No route to host', kind: 'hostUnreachable', log: const ['a', 'b']);
    expect(report.split('\n').take(8), [
      'ZestSSH error details',
      'What: Host unreachable',
      'Where: Connecting to a host',
      'Error: No route to host',
      'Details:',
      '  Kind: hostUnreachable',
      '  a',
      '  b',
    ]);
  });
}
