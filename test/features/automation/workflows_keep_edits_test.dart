import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/pages/automation_workflows_view.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/widgets/workflow_detail_pane.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart'
    show refreshPersonState;
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/automation_service.dart';

import '../../helpers/monitor_table_fixture.dart';

/// The Automation page goes when the computer shows a terminal in its place,
/// and the workflow editor's unsaved edits went with it, with no word. The
/// editor is kept in memory now, and opens again with them, unsaved. (All
/// names and addresses made up.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  late AppDatabase db;
  late SharedPreferences prefs;
  late AutomationService automation;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(ProviderContainer, ValueNotifier<bool>)> open(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    prefs = await fleet.preferences();
    automation = AutomationService(db, const FlutterSecureStorage());
    final container = ProviderContainer(
      overrides: [
        ...fleet.overrides(db, prefs),
        treeDatabaseProvider.overrideWithValue(db),
        automationServiceProvider.overrideWithValue(automation),
      ],
    );
    await tester.runAsync(
      () => container
          .read(workflowsProvider.notifier)
          .addWorkflow(
            Workflow.create(name: 'Nightly backup').copyWith(id: 'wf-backup'),
          ),
    );
    final pageShown = ValueNotifier(true);
    addTearDown(pageShown.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: pageShown,
              builder: (_, shown, _) => shown
                  ? const AutomationWorkflowsView()
                  : const Text('a terminal'),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return (container, pageShown);
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(minutes: 5));
    automation.dispose();
    await tester.runAsync(db.close);
  }

  WorkflowDetailPane pane(WidgetTester tester) =>
      tester.widget<WorkflowDetailPane>(find.byType(WorkflowDetailPane));
  WorkflowEditController editor(WidgetTester tester) => pane(tester).controller;
  Finder field(TextEditingController c) => find.byWidgetPredicate(
    (w) => w is EditableText && identical(w.controller, c),
  );
  bool prefsHold(String typed) => prefs.getKeys().any(
    (k) =>
        k.toLowerCase().contains('draft') || '${prefs.get(k)}'.contains(typed),
  );

  Future<void> awayAndBack(
    WidgetTester tester,
    ValueNotifier<bool> pageShown,
  ) async {
    pageShown.value = false;
    await settle(tester);
    expect(
      find.byType(AutomationWorkflowsView),
      findsNothing,
      reason: 'the page went, as it does for a terminal',
    );
    pageShown.value = true;
    await settle(tester);
  }

  Future<void> typeNew(WidgetTester tester) async {
    final c = editor(tester);
    await tester.enterText(field(c.nameController), 'Rotate logs weekly');
    c.addStep().commandController.text = 'logrotate -f /etc/logrotate.conf';
    await settle(tester);
    expect(c.isDirty, isTrue);
  }

  testWidgets(
    'a new workflow typed, a terminal, the page again: the editor as it was, unsaved; Save leaves nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await typeNew(tester);
      await awayAndBack(tester, pageShown);

      var c = editor(tester);
      expect(c.isCreating, isTrue);
      expect(c.isDirty, isTrue, reason: 'shown as unsaved');
      expect(c.nameController.text, 'Rotate logs weekly');
      expect(
        c.steps.single.commandController.text,
        'logrotate -f /etc/logrotate.conf',
      );
      expect(
        prefsHold('Rotate logs weekly'),
        isFalse,
        reason: 'kept in memory only',
      );

      final saving = pane(tester).onSave();
      await settle(tester);
      expect(await saving, isTrue);
      expect(
        container
            .read(workflowsProvider)
            .where((w) => w.name == 'Rotate logs weekly'),
        hasLength(1),
      );
      expect(container.read(workflowDraftsProvider).isEmpty, isTrue);

      await awayAndBack(tester, pageShown);
      c = editor(tester);
      expect(c.isDirty, isFalse, reason: 'nothing unsaved came back');
      expect(
        c.isCreating,
        isTrue,
        reason: 'the page opens on a new workflow, as before',
      );
      await finish(tester, container);
    },
  );

  testWidgets(
    'a saved workflow edited, a terminal, the page again: that workflow with the edit, unsaved; Cancel and Discard '
    'leave nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await tester.tap(find.text('Nightly backup').first);
      await settle(tester);
      var c = editor(tester);
      expect(c.original?.id, 'wf-backup');
      await tester.enterText(
        field(c.nameController),
        'Nightly backup (all hosts)',
      );
      await settle(tester);
      expect(c.isDirty, isTrue);
      await awayAndBack(tester, pageShown);

      c = editor(tester);
      expect(c.original?.id, 'wf-backup');
      expect(c.nameController.text, 'Nightly backup (all hosts)');
      expect(c.isDirty, isTrue);

      pane(tester).onClose();
      await settle(tester);
      await tester.tap(find.text(en.zestDiscardDiscard).last);
      await settle(tester);
      expect(editor(tester).isCreating, isTrue);
      await awayAndBack(tester, pageShown);
      expect(editor(tester).isDirty, isFalse);
      expect(
        container
            .read(workflowsProvider)
            .singleWhere((w) => w.id == 'wf-backup')
            .name,
        'Nightly backup',
        reason: 'nothing was saved',
      );
      await finish(tester, container);
    },
  );

  testWidgets('a change of profile forgets the edits, kept or on screen', (
    tester,
  ) async {
    final (container, pageShown) = await open(tester);
    await typeNew(tester);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(workflowDraftsProvider).isEmpty, isFalse);

    refreshPersonState(container);
    await settle(tester);
    expect(container.read(workflowDraftsProvider).isEmpty, isTrue);
    pageShown.value = true;
    await settle(tester);
    expect(editor(tester).isDirty, isFalse);
    expect(editor(tester).nameController.text, isEmpty);

    await typeNew(tester);
    refreshPersonState(container);
    await settle(tester);
    expect(editor(tester).nameController.text, isEmpty);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(workflowDraftsProvider).isEmpty, isTrue);
    await finish(tester, container);
  });
}
