import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/screens/session/screen_trust.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A remote screen's VeNCrypt certificate (4.0): trusted on
/// first use as FTPS's is, kept with the known hosts as x509-sha256, and for a
/// screen behind a carrier SSH host kept for that route alone (the carrier's
/// host:port), so localhost:5900 behind two carriers is two records; a direct
/// screen and every FTPS certificate keep no route, as before. A team's screen
/// goes by its vault's pin on that route. Made-up hosts.

const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';

ScreenCertificate _cert(String name) {
  final der = utf8.encode('made-up certificate of $name');
  return ScreenCertificate(sha256: sha256.convert(der).toString(), der: der);
}

void main() {
  final a = _cert('desk behind gateway a');
  final b = _cert('desk behind gateway b');

  group('known hosts', () {
    late AppDatabase db;
    late KnownHostsService known;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      known = KnownHostsService(db.knownHostsDao);
    });
    tearDown(() => db.close());

    test("a carrier's route is its normalized host and port; a direct screen has none", () {
      expect(screenViaScope(carrierHost: 'GW-A.Example.TEST', carrierPort: 22), 'gw-a.example.test:22');
      expect(screenViaScope(), isNull);
      expect(screenViaScope(carrierHost: 'gw', carrierPort: null), isNull);
    });

    test('scoped and unscoped certificates are kept apart; FTPS lookups (no route) are unchanged', () async {
      final viaA = screenViaScope(carrierHost: 'gw-a.example.test', carrierPort: 22);
      final viaB = screenViaScope(carrierHost: 'gw-b.example.test', carrierPort: 2222);
      await known.trustCertificate('localhost', 5900, sha256Hex: a.sha256, der: a.der, viaScope: viaA);
      await known.trustCertificate('localhost', 5900, sha256Hex: b.sha256, der: b.der, viaScope: viaB);

      expect(await known.pinnedCertificate('localhost', 5900, viaScope: viaA), a.sha256);
      expect(await known.pinnedCertificate('localhost', 5900, viaScope: viaB), b.sha256);
      expect(await known.pinnedCertificate('localhost', 5900), isNull,
          reason: 'a lookup with no route (FTPS, a direct screen) never reads a carrier-scoped pin');
      expect((await known.certificateInfo('localhost', 5900, viaScope: viaA))!.fingerprint, a.fingerprint);
      expect(await known.certificateInfo('localhost', 5900), isNull);

      // An FTPS certificate at an address and port, no route: as in 3.4.
      final ftps = _cert('files');
      await known.trustCertificate('files.example.test', 21, sha256Hex: ftps.sha256, der: ftps.der);
      expect(await known.pinnedCertificate('files.example.test', 21), ftps.sha256);
      expect(await known.pinnedCertificate('files.example.test', 21, viaScope: viaA), isNull);
      final rows = await db.knownHostsDao.getAll();
      expect({for (final r in rows) (r.host, r.port, r.viaScope, r.keyType)}, {
        ('localhost', 5900, viaA, KnownHostsService.certificateKeyType),
        ('localhost', 5900, viaB, KnownHostsService.certificateKeyType),
        ('files.example.test', 21, null, KnownHostsService.certificateKeyType),
      });

      // Replacing one route's certificate leaves the other's.
      final a2 = _cert('desk behind gateway a, renewed');
      await known.trustCertificate('localhost', 5900, sha256Hex: a2.sha256, der: a2.der, viaScope: viaA);
      expect(await known.pinnedCertificate('localhost', 5900, viaScope: viaA), a2.sha256);
      expect(await known.pinnedCertificate('localhost', 5900, viaScope: viaB), b.sha256);
      expect(await known.confirmCertificate('localhost', 5900, a2.sha256, viaScope: viaA), isNull,
          reason: 'confirmed on its own route: kept here, nothing to tell');
    });

    test('first use asks, a yes is kept for the route and connects with no question after; a no ends it quietly',
        () async {
      final via = screenViaScope(carrierHost: 'gw-a.example.test', carrierPort: 22);
      final asked = <(String?, String?)>[];
      var answer = true;
      final trust = KnownHostsScreenTrust(known, (
          {required host, required port, required certificate, viaScope, previous, previousTrustedAt, teamPin}) async {
        asked.add((viaScope, previous));
        return answer;
      }, viaScope: via);

      expect(await trust.pinnedFor('localhost', 5900), isNull);
      expect(await trust.ask(a, host: 'localhost', port: 5900), isTrue);
      await trust.remember('localhost', 5900, a);
      expect(asked, [(via, null)]);
      expect(await trust.pinnedFor('localhost', 5900), a.sha256);

      // A changed certificate is asked about with the one kept before; a no
      // leaves the kept one and says it as a certificate turned down.
      answer = false;
      await expectLater(
          trust.ask(b, host: 'localhost', port: 5900),
          throwsA(isA<HostKeyNotAccepted>()
              .having((e) => e.why, 'why', HostKeyRefusal.declinedChanged)
              .having((e) => e.certificate, 'certificate', isTrue)));
      expect(asked.last, (via, a.fingerprint));
      expect(await trust.pinnedFor('localhost', 5900), a.sha256);

      // The same address behind no carrier is another screen: asked anew.
      final direct = KnownHostsScreenTrust(known, (
          {required host, required port, required certificate, viaScope, previous, previousTrustedAt, teamPin}) async {
        asked.add((viaScope, previous));
        return false;
      });
      expect(await direct.pinnedFor('localhost', 5900), isNull);
      await expectLater(direct.ask(a, host: 'localhost', port: 5900),
          throwsA(isA<HostKeyNotAccepted>().having((e) => e.why, 'why', HostKeyRefusal.declinedNew)));
    });
  });

  group("a team's screen", () {
    late AppDatabase db;
    late KnownHostsService known;
    final via = screenViaScope(carrierHost: 'gw-a.example.test', carrierPort: 22);

    Future<void> team({required Set<String> switches}) async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      known = KnownHostsService(db.knownHostsDao);
      await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
        "VALUES (1, '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3', 'Acme', 'owner', 1, ?)",
        [_crate],
      );
      await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Production', 'manage', ?, 1)",
        [_crate, jsonEncode(switches.toList()..sort())],
      );
      await CratePlacement(db).place('host', 's1', _crate);
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 's1',
            label: 'desk',
            host: 'localhost',
            port: const Value(5900),
            protocol: const Value('vnc'),
            createdAt: DateTime(2026, 11, 9),
            updatedAt: DateTime(2026, 11, 9),
          ));
    }

    tearDown(() => db.close());

    (KnownHostsScreenTrust, List<TeamPinPrompt?>) trustAnswering(bool answer, {bool forEveryone = true}) {
      final asked = <TeamPinPrompt?>[];
      final trust = KnownHostsScreenTrust(known, (
          {required host, required port, required certificate, viaScope, previous, previousTrustedAt, teamPin}) async {
        asked.add(teamPin);
        teamPin?.forEveryone = forEveryone;
        return answer;
      }, viaScope: via, team: ScreenTeamPins(TeamHostKeys(db), hostId: 's1'));
      return (trust, asked);
    }

    test('an editor is offered to pin a first certificate for everyone, on its route; then it connects with no question',
        () async {
      await team(switches: {...CrateSwitches.all});
      final (trust, asked) = trustAnswering(true);
      expect(await trust.ask(a, host: 'localhost', port: 5900), isTrue);
      expect(asked.single!.pinned, isFalse);
      expect(asked.single!.mayChange, isTrue);
      final pin = await TeamHostKeys(db).pinFor('localhost', 5900, viaScope: via, crateId: _crate);
      expect(pin, isNotNull);
      expect(pin!.isCertificate, isTrue);
      expect(pin.certificateSha256, a.sha256);
      expect(pin.viaScope, via, reason: "the carrier's route");
      expect(await trust.pinnedFor('localhost', 5900), a.sha256);
      expect(await TeamHostKeys(db).pinFor('localhost', 5900, crateId: _crate), isNull,
          reason: 'not a pin of the address with no route');
    });

    test('another certificate than the pinned one stops whoever may not edit the vault, and an editor replaces it',
        () async {
      await team(switches: {...CrateSwitches.all});
      await TeamHostKeys(db).pinCertificate('localhost', 5900, a.der, viaScope: via, crateId: _crate);
      final (editor, askedEditor) = trustAnswering(true);
      expect(await editor.ask(b, host: 'localhost', port: 5900), isTrue);
      expect(askedEditor.single!.pinned, isTrue);
      expect(await editor.pinnedFor('localhost', 5900), b.sha256, reason: 'replaced for everyone');

      await db.customStatement('UPDATE orchard_crates SET switches = ?', [jsonEncode(['connect'])]);
      final (member, _) = trustAnswering(true);
      await expectLater(member.ask(a, host: 'localhost', port: 5900),
          throwsA(isA<HostKeyNotAccepted>().having((e) => e.why, 'why', HostKeyRefusal.pinnedOther)));
      expect(await member.pinnedFor('localhost', 5900), b.sha256, reason: 'the pin stands');
    });
  });
}
