import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/orchard_db_fixture.dart';

/// The VNC host kind (4.0): a host of its own kind whose
/// options live in connections.screen_options. Everything that needs a
/// terminal passes it over with a reason, and the column it adds travels only
/// where it is set, so an SSH host's team record and synced JSON stay byte for
/// byte what 3.4 writes.
Connection _host(String protocol, {String? screenOptions}) => Connection(
      id: 'h-$protocol',
      label: 'desk-01',
      host: 'localhost',
      port: protocol == 'vnc' ? 5900 : 22,
      colorIndex: 0,
      protocol: protocol,
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      screenOptions: screenOptions,
      createdAt: DateTime(2026, 11, 9),
      updatedAt: DateTime(2026, 11, 9),
    );

/// A team host's record as 3.4 wrote it for this host (orchard_db_fixture's
/// owner, the row below): every column of connections at schema v54 that
/// travels (not the device's own: order, size, pins, monitoring, when last
/// connected), and no other.
const _sshRecord34 = '{"connections":[{"id":"h1","label":"web","host":"10.0.0.1","port":22,'
    '"identity_id":null,"group_id":null,"color_index":0,"color_value":null,"protocol":"ssh",'
    '"zlib_compression":0,"startup_command":null,"snippet_id":null,"connect_via_id":null,'
    '"keep_alive_seconds":0,"wol_mac_address":null,"wol_broadcast_address":"255.255.255.255",'
    '"wol_port":9,"env_vars":"","forward_agent":0,"compatibility_mode":0,'
    '"icon_id":null,"custom_icon":null,"icon_color":null,"note":null,'
    '"cloud_source":null,"created_at":1762675200}],'
    '"connection_tags":[],"host_network_overrides":[],"host_accounts":[]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final all = [for (final locale in AppLocalizations.supportedLocales) lookupAppLocalizations(locale)];

  group('what needs a terminal passes a screen over, with a reason', () {
    test('a screen is never files only, runs no command, and is in no All hosts', () {
      expect(opensFilesOnly('vnc'), isFalse);
      expect(runsCommands('vnc'), isFalse);
      expect(reachedByAllHosts('vnc'), isFalse);
    });

    test('monitors, runs, snippets, broadcast and forwards say why', () {
      final screen = _host('vnc');
      expect(noTerminalReason(screen, en), en.hostScreenNoTerminal);
      expect(noCommandReason(screen, en), en.hostScreenNoTerminal);
      expect(noRunOnHostsReason(screen, en), en.hostScreenNoTerminal);
      // Said of a VNC host and of an RDP host alike: it names no kind.
      expect(en.hostScreenNoTerminal, 'This host is a remote screen: it gives no terminal.');
      for (final rdp in [_host('rdp')]) {
        expect(noTerminalReason(rdp, en), en.hostScreenNoTerminal);
        expect(noCommandReason(rdp, en), en.hostScreenNoTerminal);
      }
      for (final l10n in all) {
        for (final text in [l10n.hostScreenNoTerminal, l10n.teamHostKindFixed, l10n.knownHostsScreenCertificate]) {
          expect(text, isNot(contains('VNC')), reason: l10n.localeName);
          expect(text, isNot(contains('  ')), reason: l10n.localeName);
        }
      }
      // Nothing changes for the others.
      expect(noTerminalReason(_host('ftps'), en), en.hostFtpsNoTerminal);
      for (final other in ['ssh', 'mosh', 'et', 'telnet', 'serial']) {
        expect(noTerminalReason(_host(other), en), isNull, reason: other);
      }
      expect(ConnectionProtocol.vnc.nameIn(en), 'VNC');
    });
  });

  group("the column travels only where it is set", () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      await seedOrchardAsOwner(db);
    });
    tearDown(() => db.close());

    Future<void> insert(String id, String protocol, {String? options}) =>
        db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: id == 'h1' ? 'web' : 'desk',
              host: id == 'h1' ? '10.0.0.1' : 'localhost',
              port: Value(protocol == 'vnc' ? 5900 : 22),
              protocol: Value(protocol),
              screenOptions: Value(options),
              createdAt: DateTime.utc(2025, 11, 9, 8),
              updatedAt: DateTime.utc(2025, 11, 9, 8),
            ));

    test("an SSH host's team record is byte for byte the one 3.4 writes", () async {
      await insert('h1', 'ssh');
      final record = await OrchardItemStore(db).read('host', 'h1');
      expect(jsonEncode(record), _sshRecord34);
    });

    test("a screen's record carries its options; a record without them clears them", () async {
      final options = ScreenOptions.defaults.copyWith(viewOnly: true).encode();
      await insert('s1', 'vnc', options: options);
      final store = OrchardItemStore(db);
      final record = (await store.read('host', 's1'))!;
      final row = (record['connections'] as List).single as Map<String, Object?>;
      expect(row['screen_options'], options);
      expect(row['protocol'], 'vnc');

      // Written back as a record that leaves the column out (a member's edit
      // that cleared it): it is cleared, not left as it was.
      await db.transaction(() async {
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        final without = {
          ...record,
          'connections': [Map.of(row)..remove('screen_options')],
        };
        await store.write('host', 's1', data: without, editedAt: DateTime.utc(2025, 11, 10).millisecondsSinceEpoch);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      });
      expect((await db.connectionsDao.getById('s1'))!.screenOptions, isNull);
    });

    test("a record's options are taken only on a screen, and only as a JSON object within the bound", () async {
      final store = OrchardItemStore(db);
      Future<String?> written(String protocol, Object? options, {String id = 'x1'}) async {
        await db.transaction(() async {
          await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
          await store.write('host', id,
              data: {
                'connections': [
                  {
                    'id': id,
                    'label': 'x',
                    'host': 'localhost',
                    'port': 5900,
                    'protocol': protocol,
                    'screen_options': options,
                    'created_at': 1762675200,
                  },
                ],
              },
              editedAt: 1762675200000);
          await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
        });
        return (await db.connectionsDao.getById(id))!.screenOptions;
      }

      const ok = '{"v":1,"scaling":"fit","later":[1]}';
      expect(await written('vnc', ok), ok, reason: 'taken as it came');
      expect(await written('vnc', '[1]'), isNull);
      expect(await written('vnc', 'x' * 5000), isNull);
      // Another host: a record never turns a screen into an SSH host.
      expect(await written('ssh', ok, id: 'x2'), isNull, reason: 'options belong to a screen alone');
      await expectLater(written('ssh', ok), throwsA(isA<RecordRefused>()));
      expect((await db.connectionsDao.getById('x1'))!.protocol, 'vnc');
      // Nor into an RDP host (4.0: a kind of its own), nor an RDP host
      // into a VNC one; an RDP host's record carries its options as a screen's.
      await expectLater(written('rdp', ok), throwsA(isA<RecordRefused>()));
      expect((await db.connectionsDao.getById('x1'))!.protocol, 'vnc');
      const withoutNla = '{"v":1,"nla":false}';
      expect(await written('rdp', withoutNla, id: 'r1'), withoutNla);
      await expectLater(written('vnc', ok, id: 'r1'), throwsA(isA<RecordRefused>()));
      await expectLater(written('ssh', ok, id: 'r1'), throwsA(isA<RecordRefused>()));
      expect((await db.connectionsDao.getById('r1'))!.protocol, 'rdp');
      expect((await db.connectionsDao.getById('r1'))!.screenOptions, withoutNla);
    });
  });

  group('personal sync', () {
    test("an SSH host's JSON has no screenOptions; a screen's carries them", () {
      final ssh = SyncDataService.hostJson(_host('ssh'));
      expect(ssh.containsKey('screenOptions'), isFalse);
      // A team's shared bookmarks travel only in the team's record, never in
      // personal sync (4.0).
      expect(ssh.keys.toSet(), _host('ssh').toJson().keys.toSet().difference({'screenOptions', 'sharedPins'}));
      final options = ScreenOptions.encodeDefaults();
      expect(SyncDataService.hostJson(_host('vnc', screenOptions: options))['screenOptions'], options);
    });
  });
}
