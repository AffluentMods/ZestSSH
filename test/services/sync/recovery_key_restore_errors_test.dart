// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/sync/sync_failing_text.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../helpers/memory_store_backend.dart';

/// A recovery key is said not to work only when the store said so (3.0,
/// found while the app was held against a server that is
/// down).
///
/// Restoring with a recovery key asks the hosted server whether the key is
/// the account's. Whatever the server answered that was not "yes" was taken
/// for "no": a fault of its own (500), a way to it that answers in its place
/// (502, 503), too many tries (429), a sign-in it does not take. And on the
/// Account page, anything at all that stopped the restore, a network that
/// was down included, was shown as "That recovery key didn't work.
/// Double-check it and try again." Somebody holding the right key, the one
/// thing between them and their data, was told it was wrong.
void main() {
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const recoveryKey = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';

  late SecretKey dek;
  late Uint8List salt;
  late Uint8List recoverySalt;
  late Uint8List wrappedForRecovery;
  late Uint8List blob;

  setUpAll(() async {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
    salt = SyncService.generateSalt();
    recoverySalt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    final kek = await SyncService.deriveKey(recoveryKey.replaceAll('-', ''), recoverySalt, params: fast);
    wrappedForRecovery = await SyncService.wrapDek(dek, kek);
    blob = await SyncService.encrypt({'connections': const <dynamic>[]}, dek, salt);
  });

  tearDown(() => ZestServerBackend.debugHttpClient = null);

  /// The hosted server holding a vault with a recovery key, answering the
  /// question "is this the recovery key?" with [answer] (or failing as
  /// [fails]). [asked] counts the questions.
  ZestServerBackend server({http.Response? answer, Object? fails, void Function()? asked}) {
    ZestServerBackend.debugHttpClient = MockClient((request) async {
      if (request.url.path.endsWith('/sync/pull')) {
        return http.Response(
          jsonEncode({
            'encrypted_data': base64Encode(blob),
            'salt': base64Encode(salt),
            'version': 3,
            'updated_at': '2026-10-08T09:00:00Z',
            'wrapped_dek_password': null,
            'wrapped_dek_recovery': base64Encode(wrappedForRecovery),
            'recovery_salt': base64Encode(recoverySalt),
            'argon2_params': fast,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/sync/verify-recovery')) {
        asked?.call();
        if (fails != null) throw fails;
        return answer!;
      }
      return http.Response('{"error":"not here"}', 404);
    });
    return ZestServerBackend(
      baseUrl: 'https://sync.northwind.example/v1',
      staticToken: 'demo-token',
      requiresEntitlement: false,
      kind: SyncBackendKind.custom,
    );
  }

  group('the hosted server is asked whether the key is the account\'s', () {
    test('yes: the vault opens', () async {
      final restored = await server(answer: http.Response('{"valid":true}', 200)).pullWithRecoveryKey(recoveryKey);
      expect(await SyncService.decrypt(restored.pullResult.encryptedData, restored.dek), {'connections': const <dynamic>[]});
    });

    test('no: the key is wrong, and that is what is thrown', () async {
      await expectLater(
        server(answer: http.Response('{"valid":false}', 200)).pullWithRecoveryKey(recoveryKey),
        throwsA(isA<SyncRecoveryKeyWrongException>()),
      );
      await expectLater(
        server(answer: http.Response('{"valid":false,"reason":"no_data"}', 200)).pullWithRecoveryKey(recoveryKey),
        throwsA(isA<SyncRecoveryKeyWrongException>()),
      );
    });

    for (final (name, status, body) in [
      ('a fault of its own', 500, '{"error":"Internal server error"}'),
      ('the way to it answering in its place', 502, '<html>Bad gateway</html>'),
      ('not in service', 503, '{"status":"degraded"}'),
      ('a sign-in it does not take', 401, '{"error":"Invalid or expired token"}'),
      ('an account without hosting', 403, '{"error":"Cloud Sync required"}'),
    ]) {
      test('$name (HTTP $status): nothing is said of the key', () async {
        var asked = 0;
        Object? thrown;
        try {
          await server(answer: http.Response(body, status), asked: () => asked++).pullWithRecoveryKey(recoveryKey);
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isA<SyncException>());
        expect(thrown, isNot(isA<SyncRecoveryKeyWrongException>()), reason: 'the server never judged the key');
        expect((thrown! as SyncException).message, '${gl10n.syncRecoveryKeyNotChecked} (ZS-1210)');
        expect((thrown as SyncException).detail, contains('verify-recovery'));
        expect(asked, greaterThan(0));
      });
    }

    test('too many tries (HTTP 429): said as that, not as a wrong key', () async {
      Object? thrown;
      try {
        await server(answer: http.Response('{"error":"Too many verification attempts. Try again later."}', 429))
            .pullWithRecoveryKey(recoveryKey);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNot(isA<SyncRecoveryKeyWrongException>()));
      expect((thrown! as SyncException).message, gl10n.twoStepErrorTooMany);
    });

    test('no answer at all: what the network gave, not a verdict on the key', () async {
      await expectLater(
        server(fails: const SocketException('Connection refused')).pullWithRecoveryKey(recoveryKey),
        throwsA(isNot(isA<SyncRecoveryKeyWrongException>())),
      );
    });
  });

  test('a store that is only a file: a key that does not open it is the wrong key', () async {
    final store = MemoryStoreBackend(MemoryStore());
    final kek = await SyncService.deriveKey(recoveryKey.replaceAll('-', ''), recoverySalt, params: fast);
    await store.push(
      data: {'connections': const <dynamic>[]},
      dek: dek,
      salt: salt,
      verificationHash: Uint8List(32),
      // (A vault has a master password too; whose it is does not matter here.)
      wrappedDekPassword: await SyncService.wrapDek(dek, SyncService.generateDek()),
      wrappedDekRecovery: await SyncService.wrapDek(dek, kek),
      recoverySalt: recoverySalt,
      recoveryHash: await SyncService.computeRecoveryVerificationHash(kek),
      createOnly: true,
      argon2Params: fast,
    );
    await expectLater(store.pullWithRecoveryKey('ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ'),
        throwsA(isA<SyncRecoveryKeyWrongException>()));
    expect((await store.pullWithRecoveryKey(recoveryKey)).pullResult.version, 1);
  });

  group('what the person is told when a restore did not go through', () {
    const didNotWork = 'That recovery key didn\'t work. Double-check it and try again.';

    test('a key the store refused: that the key did not work, with the code for that', () {
      for (final hosted in [true, false]) {
        expect(recoveryRestoreFailedText(const SyncRecoveryKeyWrongException(), didNotWork, hosted: hosted),
            '$didNotWork (ZS-1211)');
      }
    });

    test('a server that did not answer the question: that it could not be checked, and that the key is not at fault',
        () {
      final said = recoveryRestoreFailedText(
          SyncException(ErrorCodes.withCode(gl10n.syncRecoveryKeyNotChecked, ErrorCodes.recoveryKeyNotChecked)),
          didNotWork,
          hosted: true);
      expect(said, '${gl10n.syncRecoveryKeyNotChecked} (ZS-1210)');
      expect(said, isNot(contains(didNotWork)));
      expect(said, contains('could not be checked'));
      expect(said, contains('Nothing is wrong with the key'));
    });

    test('a network that is down: how ZestSSH Cloud stands, or what the network said of storage of their own', () {
      const refused = SocketException('Connection refused');
      expect(recoveryRestoreFailedText(refused, didNotWork, hosted: true),
          '${gl10n.cloudNotResponding} (ZS-1101)');
      expect(
        recoveryRestoreFailedText(refused, didNotWork, hosted: false),
        '${describeNetworkError(refused, subject: gl10n.errSubjectSyncServer).message} (ZS-1201)',
      );
      for (final hosted in [true, false]) {
        expect(recoveryRestoreFailedText(refused, didNotWork, hosted: hosted), isNot(contains(didNotWork)));
      }
    });

    test('anything else the store says: its own words', () {
      expect(
        recoveryRestoreFailedText(
            const SyncException('Recovery key has not been configured for this account'), didNotWork,
            hosted: true),
        'Recovery key has not been configured for this account',
      );
    });

    test('every language says that the key could not be checked, in its own words', () {
      final en = lookupAppLocalizations(const Locale('en'));
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        expect(l.syncRecoveryKeyNotChecked.trim(), isNotEmpty, reason: '$locale');
        if (locale.languageCode != 'en') {
          expect(l.syncRecoveryKeyNotChecked, isNot(en.syncRecoveryKeyNotChecked), reason: '$locale');
          expect(l.syncRecoveryKeyNotChecked, isNot(l.profileRecoveryKeyDidntWork), reason: '$locale');
        }
      }
    });
  });
}
