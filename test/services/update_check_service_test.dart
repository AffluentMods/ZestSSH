import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/services/update_manifest.dart';

/// Version comparison decides whether the update banner appears, so a wrong
/// answer either nags a user who is up to date or hides a real update. It's
/// a pure function; pin its behaviour.
void main() {
  // A test's own release key: the manifests below are signed with it as the
  // website's release script signs (update_manifest.dart).
  late List<String> testKeys;
  late SimpleKeyPair testPair;

  setUpAll(() async {
    testPair = await Ed25519().newKeyPair();
    testKeys = [base64.encode((await testPair.extractPublicKey()).bytes)];
  });

  Future<Map<String, Object?>> signed(Map<String, Object?> manifest) async {
    final sig = await Ed25519().sign(canonicalManifestBytes(manifest), keyPair: testPair);
    return {...manifest, 'signature': base64.encode(sig.bytes)};
  }

  group('compareVersions', () {
    test('detects a newer patch / minor / major', () {
      expect(compareVersions('1.5.42', '1.5.41'), greaterThan(0));
      expect(compareVersions('1.6.0', '1.5.99'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
    });

    test('detects an older version', () {
      expect(compareVersions('1.5.40', '1.5.41'), lessThan(0));
      expect(compareVersions('1.4.0', '1.5.0'), lessThan(0));
    });

    test('treats equal versions as equal', () {
      expect(compareVersions('1.5.41', '1.5.41'), 0);
    });

    test('ignores a +build suffix', () {
      expect(compareVersions('1.5.41+63', '1.5.41+9'), 0);
      expect(compareVersions('1.5.42+1', '1.5.41+999'), greaterThan(0));
    });

    test('pads missing trailing components with zero', () {
      expect(compareVersions('1.5', '1.5.0'), 0);
      expect(compareVersions('1.5.1', '1.5'), greaterThan(0));
      expect(compareVersions('2', '1.9.9'), greaterThan(0));
    });

    test('does NOT do lexical comparison (10 > 9)', () {
      // The classic string-compare bug: '1.5.10' < '1.5.9' lexically.
      expect(compareVersions('1.5.10', '1.5.9'), greaterThan(0));
    });

    test('a malformed component is treated as 0, never "newer"', () {
      // A hostile/garbage manifest must not be able to claim it is ahead.
      expect(compareVersions('1.5.x', '1.5.0'), 0);
      expect(compareVersions('junk', '1.5.41'), lessThan(0));
      expect(compareVersions('', '0.0.0'), 0);
    });
  });

  group('compareReleases: the build counts only between builds of one version', () {
    test('the version decides first, whatever the builds say', () {
      expect(compareReleases('3.0.1', 1, '3.0.0', 999), greaterThan(0));
      expect(compareReleases('3.0.0', 999, '3.0.1', 1), lessThan(0));
      expect(compareReleases('3.0.1', null, '3.0.0', 280), greaterThan(0));
    });

    test('the same version: the higher build is newer (3.0.0+280 over 3.0.0+279)', () {
      expect(compareReleases('3.0.0', 280, '3.0.0', 279), greaterThan(0));
      expect(compareReleases('3.0.0', 279, '3.0.0', 280), lessThan(0));
      expect(compareReleases('3.0.0', 280, '3.0.0', 280), 0);
    });

    test('an unknown build never makes a release newer', () {
      expect(compareReleases('3.0.0', null, '3.0.0', 279), 0);
      expect(compareReleases('3.0.0', 280, '3.0.0', null), 0);
      expect(compareReleases('3.0.0', null, '3.0.0', null), 0);
    });
  });

  group("the manifest's URL: the live one, unless a test build was MADE with another", () {
    test('a build made without ZEST_UPDATE_MANIFEST_URL reads the live manifest', () {
      expect(kUpdateManifestUrlFromBuild, isEmpty);
      expect(kBuildUpdateManifestUrl, kUpdateManifestUrl);
      expect(kBuildUpdateManifestUrl, 'https://zestssh.com/app/latest.json');
      expect(UpdateCheckService().manifestUrl, kUpdateManifestUrl);
    }, skip: kUpdateManifestUrlFromBuild.isNotEmpty ? 'this run was made with ZEST_UPDATE_MANIFEST_URL' : false);

    test('a build made with it reads that one (where it is allowed), and a service asks there', () {
      expect(kBuildUpdateManifestUrl, updateManifestUrlFor(kUpdateManifestUrlFromBuild));
      expect(UpdateCheckService().manifestUrl, kBuildUpdateManifestUrl);
    }, skip: kUpdateManifestUrlFromBuild.isEmpty ? 'this run was made without ZEST_UPDATE_MANIFEST_URL' : false);

    test('the release builds read .env, which never sets it', () {
      // Every release is built with --dart-define-from-file=.env: a test
      // manifest's URL there would ship in a release. Where there is no .env
      // (every checkout but the one releases are built from) the test says
      // it was skipped: it returned early and counted as passed. And what it
      // finds is said as a yes or no: a failure printed the whole file,
      // secrets and all, into the test log (found in a review).
      final env = File('.env');
      if (!env.existsSync()) {
        markTestSkipped('no .env in this checkout: the release builds\' file was not checked');
        return;
      }
      final setsIt = env.readAsLinesSync().any((line) => line.contains('ZEST_UPDATE_MANIFEST_URL'));
      expect(setsIt, isFalse, reason: '.env sets ZEST_UPDATE_MANIFEST_URL (its value is not shown here)');
    });

    test('a test manifest under zestssh.com/downloads/ is taken', () {
      const test = 'https://zestssh.com/downloads/updtest-4b6b1595c9adb12c-latest.json';
      expect(updateManifestUrlFor(test), test);
      expect(updateManifestUrlFor(kUpdateManifestUrl), kUpdateManifestUrl);
      expect(updateManifestUrlFor('https://ZestSSH.com/downloads/t.json'), 'https://zestssh.com/downloads/t.json');
    });

    test('anything else is ignored, and the live manifest read', () {
      for (final bad in [
        '',
        'http://zestssh.com/downloads/t.json',
        'https://evil.example/downloads/t.json',
        'https://zestssh.com.evil.example/downloads/t.json',
        'https://evil.example@zestssh.com/downloads/t.json',
        'https://zestssh.com:8443/downloads/t.json',
        'https://zestssh.com/downloads/t.json?x=1',
        'https://zestssh.com/downloads/t.json#x',
        'https://zestssh.com/downloads/sub/t.json',
        'https://zestssh.com/downloads/../app/x.json',
        'https://zestssh.com/downloads/t.exe',
        'https://zestssh.com/other/t.json',
        'https://api.zestssh.com/app/latest.json',
        'file:///C:/t.json',
        'not a url',
      ]) {
        expect(updateManifestUrlFor(bad), kUpdateManifestUrl, reason: bad);
      }
    });

    test('a service given a test URL asks there and nowhere else', () async {
      PackageInfo.setMockInitialValues(
          appName: 'ZestSSH', packageName: 'com.zestssh.app', version: '3.0.0', buildNumber: '279', buildSignature: '');
      final asked = <Uri>[];
      final service = UpdateCheckService(
        manifestUrl: updateManifestUrlFor('https://zestssh.com/downloads/updtest-x-latest.json'),
        trustedKeys: testKeys,
        client: MockClient((r) async {
          asked.add(r.url);
          return http.Response(jsonEncode({'version': '3.0.0'}), 200);
        }),
      );
      await service.checkNow();
      expect(asked, [Uri.parse('https://zestssh.com/downloads/updtest-x-latest.json')]);
    });
  });

  group('a build of the running version (3.0.0+279 is told of 3.0.0+280)', () {
    setUp(() => PackageInfo.setMockInitialValues(
          appName: 'ZestSSH',
          packageName: 'com.zestssh.app',
          version: '3.0.0',
          buildNumber: '279',
          buildSignature: '',
        ));

    UpdateCheckService serving(Object body) => UpdateCheckService(
          trustedKeys: testKeys,
          platform: UpdatePlatform.windows,
          client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
        );

    test('a higher build of the same version, signed, is offered with its file', () async {
      final outcome = await serving(await signed({
        'version': '3.0.0',
        'build': 280,
        'platforms': {
          'windows': {'url': 'https://zestssh.com/downloads/updtest-x-ZestSSH-3.0.0-b280-Setup.exe', 'sha256': 'a' * 64, 'size': 22},
        },
      })).checkNow();
      final info = (outcome as UpdateAvailable).info;
      expect(info.version, '3.0.0');
      expect(info.build, 280);
      expect(info.package!.fileName, 'updtest-x-ZestSSH-3.0.0-b280-Setup.exe');
    });

    test('the same build, a lower one, or none named: up to date', () async {
      for (final m in <Map<String, Object?>>[
        {'version': '3.0.0', 'build': 279},
        {'version': '3.0.0', 'build': 278},
        {'version': '3.0.0'},
        {'version': '2.3.0', 'build': 999},
      ]) {
        expect(await serving(await signed(m)).checkNow(), isA<UpdateCheckUpToDate>(), reason: '$m');
      }
    });

    test('a higher build that is not signed is refused, as a higher version is', () async {
      final outcome = await serving({'version': '3.0.0', 'build': 280}).checkNow();
      expect((outcome as UpdateCheckFailed).refused, isTrue);
      final good = await signed({'version': '3.0.0', 'build': 280});
      final tampered = {...good, 'build': 281};
      expect(((await serving(tampered).checkNow()) as UpdateCheckFailed).refused, isTrue,
          reason: 'the build is signed with the rest');
    });
  });

  group('a build that a store keeps up to date', () {
    setUp(() => PackageInfo.setMockInitialValues(
          appName: 'ZestSSH',
          packageName: 'com.zestssh.app',
          version: '2.2.1',
          buildNumber: '255',
          buildSignature: '',
        ));

    /// A service whose website has a newer release, and how often it was asked.
    Future<(UpdateCheckService, List<http.BaseRequest>)> withNewerRelease({required bool storeBuild}) async {
      final asked = <http.BaseRequest>[];
      final body = jsonEncode(await signed({'version': '9.9.9', 'url': 'https://zestssh.com/download'}));
      final service = UpdateCheckService(
        storeBuild: storeBuild,
        trustedKeys: testKeys,
        client: MockClient((request) async {
          asked.add(request);
          return http.Response(body, 200);
        }),
      );
      return (service, asked);
    }

    test('asks the website nothing, and so offers no update, where another build is told of one', () async {
      final (store, askedByStore) = await withNewerRelease(storeBuild: true);
      expect(await store.check(), isNull);
      expect(await store.checkNow(), isA<UpdateCheckFailed>());
      expect(askedByStore, isEmpty, reason: 'no request leaves a store build');

      final (website, askedByWebsite) = await withNewerRelease(storeBuild: false);
      expect((await website.check())?.version, '9.9.9');
      expect([for (final r in askedByWebsite) r.url], [Uri.parse(kBuildUpdateManifestUrl)]);
    });

    test('the check sends nothing about the device: no version, no id, no query', () async {
      final (website, asked) = await withNewerRelease(storeBuild: false);
      await website.checkNow();
      final r = asked.single;
      expect(r.method, 'GET');
      expect(r.url.hasQuery, isFalse);
      expect(r.headers.keys.map((k) => k.toLowerCase()), ['accept']);
      expect(r.headers.values.join(' '), isNot(contains('2.2.1')));
    });

    test('only a computer that is no store\'s asks the website: never a phone or a tablet, whatever its screen '
        'shows (a large Android tablet held sideways has the computer\'s shell, and its Play copy was told of the '
        'website\'s releases)', () {
      for (final system in ['windows', 'macos', 'linux']) {
        expect(UpdateCheckService.checksOn(system, storeBuild: false), isTrue, reason: system);
        expect(UpdateCheckService.checksOn(system, storeBuild: true), isFalse, reason: '$system, a store build');
      }
      for (final system in ['android', 'ios', 'fuchsia']) {
        expect(UpdateCheckService.checksOn(system, storeBuild: false), isFalse, reason: system);
        expect(UpdateCheckService.checksOn(system, storeBuild: true), isFalse, reason: system);
      }
      // These tests run on a computer: the service asks as checksOn says for it.
      expect(UpdateCheckService(storeBuild: false).checksForUpdates,
          UpdateCheckService.checksOn(Platform.operatingSystem, storeBuild: false));
      expect(UpdateCheckService(storeBuild: false).checksForUpdates, isTrue);
      expect(UpdateCheckService(storeBuild: true).checksForUpdates, isFalse);
    });

    test('offers no check of its own, on any computer; a build from the website does on a computer', () {
      expect(UpdateCheckService.manualCheckSupportedIn(storeBuild: true), isFalse);
      // These tests run on a computer.
      expect(UpdateCheckService.manualCheckSupportedIn(storeBuild: false), isTrue);
      // The build under test is no store's: what the status bar and Settings ask is the same.
      expect(kStoreBuild, isFalse);
      expect(UpdateCheckService.manualCheckSupported, isTrue);
    });
  });

  group('checkNow says what it found', () {
    setUp(() => PackageInfo.setMockInitialValues(
          appName: 'ZestSSH',
          packageName: 'com.zestssh.app',
          version: '2.2.1',
          buildNumber: '255',
          buildSignature: '',
        ));

    UpdateCheckService serving(int status, Object body, {UpdatePlatform platform = UpdatePlatform.windows}) =>
        UpdateCheckService(
          trustedKeys: testKeys,
          platform: platform,
          client: MockClient((_) async =>
              http.Response.bytes(utf8.encode(body is String ? body : jsonEncode(body)), status)),
        );

    test('a newer release', () async {
      final outcome = await serving(200, await signed({
        'version': '2.3.0',
        'url': 'https://zestssh.com/download',
        'critical': true,
      })).checkNow();
      final info = (outcome as UpdateAvailable).info;
      expect(info.version, '2.3.0');
      expect(info.critical, isTrue);
      expect(info.package, isNull, reason: 'no platforms named: the download page is offered');
    });

    test("this computer's file, as the signed manifest names it", () async {
      final manifest = await signed({
        'version': '3.0.1',
        'platforms': {
          'windows': {'url': 'https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe', 'sha256': 'a' * 64, 'size': 22},
          'linux': {'url': 'https://zestssh.com/downloads/ZestSSH-3.0.1-linux-x64.tar.gz', 'sha256': 'b' * 64, 'size': 33},
          'macos': {'url': 'https://evil.example/downloads/ZestSSH-3.0.1.dmg', 'sha256': 'c' * 64, 'size': 44},
        },
      });
      final win = ((await serving(200, manifest).checkNow()) as UpdateAvailable).info.package!;
      expect(win.url.toString(), 'https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe');
      expect(win.size, 22);
      final linux = ((await serving(200, manifest, platform: UpdatePlatform.linux).checkNow()) as UpdateAvailable).info.package!;
      expect(linux.sha256, 'b' * 64);
      // Signed, but from another host: no file to install (the page instead).
      final mac = ((await serving(200, manifest, platform: UpdatePlatform.macos).checkNow()) as UpdateAvailable).info;
      expect(mac.package, isNull);
    });

    test('a newer release that is not signed, or signed by another key, is refused', () async {
      final unsigned = await serving(200, {'version': '9.0.0'}).checkNow();
      expect(unsigned, isA<UpdateCheckFailed>());
      expect((unsigned as UpdateCheckFailed).refused, isTrue);

      final good = await signed({'version': '9.0.0'});
      final tampered = {...good, 'version': '9.0.1'};
      expect(((await serving(200, tampered).checkNow()) as UpdateCheckFailed).refused, isTrue);

      final other = UpdateCheckService(
        client: MockClient((_) async => http.Response(jsonEncode(good), 200)),
      );
      expect(((await other.checkNow()) as UpdateCheckFailed).refused, isTrue,
          reason: 'the release key does not take a test key\'s signature');
    });

    test('the running version is the latest (or ahead of it): no downgrade, signed or not', () async {
      for (final latest in ['2.2.1', '2.2.0', '1.0.0']) {
        for (final body in [{'version': latest}, await signed({'version': latest})]) {
          final outcome = await serving(200, body).checkNow();
          expect((outcome as UpdateCheckUpToDate).current, '2.2.1');
        }
      }
    });

    test('no answer: a server error, a bad or oversized manifest, no network',
        () async {
      expect(await serving(503, 'down').checkNow(), isA<UpdateCheckFailed>());
      expect(await serving(200, 'not json').checkNow(), isA<UpdateCheckFailed>());
      expect(await serving(200, ['2.3.0']).checkNow(), isA<UpdateCheckFailed>());
      expect(await serving(200, {'version': ''}).checkNow(),
          isA<UpdateCheckFailed>());
      expect(await serving(200, 'x' * (64 * 1024 + 1)).checkNow(),
          isA<UpdateCheckFailed>());
      final offline = UpdateCheckService(
          client: MockClient((_) async => throw http.ClientException('offline')));
      expect(await offline.checkNow(), isA<UpdateCheckFailed>());
      expect((await offline.checkNow() as UpdateCheckFailed).refused, isFalse);
    });

    test('a download page that is not https on zestssh.com falls back to the site', () async {
      for (final page in ['http://example.com/x', 'https://evil.example/download', 'javascript:alert(1)']) {
        final outcome = await serving(200, await signed({'version': '9.0.0', 'url': page})).checkNow();
        expect((outcome as UpdateAvailable).info.downloadUrl, kUpdateDownloadFallback, reason: page);
      }
    });

    test('check() still answers with the update or null', () async {
      expect((await serving(200, await signed({'version': '2.3.0'})).check())?.version,
          '2.3.0');
      expect(await serving(200, {'version': '2.2.1'}).check(), isNull);
      expect(await serving(500, '').check(), isNull);
    });
  });
}
