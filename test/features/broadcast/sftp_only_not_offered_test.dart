import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/host_checklist.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// What needs a terminal is not offered for a host that is SFTP only:
/// where a list shows hosts for a broadcast, a run,
/// a key put in place, a snippet, a workflow's step, a forward or a
/// scheduled task, such a host is dimmed with why, and cannot be picked.
/// Everywhere else (the SFTP pickers, opening a host) it is a host as any.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 30);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-data', name: 'Data', createdAt: at));
    // (The SFTP-only one first: Enter in a picker passes over it.)
    final hosts = [
      ('h-files', 'files-01', '192.0.2.20', 'sftp'),
      ('h-db', 'db-primary', '192.0.2.10', 'ssh'),
    ];
    for (var i = 0; i < hosts.length; i++) {
      final (id, label, host, protocol) = hosts[i];
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            protocol: Value(protocol),
            groupId: const Value('g-data'),
            sortOrder: Value(i),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the hosts to run on, broadcast to or put a key on: an SFTP-only host is dimmed with why, and cannot '
      'be ticked, by itself or with its group', (tester) async {
    var picked = <String>{};
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => SingleChildScrollView(
          child: HostChecklist(
            picked: picked,
            onChanged: (next) => setState(() => picked = next),
            keyPrefix: 'run',
            autofocus: false,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('run-host-h-files-no-terminal')), findsOneWidget);
    expect(find.text(en.hostSftpOnlyNoTerminal), findsOneWidget);
    expect(find.byKey(const ValueKey('run-host-h-db-no-terminal')), findsNothing);

    await tester.tap(find.text('files-01'));
    await settle(tester);
    expect(picked, isEmpty, reason: 'nothing to run it on');
    await tester.tap(find.byKey(const ValueKey('run-group-g-data')));
    await settle(tester);
    expect(picked, {'h-db'}, reason: "the group's box ticks what can be");
    await tester.tap(find.text('db-primary'));
    await settle(tester);
    expect(picked, isEmpty);
    await finish(tester);
  });

  Future<ConnectionPickerResult?> pick(WidgetTester tester, {required bool needsTerminal, required String tap}) async {
    ConnectionPickerResult? result;
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await ConnectionPickerDialog.show(context, title: 'Run on', needsTerminal: needsTerminal),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.tap(find.text(tap));
    await settle(tester);
    return result;
  }

  testWidgets('a host picked for what runs on it (a snippet, a step, a forward): an SFTP-only host says why and '
      'cannot be picked', (tester) async {
    final none = await pick(tester, needsTerminal: true, tap: 'files-01');
    expect(none, isNull, reason: 'the picker stays open');
    expect(find.text(en.hostSftpOnlyNoTerminal), findsOneWidget);
    // Enter picks the top match that can be picked.
    await tester.enterText(find.byType(TextField), 'f');
    await settle(tester);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect(find.text('Run on'), findsOneWidget, reason: 'files-01 is the only match, and cannot be picked');
    await tester.tap(find.text(en.cancel));
    await settle(tester);
    await finish(tester);
  });

  testWidgets('Enter in a picker for what runs on a host picks the first host that can be picked', (tester) async {
    ConnectionPickerResult? result;
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await ConnectionPickerDialog.show(context, title: 'Run on', needsTerminal: true),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect(result?.connection?.connection.id, 'h-db', reason: 'files-01 stands first, and is passed over');
    await finish(tester);
  });

  testWidgets('a host picked for its files (an SFTP pane, opening a host): an SFTP-only host is a host as any',
      (tester) async {
    final picked = await pick(tester, needsTerminal: false, tap: 'files-01');
    expect(picked?.connection?.connection.id, 'h-files');
    await finish(tester);
  });

  testWidgets("a select's choice that cannot be chosen says why under its name", (tester) async {
    String? chosen;
    await pump(
      tester,
      Center(
        child: SizedBox(
          width: 320,
          child: ZestSelect<String>(
            value: chosen,
            hint: 'Host',
            items: [
              const ZestSelectItem('h-db', 'db-primary'),
              ZestSelectItem('h-files', 'files-01', enabled: false, note: en.hostSftpOnlyNoTerminal),
            ],
            onChanged: (v) => chosen = v,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Host'));
    await settle(tester);
    expect(find.text(en.hostSftpOnlyNoTerminal), findsOneWidget);
    await tester.tap(find.text('files-01'));
    await settle(tester);
    expect(chosen, isNull);
    await finish(tester);
  });
}
