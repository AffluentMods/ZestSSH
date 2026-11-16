import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart';

/// ZestSSH Cloud syncs one person's vault on up to 7 devices (its
/// pricing): a device past them is answered with 403 and
/// the code cloud-device-limit (ZestSSH Cloud's src/lib/cloud_devices.js).
/// It is said as that, in the app's language and with its code, once asked:
/// no second request with a fresh sign-in, which changes nothing, and sync
/// pauses as for a setup that is needed. A team vault's items say the same.
class _Cloud {
  final requests = <String>[];
  Map<String, dynamic> refusal = {
    'error': 'ZestSSH Cloud syncs up to 7 devices for one person. Sign out a device you no longer use, then sync this one.',
    'code': 'cloud-device-limit',
    'limit': 7,
  };

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path.replaceFirst('/v1', '');
    requests.add('${request.method} $path');
    if (path.startsWith('/sync/')) return http.Response(jsonEncode(refusal), 403);
    return http.Response(jsonEncode({'error': 'Not found'}), 404);
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final said = ErrorCodes.withCode(l10n.syncCloudDeviceLimit, ErrorCodes.syncCloudDeviceLimit);
  late _Cloud cloud;

  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'session_token': 'st-demo'});
    cloud = _Cloud();
    ZestServerBackend.debugHttpClient = MockClient(cloud.answer);
  });

  tearDown(() => ZestServerBackend.debugHttpClient = null);

  ZestServerBackend hosted() => ZestServerBackend(baseUrl: 'https://cloud.test/v1');

  final limited = isA<SyncCloudDeviceLimitException>().having((e) => e.message, 'message', said);

  test('the status, a pull: said as the 7 devices, with its code, once asked', () async {
    await expectLater(hosted().getStatus(), throwsA(limited));
    await expectLater(hosted().pull(), throwsA(limited));
    expect(cloud.requests, ['GET /sync/status', 'GET /sync/pull'], reason: 'no second request with a fresh sign-in');
    expect(said, endsWith('(ZS-1205)'));
    expect(l10n.syncCloudDeviceLimit, allOf(contains('7'), contains('Devices')));
  });

  test('it pauses sync as a setup that is needed does', () {
    final e = SyncCloudDeviceLimitException(SyncFailure.cloudDeviceLimit);
    expect(e, isA<SyncSetupRequiredException>());
    expect(SyncFailure.ofStore(e, hosted: true).message, said);
  });

  test("a server of the person's own counts no devices: its 403 is not taken for it", () async {
    final own = ZestServerBackend(
      baseUrl: 'https://sync.example.com/v1',
      staticToken: 'demo-token',
      requiresEntitlement: false,
      kind: SyncBackendKind.custom,
    );
    await expectLater(
      own.getStatus(),
      throwsA(isA<SyncException>().having((e) => e, 'kind', isNot(isA<SyncCloudDeviceLimitException>()))),
    );
  });

  test("a team vault's items refused the same way say the same", () {
    const e = OrchardServerException(403, 'cloud-device-limit');
    expect(orchardErrorMessage(e, l10n), l10n.syncCloudDeviceLimit);
  });

  test('the words in every language name the 7 devices and the Devices section, and differ from the English', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.syncCloudDeviceLimit, contains('7'), reason: locale.toLanguageTag());
      expect(words.syncCloudDeviceLimit, contains(words.zestProfileNavDevices), reason: locale.toLanguageTag());
      expect(words.juicedSevenDevices, contains('7'), reason: locale.toLanguageTag());
      if (locale.languageCode != 'en') {
        expect(words.syncCloudDeviceLimit, isNot(l10n.syncCloudDeviceLimit), reason: locale.toLanguageTag());
      }
    }
  });

  // Before, a phone was told the computer's way to its devices.
  test("each device is given its own way to the Devices section: a phone's, a computer's", () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      final phone = cloudDeviceLimitWords(words, onComputer: false);
      final computer = cloudDeviceLimitWords(words, onComputer: true);
      expect(computer, words.syncCloudDeviceLimit, reason: locale.toLanguageTag());
      expect(phone, isNot(computer), reason: locale.toLanguageTag());
      expect(phone, allOf(contains('7'), contains(words.zestProfileNavDevices), contains(words.phoneTabMore),
          contains(words.accountTitle)), reason: locale.toLanguageTag());
    }
    debugCloudDeviceLimitOnComputer = false;
    addTearDown(() => debugCloudDeviceLimitOnComputer = null);
    expect(SyncFailure.cloudDeviceLimit, startsWith(l10n.syncCloudDeviceLimitPhone));
    expect(orchardErrorMessage(const OrchardServerException(403, 'cloud-device-limit'), l10n), l10n.syncCloudDeviceLimitPhone);
  });
}
