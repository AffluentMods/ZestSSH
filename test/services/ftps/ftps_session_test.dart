import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/ftps.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations_en.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/terminal_providers.dart' show opensFilesOnly, runsCommands;
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';

import 'fake_ftps_native.dart';

/// An FTPS host's session (3.4): its certificate kept and asked about like an
/// SSH host key, and how its failures are said.
void main() {
  late AppDatabase db;
  late KnownHostsService known;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    known = KnownHostsService(db.knownHostsDao);
  });
  tearDown(() => db.close());

  const options = FtpsConnectOptions(host: 'Files.Example.Test', port: 21, username: 'demo', password: 'pw');

  test('a first certificate is asked about, kept on a yes, and not asked about again', () async {
    final native = FakeFtpsNative();
    final asked = <String?>[];
    final trust = KnownHostsFtpsTrust(known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async {
      asked.add(previous);
      expect(certificate.fingerprint, startsWith('AB:AB:'));
      return true;
    });
    final shell = FtpsShellService(options: options, trust: trust, native: native, keepAlive: const Duration(hours: 1));
    await shell.connect();
    expect(shell.isConnected, isTrue);
    expect(asked, [null]);
    // Kept as the host's certificate, under the host's name in lower case, as host keys are.
    expect(await known.pinnedCertificate('files.example.test', 21), native.certificateSha);
    await shell.disconnect();

    final again = FtpsShellService(options: options, trust: trust, native: native, keepAlive: const Duration(hours: 1));
    await again.connect();
    expect(asked, [null], reason: 'the kept one connects without a question');
    await again.disconnect();
  });

  test('a changed certificate is asked about with the one before, and a no keeps the old one', () async {
    await known.trustCertificate('files.example.test', 21, sha256Hex: 'cd' * 32, der: [1, 2]);
    final native = FakeFtpsNative(certificateSha: 'ef' * 32);
    String? before;
    final trust = KnownHostsFtpsTrust(known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async {
      before = previous;
      return false;
    });
    final shell = FtpsShellService(options: options, trust: trust, native: native);
    await expectLater(
      shell.connect(),
      throwsA(isA<HostKeyNotAccepted>().having((e) => e.why, 'why', HostKeyRefusal.declinedChanged)),
    );
    expect(before, KnownHostsService.certificateFingerprint('cd' * 32));
    expect(await known.pinnedCertificate('files.example.test', 21), 'cd' * 32);
    // Nothing past the TLS handshake was asked of the server.
    expect(native.requests.where((r) => r['op'] != 'connect'), isEmpty);
  });

  test('a certificate that came with sync is told of once, with the device that kept it, as a synced host key is',
      () async {
    final native = FakeFtpsNative();
    final recorded = DateTime.utc(2026, 10, 30);
    // As sync brings it: kept on another device, not yet confirmed here.
    await db.knownHostsDao.upsertHost(KnownHostsCompanion(
      id: const Value('synced-cert'),
      host: const Value('files.example.test'),
      port: const Value(21),
      keyType: const Value(KnownHostsService.certificateKeyType),
      fingerprint: Value(KnownHostsService.certificateFingerprint(native.certificateSha)),
      publicKeyBase64: const Value('AQI='),
      firstSeen: Value(recorded),
      lastSeen: Value(recorded),
      recordedDevice: const Value('other-laptop'),
      locallyVerified: const Value(false),
    ));
    final told = <(String, int, String, DateTime)>[];
    final trust = KnownHostsFtpsTrust(
      known,
      ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async =>
          fail('a synced certificate that matches is not asked about'),
      onAdopted: (host, port, from) => told.add((host, port, from.device, from.recordedAt.toUtc())),
    );
    for (var i = 0; i < 2; i++) {
      final shell = FtpsShellService(options: options, trust: trust, native: native, keepAlive: const Duration(hours: 1));
      await shell.connect();
      await shell.disconnect();
    }
    expect(told, [('Files.Example.Test', 21, 'other-laptop', recorded)], reason: 'once, the first time here');
    final row = await db.knownHostsDao.findHost('files.example.test', 21, KnownHostsService.certificateKeyType);
    expect(row!.locallyVerified, isTrue);
    expect(row.recordedDevice, 'other-laptop', reason: 'where it came from stays');
  });

  group('a dropped connection (3.4, stage 2)', () {
    test('is made again once, with the kept certificate and no question; the old one is closed', () async {
      final native = FakeFtpsNative();
      var asked = 0;
      final trust = KnownHostsFtpsTrust(known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async {
        asked++;
        return true;
      });
      final shell = FtpsShellService(options: options, trust: trust, native: native, keepAlive: const Duration(hours: 1));
      await shell.connect();
      expect(asked, 1);
      final first = shell.client!;
      final again = await shell.reconnect();
      expect(asked, 1, reason: 'a certificate already trusted is not asked about again');
      expect(shell.client, same(again));
      expect(identical(again, first), isFalse);
      expect(first.isClosed, isTrue);
      expect(shell.isConnected, isTrue);
      await shell.disconnect();
      await expectLater(shell.reconnect(), throwsA(isA<FtpsException>()), reason: 'not after the session ended');
    });

    test('the keep-alive connects again once before it ends the session', () async {
      final native = FakeFtpsNative();
      final trust = KnownHostsFtpsTrust(
          known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async => true);
      final shell = FtpsShellService(
          options: options, trust: trust, native: native, keepAlive: const Duration(milliseconds: 40));
      await shell.connect();
      final first = shell.client!;
      native.failNext['noop'] = {'kind': 'connection', 'message': 'connection reset'};
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(shell.isConnected, isTrue, reason: 'connected again, not ended');
      expect(identical(shell.client, first), isFalse);
      await shell.disconnect();
    });
  });

  test('a certificate kept for an FTPS port is never taken for an SSH host key there', () async {
    await known.trustCertificate('files.example.test', 22, sha256Hex: 'cd' * 32, der: [1, 2]);
    final key = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List.generate(51, (i) => i)));
    final out = await known.verify('files.example.test', 22, key);
    expect(out.result, HostKeyVerifyResult.newHost, reason: 'not "changed" because of the certificate');
    expect(await known.trustedKeyInfo('files.example.test', 22, 'ssh-ed25519'), isNull);
  });

  test('FTPS hosts open files only, run no commands, and their protocol is stored as two names', () {
    expect(opensFilesOnly('ftps'), isTrue);
    expect(opensFilesOnly('ftpsImplicit'), isTrue);
    expect(runsCommands('ftps'), isFalse);
    expect(ConnectionProtocol.storedIsFtps('ftps'), isTrue);
    expect(ConnectionProtocol.storedIsFtps('ssh'), isFalse);
    expect(ConnectionProtocol.ftpsImplicit.isFtps, isTrue);
  });

  test('failures are said in the person\'s words, with a code where it helps', () {
    final l10n = AppLocalizationsEn();
    expect(ftpsFailureText(l10n, const FtpsException(FtpsErrorKind.noTls, 'AUTH', code: 502)), contains('ZS-1606'));
    expect(ftpsFailureText(l10n, const FtpsException(FtpsErrorKind.noTls, 'AUTH', code: 502)), contains('nothing was sent'));
    expect(ftpsFailureText(l10n, const FtpsException(FtpsErrorKind.timeout, 'timed out')), contains('ZS-1607'));
    expect(ftpsFailureText(l10n, const FtpsException(FtpsErrorKind.login, '530')), l10n.ftpsLoginRefused);
    expect(ftpsFailureText(l10n, const FtpsException(FtpsErrorKind.reply, 'No such file', code: 550)),
        l10n.ftpsServerRefusedCode(550));
  });

  test('no kind puts what the server or the library said into the sentence: that is for Copy details', () {
    final l10n = AppLocalizationsEn();
    const said = 'Kx9 the words of the server';
    for (final kind in FtpsErrorKind.values) {
      for (final code in [null, 550]) {
        final text = ftpsFailureText(l10n, FtpsException(kind, said, code: code));
        expect(text, isNot(contains('Kx9')), reason: '${kind.name} $code');
        expect(text, isNot(contains('FTPS failed')), reason: 'nor the old sentence that held them');
      }
    }
  });
}
