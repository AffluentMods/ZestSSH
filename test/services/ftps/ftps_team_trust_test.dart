import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/ftps.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations_en.dart';
import 'package:zestssh/providers/terminal_providers.dart' show hostKeyNotAcceptedText;
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';

import 'fake_ftps_native.dart';

/// An FTPS host of a team (3.4): its certificate trusted as the team pinned
/// it in the host's vault, as an SSH host's key is: no question for the
/// pinned one, a different one stops whoever may not edit the vault, and
/// someone who may edit it pins one for everyone.

const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';

/// The fake server's certificate (fake_ftps_native.dart: its DER is these
/// four bytes), and its SHA-256, which a pin of it holds.
final _der = [0x30, 0x82, 0x01, 0x01];
final _sha = sha256.convert(_der).toString();

void main() {
  late AppDatabase db;
  late KnownHostsService known;

  const options = FtpsConnectOptions(host: 'files.example.test', port: 21, username: 'demo', password: 'pw');

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
    await CratePlacement(db).place('host', 'f1', _crate);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'f1',
          label: 'files',
          host: 'files.example.test',
          port: const Value(21),
          protocol: const Value('ftps'),
          createdAt: DateTime(2026, 11, 6),
          updatedAt: DateTime(2026, 11, 6),
        ));
  }

  tearDown(() => db.close());

  FtpsTeamPins pins() => FtpsTeamPins(TeamHostKeys(db), hostId: 'f1');

  /// A trust whose question answers [answer], noting what it was asked with.
  (KnownHostsFtpsTrust, List<(String?, TeamPinPrompt?)>) trustAnswering(bool answer, {bool forEveryone = true}) {
    final asked = <(String?, TeamPinPrompt?)>[];
    final trust = KnownHostsFtpsTrust(known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async {
      asked.add((previous, teamPin));
      teamPin?.forEveryone = forEveryone;
      return answer;
    }, team: pins());
    return (trust, asked);
  }

  test('someone who may edit the vault pins a first certificate for everyone in it as they trust it', () async {
    await team(switches: {...CrateSwitches.all});
    final native = FakeFtpsNative(certificateSha: _sha);
    final (trust, asked) = trustAnswering(true);
    final shell = FtpsShellService(options: options, trust: trust, native: native, keepAlive: const Duration(hours: 1));
    await shell.connect();
    await shell.disconnect();
    expect(asked.single.$2!.pinned, isFalse);
    expect(asked.single.$2!.mayChange, isTrue);
    expect(asked.single.$2!.crateName, 'Production');
    final pin = await pins().certificatePin('files.example.test', 21);
    expect(pin!.certificateSha256, _sha);
    expect(await known.pinnedCertificate('files.example.test', 21), _sha, reason: 'and kept on this device');
  });

  test('turned off, the choice pins nothing for the team', () async {
    await team(switches: {...CrateSwitches.all});
    final (trust, _) = trustAnswering(true, forEveryone: false);
    final shell = FtpsShellService(options: options, trust: trust, native: FakeFtpsNative(certificateSha: _sha));
    await shell.connect();
    await shell.disconnect();
    expect(await pins().certificatePin('files.example.test', 21), isNull);
  });

  test('a member with the team\'s pin connects with no question, whatever this device kept', () async {
    await team(switches: {...CrateSwitches.all});
    await TeamHostKeys(db).pinCertificate('files.example.test', 21, _der, crateId: _crate);
    await known.trustCertificate('files.example.test', 21, sha256Hex: 'cd' * 32, der: [1]);
    final asked = <Object?>[];
    final trust = KnownHostsFtpsTrust(known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async {
      asked.add(previous);
      return true;
    }, team: pins());
    expect(await trust.pinnedFor('files.example.test', 21), _sha, reason: "the team's pin, not this device's");
    final shell = FtpsShellService(options: options, trust: trust, native: FakeFtpsNative(certificateSha: _sha));
    await shell.connect();
    await shell.disconnect();
    expect(asked, isEmpty);
  });

  test('another certificate than the pinned one stops whoever may not edit the vault, and says who can', () async {
    await team(switches: {...CrateSwitches.all});
    await TeamHostKeys(db).pinCertificate('files.example.test', 21, _der, crateId: _crate);
    await db.customStatement('UPDATE orchard_crates SET switches = ?', [jsonEncode(['connect', 'sftp'])]);
    final native = FakeFtpsNative(certificateSha: 'ef' * 32);
    final (trust, asked) = trustAnswering(true);
    final shell = FtpsShellService(options: options, trust: trust, native: native);
    Object? error;
    try {
      await shell.connect();
    } catch (e) {
      error = e;
    }
    expect(error, isA<HostKeyNotAccepted>().having((e) => e.why, 'why', HostKeyRefusal.pinnedOther));
    final refused = error! as HostKeyNotAccepted;
    expect(refused.certificate, isTrue);
    expect(refused.crate, 'Production');
    final said = hostKeyNotAcceptedText(AppLocalizationsEn(), refused);
    expect(said, contains('certificate'));
    expect(said, isNot(contains(' key')));
    expect(asked.single.$1, KnownHostsService.certificateFingerprint(_sha), reason: 'the pinned one is shown');
    expect(asked.single.$2!.pinned, isTrue);
    expect(asked.single.$2!.mayChange, isFalse);
    expect((await pins().certificatePin('files.example.test', 21))!.certificateSha256, _sha, reason: 'the pin stays');
    expect(native.requests.where((r) => r['op'] != 'connect'), isEmpty, reason: 'no user name was sent');
  });

  test('someone who may edit the vault replaces the pin for everyone with a yes, and keeps it with a no', () async {
    await team(switches: {...CrateSwitches.all});
    await TeamHostKeys(db).pinCertificate('files.example.test', 21, [9, 9, 9], crateId: _crate);
    final (no, _) = trustAnswering(false);
    await expectLater(FtpsShellService(options: options, trust: no, native: FakeFtpsNative(certificateSha: _sha)).connect(),
        throwsA(isA<HostKeyNotAccepted>().having((e) => e.why, 'why', HostKeyRefusal.declinedChanged)));
    expect((await pins().certificatePin('files.example.test', 21))!.certificateSha256, sha256.convert([9, 9, 9]).toString());

    final (yes, asked) = trustAnswering(true);
    final shell = FtpsShellService(options: options, trust: yes, native: FakeFtpsNative(certificateSha: _sha));
    await shell.connect();
    await shell.disconnect();
    expect(asked.single.$2!.pinned, isTrue);
    expect(asked.single.$2!.mayChange, isTrue);
    expect((await pins().certificatePin('files.example.test', 21))!.certificateSha256, _sha);
  });

  test("a pin of an SSH host key at the address is no certificate's", () async {
    await team(switches: {...CrateSwitches.all});
    await TeamHostKeys(db).pin('files.example.test', 21, SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List(32)), crateId: _crate);
    expect(await pins().certificatePin('files.example.test', 21), isNull);
  });
}
