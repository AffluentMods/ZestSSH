// Who a build is, and where its services are.
//
// Every address, name and id that says "this is ZestSSH, the release, and
// these are its servers" is given its value HERE and nowhere else in lib/.
// The rest of the app reads these. A test
// (test/config/official_identity_guard_test.dart) fails when an official
// address is written anywhere else.
//
// ONE FLAG decides which build this is: --dart-define=ZEST_OFFICIAL=true.
//
//   With it, the build is ZestSSH, the release: every value below is the
//   official one unless a setting names another (a staging server).
//
//   Without it, the build is a community build: every value below is EMPTY
//   unless a setting names the builder's own. An empty address means the
//   feature that needs it is not there: no sign-in, no ZestSSH Cloud, no
//   updater, no upgrade, no link to a website, a policy or a support
//   address that is not the builder's. Connecting to hosts needs none of
//   them.
//
// The values are read at run time (getters, not consts) for one reason: the
// test runner cannot be given a build setting without every test command
// naming it, so the tests ask for the official identity as they start
// (test/flutter_test_config.dart, [debugZestOfficial]) and a few of them ask
// for a community build on purpose. Nothing in lib/ may set it; the guard
// test holds that. And in a release build nothing can: there the official
// values are not compiled in at all unless the flag is ([_mayBeOfficial]),
// so a community release holds no official address to fall back to.

/// Whether this build was made as ZestSSH, the release
/// (--dart-define=ZEST_OFFICIAL=true). Fixed when the app is compiled.
const bool kZestOfficialBuild = bool.fromEnvironment('ZEST_OFFICIAL');

/// What a build that is not the release calls itself (ZEST_BUILD_NAME), as
/// About and a copied report say it: "Community build" where it names none.
const String kZestBuildName = String.fromEnvironment('ZEST_BUILD_NAME');

/// [kZestBuildName] as it is shown and written into a report: at most 40
/// letters, digits, spaces, dots, dashes and underscores (a name is the
/// builder's own words, and goes where a person's support reads it).
String get zestBuildNameShown {
  final kept = kZestBuildName.replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '').trim();
  return kept.length > 40 ? kept.substring(0, 40).trim() : kept;
}

/// False in a release build made without the flag: the official values are
/// then not in the program, whatever is asked for at run time.
const bool _mayBeOfficial = kZestOfficialBuild || !bool.fromEnvironment('dart.vm.product');

bool _official = kZestOfficialBuild;

/// Whether the official values are in use: the flag, in the app. (A test or
/// a tool of the repository may have asked for them: [debugZestOfficial].)
bool get zestOfficial => _official;

/// For tests and the repository's own tools ONLY (the test runner and
/// `dart tool/...` cannot be given the flag without every command naming
/// it). Nothing in lib/ sets it, and in a release build made without the
/// flag it changes nothing.
set debugZestOfficial(bool official) => _official = official && _mayBeOfficial;

/// A setting's value where the build names one, else the official value in
/// an official build, else nothing.
String _value(String named, String official) => named != '' ? named : (_official ? official : '');

/// [path] under [base], or nothing where the build has no [base].
String zestUnder(String base, String path) => base == '' ? '' : '$base$path';

String _hostOf(String url) => url == '' ? '' : (Uri.tryParse(url)?.host ?? '');

/// ZestSSH Cloud's API, with its version path and no slash at the end
/// (SYNC_API_BASE_URL: a staging server's or a fork's own). Empty: the build
/// has no account service, so no sign-in, sync to ZestSSH Cloud, teams,
/// tickets or reports.
String get kZestApiBase =>
    _value(const String.fromEnvironment('SYNC_API_BASE_URL'), _mayBeOfficial ? 'https://api.zestssh.com/v1' : '');

/// Whether the build has an account service at all.
bool get zestHasCloud => kZestApiBase != '';

/// Whether the build has plans to buy, a code to redeem or an upgrade to
/// offer: these are the account service's. A build with none (a community
/// build) offers no upgrade anywhere; what a plan unlocks stays as it is.
bool get zestHasPlans => zestHasCloud;

/// The API's host as people are told of it (a firewall to open, a filter to
/// allow): ZEST_API_HOST, else the host of the API's address.
String get kZestApiHost {
  const named = String.fromEnvironment('ZEST_API_HOST');
  return named != '' ? named : _hostOf(kZestApiBase);
}

/// Where an account's paid plans are read from (ENTITLEMENTS_API_URL, else
/// under the API).
String get kZestEntitlementsUrl {
  const named = String.fromEnvironment('ENTITLEMENTS_API_URL');
  return named != '' ? named : zestUnder(kZestApiBase, '/entitlements');
}

/// The website, with no slash at the end (WEBSITE_URL): sign-in pages, the
/// account's pages, the upgrade, the legal pages, downloads.
String get kZestWebsite =>
    _value(const String.fromEnvironment('WEBSITE_URL'), _mayBeOfficial ? 'https://zestssh.com' : '');

/// The website's host, as a link to it is captioned.
String get kZestWebsiteHost => _hostOf(kZestWebsite);

