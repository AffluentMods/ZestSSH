import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show SSHAuthFailedException;
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A run on hosts that keeps what it was asked and shows what the test
/// sets: nothing is signed in to.
class _Recorded extends RunOnHostsNotifier {
  _Recorded() : super((_) async => throw StateError('nothing is signed in to here'));

  final runs = <({List<String> hosts, String command, String? typed, List<String> secrets})>[];
  final calls = <String>[];

  void show(HostsRun run) => state = run;

  @override
  Future<void> run(List<Connection> hosts, String command,
      {String? typed, List<String> secrets = const [], String? shown, String? input}) async {
    runs.add((hosts: [for (final h in hosts) h.id], command: command, typed: typed, secrets: secrets));
    state = HostsRun(
      command: command,
      typed: typed,
      secrets: secrets,
      shown: shown,
      hosts: [for (final h in hosts) HostRun(host: h, state: HostRunState.signingIn)],
      running: true,
    );
  }

  @override
  Future<void> again({bool all = false}) async => calls.add(all ? 'again all' : 'again');

  @override
  void stop() {
    calls.add('stop');
    super.stop();
  }
}

Connection _conn(String id) => Connection(
      id: id,
      label: id,
      host: '$id.example.com',
      port: 22,
      colorIndex: 0,
      protocol: 'ssh',
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: DateTime(2026, 10, 15),
      updatedAt: DateTime(2026, 10, 15),
    );

Snippet _snippet(String id, String label, String command, {bool confirm = false}) => Snippet(
      id: id,
      label: label,
      command: command,
      confirmBeforeRun: confirm,
      isDefault: false,
      sortOrder: 0,
      createdAt: DateTime(2026, 10, 15),
      updatedAt: DateTime(2026, 10, 15),
    );

