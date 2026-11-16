import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/triggers/widgets/trigger_edit_dialog.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/redactor.dart';

/// Recording mode on the host picker: the one row of a host every "pick a
/// connection" dialog is built from (SFTP server picker, the terminal-pane
/// picker, the automation wizard's host list, the desktop pane placeholder). A
/// release build leaked the raw label and `host:port` here, so the row is pumped
/// on its own with constructor data, and then the whole picker dialog is
/// pumped over a seeded database, and every string the framework would paint
/// or announce is checked against every seed value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // The fleet. The third host has no label, so the row titles it by its
  // bare address (a separate code path in the row).
  const hostLabels = ['Hypervisor Node3', 'app-server-01', ''];
  const hostAddrs = ['10.50.0.24', 'nas.home', '192.168.7.3'];
  const secrets = ['Hypervisor Node3', 'app-server-01', ...hostAddrs];

  late SharedPreferences prefs;

  Future<void> setMode(bool on) async {
    SharedPreferences.setMockInitialValues({'recording_mode_enabled': on});
    prefs = await SharedPreferences.getInstance();
    Redactor.instance
      ..clearNames()
      ..enabled = on
      ..level = RedactLevel.layout
      ..registerNames(hostLabels.where((l) => l.isNotEmpty))
      ..registerAddresses(hostAddrs);
  }

  setUp(() => setMode(true));

  tearDown(() {
    Redactor.instance
      ..clearNames()
      ..enabled = false;
  });

  ConnectionWithDetails conn(int i) {
    final now = DateTime(2026, 1, 1);
    return ConnectionWithDetails(
      connection: Connection(
        id: 'c$i',
        label: hostLabels[i],
        host: hostAddrs[i],
        port: 22,
        colorIndex: 0,
        protocol: 'ssh',
        zlibCompression: false,
        keepAliveSeconds: 0,
        envVars: '',
        forwardAgent: false,
        compatibilityMode: false,
        sortOrder: i,
        sizeTier: 1,
        pinned: false,
        monitored: false,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Every string the framework would paint or announce for the pumped tree.
  List<String> renderedStrings(WidgetTester tester) {
    final out = <String>[];
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      out.add(t.data ?? t.textSpan?.toPlainText() ?? '');
      if (t.semanticsLabel != null) out.add(t.semanticsLabel!);
    }
    for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
      out.add(r.text.toPlainText());
    }
    for (final tip in tester.widgetList<Tooltip>(find.byType(Tooltip))) {
      out.add(tip.message ?? tip.richMessage?.toPlainText() ?? '');
    }
    for (final s in tester.widgetList<Semantics>(find.byType(Semantics))) {
      final label = s.properties.label;
      if (label != null) out.add(label);
    }
    return out;
  }

  void expectNoSecret(WidgetTester tester, String screen) {
    final all = renderedStrings(tester);
    expect(all, isNotEmpty, reason: '$screen rendered nothing');
    for (final s in all) {
      for (final secret in secrets) {
        expect(s.toLowerCase(), isNot(contains(secret.toLowerCase())),
            reason: '$screen leaked "$secret" in "$s"');
      }
    }
  }

  /// Fails on any exception except a RenderFlex overflow: the test font
  /// draws every glyph one em wide, so labels that fit a real font overflow
  /// here, and that is not what this test is about.
  void expectNoRealException(WidgetTester tester, String screen) {
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'),
          reason: '$screen threw: $ex');
    }
  }

  Widget scope(Widget child, {List<Override> overrides = const []}) =>
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ...overrides,
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(width: 480, height: 600, child: child),
          ),
        ),
      );

  Widget tiles() => Column(
        children: [
          for (var i = 0; i < hostLabels.length; i++)
            HostRow(
              host: conn(i).connection,
              user: 'deploy',
              // One row in the "already open" state, so the hint is exercised
              // too.
              open: i == 0,
              openLabel: 'Already open',
              showOpenLabel: true,
              onTap: () {},
            ),
        ],
      );

  testWidgets('the row of a host renders no label or address while recording',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 600));
    await tester.pumpWidget(scope(tiles()));
    await tester.pump();
    expectNoRealException(tester, 'host row');

    final texts = renderedStrings(tester).join('\n');
    // The label goes through the name rule, the addresses through the
    // address rule, and the user beside them through its own.
    expect(texts, contains('Hy000e3'), reason: 'label masked by the 3a rule');
    expect(texts, contains(RegExp(r'192\.0\.2\.\d+')),
        reason: 'an IPv4 masks into TEST-NET-1');
    expect(texts, contains(RegExp(r'host-\d\d\.example\.invalid')),
        reason: 'a DNS name masks into the reserved TLD');
    expectNoSecret(tester, 'host row');
  });

  testWidgets('the row of a host shows the real label and address with the mode off',
      (tester) async {
    await setMode(false);
    await tester.binding.setSurfaceSize(const Size(480, 600));
    await tester.pumpWidget(scope(tiles()));
    await tester.pump();
    expectNoRealException(tester, 'host row, mode off');

    final texts = renderedStrings(tester).join('\n');
    expect(texts, contains('Hypervisor Node3'));
    expect(texts, contains('deploy@10.50.0.24'));
    expect(texts, contains('deploy@nas.home'));
    // No label: the bare address is the title, and it is not masked.
    expect(texts, contains('192.168.7.3'));
  });

  testWidgets('the connection picker dialog renders no fleet value while recording',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime(2026, 1, 1);
    for (var i = 0; i < hostLabels.length; i++) {
      // The table requires a label; a host saved without one gets its
      // address as the label, which is exactly the address-shaped name the
      // name rule must not keep the digits of.
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'c$i',
            label: hostLabels[i].isEmpty ? hostAddrs[i] : hostLabels[i],
            host: hostAddrs[i],
            port: const Value(22),
            createdAt: now,
            updatedAt: now,
          ));
    }

    await tester.binding.setSurfaceSize(const Size(600, 700));
    await tester.pumpWidget(scope(
      const ConnectionPickerDialog(title: 'Pick a connection'),
      overrides: [databaseProvider.overrideWithValue(db)],
    ));
    // DB streams deliver on later frames; give them a few.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectNoRealException(tester, 'connection picker');

    final texts = renderedStrings(tester).join('\n');
    expect(texts, contains('Hy000e3'), reason: 'host rows rendered, masked');
    expectNoSecret(tester, 'connection picker');

    // Unmount so widgets cancel their DB streams, flush, then close the
    // database. Inside the body on purpose: the framework checks for pending
    // timers before any tearDown runs.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  });

  testWidgets("a trigger's select of hosts renders no fleet value while recording",
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    await tester.pumpWidget(scope(Builder(
      builder: (context) => TextButton(
        onPressed: () => showTriggerEditDialog(
          context: context,
          connections: [for (var i = 0; i < hostLabels.length; i++) conn(i).connection],
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byType(ZestSelect<String?>));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectNoRealException(tester, "a trigger's select");

    final texts = renderedStrings(tester).join('\n');
    expect(texts, contains('Hy000e3'), reason: 'the hosts are in the menu, masked');
    expectNoSecret(tester, "a trigger's select");
  });
}
