import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart';

/// ZestSSH Cloud as it answers an account: its sync routes refuse an account
/// without Juiced with 403 and the code ENTITLEMENT_REQUIRED
/// (ZestSSH Cloud's src/middleware/entitlement.js), and its entitlement
/// check says whether the account has it.
class _Cloud {
  bool juiced = false;
  Map<String, dynamic> refusal = {'error': 'Cloud Sync entitlement required', 'code': 'ENTITLEMENT_REQUIRED'};
  final requests = <String>[];

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path.replaceFirst('/v1', '');
    requests.add('${request.method} $path');
    if (path == '/auth/verify-entitlement') return http.Response(jsonEncode({'has_cloud_sync': juiced}), 200);
    if (!juiced && path.startsWith('/sync/')) return http.Response(jsonEncode(refusal), 403);
    if (path == '/sync/status') {
      return http.Response(jsonEncode({'has_data': false, 'version': 0, 'blob_size': 0}), 200);
    }
    return http.Response(jsonEncode({'error': 'Not found'}), 404);
  }
}

/// Free accounts that chose ZestSSH Cloud read "Couldn't reach the sync
/// server" in 2.2.1 (a reported bug), and the server's own
/// English after: ZestSSH Cloud's storage comes with Juiced, and that is
/// what the person is told now, in the app's language and with its code.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final said = ErrorCodes.withCode(l10n.syncHostingNeedsJuiced, ErrorCodes.syncHostingNotIncluded);
  late _Cloud cloud;

  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
  });

  setUp(() {
    // A desktop's sign-in, as the hosted backend reads it without Firebase.
    FlutterSecureStorage.setMockInitialValues({'session_token': 'st-demo'});
    cloud = _Cloud();
    ZestServerBackend.debugHttpClient = MockClient(cloud.answer);
  });

  tearDown(() => ZestServerBackend.debugHttpClient = null);

  ZestServerBackend hosted() => ZestServerBackend(baseUrl: 'https://cloud.test/v1');

  final hostingRefused = isA<SyncHostingRequiredException>().having((e) => e.message, 'message', said);

  test('the status asked of ZestSSH Cloud by an account without Juiced: said as that, once asked', () async {
    await expectLater(hosted().getStatus(), throwsA(hostingRefused));
    expect(cloud.requests, ['GET /sync/status'], reason: 'no second request with a fresh sign-in: it changes nothing');
    expect(said, endsWith('(ZS-1204)'));
    expect(l10n.syncHostingNeedsJuiced, contains('Juiced'));
  });

  test('a pull and a push are refused the same way', () async {
    await expectLater(hosted().pull(), throwsA(hostingRefused));
    await expectLater(
      hosted().push(
        data: const {'connections': <Object>[]},
        dek: SyncService.generateDek(),
        salt: SyncService.generateSalt(),
        verificationHash: Uint8List(32),
      ),
      throwsA(hostingRefused),
    );
    expect(cloud.requests, ['GET /sync/pull', 'POST /sync/push']);
  });

  test('it pauses sync as a setup that is needed does, and is no outage of ZestSSH Cloud', () async {
    final refused = SyncHostingRequiredException(SyncFailure.hostingNotIncluded);
    expect(refused, isA<SyncSetupRequiredException>());
    expect(refused, isNot(isA<SyncKeysMismatchException>()));
    final asSaid = SyncFailure.ofStore(refused, hosted: true);
    expect(asSaid.message, said);
  });

  test('another 403 is not taken for it, and is asked once more with a fresh sign-in, as before', () async {
    cloud.refusal = {'error': 'Forbidden'};
    await expectLater(
      hosted().getStatus(),
      throwsA(isA<SyncException>().having((e) => e, 'kind', isNot(isA<SyncHostingRequiredException>()))),
    );
    expect(cloud.requests, ['GET /sync/status', 'GET /sync/status']);
  });

  test('a server of the person\'s own that answers so is not said to be ZestSSH Cloud', () async {
    final own = ZestServerBackend(
      baseUrl: 'https://sync.example.com/v1',
      staticToken: 'demo-token',
      requiresEntitlement: false,
      kind: SyncBackendKind.custom,
    );
    await expectLater(
      own.getStatus(),
      throwsA(isA<SyncException>().having((e) => e, 'kind', isNot(isA<SyncHostingRequiredException>()))),
    );
  });

  test('the entitlement check: without Juiced the same words; with it, nothing to say; none asked of other storage',
      () async {
    await expectLater(hosted().verifyEntitlement(), throwsA(hostingRefused));
    cloud.juiced = true;
    await hosted().verifyEntitlement();
    expect(cloud.requests, ['POST /auth/verify-entitlement', 'POST /auth/verify-entitlement']);
    cloud.requests.clear();
    await ZestServerBackend(
      baseUrl: 'https://sync.example.com/v1',
      staticToken: 'demo-token',
      requiresEntitlement: false,
      kind: SyncBackendKind.custom,
    ).verifyEntitlement();
    expect(cloud.requests, isEmpty);
  });

  test('the words in every language name Juiced and the free storage, and differ from the English', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.syncHostingNeedsJuiced, allOf(contains('Juiced'), contains('WebDAV'), contains('S3')),
          reason: locale.toLanguageTag());
      expect(words.syncHostingTitle, contains('Juiced'), reason: locale.toLanguageTag());
      if (locale.languageCode != 'en') {
        expect(words.syncHostingNeedsJuiced, isNot(l10n.syncHostingNeedsJuiced), reason: locale.toLanguageTag());
        expect(words.syncHostingChooseStorage, isNot(l10n.syncHostingChooseStorage), reason: locale.toLanguageTag());
      }
    }
  });
}
