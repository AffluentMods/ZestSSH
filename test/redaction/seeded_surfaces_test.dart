import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/host_slide_out_panel.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/screens/identity/identity_list_screen.dart';
import 'package:zestssh/utils/redactor.dart';

/// The second half of the recording-mode golden test: the surfaces that
/// read the fleet from the DATABASE rather than from constructor arguments.
/// A real fleet is seeded into an in-memory database, the mode is on, and
/// every string the framework would paint or announce is checked against
/// every seed value. These are exactly the surfaces a user found leaking on
/// a release build: the hosts drawer, the Keys page with its saved passwords
/// and their usernames, the identity list, the server monitor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const hostLabels = ['Hypervisor Node3', 'app-server-01', 'Firewall-1', 'lb-2'];
  const hostAddrs = ['10.50.0.24', '10.50.0.25', 'firewall.home', '10.77.0.10'];
  const groupName = 'Edge Security';
  const username = 'alex';
  const keyName = 'Alex Desktop';
  const passwordLabel = 'root@10.77.0.10';
  const passwordUser = 'rootadmin';
  const keyComment = 'ops@mac-studio';
  const fingerprint = 'SHA256:Aq65otBkq++WRjtuKV+Xxu5fTMXxuE3isnjpem4u3xs=';
  const secrets = [
    ...hostLabels,
    ...hostAddrs,
    groupName,
    username,
    keyName,
    passwordLabel,
    passwordUser,
    keyComment,
    'Aq65otBkq',
    'mac-studio',
  ];

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
    prefs = await SharedPreferences.getInstance();
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerNames([...hostLabels, groupName])
      ..registerAddresses(hostAddrs);
  });

  tearDown(() {
    Redactor.instance
      ..clearNames()
      ..enabled = false;
  });

  Future<AppDatabase> seed() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime(2026, 1, 1);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
        id: 'g1', name: groupName, createdAt: now));
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'i-key',
          label: keyName,
          username: username,
          authMethod: 'publicKey',
          keyType: const Value('ed25519'),
          publicKeyFingerprint: const Value(fingerprint),
          publicKeyData: const Value('ssh-ed25519 AAAAC3Nza $keyComment'),
          createdAt: now,
        ));
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'i-pass',
          label: passwordLabel,
          username: passwordUser,
          authMethod: 'password',
          createdAt: now,
        ));
    for (var i = 0; i < hostLabels.length; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'c$i',
            label: hostLabels[i],
            host: hostAddrs[i],
            port: const Value(22),
            identityId: Value(i.isEven ? 'i-key' : 'i-pass'),
            groupId: Value(i < 2 ? 'g1' : null),
            monitored: const Value(true),
            createdAt: now,
            updatedAt: now,
          ));
    }
    return db;
  }

  List<String> renderedStrings(WidgetTester tester) {
    final out = <String>[];
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      out.add(t.data ?? t.textSpan?.toPlainText() ?? '');
      if (t.semanticsLabel != null) out.add(t.semanticsLabel!);
    }
    for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
      out.add(r.text.toPlainText());
    }
    for (final e in tester.widgetList<EditableText>(find.byType(EditableText))) {
      out.add(e.controller.text);
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

  Widget scope(AppDatabase db, Widget child,
          {Size size = const Size(1200, 800)}) =>
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          // The monitor must not open real SSH connections to the seed
          // addresses from a widget test.
          serverStatsProvider.overrideWith((ref) => _StubStats(ref)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
                width: size.width, height: size.height, child: child),
          ),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    // DB streams deliver on later frames; give them a few.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Unmount the tree so widgets cancel their timers and DB streams, flush
  /// what is left, then close the database. Inside the body on purpose: the
  /// framework checks for pending timers before any tearDown runs.
  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  testWidgets('the hosts drawer masks group names and host rows',
      (tester) async {
    final db = await seed();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(scope(
        db,
        Row(children: [
          HostSlideOutPanel(
            onConnectTo: (_) {},
            onManageHosts: () {},
            onClose: () {},
          ),
          const Expanded(child: SizedBox()),
        ])));
    await settle(tester);
    expectNoRealException(tester, 'hosts drawer');
    final texts = renderedStrings(tester).join('\n');
    expect(texts, contains('Hy000e3'), reason: 'host rows rendered, masked');
    expectNoSecret(tester, 'hosts drawer');
    await finish(tester, db);
  });

  testWidgets('the Keys page masks key names, saved passwords and usernames',
      (tester) async {
    final db = await seed();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(
        scope(db, const KeysView(), size: const Size(1400, 900)));
    await settle(tester);
    expectNoRealException(tester, 'Keys page');
    final texts = renderedStrings(tester).join('\n');
    expect(texts, matches(RegExp(r'key-\d\d')), reason: 'identity rows rendered');
    expectNoSecret(tester, 'Keys page');

    // Opening the key shows the editor: still nothing real on screen.
    final row = find.text(Redactor.keyName(keyName));
    if (row.evaluate().isNotEmpty) {
      await tester.tap(row.first);
      await settle(tester);
      expectNoRealException(tester, 'Keys page, identity open');
      expectNoSecret(tester, 'Keys page, identity open');
    }
    await finish(tester, db);
  });

  testWidgets('the mobile identity list masks every identity', (tester) async {
    final db = await seed();
    await tester.binding.setSurfaceSize(const Size(420, 900));
    await tester.pumpWidget(
        scope(db, const IdentityListScreen(), size: const Size(420, 900)));
    await settle(tester);
    expectNoRealException(tester, 'identity list');
    final texts = renderedStrings(tester).join('\n');
    expect(texts, matches(RegExp(r'key-\d\d')), reason: 'identity rows rendered');
    expectNoSecret(tester, 'identity list');
    await finish(tester, db);
  });

  testWidgets('the server monitor table masks host names and addresses',
      (tester) async {
    final db = await seed();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(
        scope(db, const MonitorTableView(), size: const Size(1400, 900)));
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expectNoRealException(tester, 'monitor table');
    // The table lists hosts only once a first poll has produced stats; with
    // polling stubbed it may stay on its empty state. Either way, nothing
    // real may be on screen.
    expectNoSecret(tester, 'monitor table');
    await finish(tester, db);
  });
}

/// A stats notifier that never polls: the table under test only has to
/// paint the hosts it is given.
class _StubStats extends ServerStatsNotifier {
  _StubStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}
