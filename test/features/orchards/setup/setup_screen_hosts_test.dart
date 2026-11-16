import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'setup_world.dart';

// Remote screens and setup files (4.0): a setup file has no word for
// a VNC host yet (that comes as a later file version, as FTPS came in 3.4.1).
// An export leaves a team's screens out, counted, and never writes one as an
// SSH host; a file that names a screen is a problem, and changes nothing of
// it (a team's host never changes kind class).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;

  setUpAll(SetupWorld.makeKeys);

  setUp(() async {
    world = SetupWorld();
    await world.start();
    owner = world.device(SetupWorld.owner);
    o = await world.orchard(owner);
    final gw = await owner.addHost(o.id, 'gateway', crateId: o.production, address: '10.50.0.1');
    final desk = await owner.addHost(o.id, 'desk', crateId: o.production, address: 'localhost', port: 5900, protocol: 'vnc');
    final db = await owner.db(o.id);
    await db.customStatement(
        "UPDATE orchard_sync_control SET applying = 1 WHERE id = 1");
    await db.customStatement('UPDATE connections SET connect_via_id = ? WHERE id = ?', [gw, desk]);
    await db.customStatement(
        "UPDATE orchard_sync_control SET applying = 0 WHERE id = 1");
  });

  tearDown(() => world.stop());

  test('the file has no word for a screen', () {
    expect(setupProtocolWord('vnc'), isNull);
    expect(kSetupProtocols, isNot(contains('vnc')));
  });

  test("an export leaves the team's screen out, counted, and writes its carrier as the SSH host it is", () async {
    final export = exportSetup(await owner.snapshot(o.id));
    expect(texts(export.leftOut), ['otherHosts 1']);
    final hosts = {
      for (final c in export.file.crates!)
        for (final h in c.hosts ?? const <SetupHost>[]) h.name: h.toJson()['protocol'],
    };
    expect(hosts, {'gateway': 'ssh'}, reason: 'the screen is never written, as SSH or otherwise');
    expect(export.text, isNot(contains('desk')));
    expect(export.text, isNot(contains('5900')));
  });

  test('a file that names a screen is a problem, whatever it says of it, and nothing of it is applied', () async {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final host in [
      {'name': 'desk', 'address': 'localhost', 'protocol': 'ssh'},
      {'name': 'desk', 'address': '10.50.0.9'},
      {'name': 'desk', 'protocol': 'ftps'},
    ]) {
      final plan = await owner.plan(o.id, {
        'crates': [
          {'name': 'Production', 'hosts': [host]},
        ],
      });
      expect([for (final p in plan.problems) p.kind], [SetupProblemKind.screenHost], reason: '$host');
      expect(texts(plan.steps), isEmpty, reason: '$host');
      expect(setupProblemWords(plan.problems.single, en),
          'desk in Production is a remote screen, which a setup file cannot change yet. '
          'Leave it out of the file, or add a host under a new name.');
    }
    expect((await owner.hosts(o.id)).where((h) => h.startsWith('Production/desk ')).single,
        contains('localhost:5900 vnc'));
  });
}