/// The page a computer's browser is sent to for signing in (AUTH_URL, else
/// the website's).
String get kZestAuthPage {
  const named = String.fromEnvironment('AUTH_URL');
  return named != '' ? named : zestUnder(kZestWebsite, '/auth?platform=desktop');
}

/// Whose passkeys Windows is asked for (ZEST_PASSKEY_RP_ID) and from which
/// origin (ZEST_PASSKEY_ORIGIN, else the website). A build that is not the
/// release must never ask Windows for a zestssh.com passkey.
String get kZestPasskeyRpId =>
    _value(const String.fromEnvironment('ZEST_PASSKEY_RP_ID'), _mayBeOfficial ? 'zestssh.com' : '');
String get kZestPasskeyOrigin {
  const named = String.fromEnvironment('ZEST_PASSKEY_ORIGIN');
  return named != '' ? named : kZestWebsite;
}

/// The documentation site, with no slash at the end (ZEST_DOCS_URL): the
/// guides the app fetches and the pages it links to.
String get kZestDocsOrigin =>
    _value(const String.fromEnvironment('ZEST_DOCS_URL'), _mayBeOfficial ? 'https://docs.zestssh.com' : '');

/// The docs site's host as people are told of it: ZEST_DOCS_HOST, else the
/// host of the docs site's address.
String get kZestDocsHost {
  const named = String.fromEnvironment('ZEST_DOCS_HOST');
  return named != '' ? named : _hostOf(kZestDocsOrigin);
}

/// The website's pages the app opens: the privacy policy, the terms and the
/// download page of the build's own website. A build with no website shows
/// none: the release's policy says nothing about another build.
String get kZestPrivacyUrl => zestUnder(kZestWebsite, '/privacy');
String get kZestTermsUrl => zestUnder(kZestWebsite, '/terms');
String get kZestDownloadPage => zestUnder(kZestWebsite, '/download');

/// What a team's join link starts with, made and taken (ZEST_JOIN_LINK_BASE).
/// Its own setting, not made from the website's: the links a phone opens in
/// the app are the ones its system was told of when the app was installed.
String get kZestJoinLinkBase =>
    _value(const String.fromEnvironment('ZEST_JOIN_LINK_BASE'), _mayBeOfficial ? 'https://zestssh.com/join' : '');

/// The updater (computers): the one host a release is told of and downloaded
/// from (ZEST_UPDATE_HOST), and the keys a release's manifest must be signed
/// with (ZEST_UPDATE_KEY and, for the release before a key is replaced,
/// ZEST_UPDATE_KEY_2: raw Ed25519 public keys, base64). Settings of their
/// own, never made from the website's: what a build installs over itself is
/// decided by these alone. A build with no host or no key takes no update
/// at all, and asks nobody whether there is one.
String get kZestUpdateHost =>
    _value(const String.fromEnvironment('ZEST_UPDATE_HOST'), _mayBeOfficial ? 'zestssh.com' : '');
String get kZestUpdateKey => _value(
      const String.fromEnvironment('ZEST_UPDATE_KEY'),
      // Made 23 October 2026 by ZestSSH-Website scripts/update-signing-key.mjs.
      _mayBeOfficial ? 'GsjKopCNQaxpGUF9UEkbExb3ZEs79AD8hPPU04534+4=' : '',
    );
String get kZestUpdateKey2 => const String.fromEnvironment('ZEST_UPDATE_KEY_2');

/// The app's pages in the stores, where "Rate ZestSSH" and the review prompt
/// send people: the App Store's id (ZEST_APP_STORE_ID) and the Play listing's
/// package (ZEST_PLAY_PACKAGE). A build that is not the release's must not
/// send its people to the release's listing to review it: it names its own,
/// or none (empty: the row is not shown and no review is asked for).
String get kZestAppStoreId =>
    _value(const String.fromEnvironment('ZEST_APP_STORE_ID'), _mayBeOfficial ? '6760552523' : '');
String get kZestPlayPackage =>
    _value(const String.fromEnvironment('ZEST_PLAY_PACKAGE'), _mayBeOfficial ? 'com.affluentlabs.zestssh' : '');
String get kZestAppStoreUrl =>
    kZestAppStoreId == '' ? '' : 'https://apps.apple.com/app/zestssh/id$kZestAppStoreId';
String get kZestPlayStoreUrl =>
    kZestPlayPackage == '' ? '' : 'https://play.google.com/store/apps/details?id=$kZestPlayPackage';

/// Who makes the app, as About and Help link to them (ZEST_MAKER_URL).
String get kZestMakerUrl =>
    _value(const String.fromEnvironment('ZEST_MAKER_URL'), _mayBeOfficial ? 'https://affluentlabs.dev' : '');

/// Where people write for help (ZEST_SUPPORT_EMAIL).
String get kZestSupportAddress =>
    _value(const String.fromEnvironment('ZEST_SUPPORT_EMAIL'), _mayBeOfficial ? 'support@zestssh.com' : '');

/// The community's Discord invite (ZEST_DISCORD_URL).
String get kZestDiscordInvite =>
    _value(const String.fromEnvironment('ZEST_DISCORD_URL'), _mayBeOfficial ? 'https://discord.gg/NnkUwxSdFX' : '');
