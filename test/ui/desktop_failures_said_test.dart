import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/port_forward_rules_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

/// The port forwards' rules, as the database gives them, but a delete
/// fails as a full disk would make it.
class _FullDisk extends PortForwardRulesDao {
  _FullDisk(super.db);

  @override
  Future<void> deleteRule(String id) async => throw const _DiskFailure('database or disk is full');
}

/// Sessions as the port forward test has them: none open.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
}

class _DiskFailure implements Exception {
  const _DiskFailure(this.message);
  final String message;
  @override
  String toString() => 'SqliteException(13): $message';
}

/// What failed on the computer's pages is said in the person's language,
/// with what was thrown kept for Copy details (3.0): a forward
/// the row's menu deletes said nothing at all when the delete failed (it was
/// thrown on), and the snippet library said "Error:" and the error as the
/// program writes it.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  // Real time for the database's streams, frames for the screen.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a forward the row\'s menu deletes, and that is not deleted: said as that, with what failed', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 1);
    await tester.runAsync(() async {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-db1',
            label: 'db-01',
            host: '10.50.0.7',
            createdAt: at,
            updatedAt: at,
          ));
      await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: 'r1',
            connectionId: 'h-db1',
            type: 'local',
            bindPort: 15432,
            remoteHost: '127.0.0.1',
            remotePort: 5432,
            label: const Value('db tunnel'),
            createdAt: at,
          ));
    });
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      portForwardRulesDaoProvider.overrideWith((ref) => _FullDisk(db)),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: PortForwardListView()),
      ),
    ));
    await settle(tester);

    await tester.tap(find.text('db tunnel'), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, en.delete));
    await settle(tester);
    await tester.tap(find.text('Delete').last);
    await settle(tester);

    final notice = container.read(notificationCenterProvider).history.first;
    expect(notice.title, en.portForwardNotDeleted);
    expect(notice.details, contains('database or disk is full'));
    expect(find.text('db tunnel'), findsOneWidget, reason: 'the forward is still there');
  });

  testWidgets('a snippet library that cannot be loaded says so, with Try again and its details', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var asked = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        snippetsProvider.overrideWith((ref) {
          asked++;
          return Stream.error(const _DiskFailure('database is locked'));
        }),
        snippetCategoryMetaProvider.overrideWith((ref) => Stream.value(const <SnippetCategory>[])),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        connectionGroupsProvider.overrideWith((ref) => Stream.value(const <ConnectionGroup>[])),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SnippetsLibraryView()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(en.snippetsLoadError), findsOneWidget);
    expect(find.textContaining('database is locked'), findsNothing, reason: 'the error is not the sentence');
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    final before = asked;
    await tester.tap(find.text(en.retry));
    await tester.pumpAndSettle();
    expect(asked, greaterThan(before), reason: 'Try again loads it again');
  });
}
