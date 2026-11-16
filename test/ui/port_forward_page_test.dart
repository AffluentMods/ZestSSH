import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_edit_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The computer's Port forwarding page as its design
/// draws it: the rules by state with how many, each with where it goes
/// and Start or Stop; a new rule's editor with the two ends and what happens,
/// "Let other machines reach it" with what it means, the same command for
/// OpenSSH, and Save and start. (All names and addresses made up.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
        final at = DateTime(2026, 10, 1);
        for (final (id, label, address) in [('mon', 'monitoring', '192.168.10.60'), ('api', 'web-01', '192.168.10.21')]) {
          await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id, label: label, host: address, createdAt: at, updatedAt: at));
        }
        for (final (id, type, port, label) in [
          ('pf-prom', 'local', 9090, 'Prometheus'),
          ('pf-socks', 'dynamic', 1080, 'Browsing proxy'),
        ]) {
          await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
                id: id,
                connectionId: 'mon',
                type: type,
                bindPort: port,
                remoteHost: type == 'dynamic' ? '' : 'localhost',
                remotePort: type == 'dynamic' ? 0 : port,
                label: Value(label),
                autoStart: Value(id == 'pf-prom'),
                createdAt: at,
              ));
        }
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<ProviderContainer> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed(tester);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      activeForwardIdsProvider.overrideWith((ref) => {'pf-prom'}),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: PortForwardListView()),
      ),
    ));
    await settle(tester);
    return container;
  }

  testWidgets('the rules by state, with how many; each says where it goes, via which host', (tester) async {
    await open(tester);
    expect(find.text(en.pfPageFilterAll(2)), findsOneWidget);
    expect(find.text(en.pfPageFilterRunning(1)), findsOneWidget);
    expect(find.text(en.pfPageFilterStopped(1)), findsOneWidget);
    expect(find.text('localhost:9090 → monitoring:9090'), findsOneWidget);
    expect(find.text(en.pfPageSocksOn('localhost:1080')), findsOneWidget);
    expect(find.text('${en.pfPageVia('monitoring')} · ${en.pfPageStartsOnConnect}'), findsOneWidget);
    expect(find.text(en.pfPageOpen('localhost:9090')), findsOneWidget, reason: 'a running local forward opens');
    expect(find.byKey(const ValueKey('pf-stop-pf-prom')), findsOneWidget);
    expect(find.byKey(const ValueKey('pf-start-pf-socks')), findsOneWidget);

    await tester.tap(find.text(en.pfPageFilterRunning(1)));
    await settle(tester);
    expect(find.text('Prometheus'), findsOneWidget);
    expect(find.text('Browsing proxy'), findsNothing);
    await tester.tap(find.text(en.pfPageFilterStopped(1)));
    await settle(tester);
    expect(find.text('Prometheus'), findsNothing);
    expect(find.text('Browsing proxy'), findsOneWidget);
  });

  Future<void> fillRemote(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('pf-intent-remote')));
    await settle(tester);
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('pf-name')), matching: find.byType(EditableText)), 'Dev database');
    await tester.tap(find.text(en.zestPfChooseConnection));
    await settle(tester);
    await tester.tap(find.text('web-01').last);
    await settle(tester);
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('pf-port-here')), matching: find.byType(EditableText)), '3000');
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('pf-port-server')), matching: find.byType(EditableText)), '8080');
    await settle(tester);
  }

  testWidgets('a new rule: the two ends, what happens, who may reach it, the command for OpenSSH', (tester) async {
    await open(tester);
    await fillRemote(tester);
    expect(find.text(en.pfPageSentenceRemote('web-01', 8080, 3000)), findsOneWidget);
    expect(find.text(en.pfPageOthersOffServer('web-01', 8080)), findsOneWidget);
    expect(find.textContaining('-R 8080:localhost:3000'), findsOneWidget);

    // (Brought into view: with a finger's 48 high controls the form is taller.)
    await tester.ensureVisible(find.byKey(const ValueKey('pf-let-others')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pf-let-others')));
    await settle(tester);
    expect(find.text(en.pfPageOthersOnServer('web-01', 8080)), findsOneWidget);
    expect(find.textContaining('-R 0.0.0.0:8080:localhost:3000'), findsOneWidget,
        reason: 'the host is asked for every address, as the forward asks it');
    expect(find.textContaining(' -g '), findsNothing, reason: '-g is for a port this device listens on');
  });

  testWidgets('Save and start keeps the rule and starts it: with no session open, it asks to connect', (tester) async {
    await open(tester);
    await fillRemote(tester);
    await tester.tap(find.byKey(const ValueKey('pf-save-start')));
    await settle(tester);
    final rules = await tester.runAsync(() => db.portForwardRulesDao.getAll());
    final saved = rules!.singleWhere((r) => r.label == 'Dev database');
    expect((saved.type, saved.bindPort, saved.remotePort, saved.connectionId), ('remote', 3000, 8080, 'api'));
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.text(en.portForwardListConnectTitle('web-01')), findsOneWidget);
  });

  test('the command: -g for a port here, every address of the host for a port there', () {
    String cmd(PfForwardType type) => buildForwardCommand(
          type: type,
          bindAddress: 'localhost',
          bindPort: 3000,
          remoteHost: 'localhost',
          remotePort: 8080,
          host: 'srv',
          username: 'u',
          gatewayPorts: true,
        );
    expect(cmd(PfForwardType.local), 'ssh -N -f -g -L 3000:localhost:8080 u@srv');
    expect(cmd(PfForwardType.remote), 'ssh -N -f -R 0.0.0.0:8080:localhost:3000 u@srv');
  });
}
