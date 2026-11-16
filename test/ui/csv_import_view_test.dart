import 'dart:convert';

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart' show kCloudTreeSpace;
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_view.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_writer.dart' show CsvImportOutcome;
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart' show ImportCompatibilityOption, ImportSourceTile;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/utils/redactor.dart';

import '../helpers/orchard_db_fixture.dart';

/// Import hosts from a CSV file (3.0), driven as a person would: choose a
/// file (or paste one), see each host with what an import does with it and
/// how it signs in, untick what is not wanted, choose where they go, and
/// Import. A file that cannot be read says why, with its details where there
/// are any.

final l10n = lookupAppLocalizations(const Locale('en'));
const _ops = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _look = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

/// No Orchard on this device, but the one [_OneOrchard] stands in for.
class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

/// The Orchard of [db], open: each time after [hold] where it is set, and
/// failing with [fail] where that is set.
class _OneOrchard extends OrchardDatabasesNotifier {
  _OneOrchard(this.db) : super(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: _NoOrchards());
  final AppDatabase db;
  Future<void>? hold;
  Object? fail;

  @override
  Future<AppDatabase> open(String orchardId) async {
    if (hold != null) await hold;
    if (fail != null) throw fail!;
    return db;
  }
}

const _file = 'name,host,port,user,group,tags,key,protocol,note,owner\n'
    'Web 1,web-01.example.com,2222,,Production,web;eu,deploy key,ssh,Front end,Alex\n'
    'Builder,builder.example.com,,,,,,,,\n'
    'Again,WEB-01.example.com,2222,,,,,,,\n'
    'Cache,cache.example.com,,ops,,,Missing,mosh,,\n'
    'Broken,db.example.com,99999,,,,,,,\n';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late CsvImportResult? result;
  late bool closed;
  late List<CsvPicked?> files;
  late Object? pickError;
  final at = DateTime.utc(2026, 10, 15, 12);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    result = null;
    closed = false;
    files = [];
    pickError = null;
  });

  tearDown(() => db.close());

  CsvPicked named(String name, String text) => (name: name, bytes: utf8.encode(text));

  Future<void> open(WidgetTester tester,
      {List<Override> more = const [], bool recording = false, HostFileKind kind = HostFileKind.csv}) async {
    tester.view.physicalSize = const Size(1400, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    if (recording) {
      // Recording mode on, as the app seeds it.
      Redactor.instance
        ..enabled = true
        ..level = RedactLevel.layout;
      addTearDown(() => Redactor.instance.enabled = false);
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
        ...more,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showZestModal<CsvImportResult>(
                  context: context,
                  size: ZestModalSize.large,
                  barrierDismissible: false,
                  child: CsvImportDialog(
                      kind: kind,
                      pickFile: () async {
                        if (pickError != null) throw pickError!;
                        return files.removeAt(0);
                      }),
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
        find.text(switch (kind) {
          HostFileKind.paste => l10n.importPasteTitle,
          _ => hostFileAppIn(kind, l10n) == null ? l10n.csvImpTitle : l10n.migrateTitle(hostFileAppIn(kind, l10n)!),
        }),
        findsOneWidget);
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('csv-choose')));
    await tester.pumpAndSettle();
  }

  /// [choose], for a file large enough to be read on another isolate, off the
  /// test's clock, until [found] shows.
  Future<void> chooseLarge(WidgetTester tester, Finder found) async {
    await tester.tap(find.byKey(const ValueKey('csv-choose')));
    for (var i = 0; i < 500 && found.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(found, findsWidgets);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Finder rowOf(int line) => find.byKey(ValueKey('csv-row-$line'));

  String said(WidgetTester tester, Finder f) =>
      tester.widgetList<Text>(find.descendant(of: f, matching: find.byType(Text))).map((t) => t.data ?? '').join(' | ');

  Future<void> seed() async {
    await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
        id: 'k-deploy', label: 'Deploy Key', username: 'deploy', authMethod: 'publicKey', createdAt: at));
    await db.connectionsDao.insertConnection(ConnectionsCompanion.insert(
        id: 'mine', label: 'My builder', host: 'Builder.Example.com', createdAt: at, updatedAt: at));
  }

  testWidgets('a key that would send a host your password asks, for that host alone, naming the address', (tester) async {
    await db.identitiesDao.insertIdentity(
        IdentitiesCompanion.insert(id: 'k-root', label: 'root', username: 'root', authMethod: 'password', createdAt: at));
    FlutterSecureStorage.setMockInitialValues({'identity_password_k-root': 'made-up-password'});
    files.add(named('hosts.csv', 'name,host,key\nEvil,evil.example.com,root\nGood,good.example.com,root\n'));
    await open(tester);
    await choose(tester);
    final tick = find.byKey(const ValueKey('csv-key-password-3'));
    expect(find.text(l10n.csvImpKeyPassword('root', 'evil.example.com')), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(tick).value, isFalse, reason: 'off unless ticked');
    await tester.ensureVisible(tick);
    await tester.pumpAndSettle();
    await tester.tap(tick);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(tick).value, isTrue);
    await press(tester, l10n.cloudImpImportN(2));
    expect(closed, isTrue);
    final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c.identityId};
    expect(hosts, {'Evil': null, 'Good': 'k-root'});
  });

  testWidgets('a file chosen: each host with what an import does with it and how it signs in; the new ones ticked; '
      'Import writes them and ends with what it did', (tester) async {
    await seed();
    files.add(named('hosts.csv', _file));
    await open(tester);
    expect(find.text(l10n.csvImpHelp), findsOneWidget);
    await choose(tester);

    expect(find.text('hosts.csv'), findsOneWidget, reason: "the file's name under the title");
    expect(find.text(l10n.csvImpFound(5, 1, 1)), findsOneWidget);
    expect(find.text(l10n.csvImpIgnored('owner')), findsOneWidget);
    expect(said(tester, rowOf(2)), contains('Web 1'));
    expect(said(tester, rowOf(2)), contains('web-01.example.com:2222'));
    expect(said(tester, rowOf(2)), contains('Deploy Key (deploy) · Production · web, eu'));
    expect(said(tester, rowOf(2)), contains(l10n.cloudImpStNew));
    expect(said(tester, rowOf(3)), contains(l10n.cloudImpStHere), reason: 'the same address, in any case, and port');
    expect(said(tester, rowOf(4)), contains(l10n.csvImpTwice), reason: 'a host new here, on an earlier line too');
    expect(said(tester, rowOf(5)), contains('ops · mosh'));
    expect(said(tester, rowOf(5)), contains(l10n.csvImpKeyMissing('Missing')));
    expect(said(tester, rowOf(6)), contains(l10n.csvImpBadPort));
    for (final line in [3, 4, 6]) {
      expect(find.descendant(of: rowOf(line), matching: find.byType(Checkbox)), findsNothing,
          reason: 'only a new host can be ticked');
    }

    await press(tester, l10n.cloudImpImportN(2));
    expect(closed, isTrue);
    expect(result!.fileName, 'hosts.csv');
    expect(result!.outcome.added, 2);
    expect(result!.asCloudOutcome.added, 2);
    final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c};
    expect(hosts.keys.toSet(), {'My builder', 'Web 1', 'Cache'});
    expect(hosts['Web 1']!.identityId, 'k-deploy');
    expect((hosts['Cache']!.protocol, hosts['Cache']!.port), ('mosh', 22));
    final ops = (await db.identitiesDao.getAll()).singleWhere((i) => i.username == 'ops');
    expect(ops.label, l10n.sshConfigImportImportedIdentityLabel('ops'));
    expect(hosts['Cache']!.identityId, ops.id);
  });

  testWidgets('a host unticked is left out; Select all and Deselect all; with none ticked nothing can be imported',
      (tester) async {
    files.add(named('hosts.csv', 'host\na.example.com\nb.example.com\nc.example.com\n'));
    await open(tester);
    await choose(tester);
    expect(find.text(l10n.cloudImpImportN(3)), findsOneWidget);
    await tester.tap(find.descendant(of: rowOf(3), matching: find.byType(Checkbox)));
    await tester.pump();
    expect(find.text(l10n.cloudImpImportN(2)), findsOneWidget);
    await tester.tap(rowOf(3));
    await tester.pump();
    expect(find.text(l10n.cloudImpImportN(3)), findsOneWidget, reason: 'the whole row is the target');
    await press(tester, l10n.sshImportDeselectAll);
    expect(find.text(l10n.cloudImpImportN(0)), findsOneWidget);
    await press(tester, l10n.cloudImpImportN(0));
    expect(closed, isFalse, reason: 'nothing to import');
    await press(tester, l10n.sshImportSelectAll);
    await tester.tap(find.descendant(of: rowOf(2), matching: find.byType(Checkbox)));
    await tester.pump();
    await press(tester, l10n.cloudImpImportN(2));
    expect([for (final c in await db.connectionsDao.getAll()) c.host]..sort(), ['b.example.com', 'c.example.com']);
  });

  testWidgets('Compatibility mode for every host imported, off unless ticked, and said as not recommended',
      (tester) async {
    files.add(named('old.csv', 'host\nold-01.example.com\nold-02.example.com\n'));
    await open(tester);
    await choose(tester);
    final box = find.byKey(const ValueKey('csv-compatibility'));
    expect(tester.widget<ImportCompatibilityOption>(box).value, isFalse);
    expect(find.text(l10n.csvImpCompatibilityNote), findsOneWidget);
    await tester.tap(box);
    await tester.pump();
    await press(tester, l10n.cloudImpImportN(2));
    expect({for (final c in await db.connectionsDao.getAll()) c.host: c.compatibilityMode},
        {'old-01.example.com': true, 'old-02.example.com': true});
  });

  testWidgets('a file that cannot be read says why: too large, empty, no host column (with the columns it has), '
      'unreadable (with its details); the next one is read', (tester) async {
    files
      ..add((name: 'big.csv', bytes: utf8.encode('é' * (kCsvMaxBytes ~/ 2 + 1))))
      ..add(named('empty.csv', '\n \n'))
      ..add(named('wrong.csv', 'server name,owner\nweb,Alex\n'))
      ..add(named('fine.csv', 'host\nweb.example.com\n'));
    await open(tester);
    await chooseLarge(tester, find.text(l10n.csvImpTooLarge(5)));
    expect(find.text(l10n.csvImpTooLarge(5)), findsOneWidget);
    expect(find.text(l10n.desktopShellCopyDetails), findsNothing, reason: 'nothing more to copy');
    await choose(tester);
    expect(find.text(l10n.csvImpEmpty), findsOneWidget);
    await choose(tester);
    expect(find.text(l10n.csvImpNoHostColumn), findsOneWidget);
    expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget, reason: 'the columns it has, to copy');
    pickError = const FileSystemExceptionStandIn('the disk went away');
    await choose(tester);
    expect(find.text(l10n.csvImpUnreadable), findsOneWidget);
    expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
    pickError = null;
    await choose(tester);
    expect(find.byKey(const ValueKey('csv-problem')), findsNothing);
    expect(find.text(l10n.csvImpFound(1, 0, 0)), findsOneWidget);
  });

  testWidgets('a file with more hosts than are read says so', (tester) async {
    files.add(named('many.csv', 'host\n${List.generate(kCsvMaxHosts + 1, (i) => 'web-$i.example.com').join('\n')}'));
    await open(tester);
    await chooseLarge(tester, find.text(l10n.csvImpCut(kCsvMaxHosts)));
    expect(find.text(l10n.csvImpCut(kCsvMaxHosts)), findsOneWidget);
    expect(find.text(l10n.csvImpFound(kCsvMaxHosts, 0, 0)), findsOneWidget);
  });

  test("what an import ended with, as a cloud import's is said: how many were added, and each that was not", () {
    final outcome = CsvImportOutcome()
      ..added = 3
      ..keysMade = 1
      ..failures.add((name: 'web-9', error: 'orchard-access: refused'));
    final said = CsvImportResult(fileName: 'hosts.csv', outcome: outcome).asCloudOutcome;
    expect((said.added, said.linked, said.updated, said.gone), (3, 0, 0, 0));
    expect(said.failures, [(name: 'web-9', error: 'orchard-access: refused')]);
  });

  testWidgets('text pasted is read as a file is, under its own name; Another file goes back to choosing one',
      (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'host;user\nweb.example.com;deploy\n'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('csv-paste')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.csvImpPasted), findsOneWidget);
    expect(said(tester, rowOf(2)), contains('deploy'));
    await press(tester, l10n.csvImpAnother);
    expect(find.byKey(const ValueKey('csv-choose')), findsOneWidget);
    expect(find.text(l10n.csvImpPasted), findsNothing);
    await press(tester, l10n.cancel);
    expect(closed, isTrue);
    expect(result, isNull);
    expect(await db.connectionsDao.getAll(), isEmpty);
  });

  testWidgets("while the screen is recorded, addresses, names, users and the file's name are not shown as they are",
      (tester) async {
    files.add(named('payroll-hosts.csv', 'name,host,user\nPayroll,payroll.example.com,alex\n'));
    await open(tester, recording: true);
    await choose(tester);
    expect(find.textContaining('payroll'), findsNothing, reason: "nor the file's name");
    final row = said(tester, rowOf(2));
    expect(row, isNot(contains('payroll.example.com')));
    expect(row, isNot(contains('Payroll')));
    expect(row, isNot(contains('alex')));
  });

  testWidgets('in a build with Orchards: a Crate this account may add to is a place they can go; what is already '
      'there is worked out again for it (where it cannot be, they go where they were going), and they are written '
      'into it; nothing closes it while they are', (tester) async {
    final orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(orchard.close);
    late OrchardSummary summary;
    await tester.runAsync(() async {
      await seedOrchardAsOwner(orchard);
      Future<void> crate(String id, String name, CrateLevel level) => orchard.customStatement(
          "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, ?, 'use', ?, 1)",
          [id, name, jsonEncode(switchList(levelSwitches(level)))]);
      await crate(_ops, 'Ops', CrateLevel.manage);
      await crate(_look, 'Look', CrateLevel.connect);
      await orchard.transaction(() async {
        await CratePlacement(orchard).place('host', 'there', _ops);
        await orchard.connectionsDao.insertConnection(ConnectionsCompanion.insert(
            id: 'there', label: 'Theirs', host: 'b.example.com', createdAt: at, updatedAt: at));
      });
      summary = await readOrchardSummary(orchard, kFixtureOrchardId);
    });
    await db.connectionsDao.insertConnection(
        ConnectionsCompanion.insert(id: 'mine', label: 'Mine', host: 'a.example.com', createdAt: at, updatedAt: at));
    files.add(named('hosts.csv', 'host\na.example.com\nb.example.com\nc.example.com\n'));
    final orchards = _OneOrchard(orchard);
    await open(tester, more: [
      orchardSummariesProvider.overrideWith((ref) async => [summary]),
      orchardDatabasesProvider.overrideWith((ref) => orchards),
    ]);
    await choose(tester);
    expect(said(tester, rowOf(2)), contains(l10n.cloudImpStHere));
    expect(said(tester, rowOf(3)), contains(l10n.cloudImpStNew));
    final crate = find.byKey(const ValueKey('csv-destination-$kFixtureOrchardId/$_ops'));
    expect(find.byKey(const ValueKey('csv-destination-$kFixtureOrchardId/$kFixtureCrateId')), findsOneWidget);
    expect(find.byKey(const ValueKey('csv-destination-$kFixtureOrchardId/$_look')), findsNothing,
        reason: 'a Crate this account may not add to');
    bool chosen(Finder tile) => tester.widget<ImportSourceTile>(tile).selected;
    const tree = ValueKey('csv-destination-$kCloudTreeSpace');
    // c, new in both places, unticked by the person: it stays so.
    await tester.tap(find.descendant(of: rowOf(4), matching: find.byType(Checkbox)));
    await tester.pump();
    expect(find.text(l10n.cloudImpImportN(1)), findsOneWidget);

    // A Crate whose hosts cannot be read: said, with its details, and they
    // still go into the Tree, as worked out for it.
    orchards.fail = StateError('the Orchard is locked');
    await tester.tap(crate);
    await tester.pumpAndSettle();
    expect(find.text(l10n.csvImpCouldNotRead), findsOneWidget);
    expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
    expect(chosen(find.byKey(tree)), isTrue);
    expect(chosen(crate), isFalse);
    expect(said(tester, rowOf(2)), contains(l10n.cloudImpStHere));

    orchards.fail = null;
    await tester.tap(crate);
    await tester.pumpAndSettle();
    expect(find.text(l10n.csvImpCouldNotRead), findsNothing);
    expect(chosen(crate), isTrue);
    expect(said(tester, rowOf(2)), contains(l10n.cloudImpStNew));
    expect(said(tester, rowOf(3)), contains(l10n.cloudImpStHere));
    expect(tester.widget<Checkbox>(find.descendant(of: rowOf(4), matching: find.byType(Checkbox))).value, isFalse);
    expect(find.text(l10n.cloudImpImportN(1)), findsOneWidget, reason: 'a, new there');

    // While the hosts are being written nothing closes it: not Cancel, not
    // its close button, not the system's back.
    final gate = Completer<void>();
    orchards.hold = gate.future;
    await tester.tap(find.text(l10n.cloudImpImportN(1)));
    await tester.pump();
    expect(find.text(l10n.cloudImpImporting), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pump();
    await tester.tap(find.byTooltip(l10n.close));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(CsvImportDialog), findsOneWidget);
    expect(closed, isFalse);
    gate.complete();
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result!.outcome.added, 1);
    final written = (await orchard.connectionsDao.getAll()).singleWhere((c) => c.host == 'a.example.com');
    expect(await CratePlacement(orchard).crateOf('host', written.id), _ops, reason: 'not where new items go');
    expect([for (final c in await db.connectionsDao.getAll()) c.id], ['mine'], reason: 'the Tree is as it was');
  }, skip: !kOrchardsEnabled);

  testWidgets('from MobaXterm: its help says where its file is; its sessions are read and imported with their folders '
      'as groups', (tester) async {
    files.add(named('sessions.mxtsessions',
        '[Bookmarks]\r\nSubRep=\r\nImgNum=42\r\njump=#109#0%jump.example.com%22%ops%%-1\r\n'
        '[Bookmarks_1]\r\nSubRep=Production\r\nImgNum=41\r\nweb=#109#0%web.example.com%2222%deploy%%-1\r\n'));
    await open(tester, kind: HostFileKind.mobaxterm);
    expect(find.text('${l10n.migrateMobaHelp} ${l10n.migrateHelpRdpToo}'), findsOneWidget);
    await choose(tester);
    expect(find.text(l10n.csvImpFound(2, 0, 0)), findsOneWidget);
    expect(said(tester, rowOf(8)), contains('web.example.com:2222'));
    expect(said(tester, rowOf(8)), contains('deploy · Production'));
    await press(tester, l10n.cloudImpImportN(2));
    expect(closed, isTrue);
    expect(result!.outcome.added, 2);
    final hosts = await db.connectionsDao.getAll();
    expect({for (final h in hosts) h.label: (h.host, h.port)},
        {'jump': ('jump.example.com', 22), 'web': ('web.example.com', 2222)});
  });

  testWidgets('a Remote Desktop file, where RDP is offered: its help; one host named after the file; what the file '
      'asked for and the host will not do is said before anything is imported; the host comes in', (tester) async {
    const rdp = 'full address:s:pc.example.test:3390' '\r\n'
        'username:s:alex' '\r\n'
        'redirectclipboard:i:0' '\r\n'
        'gatewayhostname:s:gw.example.test' '\r\n'
        'gatewayusagemethod:i:1' '\r\n'
        'enablecredsspsupport:i:0' '\r\n'
        'remoteapplicationmode:i:1' '\r\n'
        'password 51:b:01000000D08C9DDF' '\r\n';
    files.add(named('Office PC.rdp', rdp));
    await open(tester, kind: HostFileKind.rdpfile, more: [rdpOfferedProvider.overrideWithValue(true)]);
    expect(find.text(l10n.migrateTitle(l10n.migrateRdpFileTitle)), findsOneWidget);
    expect(find.text(l10n.migrateRdpFileHelp), findsOneWidget);
    await choose(tester);
    expect(find.text(l10n.csvImpFound(1, 0, 0)), findsOneWidget);
    expect(said(tester, rowOf(1)), contains('pc.example.test:3390'));
    expect(find.text(l10n.rdpFileNotePassword), findsOneWidget);
    expect(find.text(l10n.rdpFileNoteProgram), findsOneWidget);
    expect(find.text(l10n.rdpFileNoteNla), findsOneWidget);
    expect(find.text(l10n.rdpFileNoteGateway('gw.example.test')), findsOneWidget);
    // Nothing of the saved password is on the screen.
    expect(find.textContaining('D08C9DDF'), findsNothing);
    await press(tester, l10n.cloudImpImportN(1));
    expect(closed, isTrue);
    expect(result!.outcome.added, 1);
    final host = (await db.connectionsDao.getAll()).single;
    expect((host.label, host.protocol, host.host, host.port), ('Office PC', 'rdp', 'pc.example.test', 3390));
    final options = ScreenOptions.decode(host.screenOptions);
    expect(options.clipboard, isFalse);
    expect(options.nla, isTrue);
  });

  testWidgets('a Remote Desktop file, where RDP is not offered: nothing of it is read, in any import', (tester) async {
    const rdp = 'full address:s:pc.example.test' '\r\n' 'username:s:alex' '\r\n';
    files.add(named('Office PC.rdp', rdp));
    await open(tester, more: [rdpOfferedProvider.overrideWithValue(false)]);
    await choose(tester);
    expect(find.text(l10n.csvImpEmpty), findsOneWidget);
    expect(find.textContaining('pc.example.test'), findsNothing);
    expect(await db.connectionsDao.getAll(), isEmpty);
  });

  testWidgets('the programs that keep Remote Desktop connections say those come in too, only where RDP is offered',
      (tester) async {
    String help() => tester.widget<Text>(find.byKey(const ValueKey('csv-help'))).data!;
    final texts = {
      HostFileKind.mobaxterm: l10n.migrateMobaHelp,
      HostFileKind.mremoteng: l10n.migrateMRemoteNgHelp,
      HostFileKind.remmina: l10n.migrateRemminaHelp,
    };
    for (final MapEntry(key: kind, value: text) in texts.entries) {
      await open(tester, kind: kind, more: [rdpOfferedProvider.overrideWithValue(false)]);
      expect(help(), text, reason: '$kind');
      await tester.pumpWidget(const SizedBox());
      await open(tester, kind: kind, more: [rdpOfferedProvider.overrideWithValue(true)]);
      expect(help(), '$text ${l10n.migrateHelpRdpToo}', reason: '$kind');
      await tester.pumpWidget(const SizedBox());
    }
    // The others keep none, and say nothing of it.
    await open(tester, kind: HostFileKind.putty, more: [rdpOfferedProvider.overrideWithValue(true)]);
    expect(help(), l10n.migratePuttyHelp);
  });

  testWidgets('a Remote Desktop file that names no computer says so, and another can be chosen', (tester) async {
    files
      ..add(named('Empty.rdp', 'full address:s:\nusername:s:alex'))
      ..add(named('Desk 4.rdp', 'full address:s:10.50.0.7'));
    await open(tester, kind: HostFileKind.rdpfile, more: [rdpOfferedProvider.overrideWithValue(true)]);
    await choose(tester);
    expect(find.text(l10n.rdpFileNoAddress), findsOneWidget);
    await choose(tester);
    expect(find.text(l10n.csvImpFound(1, 0, 0)), findsOneWidget);
    expect(said(tester, rowOf(1)), contains('Desk 4'));
  });

  testWidgets('a Remote Desktop file in recording mode: the gateway address of its note is hidden', (tester) async {
    const rdp = 'full address:s:pc.example.test' '\r\n'
        'gatewayhostname:s:gw.example.test' '\r\n'
        'gatewayusagemethod:i:1' '\r\n';
    files.add(named('Office PC.rdp', rdp));
    await open(tester,
        kind: HostFileKind.rdpfile, recording: true, more: [rdpOfferedProvider.overrideWithValue(true)]);
    await choose(tester);
    expect(find.byKey(const ValueKey('csv-note-rdpGateway')), findsOneWidget);
    expect(find.textContaining('gw.example.test'), findsNothing);
  });

  testWidgets('from SecureCRT: a file that is none of its says so in its words, and another can be chosen', (tester) async {
    files
      ..add(named('notes.txt', 'nothing to see here'))
      ..add(named('crt.xml',
          '<VanDyke version="3.0"><key name="Sessions"><key name="api"><string name="Hostname">api.example.com</string>'
          '<dword name="[SSH2] Port">22</dword></key></key></VanDyke>'));
    await open(tester, kind: HostFileKind.securecrt);
    expect(find.text(l10n.migrateCrtHelp), findsOneWidget);
    await choose(tester);
    expect(find.text(l10n.migrateNotThisApp('SecureCRT')), findsOneWidget);
    await choose(tester);
    expect(find.text(l10n.csvImpFound(1, 0, 0)), findsOneWidget);
  });

  group('Paste a list is for hosts: anything else is said, and kept nowhere', () {
    // (Made up: the shape of a key, no key.)
    const madeUpKey = '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nBG5vbmUAAAAEbm9uZQAAAA\nAAAAEAAAAzAAAAC3NzaC1\n'
        '-----END OPENSSH PRIVATE KEY-----\n';

    for (final (name, text, words, close) in <(String, String, String, String)>[
      ('a private key', madeUpKey, l10n.importPastedOther, l10n.close),
      ('a list with a private key in it', 'gate.example.com\n$madeUpKey', l10n.importPastedOther, l10n.close),
      ('SSH.com\'s form of one', '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nP2/56wAAAAA=\nabcdefgh\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n',
          l10n.importPastedOther, l10n.close),
      ('a public key', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemo demo@example.com\n', l10n.importFoundPublicKey, l10n.cancel),
      ('known_hosts', 'web1.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n', l10n.importFoundKnownHosts, l10n.close),
      ('an SSH config', 'Host web1\n  HostName 203.0.113.10\n', l10n.importFoundSshConfig, l10n.cancel),
      ('a share link', 'zestssh://add-host?host=web1.example.com&port=22\n', l10n.importFoundLink, l10n.cancel),
    ]) {
      testWidgets('$name: said, none of it read as hosts or shown, and the field left empty', (tester) async {
        await open(tester, kind: HostFileKind.paste);
        await tester.enterText(find.byKey(const ValueKey('paste-list-field')), text);
        await tester.pump();
        await press(tester, l10n.pasteListRead);
        // No row of it, nothing of it on screen.
        expect(find.byKey(const ValueKey('csv-found')), findsNothing);
        expect(rowOf(1), findsNothing);
        expect(find.text(l10n.importWrongTitle(l10n.importPasteTitle)), findsOneWidget);
        expect(find.text(words), findsOneWidget);
        expect(find.text(l10n.importReadRest), findsNothing, reason: 'pasted: there is no file to read again');
        await press(tester, close);
        expect(find.text(l10n.importWrongTitle(l10n.importPasteTitle)), findsNothing);
        expect(tester.widget<TextField>(find.byKey(const ValueKey('paste-list-field'))).controller!.text, isEmpty);
        for (final line in text.split('\n').where((l) => l.isNotEmpty)) {
          expect(find.textContaining(line), findsNothing, reason: line);
        }
      });
    }

    testWidgets('another app\'s file pasted: read as that app\'s, and the list goes on to its hosts', (tester) async {
      await open(tester, kind: HostFileKind.paste);
      await tester.enterText(find.byKey(const ValueKey('paste-list-field')), '[Bookmarks]\nSubRep=\nweb1=#109#0%203.0.113.10%22%deploy%%-1%-1%\n');
      await tester.pump();
      await press(tester, l10n.pasteListRead);
      expect(find.byKey(const ValueKey('csv-found')), findsOneWidget);
      expect(find.textContaining('203.0.113.10'), findsOneWidget);
    });

    testWidgets('a list of hosts is still that', (tester) async {
      await open(tester, kind: HostFileKind.paste);
      await tester.enterText(find.byKey(const ValueKey('paste-list-field')), 'web-01.example.com\nweb-02.example.com\n');
      await tester.pump();
      await press(tester, l10n.pasteListRead);
      expect(said(tester, rowOf(1)), contains('web-01.example.com'));
      expect(said(tester, rowOf(2)), contains('web-02.example.com'));
    });
  });

  testWidgets('Paste a list: each line read as a host, one already here and one twice not ticked, a line that is no host '
      'named by its number; Edit the list goes back to the text as it was; only comments say there is no host',
      (tester) async {
    await seed();
    await open(tester, kind: HostFileKind.paste);
    expect(find.text(l10n.pasteListHelp), findsOneWidget);
    await press(tester, l10n.pasteListRead);
    expect(find.byKey(const ValueKey('csv-found')), findsNothing, reason: 'nothing pasted yet');
    const list = 'deploy@web-01.example.com:2222\nbuilder.example.com\nhost:99999\nweb-01.example.com:2222\n';
    await tester.enterText(find.byKey(const ValueKey('paste-list-field')), list);
    await tester.pump();
    await press(tester, l10n.pasteListRead);

    expect(find.text(l10n.csvImpFound(4, 1, 1)), findsOneWidget);
    expect(said(tester, rowOf(1)), contains('web-01.example.com:2222'));
    expect(said(tester, rowOf(1)), contains(l10n.cloudImpStNew));
    expect(said(tester, rowOf(2)), contains(l10n.cloudImpStHere));
    expect(said(tester, rowOf(3)), contains('${l10n.csvImpLine(3)} · host:99999'));
    expect(said(tester, rowOf(4)), contains(l10n.csvImpTwice));
    expect(find.text(l10n.importPasteTitle), findsOneWidget, reason: 'no file name under the title');

    await press(tester, l10n.pasteListEdit);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('paste-list-field'))).controller!.text, list);
    await press(tester, l10n.pasteListRead);
    await press(tester, l10n.cloudImpImportN(1));
    expect(closed, isTrue);
    expect(result!.outcome.added, 1);
    final web = (await db.connectionsDao.getAll()).singleWhere((c) => c.host == 'web-01.example.com');
    expect((web.port, web.label), (2222, 'web-01.example.com'));

    closed = false;
    await open(tester, kind: HostFileKind.paste);
    await tester.enterText(find.byKey(const ValueKey('paste-list-field')), '# old servers\n\n# none left\n');
    await tester.pump();
    await press(tester, l10n.pasteListRead);
    expect(find.text(l10n.pasteListEmpty), findsOneWidget);
  });

}

/// What a file system says when a file cannot be read.
class FileSystemExceptionStandIn implements Exception {
  const FileSystemExceptionStandIn(this.message);
  final String message;

  @override
  String toString() => 'FileSystemException: $message';
}
