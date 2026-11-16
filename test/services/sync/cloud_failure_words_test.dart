import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart'
    show SyncException, SyncSetupRequiredException;

/// A ZestSSH sync server, ZestSSH Cloud or one of the person's own, as it
/// answers: each route with the status and the body played for it.
class _Server {
  final status = <String, int>{};
  final body = <String, String>{};
  final requests = <String>[];

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path.replaceFirst('/v1', '');
    requests.add('${request.method} $path');
    return http.Response(body[path] ?? jsonEncode({'error': 'Internal server error'}), status[path] ?? 500);
  }

  void plays(String path, int answer, Object said) {
    status[path] = answer;
    body[path] = said is String ? said : jsonEncode(said);
  }
}

/// What [step] failed with; the test fails where it did not fail.
Future<SyncException> _failure(Future<void> Function() step) async {
  try {
    await step();
  } on SyncException catch (e) {
    return e;
  }
  fail('it did not fail');
}

/// ZestSSH Cloud and a ZestSSH server of the person's own failing (3.0):
/// what the server answered was said in the code's
/// English with the server's words ("Push failed: Internal server error",
/// "Status check failed: Invalid token"), in every language, and a fault of
/// ZestSSH Cloud's own was not told for one where the server said why in
/// words of its own, which hold no status. Each is said as the situation it
/// is, in the person's language, with the server's words kept for the
/// details.
void main() {
  final de = lookupAppLocalizations(const Locale('de'));
  late _Server server;

  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
  });
  setUp(() {
    L10nGlobal.update(de);
    // A desktop's sign-in, as the hosted backend reads it without Firebase.
    FlutterSecureStorage.setMockInitialValues({'session_token': 'st-demo'});
    server = _Server();
    ZestServerBackend.debugHttpClient = MockClient(server.answer);
  });
  tearDown(() {
    ZestServerBackend.debugHttpClient = null;
    currentCloudReach = null;
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
  });

  ZestServerBackend cloud() => ZestServerBackend(baseUrl: 'https://cloud.example.com/v1', requiresEntitlement: false);
  ZestServerBackend own({String? token = 'demo-token'}) => ZestServerBackend(
        baseUrl: 'https://sync.example.com/v1',
        staticToken: token,
        requiresEntitlement: false,
        kind: SyncBackendKind.custom,
      );

  group('ZestSSH Cloud', () {
    test('a fault of its own is told for one, its words kept for the details, where it said why in words of its own',
        () async {
      server.plays('/sync/status', 500, {'error': 'Internal server error'});
      var said = await _failure(cloud().getStatus);
      expect(said.message, de.syncStoreFault(500), reason: 'a fault, with its status, so that it is told for one');
      expect(said.detail, 'Status check failed: Internal server error (HTTP 500)');
      var told = SyncFailure.ofStore(said, hosted: true);
      expect(told.message, '${de.cloudFault(500)} (ZS-1103)');
      expect(told.detail, 'Status check failed: Internal server error (HTTP 500)', reason: 'the server\'s words kept');

      // Something in front of it answering with a page of its own.
      server.plays('/sync/pull', 502, '<html>Bad gateway</html>');
      said = await _failure(cloud().pull);
      expect(said.message, de.syncStoreFault(502));
      expect(said.detail, 'Pull failed: HTTP 502');
      told = SyncFailure.ofStore(said, hosted: true);
      expect(told.message, '${de.cloudFault(502)} (ZS-1103)');
    });

    test('a sign-in it does not take, too many requests, too much, an answer this version does not know', () async {
      // A computer's sign-in that ran out: sign in again where you are
      // (found in a security review).
      server.plays('/sync/status', 401, {'error': 'This sign-in ran out. Sign in again.', 'code': 'session-expired'});
      var said = await _failure(cloud().getStatus);
      expect(said.message, de.syncCloudSignInRanOut);
      server.requests.clear();

      server.plays('/sync/status', 401, {'error': 'Invalid token'});
      said = await _failure(cloud().getStatus);
      expect(said.message, de.syncCloudSignInRefused);
      expect(said.detail, 'Status check failed: Invalid token (HTTP 401)');
      expect(server.requests, ['GET /sync/status', 'GET /sync/status'], reason: 'asked again with a fresh sign-in');

      // Something on the way answering in the service's place.
      server.plays('/sync/status', 403, '<html>Blocked</html>');
      said = await _failure(cloud().getStatus);
      expect(said.message, de.syncCloudAnswerUnknown(403));

      server.plays('/sync/verify-password', 429, {'error': 'Too many verification attempts. Try again later.'});
      said = await _failure(() => cloud().verifyPassword(SecretKey(List.filled(32, 7))));
      expect(said.message, de.syncCloudTooMany);
      expect(said.detail, 'Verification failed: Too many verification attempts. Try again later. (HTTP 429)');

      server.plays('/sync/push', 413, {'error': 'Blob exceeds size limits'});
      said = await _failure(() => cloud().push(
            data: const {'hosts': <Object>[]},
            dek: SecretKey(List.filled(32, 7)),
            salt: Uint8List(32),
            verificationHash: Uint8List(32),
          ));
      expect(said.message, de.syncStoreTooLarge);
      expect(said.detail, 'Push failed: Blob exceeds size limits (HTTP 413)');

      server.plays('/sync/status', 410, {'error': 'Gone'});
      said = await _failure(cloud().getStatus);
      expect(said.message, de.syncCloudAnswerUnknown(410));
    });

    test('nothing stored yet, no recovery key, and no sign-in at all', () async {
      server.plays('/sync/pull', 404, {'error': 'No sync data found'});
      var said = await _failure(cloud().pull);
      expect(said.message, de.syncStoreEmpty);

      server.plays('/sync/pull', 200, {
        'encrypted_data': base64Encode(List.filled(80, 0)),
        'salt': base64Encode(List.filled(32, 0)),
        'version': 3,
        'updated_at': '2026-10-16T12:00:00Z',
      });
      said = await _failure(() => cloud().pullWithRecoveryKey('ABCD-EFGH-IJKL'));
      expect(said.message, de.syncStoreNoRecoveryKey);
      expect(said.detail, 'Recovery key has not been configured for this account');

      FlutterSecureStorage.setMockInitialValues({});
      said = await _failure(cloud().getStatus);
      expect(said.message, de.syncSignInFirst);
      expect(server.requests, isNot(contains('GET /sync/status')), reason: 'nothing is asked without a sign-in');
    });

    test('a push it refuses for want of a vault stops sync as the data gone from the store', () async {
      server.plays('/sync/push', 426, {'error': 'Cloud Sync must be set up again on this version.', 'code': 'REENROLL_REQUIRED'});
      final said = await _failure(() => cloud().push(
            data: const {'hosts': <Object>[]},
            dek: SecretKey(List.filled(32, 7)),
            salt: Uint8List(32),
            verificationHash: Uint8List(32),
          ));
      expect(said, isA<SyncSetupRequiredException>());
      expect(said.message, de.syncStoreDataMissing);
      expect(said.detail, 'Push refused: Cloud Sync must be set up again on this version. (HTTP 426)');
    });

    test('sync data that does not come in time is said as ZestSSH Cloud not answering', () {
      final late = SyncFailure.storeNoAnswerInTime('Store response stalled for 30s');
      final told = SyncFailure.ofStore(late, hosted: true);
      expect(told.message, '${de.cloudNotResponding} (ZS-1101)');
      expect(told.detail, 'Store response stalled for 30s');
      // Storage of one's own says it as its own.
      expect(SyncFailure.ofStore(late, hosted: false), same(late));
    });
  });

  group('a ZestSSH server of the person\'s own', () {
    test('without an access token of its own: said as that, and nothing is sent', () async {
      final said = await _failure(own(token: null).getStatus);
      expect(said.message, de.syncServerNeedsToken);
      expect(server.requests, isEmpty);
    });

    test('refusing the token, asking to slow down, no such place, a fault of its own', () async {
      server.plays('/sync/status', 403, {'error': 'Forbidden'});
      var said = await _failure(own().getStatus);
      expect(said.message, de.syncServerTokenRefused);
      expect(said.detail, 'Status check failed: Forbidden (HTTP 403)');

      server.plays('/sync/status', 429, {'error': 'Too many requests. Try again in a minute.'});
      said = await _failure(own().getStatus);
      expect(said.message, de.syncServerTooMany);

      server.plays('/sync/status', 404, '<html>Not Found</html>');
      said = await _failure(own().getStatus);
      expect(said.message, de.syncStoreNotThere);

      server.plays('/sync/status', 503, {'error': 'Service unavailable'});
      said = await _failure(own().getStatus);
      expect(SyncFailure.ofStore(said, hosted: false).message, '${de.syncStoreFault(503)} (ZS-1201)');
    });

    test('a purge with a sync password that is not the account\'s: nothing was deleted', () async {
      server.plays('/sync/purge', 403, {'error': 'Sync verification failed', 'code': 'SYNC_VERIFICATION_FAILED'});
      final said = await _failure(() => own().purge(Uint8List(32)));
      expect(said.message, de.accountDeleteWrongSyncPassword);
    });
  });
}