/// Run on hosts (3.0), its dialog: hosts ticked and a command typed (or a
/// snippet's, its variables asked for), Run, and each host's result as it
/// comes; Copy all results; what a host printed and why it failed; Stop,
/// Run again where it failed, New run; a run that is going shown as it
/// stands; the free plan's limit.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  final copied = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(l10n);
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  /// The dialog over a page, with [hosts] saved and [snippets]; a Squeezed
  /// account unless not [pro]. [before] sets the run's state before it opens.
  Future<_Recorded> open(
    WidgetTester tester, {
    List<String> hosts = const ['web1', 'web2', 'web3'],
    List<Snippet> snippets = const [],
    bool pro = true,
    Snippet? snippet,
    void Function(_Recorded run)? before,
  }) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recorded = _Recorded();
    before?.call(recorded);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        runOnHostsProvider.overrideWith((ref) => recorded),
        connectionsWithDetailsProvider.overrideWith(
            (ref) => Stream.value([for (final id in hosts) ConnectionWithDetails(connection: _conn(id))])),
        snippetsProvider.overrideWith((ref) => Stream.value(snippets)),
        isProProvider.overrideWith((ref) => _Pro(pro)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRunOnHosts(context, snippet: snippet),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(RunOnHostsDialog), findsOneWidget);
    return recorded;
  }

  Finder primary() => find.byKey(const ValueKey('zest-dialog-primary'));
  Finder secondary() => find.byKey(const ValueKey('zest-dialog-secondary'));
  String labelOf(WidgetTester tester, Finder button) => (tester.widget(button) as dynamic).label as String;
  bool enabled(WidgetTester tester, Finder button) => (tester.widget(button) as dynamic).onPressed != null;
  /// The text keyed [key], or the text inside what is keyed so.
  String textOf(WidgetTester tester, String key) {
    final keyed = find.byKey(ValueKey(key));
    final widget = tester.widget(keyed);
    if (widget is Text) return widget.data!;
    return tester.widget<Text>(find.descendant(of: keyed, matching: find.byType(Text))).data!;
  }

  testWidgets('hosts ticked and a command typed: Run runs it on them, and each host\'s result shows as it comes; '
      'Copy all results copies them; a host opens to what it printed, or why it failed', (tester) async {
    final run = await open(tester);
    expect(find.byKey(const ValueKey('run-pick')), findsOneWidget);
    expect(enabled(tester, primary()), isFalse);

    await tester.enterText(find.byKey(const ValueKey('run-command')), 'uptime');
    await tester.tap(find.byKey(const ValueKey('run-host-web1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('run-host-web3')));
    await tester.pump();
    expect(find.byKey(const ValueKey('run-pick')), findsNothing);
    expect(labelOf(tester, primary()), l10n.runOnHostsRun(2));
    await tester.tap(primary());
    await tester.pumpAndSettle();
    expect(run.runs.single.hosts, ['web1', 'web3']);
    expect(run.runs.single.command, 'uptime');
    expect(run.runs.single.secrets, isEmpty);

    // As it goes: how far it is, and Stop.
    expect(textOf(tester, 'run-summary'), l10n.runOnHostsProgress(0, 2));
    expect(labelOf(tester, primary()), l10n.runOnHostsStop);
    expect(textOf(tester, 'run-state-web1'), l10n.runOnHostsSigningIn);

    const failure = SSHAuthFailedException('The server did not accept the key for deploy.');
    run.show(HostsRun(command: 'uptime', hosts: [
      HostRun(
          host: _conn('web1'),
          state: HostRunState.done,
          exitCode: 0,
          output: 'up 3 days\n',
          cut: true,
          logged: true,
          took: const Duration(milliseconds: 1200)),
      HostRun(host: _conn('web3'), state: HostRunState.failed, failure: failure, took: const Duration(milliseconds: 300)),
    ]));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'run-summary'), l10n.runOnHostsSummary(1, 1));
    expect(textOf(tester, 'run-state-web1'), l10n.runOnHostsOk);
    expect(textOf(tester, 'run-state-web3'), l10n.runOnHostsFailed);
    expect(find.text(l10n.runOnHostsSeconds('1.2')), findsOneWidget);
    final said = hostRunFailureSaid(run.state!.hosts[1], l10n);
    expect(textOf(tester, 'run-why-web3'), said.title, reason: 'why it failed, without opening it');
    expect(find.byKey(const ValueKey('run-why-web1')), findsNothing);
    // Logged for its team: said on its row, and only on its.
    expect(find.byKey(const ValueKey('run-logged-web1')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-logged-web3')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('run-copy')));
    await tester.pump();
    expect(copied.single, startsWith('\$ uptime\n'));
    expect(copied.single, contains('== web1 (web1.example.com): ${l10n.runOnHostsOk}\nup 3 days\n'));
    expect(copied.single, contains('== web3 (web3.example.com): ${l10n.runOnHostsFailed}\n${said.title}: ${said.description}\n'));

    expect(find.byKey(const ValueKey('run-output-web1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('run-open-web1')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('run-output-web1')), matching: find.text('up 3 days\n')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('run-details-web1')), matching: find.text(l10n.runOnHostsCut(256))),
        findsOneWidget, reason: 'more was printed than is kept');
    await tester.tap(find.byKey(const ValueKey('run-open-web3')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('run-details-web3')), matching: find.text(said.description)),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('run-details-web3')), matching: find.byType(CopyDetailsButton)),
        findsOneWidget);

    // Over: Run again where it failed, and a new run.
    expect(labelOf(tester, primary()), l10n.runOnHostsAgain);
    await tester.tap(primary());
    await tester.pump();
    expect(run.calls, ['again']);
    expect(labelOf(tester, secondary()), l10n.runOnHostsNew);
  });

  testWidgets('a snippet: its command is filled in, its variables are asked for with Run as the last step, and its '
      'masked value is hidden where the command is shown', (tester) async {
    final db = _snippet('s1', 'DB status', r'mysql -u ${USER} -p${PW:secret} -e status');
    final run = await open(tester, snippet: db);
    expect(find.widgetWithText(TextField, r'mysql -u ${USER} -p${PW:secret} -e status'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run-host-web2')));
    await tester.pump();
    await tester.tap(primary());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'deploy');
    await tester.pump();
    await tester.tap(find.text(l10n.next));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'hunter22');
    await tester.pump();
    expect(find.text(l10n.snippetVarPaste), findsNothing, reason: 'nothing is pasted anywhere');
    await tester.tap(find.text(l10n.snippetRunAction));
    await tester.pumpAndSettle();
    // (Each value goes in quoted, as a snippet's does in a terminal.)
    expect(run.runs.single.command, "mysql -u 'deploy' -p'hunter22' -e status");
    expect(run.runs.single.typed, r'mysql -u ${USER} -p${PW:secret} -e status');
    expect(run.runs.single.secrets, ['hunter22']);
    expect(textOf(tester, 'run-command-shown'), "mysql -u 'deploy' -p'••••••' -e status");
    expect(find.textContaining('hunter22'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('run-copy')));
    await tester.pump();
    expect(copied.single, startsWith("\$ mysql -u 'deploy' -p'••••••' -e status\n"));
    expect(copied.single, isNot(contains('hunter22')));
  });

  testWidgets('a snippet that asks before it runs asks first; changed by hand, it no longer does', (tester) async {
    final restart = _snippet('s2', 'Restart web', 'systemctl restart nginx', confirm: true);
    final run = await open(tester, snippets: [restart]);
    await tester.tap(find.byKey(const ValueKey('run-snippet')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart web').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'systemctl restart nginx'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run-host-web1')));
    await tester.pump();
    await tester.tap(primary());
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(l10n.cancel)));
    await tester.pumpAndSettle();
    expect(run.runs, isEmpty);

    await tester.enterText(find.byKey(const ValueKey('run-command')), 'systemctl reload nginx');
    await tester.pump();
    await tester.tap(primary());
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(run.runs.single.command, 'systemctl reload nginx');
  });

  testWidgets('the free plan runs on as many hosts at once as it opens sessions: more ticked says so, and Run '
      'waits', (tester) async {
    final hosts = [for (var i = 1; i <= runOnHostsFreeLimit + 1; i++) 'web$i'];
    await open(tester, hosts: hosts, pro: false);
    await tester.enterText(find.byKey(const ValueKey('run-command')), 'uptime');
    await tester.tap(find.byKey(const ValueKey('run-group-none')));
    await tester.pump();
    expect(find.text(l10n.runOnHostsLimit(runOnHostsFreeLimit)), findsOneWidget);
    expect(enabled(tester, primary()), isFalse);
    await tester.tap(find.byKey(ValueKey('run-host-${hosts.last}')));
    await tester.pump();
    expect(find.byKey(const ValueKey('run-limit')), findsNothing);
    expect(enabled(tester, primary()), isTrue);
  });

  testWidgets('Squeezed runs on any number of hosts', (tester) async {
    final hosts = [for (var i = 1; i <= runOnHostsFreeLimit + 3; i++) 'web$i'];
    final run = await open(tester, hosts: hosts);
    await tester.enterText(find.byKey(const ValueKey('run-command')), 'uptime');
    await tester.tap(find.byKey(const ValueKey('run-group-none')));
    await tester.pump();
    expect(find.byKey(const ValueKey('run-limit')), findsNothing);
    await tester.tap(primary());
    await tester.pumpAndSettle();
    expect(run.runs.single.hosts, hosts);
  });

  void going(_Recorded run) => run.show(HostsRun(
        command: 'echo 1',
        typed: r'echo ${N}',
        hosts: [HostRun(host: _conn('web2'), state: HostRunState.running)],
        running: true,
      ));

  testWidgets('a run that is going is shown as it stands when opened again; Stop stops it; New run goes back to the '
      'setup with the command as it was typed and its hosts ticked', (tester) async {
    final run = await open(tester, before: going);
    expect(find.byKey(const ValueKey('run-summary')), findsOneWidget, reason: 'the run, not the setup');
    expect(textOf(tester, 'run-state-web2'), l10n.runOnHostsRunning);
    await tester.tap(primary());
    await tester.pump();
    expect(run.calls, ['stop']);
    expect(textOf(tester, 'run-state-web2'), l10n.runOnHostsStopped);
    expect(textOf(tester, 'run-summary'), l10n.runOnHostsSummary(0, 1));
    await tester.tap(secondary());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, r'echo ${N}'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.descendant(of: find.byKey(const ValueKey('run-host-web2')), matching: find.byType(Checkbox))).value,
        isTrue);
  });

  testWidgets('opened from a snippet while a run is going: the run is shown, and the snippet\'s command waits for '
      'a new run', (tester) async {
    final run = await open(tester, snippet: _snippet('s3', 'Other', 'whoami'), before: going);
    expect(find.byKey(const ValueKey('run-summary')), findsOneWidget, reason: 'the run, not the setup');
    await tester.tap(primary());
    await tester.pump();
    expect(run.calls, ['stop']);
    await tester.tap(secondary());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'whoami'), findsOneWidget);
  });

  testWidgets('a run that is over is shown when opened again with nothing new to run; a snippet starts a new one',
      (tester) async {
    void over(_Recorded run) => run.show(HostsRun(
          command: 'uptime',
          hosts: [HostRun(host: _conn('web1'), state: HostRunState.done, exitCode: 0)],
        ));
    await open(tester, before: over);
    expect(find.byKey(const ValueKey('run-summary')), findsOneWidget);
    expect(labelOf(tester, primary()), l10n.runOnHostsAgain);
    expect(enabled(tester, primary()), isFalse, reason: 'every host ended well');
    await tester.pumpWidget(const SizedBox());
    await open(tester, snippet: _snippet('s4', 'Disk', 'df -h'), before: over);
    expect(find.byKey(const ValueKey('run-summary')), findsNothing);
    expect(find.widgetWithText(TextField, 'df -h'), findsOneWidget);
  });
}
