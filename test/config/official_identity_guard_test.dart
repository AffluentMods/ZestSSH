import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/services/update_manifest.dart';
import 'package:zestssh/utils/help_links.dart';

/// Every address and name that says "this is the
/// release, and these are its servers" is written in one file,
/// lib/config/official_identity.dart, as a build setting. This reads lib/ and
/// fails when one is written anywhere else, so that a build made by someone
/// else can be pointed at its own services from one place.
///
/// It is being reached in steps. A literal whose every use has moved is held
/// at none. One still being moved is held at the number of code lines it had
/// when this test was last changed: the number may only go down, and whoever
/// moves the last of them sets it to none.
void main() {
  /// Code lines of lib/ (comments left out) that hold [literal], outside the
  /// identity file and what is generated.
  List<String> uses(String literal) {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      if (path.contains('l10n/generated') || path.endsWith('config/official_identity.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (lines[i].contains(literal)) found.add('$path:${i + 1}');
      }
    }
    return found;
  }

  test('the API address, the support address, the Discord invite: written in the identity file alone', () {
    expect(uses('api.zestssh.com'), isEmpty);
    expect(uses('support@zestssh.com'), isEmpty);
    expect(uses('discord.gg'), isEmpty);
  });

  test('the website, the store pages, the maker\'s site: written in the identity file alone', () {
    expect(uses('https://zestssh.com'), isEmpty);
    expect(uses('affluentlabs.dev'), isEmpty);
    expect(uses('6760552523'), isEmpty);
    expect(uses('apps.apple.com'), isEmpty);
    expect(uses('play.google.com'), isEmpty);
    // The release key of the updater.
    expect(uses('GsjKopCNQaxpGUF9UEkbExb3ZEs79AD8hPPU04534+4='), isEmpty);
  });

  test('what is still being moved does not grow: the package id; and the one line of history that stays', () {
    // (Each number: the code lines when last counted. Lower it as they move; never raise it.)
    // The docs site's one is a line of the changelog, which says what a past version did and
    // stays as it was written. The package id's are the data folders, the secure storage and
    // the platform channels' names: the identity of the installed program.
    const stillToMove = {
      'docs.zestssh.com': 1,
      'com.affluentlabs.zestssh': 21,
    };
    for (final e in stillToMove.entries) {
      final found = uses(e.key);
      expect(found.length, lessThanOrEqualTo(e.value),
          reason: '${e.key} is written in more places than before:\n${found.join('\n')}');
    }
  });

  test('the passkey RP ID is written in the identity file alone, and nothing in lib/ asks for the official identity', () {
    expect(uses("'zestssh.com'"), isEmpty);
    // Only tests and the repository's tools may: in the app, the build's flag alone decides.
    expect(uses('debugZestOfficial'), isEmpty);
    expect(uses("'ZEST_OFFICIAL'"), isEmpty);
  });

  test('the release (ZEST_OFFICIAL, which the tests are given) with no other setting is the build it always was', () {
    expect(zestOfficial, isTrue);
    expect(zestHasCloud, isTrue);
    expect(kZestAuthPage, 'https://zestssh.com/auth?platform=desktop');
    expect(kZestPasskeyRpId, 'zestssh.com');
    expect(kZestPasskeyOrigin, 'https://zestssh.com');
    expect(kZestApiBase, 'https://api.zestssh.com/v1');
    expect(kZestApiHost, 'api.zestssh.com');
    expect(kZestEntitlementsUrl, 'https://api.zestssh.com/v1/entitlements');
    expect(kZestWebsite, 'https://zestssh.com');
    expect(kZestDocsOrigin, 'https://docs.zestssh.com');
    expect(kZestSupportAddress, 'support@zestssh.com');
    expect(kZestDiscordInvite, 'https://discord.gg/NnkUwxSdFX');
    expect(kZestDocsHost, 'docs.zestssh.com');
    expect(kZestPrivacyUrl, 'https://zestssh.com/privacy');
    expect(kZestTermsUrl, 'https://zestssh.com/terms');
    expect(kZestDownloadPage, 'https://zestssh.com/download');
    expect(kZestJoinLinkBase, 'https://zestssh.com/join');
    expect(kZestAppStoreUrl, 'https://apps.apple.com/app/zestssh/id6760552523');
    expect(kZestPlayStoreUrl, 'https://play.google.com/store/apps/details?id=com.affluentlabs.zestssh');
    expect(kZestMakerUrl, 'https://affluentlabs.dev');
    // The updater: the release's host, feed and key, as they were.
    expect(kUpdateDownloadHost, 'zestssh.com');
    expect(kUpdateManifestUrl, 'https://zestssh.com/app/latest.json');
    expect(kUpdateSigningPublicKeys, ['GsjKopCNQaxpGUF9UEkbExb3ZEs79AD8hPPU04534+4=']);
    // What is made from them reads as it did.
    expect(kZestDocsUrl, 'https://docs.zestssh.com/');
    expect(kZestFaqUrl, 'https://zestssh.com/faq');
    expect(kZestChangelogUrl, 'https://zestssh.com/changelog');
    expect(kZestPlansUrl, 'https://zestssh.com/pricing/plans');
    expect(kZestSupportEmail, 'support@zestssh.com');
    expect(kZestSupportMailto, 'mailto:support@zestssh.com?subject=ZestSSH%20support');
    expect(kZestDocsImporting, 'https://docs.zestssh.com/getting-started/importing-from-other-apps/');
    expect(kZestDocsConnectionIssues, 'https://docs.zestssh.com/troubleshooting/connection-issues/');
    expect(kZestDocsSyncNotWorking, 'https://docs.zestssh.com/troubleshooting/sync-not-working/');
    expect(kZestDocsWhatIsAnSshKey, 'https://docs.zestssh.com/getting-started/what-is-an-ssh-key/');
  });
}
