import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/update_manifest.dart';

/// The trust of the in-app updater: a manifest that names a new release is
/// believed only with a good Ed25519 signature from a release key, over the
/// canonical bytes the website's signer writes (lib/services/update_manifest.dart).
void main() {
  Map<String, Object?> fixture(String name) =>
      jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, Object?>;

  /// A test's own key pair and a manifest signed with it, as the release
  /// script signs (prefix + canonical JSON).
  Future<(List<String>, Map<String, Object?>)> signedWithTestKey(Map<String, Object?> manifest) async {
    final ed = Ed25519();
    final pair = await ed.newKeyPair();
    final pub = await pair.extractPublicKey();
    final sig = await ed.sign(canonicalManifestBytes(manifest), keyPair: pair);
    return ([base64.encode(pub.bytes)], {...manifest, 'signature': base64.encode(sig.bytes)});
  }

  Map<String, Object?> sample() => {
        'version': '3.0.1',
        'build': 281,
        'url': 'https://zestssh.com/download',
        'notes': 'Faster SFTP.',
        'critical': false,
        'platforms': {
          'windows': {'url': 'https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe', 'sha256': 'a' * 64, 'size': 22123456},
        },
      };

  group('the website and the app write the same signed bytes', () {
    test('a manifest signed by the website\'s signer (node) verifies here, byte for byte', () async {
      final f = fixture('update_manifest_signed.json');
      final manifest = f['manifest'] as Map<String, Object?>;
      expect(utf8.decode(canonicalManifestBytes(manifest)), f['canonical'],
          reason: 'notes with quotes, a tab, a new line, umlauts and Chinese: the same canonical text in both');
      expect(await verifyManifestSignature(manifest, trustedKeys: [f['test_public_key'] as String]), ManifestSignature.good);
    });

    test('the release key built into the app is the one the release script signs with', () async {
      final vector = fixture('update_manifest_release_key.json');
      expect(vector['version'], '0.0.1', reason: 'a harmless vector: older than every release');
      expect(await verifyManifestSignature(vector), ManifestSignature.good);
    });

    test('keys are sorted at every level, there is no white space, and the signature is left out', () {
      final text = utf8.decode(canonicalManifestBytes({
        'b': 1,
        'a': {'z': true, 'y': null},
        'signature': 'x',
      }));
      expect(text.substring(0, kUpdateSignaturePrefix.length), kUpdateSignaturePrefix);
      expect(text.substring(kUpdateSignaturePrefix.length), '{"a":{"y":null,"z":true},"b":1}');
    });

    test('a fraction cannot be signed (a release writes whole numbers only)', () {
      expect(() => canonicalManifestBytes({'size': 1.5}), throwsFormatException);
    });
  });

  group('a signature is refused', () {
    test('a good one is good', () async {
      final (keys, signed) = await signedWithTestKey(sample());
      expect(await verifyManifestSignature(signed, trustedKeys: keys), ManifestSignature.good);
    });

    test('where any value was changed after signing', () async {
      final (keys, signed) = await signedWithTestKey(sample());
      final cases = <Map<String, Object?>>[
        {...signed, 'version': '9.9.9'},
        {...signed, 'notes': 'Faster SFTP!'},
        {...signed, 'critical': true},
        {...signed, 'extra': 'added'},
        {
          ...signed,
          'platforms': {
            'windows': {'url': 'https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe', 'sha256': 'b' * 64, 'size': 22123456},
          },
        },
      ];
      for (final c in cases) {
        expect(await verifyManifestSignature(c, trustedKeys: keys), ManifestSignature.bad);
      }
    });

    test('where it was made with another key', () async {
      final (_, signed) = await signedWithTestKey(sample());
      final (otherKeys, _) = await signedWithTestKey(sample());
      expect(await verifyManifestSignature(signed, trustedKeys: otherKeys), ManifestSignature.bad);
      // The release key does not take a test key's signature either.
      expect(await verifyManifestSignature(signed), ManifestSignature.bad);
    });

    test('where there is none, or it is no signature at all', () async {
      expect(await verifyManifestSignature(sample()), ManifestSignature.missing);
      for (final junk in <Object>['', 'not base64!', base64.encode([1, 2, 3]), 42]) {
        expect(await verifyManifestSignature({...sample(), 'signature': junk}), ManifestSignature.bad);
      }
    });
  });

  group('where a release may come from', () {
    test('https on zestssh.com under /downloads/ only', () {
      bool ok(String u) => isAllowedDownloadUrl(Uri.parse(u));
      expect(ok('https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe'), isTrue);
      expect(ok('https://ZESTSSH.com/downloads/ZestSSH-3.0.1.dmg'), isTrue);
      expect(ok('https://zestssh.com:443/downloads/ZestSSH-3.0.1.dmg'), isTrue);
      for (final bad in [
        'http://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe',
        'https://evil.example/downloads/ZestSSH-3.0.1-Setup.exe',
        'https://zestssh.com.evil.example/downloads/x.exe',
        'https://downloads.zestssh.com/downloads/x.exe',
        'https://user:pw@zestssh.com/downloads/x.exe',
        'https://zestssh.com:8443/downloads/x.exe',
        'https://zestssh.com/other/x.exe',
        'https://zestssh.com/downloads/',
        'https://zestssh.com/downloads/sub/x.exe',
        'https://zestssh.com/downloads/x.exe?y=1',
        'https://zestssh.com/downloads/x.exe#y',
        'https://zestssh.com/downloads/..%2Fx.exe',
        'ftp://zestssh.com/downloads/x.exe',
      ]) {
        expect(ok(bad), isFalse, reason: bad);
      }
    });

    test('a package needs an allowed URL, 64 hex digits and a size in range', () {
      final good = {'url': 'https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe', 'sha256': 'AB' * 32, 'size': 10};
      final pkg = UpdatePackage.parse(good)!;
      expect(pkg.sha256, 'ab' * 32, reason: 'compared in lower case');
      expect(pkg.fileName, 'ZestSSH-3.0.1-Setup.exe');
      expect(UpdatePackage.parse({...good, 'url': 'https://evil.example/downloads/x.exe'}), isNull);
      expect(UpdatePackage.parse({...good, 'sha256': 'a' * 63}), isNull);
      expect(UpdatePackage.parse({...good, 'sha256': 'g' * 64}), isNull);
      expect(UpdatePackage.parse({...good, 'size': 0}), isNull);
      expect(UpdatePackage.parse({...good, 'size': kUpdateMaxSize + 1}), isNull);
      expect(UpdatePackage.parse({...good, 'size': '10'}), isNull);
      expect(UpdatePackage.parse('nope'), isNull);
    });

    test('the download page opened is https on zestssh.com', () {
      expect(isAllowedReleasePage(Uri.parse('https://zestssh.com/download')), isTrue);
      expect(isAllowedReleasePage(Uri.parse('https://evil.example/download')), isFalse);
      expect(isAllowedReleasePage(Uri.parse('http://zestssh.com/download')), isFalse);
    });
  });
}
