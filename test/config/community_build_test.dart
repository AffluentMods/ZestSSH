import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/cloud/observed_client.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/services/passkeys/windows_webauthn.dart';
import 'package:zestssh/services/store_handover_start.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/services/update_manifest.dart';
import 'package:zestssh/utils/help_links.dart';

/// A build made without `--dart-define=ZEST_OFFICIAL=true` is a community
/// build. It
/// knows no address of the release's, so it cannot sign anyone in to ZestSSH
/// Cloud, read the release's update feed, take the Store's copy's data, or
/// show the release's policy, support address or store page as its own.
///
/// The tests run as the release (test/flutter_test_config.dart). These ask
/// for the community build, and put the release back.
void main() {
  setUp(() {
    debugZestOfficial = false;
    addTearDown(() => debugZestOfficial = true);
  });

  test('it is not the release, and holds no address of the release', () {
    expect(zestOfficial, isFalse);
    expect(zestHasCloud, isFalse);
    for (final value in [
      kZestApiBase,
      kZestApiHost,
      kZestEntitlementsUrl,
      kZestWebsite,
      kZestAuthPage,
      kZestPasskeyRpId,
      kZestPasskeyOrigin,
      kZestDocsOrigin,
      kZestDocsHost,
      kZestPrivacyUrl,
      kZestTermsUrl,
      kZestDownloadPage,
      kZestJoinLinkBase,
      kZestUpdateHost,
      kZestUpdateKey,
      kZestUpdateKey2,
      kZestAppStoreId,
      kZestPlayPackage,
      kZestAppStoreUrl,
      kZestPlayStoreUrl,
      kZestMakerUrl,
      kZestSupportAddress,
      kZestDiscordInvite,
      // What is made from them is nothing too, never a path with no site.
      kZestDocsUrl,
      kZestFaqUrl,
      kZestChangelogUrl,
      kZestPlansUrl,
      kZestDiscordUrl,
      kZestSupportEmail,
      kZestSupportMailto,
      kZestDocsImporting,
      kZestDocsConnectionIssues,
      kZestDocsSyncNotWorking,
      kZestDocsWhatIsAnSshKey,
      kTwoStepWebPage,
      kUpdateManifestUrl,
      kBuildUpdateManifestUrl,
      kUpdateDownloadHost,
      kUpdateDownloadFallback,
      kWindowsPasskeyRpId,
      kWindowsPasskeyOrigin,
    ]) {
      expect(value, '');
    }
    expect(kUpdateSigningPublicKeys, isEmpty);
  });

  test('the release comes back when a test has had its community build', () {
    debugZestOfficial = true;
    expect(zestOfficial, isTrue);
    expect(kZestApiBase, 'https://api.zestssh.com/v1');
  });

  group('the updater', () {
    test('there is none: no check is offered, and a check asks nobody', () async {
      expect(updaterSetUp, isFalse);
      expect(UpdateCheckService.manualCheckSupported, isFalse);
      var asked = 0;
      final service = UpdateCheckService(
        client: MockClient((request) async {
          asked++;
          return http.Response('{}', 200);
        }),
        storeBuild: false,
      );
      expect(service.manifestUrl, '');
      expect(service.checksForUpdates, isFalse);
      expect(await service.check(), isNull);
      expect(await service.checkNow(), isA<UpdateCheckFailed>());
      expect(asked, 0);
    });

    test('nothing is a download or a manifest of its own, an address with no host least of all', () {
      for (final url in [
        'https:///downloads/ZestSSH-Setup.exe',
        'https://zestssh.com/downloads/ZestSSH-Setup.exe',
        'https://example.com/downloads/ZestSSH-Setup.exe',
      ]) {
        expect(isAllowedDownloadUrl(Uri.parse(url)), isFalse, reason: url);
        expect(isAllowedReleasePage(Uri.parse(url)), isFalse, reason: url);
      }
      expect(isAllowedManifestUrl(Uri.parse('https:///app/latest.json')), isFalse);
      expect(isAllowedManifestUrl(Uri.parse('https://zestssh.com/app/latest.json')), isFalse);
      // A build setting for a test manifest names the release's host: not taken.
      expect(updateManifestUrlFor('https://zestssh.com/downloads/test.json'), '');
    });

    test('a manifest signed with the release key is not believed: the build trusts no key', () async {
      expect(
        await verifyManifestSignature({'version': '9.9.9', 'signature': 'A' * 86 + '=='}),
        isNot(ManifestSignature.good),
      );
    });
  });

  test('the Store hand-over: nothing is handed over, taken in or asked, and the start goes on', () async {
    var prefsAsked = 0;
    final ends = await storeHandoverAtStart(
      rawPrefs: () async {
        prefsAsked++;
        return SharedPreferences.getInstance();
      },
      storeBuild: false,
      packaged: () => fail('a community build does not ask whether it is a package'),
      takeLock: (h, wait) => fail('a community build takes no hand-over lock'),
      storeCopyVersion: () => fail('a community build does not look for the Store copy'),
    );
    expect(ends, isFalse);
    expect(prefsAsked, 0);

    // The Store's own build of a community tree: the same.
    expect(
      await storeHandoverAtStart(
        rawPrefs: () => fail('not asked'),
        storeBuild: true,
        takeLock: (h, wait) => fail('a community build takes no hand-over lock'),
      ),
      isFalse,
    );
  });

  test('a request to a service the build does not have is refused before it is made', () async {
    var sent = 0;
    final client = ObservedClient(
      MockClient((request) async {
        sent++;
        return http.Response('', 200);
      }),
      watches: (url) => isCloudExchange(url, apiBase: kZestApiBase),
      listener: () => (status, error) => fail('nobody is told of a request that was never made'),
    );
    // What every part of the app makes of an empty API address.
    for (final url in ['$kZestApiBase/auth/session', '$kZestApiBase/health', kZestEntitlementsUrl]) {
      await expectLater(client.get(Uri.parse(url)), throwsA(isA<NoServiceInThisBuild>()), reason: url);
      await expectLater(client.post(Uri.parse(url), body: 'x'), throwsA(isA<http.ClientException>()), reason: url);
    }
    expect(sent, 0);
  });

  test('pointed at a service of its own, it says to that service that it is not the release; the release says nothing',
      () async {
    final seen = <String?>[];
    final client = ObservedClient(
      MockClient((request) async {
        seen.add(request.headers['X-ZestSSH-Build']);
        return http.Response('', 200);
      }),
      watches: (url) => url.host == 'api.example.org',
      listener: () => null,
    );
    await client.get(Uri.parse('https://api.example.org/v1/feedback'));
    // (Not to anybody else's address.)
    await client.get(Uri.parse('https://storage.example.net/file'));
    debugZestOfficial = true;
    await client.get(Uri.parse('https://api.example.org/v1/feedback'));
    expect(seen, ['community', null, null]);
  });

  test('what it copies into a report names it, by the name the builder gave or as a community build', () {
    expect(zestBuildNameShown, '');
  });

  test('Windows is asked for nobody\'s passkey', () {
    final options = <String, Object?>{
      'challenge': 'AAAA',
      'rp': {'id': 'zestssh.com', 'name': 'ZestSSH'},
      'user': {'id': 'AAAA', 'name': 'ada@example.com', 'displayName': 'Ada'},
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
      ],
    };
    expect(() => winCreationOf(options), throwsA(isA<PasskeyError>()));
    expect(() => winAssertionRequestOf({'challenge': 'AAAA', 'rpId': 'zestssh.com'}), throwsA(isA<PasskeyError>()));
    // With no RP ID named in the options either: still nobody's.
    expect(() => winAssertionRequestOf({'challenge': 'AAAA'}), throwsA(isA<PasskeyError>()));
  });
}
