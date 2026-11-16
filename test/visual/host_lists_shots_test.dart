import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart';
import 'package:zestssh/ui/widgets/command_palette.dart';
import 'package:zestssh/models/command_palette_item.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/features/automation/widgets/step_targets_dialog.dart';
import 'package:zestssh/features/automation/widgets/workflow_detail_pane.dart';
import 'package:zestssh/features/automation/workflow_templates.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/services/workflow_service.dart';

import '../helpers/monitor_table_fixture.dart';
import 'shots_util.dart';

/// Pictures of what lists hosts (from a
/// review): the one row of a host in Broadcast, a picker, Monitor thresholds,
/// the command palette and the Server monitor, with the real fonts and a
/// made-up fleet:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/host_lists_shots_test.dart
///
/// Pictures land in build/shots/. Another language with
/// --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

SessionState _session(String id, String connectionId, String label, String host) => SessionState(
      status: SessionStatus.connected,
      connectionId: connectionId,
      connectionLabel: label,
      host: host,
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: connectionId,
        terminal: Terminal(),
        shell: _Shell(),
        startedAt: DateTime(2026, 10, 3, 9),
      ),
    );

class _OpenSessions extends ActiveSessionsNotifier {
  _OpenSessions(super.ref) {
    state = {
      's1': _session('s1', 'web1', 'web-01', '192.168.10.21'),
      's2': _session('s2', 'db', 'db-primary', '192.168.10.31'),
      's3': _session('s3', 'hva', 'hypervisor-a', '192.168.20.11'),
    };
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  Future<void> shot(
    WidgetTester tester,
    String name, {
    required Future<void> Function(BuildContext context, WidgetRef ref) open,
    Size size = const Size(1280, 860),
    String themeId = 'graphite',
    Widget Function()? page,
    TargetPlatform platform = TargetPlatform.windows,
    double keyboard = 0,
    ActiveSessionsNotifier Function(Ref ref)? sessions,
    Future<void> Function(AppDatabase db)? seed,
  }) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = platform;
    try {
      L10nGlobal.update(l10n);
      final theme = BuiltInThemes.getById(themeId);
      AppColors.applyTheme(theme.colorScheme);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);
      final fleet = MonitorFleet();
      final db = await fleet.database();
      for (final (id, name, order) in [('g-web', 'Web', 0), ('g-data', 'Data', 1), ('g-infra', 'Infrastructure', 2)]) {
        await db.into(db.connectionGroups).insert(
            ConnectionGroupsCompanion.insert(id: id, name: name, sortOrder: Value(order), createdAt: DateTime(2026)));
      }
      for (final (host, group) in [
        ('web1', 'g-web'),
        ('web2', 'g-web'),
        ('cache', 'g-data'),
        ('db', 'g-data'),
        ('logs', 'g-data'),
        ('hva', 'g-infra'),
        ('hvb', 'g-infra'),
        ('edge', 'g-infra'),
      ]) {
        await (db.update(db.connections)..where((t) => t.id.equals(host)))
            .write(ConnectionsCompanion(groupId: Value(group)));
      }
      await seed?.call(db);
      final prefs = await fleet.preferences();
      await prefs.setString('os_kind_web1', 'ubuntu');
      await prefs.setString('os_kind_web2', 'ubuntu');
      await prefs.setString('os_kind_db', 'debian');
      await prefs.setString('os_kind_edge', 'freebsd');
      await prefs.setString('os_kind_mac', 'macos');
      await prefs.setString('os_kind_hva', 'debian');
      await prefs.setString('os_kind_hvb', 'debian');
      await SharedPreferences.getInstance();
      final key = GlobalKey();
      late BuildContext at;
      late WidgetRef refAt;
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: fleet.app(
          [
            ...fleet.overrides(db, prefs),
            activeSessionsProvider.overrideWith(sessions ?? _OpenSessions.new),
            osDetectionCacheProvider.overrideWith((ref) => _Os(prefs)),
          ],
          Consumer(builder: (context, ref, _) {
            at = context;
            refAt = ref;
            return page?.call() ?? const SizedBox.expand();
          }),
          theme: theme.toThemeData(),
          locale: const Locale(_locale),
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await open(at, refAt);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await saveShot(tester, key, name);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      await db.close();
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }

  testWidgets('Broadcast to hosts', (tester) async {
    await shot(tester, 'hosts_broadcast', open: (context, ref) async {
      showBroadcastToHosts(context, ref, preselected: const {'web2', 'logs'}).ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Run snippet on', (tester) async {
    await shot(tester, 'hosts_picker_run', open: (context, ref) async {
      ConnectionPickerDialog.show(context, title: l10n.zestSnippetsRunOnTitle, needsTerminal: true, place: HostListPlace.runSnippet)
          .ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Monitor thresholds, a host', (tester) async {
    await shot(tester, 'hosts_thresholds_host', open: (context, ref) async {
      ref.read(monitorThresholdsProvider.notifier).setOverrideMetric('hva', MonitorMetric.ram, const MetricThreshold(92, 97));
      ref.read(monitorThresholdsProvider.notifier).setOverrideReason('hva', 'Runs VMs, RAM is meant to be full');
      showMonitorThresholds(context, hostId: 'hva').ignore();
    });
  }, skip: !shotsEnabled);

  // A phone opens these as sheets, with no room for two panes.
  const phone = Size(390, 844);

  testWidgets('Monitor thresholds on a phone', (tester) async {
    await shot(tester, 'hosts_phone_thresholds', size: phone, platform: TargetPlatform.android, open: (context, ref) async {
      ref.read(monitorThresholdsProvider.notifier).setOverrideMetric('hva', MonitorMetric.ram, const MetricThreshold(92, 97));
      showMonitorThresholds(context, hostId: 'hva').ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Run snippet on, on a phone', (tester) async {
    await shot(tester, 'hosts_phone_picker', size: phone, platform: TargetPlatform.android, open: (context, ref) async {
      ConnectionPickerDialog.show(context, title: l10n.zestSnippetsRunOnTitle, needsTerminal: true, place: HostListPlace.runSnippet)
          .ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Run on hosts, on a phone', (tester) async {
    await shot(tester, 'hosts_phone_run_on', size: phone, platform: TargetPlatform.android, open: (context, ref) async {
      showRunOnHosts(context, preselected: const {'web2'}).ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Monitor thresholds on a phone on its side, the keyboard up', (tester) async {
    await shot(tester, 'hosts_phone_thresholds_side', size: const Size(844, 390), keyboard: 190, platform: TargetPlatform.android,
        open: (context, ref) async {
      showMonitorThresholds(context, hostId: 'hva').ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Run on hosts on a phone, the keyboard up', (tester) async {
    await shot(tester, 'hosts_phone_run_on_keyboard', size: phone, keyboard: 340, platform: TargetPlatform.android,
        open: (context, ref) async {
      showRunOnHosts(context, preselected: const {'web2'}).ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('The question before a run with risky commands', (tester) async {
    await shot(tester, 'hosts_danger_question', open: (context, ref) async {
      showWorkflowDangerDialog(context, commands: const [(runs: 'sudo reboot', shown: 'sudo reboot'), (runs: 'shutdown -h now', shown: 'shutdown -h now')], hosts: 3).ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Monitor thresholds, all hosts', (tester) async {
    await shot(tester, 'hosts_thresholds_all', themeId: 'default_light', open: (context, ref) async {
      showMonitorThresholds(context).ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Command palette', (tester) async {
    await shot(tester, 'hosts_palette', open: (context, ref) async {
      showCommandPalette(context, ref, actions: const []).ignore();
    });
  }, skip: !shotsEnabled);

  // The 4.0 mockup palette: "web" typed, in Ember as the mockup is drawn. Its
  // hosts (web-01 with two sessions open, web-02 one), the actions that name
  // them and their group, a snippet found by its category.
  testWidgets('Command palette, typed', (tester) async {
    await shot(tester, 'hosts_palette_typed', themeId: 'default_dark', sessions: _PaletteSessions.new, seed: _paletteSnippets,
        open: (context, ref) async {
      showCommandPalette(context, ref,
              actions: _paletteActions(l10n), onOpenInSplit: (_) {}, onOpenSftp: (_) {}, onBroadcast: (_) {})
          .ignore();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.enterText(find.byKey(const ValueKey('palette-query')), 'web');
    });
  }, skip: !shotsEnabled);

  // Nothing typed, three hosts connected to lately: they come first, then
  // the actions and the snippets.
  testWidgets('Command palette, the hosts connected to last', (tester) async {
    await shot(tester, 'hosts_palette_recent', themeId: 'default_dark', sessions: _PaletteSessions.new,
        seed: (db) async {
      await _paletteSnippets(db);
      final now = DateTime.now();
      for (final (id, ago) in [('web1', const Duration(minutes: 4)), ('db', const Duration(hours: 2)), ('hva', const Duration(days: 3))]) {
        await (db.update(db.connections)..where((t) => t.id.equals(id))).write(ConnectionsCompanion(lastConnected: Value(now.subtract(ago))));
      }
    }, open: (context, ref) async {
      showCommandPalette(context, ref, actions: _paletteActions(l10n), onOpenInSplit: (_) {}, onOpenSftp: (_) {}).ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('A workflow, its Run in its head and its output in its panel', (tester) async {
    final editor = WorkflowEditController();
    final run = WorkflowRunController();
    final wf = buildTemplateWorkflow(WorkflowTemplate.checkDiskSpace, l10n, groups: const [], connections: const []);
    editor.bind(wf);
    await shot(
      tester,
      'hosts_workflow_run',
      size: const Size(760, 860),
      page: () => WorkflowDetailPane(
        controller: editor,
        runController: run,
        hasSelection: true,
        onNew: () {},
        onSave: () async => true,
        onClose: () {},
        onDelete: () {},
        onRun: () {},
        onRunOn: () {},
      ),
      open: (context, ref) async {
        await run.run(_Fake(), wf);
      },
    );
  }, skip: !shotsEnabled);

  testWidgets('What a step runs on', (tester) async {
    await shot(tester, 'hosts_step_targets', open: (context, ref) async {
      showStepTargets(context, current: const StepTargets(hosts: ['web1', 'db'])).ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Run on…', (tester) async {
    await shot(tester, 'hosts_workflow_run_on', open: (context, ref) async {
      showWorkflowRunOn(context, workflowName: 'Check disk space everywhere').ignore();
    });
  }, skip: !shotsEnabled);

  testWidgets('Server monitor, filtered', (tester) async {
    await shot(
      tester,
      'hosts_monitor',
      size: const Size(1440, 700),
      page: () => const MonitorTableView(),
      open: (context, ref) async {},
    );
  }, skip: !shotsEnabled);

  testWidgets('Server monitor, filtered to the reboots', (tester) async {
    await shot(
      tester,
      'hosts_monitor_filtered',
      size: const Size(1440, 560),
      page: () => const MonitorTableView(),
      open: (context, ref) async {
        await tester.tap(find.byKey(const ValueKey('monitor-filter-reboot')));
      },
    );
  }, skip: !shotsEnabled);
}

/// A run's results, at once, made up.
class _Fake implements WorkflowService {
  @override
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    final step = workflow.steps.first;
    final results = [
      for (final (host, ok) in [('web1', true), ('edge', false), ('db', true), ('hva', true), ('mac', false), ('logs', true)])
        WorkflowStepResult(
          stepId: step.id,
          stepType: step.type,
          success: ok,
          output: ok ? '/dev/sda1 92% /srv' : '',
          error: ok ? '' : 'df: invalid option -- x',
          exitCode: ok ? 0 : 64,
          elapsed: const Duration(milliseconds: 1200),
          connectionId: host,
          stepIndex: 0,
        ),
    ];
    onStepHosts?.call(0, results.length);
    for (final r in results) {
      onStepComplete?.call(0, workflow.steps.length, r);
    }
    return WorkflowResult(
      workflowId: workflow.id,
      workflowName: workflow.name,
      success: false,
      stepResults: results,
      totalElapsed: const Duration(seconds: 4),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Sessions as the mockup palette has them: two open to web-01, one to web-02.
class _PaletteSessions extends ActiveSessionsNotifier {
  _PaletteSessions(super.ref) {
    state = {
      's1': _session('s1', 'web1', 'web-01', '192.168.10.21'),
      's2': _session('s2', 'web1', 'web-01', '192.168.10.21'),
      's3': _session('s3', 'web2', 'web-02', '192.168.10.22'),
    };
  }
}

/// Snippets for the palette's pictures, with their categories.
Future<void> _paletteSnippets(AppDatabase db) async {
  final at = DateTime(2026);
  for (final (id, label, command, category) in [
    ('sn1', 'Restart nginx', 'sudo systemctl restart nginx', 'Web'),
    ('sn2', 'Disk usage', 'df -h /', 'System'),
    ('sn3', 'Tail the app log', 'tail -f /var/log/app/current.log', 'Logs'),
  ]) {
    await db.into(db.snippets).insert(SnippetsCompanion.insert(
        id: id, label: label, command: command, category: Value(category), createdAt: at, updatedAt: at));
  }
}

/// A few of the desktop shell's actions, each with what it does and its key
/// as the shortcut formatter writes it.
List<CommandPaletteItem> _paletteActions(AppLocalizations l10n) {
  CommandPaletteItem item(String id, String title, String desc, IconData icon, {ShortcutKey? key}) => CommandPaletteItem(
        id: id,
        category: CommandCategory.action,
        title: title,
        subtitle: desc,
        icon: icon,
        shortcut: key?.displayLabel,
        onSelect: () {},
      );
  return [
    item('quick', l10n.desktopQuickConnect, l10n.paletteDescQuickConnect, LucideIcons.zap,
        key: ShortcutKey(keyId: LogicalKeyboardKey.keyT.keyId, ctrl: true, shift: true)),
    item('new-host', l10n.hostsNewHost, l10n.paletteDescNewHost, LucideIcons.plus,
        key: ShortcutKey(keyId: LogicalKeyboardKey.keyN.keyId, ctrl: true, shift: true)),
    item('import', l10n.cloudImpTitle, l10n.paletteDescImportHosts, LucideIcons.downloadCloud),
    item('sftp', l10n.sftpOpenPickerTitle, l10n.paletteDescSftpPicker, LucideIcons.folderOpen),
    item('broadcast', l10n.desktopCmdBroadcastToHosts, l10n.paletteDescBroadcastHosts, LucideIcons.radioTower),
    item('settings', l10n.settingsTitle, l10n.paletteDescSettings, LucideIcons.settings,
        key: ShortcutKey(keyId: LogicalKeyboardKey.comma.keyId, ctrl: true)),
  ];
}

class _Os extends OsDetectionCacheNotifier {
  _Os(super.prefs) {
    state = {
      'web1': OsKind.ubuntu,
      'web2': OsKind.ubuntu,
      'db': OsKind.debian,
      'edge': OsKind.freebsd,
      'mac': OsKind.macos,
      'hva': OsKind.debian,
      'hvb': OsKind.debian,
    };
  }
}
