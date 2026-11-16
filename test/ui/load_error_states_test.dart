import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// What a list shows when it could not be loaded (3.0): what
/// went wrong, Try again, and the details to copy. The phone's lists of keys
/// and forwarded ports said only that they could not be loaded. Names here
/// are made up.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
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
    ErrorReport.app = 'ZestSSH 3.0.0 (build 256)';
    ErrorReport.system = () => 'android 14';
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('the state says what went wrong, offers Try again, and copies the details', (tester) async {
    await phone(tester);
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LoadErrorState(
          message: 'The hosts could not be loaded.',
          hint: 'Try restarting the app.',
          where: 'Loading the hosts',
          error: StateError('disk I/O error at /home/demo/.local/share/zestssh/zestssh.db'),
          stack: StackTrace.fromString('#0      HostsDao.watch (package:zestssh/database/daos/hosts_dao.dart:12:3)'),
          onRetry: () => retried++,
        ),
      ),
    ));
    expect(find.text('The hosts could not be loaded.'), findsOneWidget);
    expect(find.text('Try restarting the app.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('load-error-retry')));
    expect(retried, 1);
    await tester.tap(find.text('Copy details'));
    await tester.pump();
    final report = copied.single;
    expect(report, contains('What: The hosts could not be loaded.'));
    expect(report, contains('Where: Loading the hosts'));
    expect(report, contains('Error: Bad state: disk I/O error at /home/<user>/'));
    expect(report, contains('hosts_dao.dart:12:3'));
    expect(report, isNot(contains('demo')));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('with nothing to try again, there is no button for it', (tester) async {
    await phone(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: LoadErrorState(message: 'm', where: 'w', error: 'e')),
    ));
    expect(find.byKey(const ValueKey('load-error-retry')), findsNothing);
    expect(find.text('Copy details'), findsOneWidget);
  });

  group('On a phone', () {
    Future<ProviderContainer> pump(WidgetTester tester, Widget screen, List<Override> failing) async {
      await phone(tester);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        recordingModeProvider.overrideWith((ref) => false),
        ...failing,
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: screen,
        ),
      ));
      await tester.pump();
      await tester.pump();
      return container;
    }

    testWidgets('the keys that could not be loaded say so, are loaded again, and have their details', (tester) async {
      var tries = 0;
      await pump(tester, const KeysPhoneScreen(), [
        filteredIdentitiesProvider.overrideWith((ref) {
          tries++;
          return Stream<List<Identity>>.error(StateError('no such table: identities'));
        }),
      ]);
      expect(find.text(l10n.homeUnableToLoadIdentities), findsOneWidget);
      expect(find.text(l10n.homeTryRestartingApp), findsOneWidget);
      expect(tries, 1);
      await tester.tap(find.byKey(const ValueKey('load-error-retry')));
      await tester.pump();
      await tester.pump();
      expect(tries, 2, reason: 'Try again loads them again');
      await tester.tap(find.text('Copy details'));
      await tester.pump();
      expect(copied.single, contains('Where: Loading the keys'));
      expect(copied.single, contains('no such table: identities'));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the keys screen closes cleanly, and its search starts empty the next time', (tester) async {
      final c = await pump(tester, const KeysPhoneScreen(), [
        filteredIdentitiesProvider.overrideWith((ref) => Stream.value(const <Identity>[])),
      ]);
      c.read(identitySearchQueryProvider.notifier).state = 'web';
      // Closed without a search typed on it: it reached for what it had
      // not read yet when closing, and threw.
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const SizedBox()));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(c.read(identitySearchQueryProvider), '');
    });

    testWidgets('the forwarded ports that could not be loaded say so, are loaded again, and have their details',
        (tester) async {
      var tries = 0;
      await pump(tester, const PortForwardsPhoneScreen(), [
        filteredPortForwardRulesProvider.overrideWith((ref) {
          tries++;
          return Stream<List<PortForwardRule>>.error(StateError('database is locked'));
        }),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const <ConnectionWithDetails>[])),
      ]);
      expect(find.text(l10n.homeUnableToLoadPortForwards), findsOneWidget);
      expect(find.text(l10n.homeTryRestartingApp), findsOneWidget);
      expect(tries, 1);
      await tester.tap(find.byKey(const ValueKey('load-error-retry')));
      await tester.pump();
      await tester.pump();
      expect(tries, 2);
      await tester.tap(find.text('Copy details'));
      await tester.pump();
      expect(copied.single, contains('Where: Loading the forwarded ports'));
      expect(copied.single, contains('database is locked'));
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
