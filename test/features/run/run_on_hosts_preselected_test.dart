import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/run/install_key_view.dart';
import 'package:zestssh/features/run/run_client.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';

import '../../helpers/desktop_mouse.dart';
import '../../helpers/monitor_table_fixture.dart';

/// Hosts handed to Run on hosts and to Broadcast (the Server monitor's Run snippet
/// on these and Broadcast to these): the last command typed was ready to run on
/// them; a run that was showing dropped them; and an SFTP-only host counted among
/// them, though it cannot be ticked.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget Function(BuildContext context) child, {Completer<RunClient>? gate}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    await tester.runAsync(() => (db.update(db.connections)..where((t) => t.id.equals('build')))
        .write(const ConnectionsCompanion(protocol: Value('sftp'))));
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(
      [
        ...fleet.overrides(db, prefs),
        runOnHostsProvider.overrideWith(
            (ref) => RunOnHostsNotifier((host) => gate == null ? Future<RunClient>.error(Exception('no')) : gate.future)),
      ],
      Builder(builder: (context) {
        container = ProviderScope.containerOf(context);
        return child(context);
      }),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  Future<List<Connection>> hosts(WidgetTester tester, Set<String> ids) async {
    final all = (await tester.runAsync(() => db.select(db.connections).get()))!;
    return [for (final c in all) if (ids.contains(c.id)) c];
  }

  Widget opener(BuildContext context, {Set<String>? preselected}) =>
      TextButton(onPressed: () => showRunOnHosts(context, preselected: preselected), child: const Text('open'));

  String command(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const ValueKey('run-command'))).controller!.text;

  desktopTest('hosts handed over start with an empty command, never the last one typed', (tester) async {
    await pump(tester, (context) => opener(context, preselected: {'web2', 'db', 'hva'}));
    final last = await hosts(tester, {'web1'});
    await tester.runAsync(() => container.read(runOnHostsProvider.notifier).run(last, 'sudo reboot'));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(command(tester), isEmpty);
    expect(find.text(en.runOnHostsRun(3)), findsOneWidget);
    await finish(tester);
  });

  desktopTest('opened with no hosts handed over, the last command stands, on its hosts', (tester) async {
    await pump(tester, (context) => opener(context));
    final last = await hosts(tester, {'web1'});
    await tester.runAsync(() => container.read(runOnHostsProvider.notifier).run(last, 'uptime', typed: 'uptime'));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.tap(find.text(en.runOnHostsNew));
    await settle(tester);
    expect(command(tester), 'uptime');
    expect(find.text(en.runOnHostsRun(1)), findsOneWidget);
    await finish(tester);
  });

  desktopTest('a run showing as it opens: New opens on the hosts asked for, with no command', (tester) async {
    final gate = Completer<RunClient>();
    await pump(tester, (context) => opener(context, preselected: {'web2'}), gate: gate);
    final going = await hosts(tester, {'web1', 'db', 'hva', 'hvb', 'mon'});
    unawaited(container.read(runOnHostsProvider.notifier).run(going, 'uptime', typed: 'uptime'));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.byKey(const ValueKey('run-command')), findsNothing, reason: 'the run going is shown');
    gate.completeError(Exception('no'));
    await settle(tester);
    await tester.tap(find.text(en.runOnHostsNew));
    await settle(tester);
    expect(find.text(en.runOnHostsRun(1)), findsOneWidget);
    expect(find.text(en.runOnHostsRun(5)), findsNothing);
    expect(command(tester), isEmpty);
    await finish(tester);
  });

  desktopTest('an SFTP-only host handed to Run on hosts is not counted, and not run on', (tester) async {
    await pump(tester, (context) => opener(context, preselected: {'web2', 'build'}));
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text(en.runOnHostsRun(1)), findsOneWidget);
    expect(find.text(en.runOnHostsRun(2)), findsNothing);
    await finish(tester);
  });

  for (final protocol in const ['telnet', 'serial', 'mosh', 'et']) {
    desktopTest('a $protocol host handed to Run on hosts is not counted, and cannot be ticked: it could only fail', (tester) async {
      await pump(tester, (context) => opener(context, preselected: {'web2', 'cache'}));
      await tester.runAsync(() => (db.update(db.connections)..where((t) => t.id.equals('cache')))
          .write(ConnectionsCompanion(protocol: Value(protocol))));
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text(en.runOnHostsRun(1)), findsOneWidget);
      expect(find.text(en.runOnHostsRun(2)), findsNothing);
      expect(find.byKey(const ValueKey('run-host-cache-no-terminal')), findsOneWidget);
      expect(find.text(en.runOnHostsSshOnly), findsOneWidget);
      await finish(tester);
    });
  }

  desktopTest('Install a key on hosts runs on SSH hosts alone too: another cannot be ticked', (tester) async {
    await pump(tester, (context) => SizedBox(
          height: 900,
          child: InstallKeyDialog(
            keyToInstall: Identity(
              id: 'k1',
              label: 'Deploy key',
              username: 'deploy',
              authMethod: 'publicKey',
              publicKeyData: 'ssh-ed25519 AAAAmadeup deploy@example.com',
              colorIndex: 0,
              isDefault: false,
              allowUnattended: false,
              usesAgent: false,
              passwordAfterKey: false,
              createdAt: DateTime(2026),
            ),
          ),
        ));
    await tester.runAsync(() => (db.update(db.connections)..where((t) => t.id.equals('cache')))
        .write(const ConnectionsCompanion(protocol: Value('telnet'))));
    await settle(tester);
    expect(find.byKey(const ValueKey('install-host-cache-no-terminal')), findsOneWidget);
    expect(find.byKey(const ValueKey('install-host-web2-no-terminal')), findsNothing);
    await finish(tester);
  });

  desktopTest('an SFTP-only host handed to Broadcast is not counted, and not opened', (tester) async {
    await pump(tester, (_) => const BroadcastToHostsDialog(preselected: {'web2', 'build'}));
    expect(find.text(en.broadcastToHostsOpen(1)), findsOneWidget);
    expect(find.text(en.broadcastToHostsOpen(2)), findsNothing);
    await finish(tester);
  });
}
