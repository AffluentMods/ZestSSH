import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_status.dart';
import 'package:zestssh/features/automation/widgets/workflow_detail_pane.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';

import '../../helpers/words_cut.dart';
import '../../visual/shots_util.dart';

class _Workflows extends StateNotifier<List<Workflow>> implements WorkflowNotifier {
  _Workflows(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A workflow's names' column on a computer (3.0): the Name
/// field and the Description cell beside it share a column measured from the
/// two names at the text size the app is drawn at, at least the 104 they had.
/// A fixed 104 clipped "Beschreibung" at the cell's edge, and at a larger
/// system text size it would break it.
void main() {
  final workflow = Workflow(
    id: 'w1',
    name: 'Nightly backup',
    createdAt: DateTime(2026, 10, 1),
    steps: const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'backup.sh')],
  );

  Future<void> pump(WidgetTester tester, Locale locale, double scale) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(theme.colorScheme);
    final controller = WorkflowEditController()..bind(workflow);
    final run = WorkflowRunController();
    addTearDown(controller.dispose);
    addTearDown(run.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        workflowsProvider.overrideWith((ref) => _Workflows([workflow])),
        workflowLastRunProvider.overrideWith((ref) => const {}),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        automationLogProvider.overrideWith((ref) => Stream.value(const [])),
        scheduledTasksStreamProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: Scaffold(
          body: WorkflowDetailPane(
            controller: controller,
            runController: run,
            hasSelection: true,
            onNew: () {},
            onSave: () async => true,
            onClose: () {},
            onDelete: () {},
            onRun: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('in German, at the size the app is drawn at and larger, "Beschreibung" stands whole in its cell, on the '
      'rule of the Name field', (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    for (final scale in const [1.0, 1.25, 1.5]) {
      await pump(tester, const Locale('de'), scale);
      final description = tester.renderObject<RenderParagraph>(find.text(de.zestAutoFieldDescription));
      expect(wordsCut(description), isEmpty, reason: 'at $scale times');
      expect(clippedAtEdge(description), isNull, reason: 'at $scale times');
      expect(cutTopAndBottom(description), isNull, reason: 'at $scale times');
      final name = tester.widget<ZestField>(find.byType(ZestField).first);
      expect(name.label, de.zestAutoFieldName);
      expect(name.labelWidth, greaterThanOrEqualTo(120));
      expect(tester.getTopLeft(find.text(de.zestAutoFieldDescription)).dx,
          closeTo(tester.getTopLeft(find.text(de.zestAutoFieldName).first).dx, 1),
          reason: 'the two names start on one rule');
    }
  });

  // (120: the names' column every editor of the computer has; it was 104
  // here, 108, 116 and 88 on the other pages.)
  testWidgets('in English at the size the app is drawn at, the column is the 120 of every editor', (tester) async {
    await pump(tester, const Locale('en'), 1.0);
    expect(tester.widget<ZestField>(find.byType(ZestField).first).labelWidth, 120);
  });
}
