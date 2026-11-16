import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/update_manifest.dart';
import 'package:zestssh/utils/logger.dart';

/// Where the app looks for the "latest released version" manifest.
///
/// The website serves a small static JSON here; the app fetches it, compares
/// LOCALLY, and shows a banner if a newer version exists. The request sends
/// NOTHING about this device - no current version, no id, no telemetry - so
/// an update check reveals no more than any plain web request would (an IP
/// and a timestamp), in keeping with the app's no-tracking stance.
///
/// Its shape, and why the app believes it (an Ed25519 signature over its
/// canonical bytes, per-platform files with their SHA-256 and size), are in
/// lib/services/update_manifest.dart.
String get kUpdateManifestUrl => kZestUpdateHost == '' ? '' : 'https://$kZestUpdateHost/app/latest.json';

/// A TEST build's own manifest, set at BUILD time only with
/// `--dart-define=ZEST_UPDATE_MANIFEST_URL=https://zestssh.com/downloads/<name>.json`
/// (the in-app updater's end-to-end test: a test build "A" is told of a
/// test build "B" without the live manifest, which every 2.x and 3.0 app
/// reads, ever changing). Empty in every build made without it, the
/// releases among them: `String.fromEnvironment` is fixed when the app is
/// compiled, so nothing at runtime (a setting, a file, the environment) can
/// set it. It moves only WHERE the manifest is read: the manifest it names
/// must still be signed with a release key, and its files are still only
/// taken from https://zestssh.com/downloads/.
const String kUpdateManifestUrlFromBuild = String.fromEnvironment('ZEST_UPDATE_MANIFEST_URL');

/// The manifest this build reads: [kUpdateManifestUrl], or the one the
/// build was made with ([kUpdateManifestUrlFromBuild]) where that one is
/// allowed ([updateManifestUrlFor]).
String get kBuildUpdateManifestUrl => updateManifestUrlFor(kUpdateManifestUrlFromBuild);

/// The manifest URL for a build made with [fromBuild] (the value of
/// ZEST_UPDATE_MANIFEST_URL, empty without it): [kUpdateManifestUrl] unless
/// [fromBuild] is an allowed manifest URL ([isAllowedManifestUrl]); any
/// other value is ignored, so a mistyped define reads the live manifest.
String updateManifestUrlFor(String fromBuild) {
  if (fromBuild.isEmpty) return kUpdateManifestUrl;
  final uri = Uri.tryParse(fromBuild.trim());
  return uri != null && isAllowedManifestUrl(uri) ? uri.toString() : kUpdateManifestUrl;
}

/// Whether [url] may be a build's update manifest: https on zestssh.com,
/// with no user, no port of its own, no query and no fragment, and either
/// the live manifest's path or a `.json` file of its own under
/// https://zestssh.com/downloads/ (where the website serves what is uploaded
/// to its R2 bucket without a site deploy).
bool isAllowedManifestUrl(Uri url) {
  if (kUpdateDownloadHost == '') return false;
  if (url.scheme != 'https' || url.host.toLowerCase() != kUpdateDownloadHost) return false;
  if (url.userInfo.isNotEmpty || (url.hasPort && url.port != 443)) return false;
  if (url.hasQuery || url.hasFragment) return false;
  if (url.path == Uri.parse(kUpdateManifestUrl).path) return true;
  return isAllowedDownloadUrl(url) && url.path.toLowerCase().endsWith('.json');
}

/// Fallback download page when the manifest omits (or supplies another
/// than a zestssh.com https) `url`.
String get kUpdateDownloadFallback => kZestDownloadPage;

/// A newer release the user can install.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    this.build,
    this.notes,
    this.critical = false,
    this.package,
  });

  final String version;

  /// The download page (always https on zestssh.com).
  final String downloadUrl;
  final int? build;
  final String? notes;

  /// The manifest flagged this as an important/security update - the UI can
  /// present it more prominently (but never force it).
  final bool critical;

  /// This computer's file of the release, as the SIGNED manifest names it:
  /// what "Update and restart" downloads and checks. Null where the release
  /// has none for this platform (the download page is offered instead).
  final UpdatePackage? package;
}

/// What a check found: a newer release, nothing newer, or no answer.
sealed class UpdateCheckOutcome {
  const UpdateCheckOutcome();
}

/// A newer release exists.
class UpdateAvailable extends UpdateCheckOutcome {
  const UpdateAvailable(this.info);
  final UpdateInfo info;
}

/// The running version is the latest released one (or newer).
class UpdateCheckUpToDate extends UpdateCheckOutcome {
  const UpdateCheckUpToDate(this.current);

  /// The running version, e.g. "2.2.1".
  final String current;
}

/// The manifest could not be fetched or read (offline, a server error, a
/// malformed or oversized body), or this platform does not check; or
/// ([refused]) it names a newer version and is not signed by ZestSSH.
class UpdateCheckFailed extends UpdateCheckOutcome {
  const UpdateCheckFailed({this.refused = false});

  /// The manifest named a newer release and its signature was missing or
  /// did not verify: nothing of it is offered.
  final bool refused;
}

/// Whether this build is one that a store keeps up to date: the Microsoft
/// Store's package, built with `--dart-define=ZEST_STORE=true`.
///
/// Such a build asks the website nothing about newer versions and offers
/// no check of its own: the store installs the next version. What the
/// website has is the installer, and that beside a store install would be
/// a second copy of the app, with data of its own. (An App Store build on
/// an iPhone is told apart by its platform, with the same end.)
const bool kStoreBuild = bool.fromEnvironment('ZEST_STORE');

/// Checks a static manifest for a newer app version.
class UpdateCheckService {
  UpdateCheckService({
    http.Client? client,
    String? manifestUrl,
    bool storeBuild = kStoreBuild,
    List<String>? trustedKeys,
    UpdatePlatform? platform,
  })  : _client = client ?? http.Client(),
        _manifestUrl = manifestUrl ?? kBuildUpdateManifestUrl,
        _storeBuild = storeBuild,
        _trustedKeys = trustedKeys ?? kUpdateSigningPublicKeys,
        _platform = platform ?? UpdatePlatform.current;

  final http.Client _client;
  final String _manifestUrl;
  final bool _storeBuild;
  final List<String> _trustedKeys;
  final UpdatePlatform? _platform;

  /// The manifest this service reads.
  String get manifestUrl => _manifestUrl;

  /// Where a check the person asks for (clicking the version) makes sense:
  /// the desktop builds, which update from the website. Store builds update
  /// through their store.
  static bool get manualCheckSupported => updaterSetUp && manualCheckSupportedIn(storeBuild: kStoreBuild);

  /// [manualCheckSupported] for a build that is, or is not, a store's.
  static bool manualCheckSupportedIn({required bool storeBuild}) =>
      !storeBuild && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Returns an [UpdateInfo] when the released version is newer than the
  /// running one, else null.
  ///
  /// NEVER throws. An update check must never break the app or nag on a
  /// flaky network, so every failure path - offline, DNS error, non-200,
  /// oversized or malformed body, timeout - resolves to null. Phones and
  /// tablets are skipped entirely ([checksForUpdates]): store apps must not
  /// steer users to an off-store download.
  Future<UpdateInfo?> check() async {
    final outcome = await checkNow();
    return outcome is UpdateAvailable ? outcome.info : null;
  }

  /// Like [check], but says whether the running version is the latest or
  /// the check could not tell, so a check the person asked for can answer.
  /// Never throws either.
  Future<UpdateCheckOutcome> checkNow() async {
    // A store's build asks nothing: no request is made at all.
    if (!checksForUpdates) return const UpdateCheckFailed();
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;
      final currentBuild = int.tryParse(info.buildNumber.trim());

      // A plain GET: no version, no id, no cookie. (The http client sends
      // its own User-Agent, the same for every copy of the app.)
      final resp = await _client
          .get(Uri.parse(_manifestUrl),
              headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return const UpdateCheckFailed();
      // A manifest is a few hundred bytes; anything large is wrong or
      // hostile, so bound it before decoding.
      if (resp.bodyBytes.length > 64 * 1024) return const UpdateCheckFailed();

      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, Object?>) return const UpdateCheckFailed();

      final latest = decoded['version'];
      if (latest is! String || latest.isEmpty) return const UpdateCheckFailed();
      final latestBuild = decoded['build'] is int ? decoded['build'] as int : null;
      // Not newer: nothing is done with it, signed or not (the manifest out
      // before 3.0 was unsigned). No downgrade is ever offered. The same
      // version is newer only by a higher build number ([compareReleases]).
      if (compareReleases(latest, latestBuild, current, currentBuild) <= 0) {
        return UpdateCheckUpToDate(current);
      }

      // Newer: only a manifest signed with a release key is believed
      // (update_manifest.dart says why and how).
      final signature = await verifyManifestSignature(decoded, trustedKeys: _trustedKeys);
      if (signature != ManifestSignature.good) {
        AppLogger.warning('Update manifest for $latest refused: signature ${signature.name}');
        return const UpdateCheckFailed(refused: true);
      }

      final rawUrl = decoded['url'];
      final page = rawUrl is String ? Uri.tryParse(rawUrl) : null;
      final url = page != null && isAllowedReleasePage(page) ? rawUrl as String : kUpdateDownloadFallback;

      final platforms = decoded['platforms'];
      final package = _platform != null && platforms is Map ? UpdatePackage.parse(platforms[_platform.name]) : null;

      return UpdateAvailable(UpdateInfo(
        version: latest,
        downloadUrl: url,
        build: latestBuild,
        notes: decoded['notes'] is String && (decoded['notes'] as String).isNotEmpty
            ? decoded['notes'] as String
            : null,
        critical: decoded['critical'] == true,
        package: package,
      ));
    } catch (e) {
      AppLogger.info('Update check skipped: $e');
      return const UpdateCheckFailed();
    }
  }

  /// Whether a check asks the website at all: only on a computer (Windows,
  /// macOS, Linux) whose build is no store's. Never on a phone or a tablet,
  /// whatever its screen shows (a large Android tablet held sideways has the
  /// computer's shell, and its Play copy was told of the website's releases),
  /// nor on a store's build: their store keeps them up to date ([checkNow]
  /// makes no request there), so nothing waits for a later check either. And
  /// never in a build with no manifest to read or no key to check it with (a
  /// community build that names no updater of its own).
  bool get checksForUpdates =>
      checksOn(Platform.operatingSystem, storeBuild: _storeBuild) && _manifestUrl != '' && _trustedKeys.isNotEmpty;

  /// Whether [os], named as [Platform.operatingSystem] names it, asks for
  /// updates at all (a build with a manifest and a key; see [checksForUpdates]).
  static bool checksOn(String os, {required bool storeBuild}) =>
      !storeBuild && (os == 'windows' || os == 'macos' || os == 'linux');

  void dispose() => _client.close();
}

/// Compare two dotted version strings, e.g. `compareVersions("1.5.41",
/// "1.5.42") < 0`.
///
/// Returns a negative number if [a] < [b], zero if equal, positive if
/// [a] > [b]. A `+build` suffix is ignored, missing trailing components are
/// treated as 0 (`"1.5" == "1.5.0"`), and any non-numeric component is 0 so
/// a malformed manifest can never claim to be "newer".
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

/// Compares two releases: their versions first ([compareVersions]), and
/// where those are the same, their build numbers, but only where BOTH are
/// known: an unknown build (a manifest without `build`, a copy that cannot
/// read its own) never makes a release newer, so it can only ever hold an
/// update back, never offer one.
///
/// Why the build counts: every public release has a version of its own (a
/// shipped version is never cut again), so between releases the version
/// decides, as it always did. But two builds of one version exist (the
/// test builds before a release, 3.0.0+279 and 3.0.0+280), and the later
/// one is the newer program. Comparing the build too is what lets such a
/// build update to the next, and changes nothing between versions.
int compareReleases(String aVersion, int? aBuild, String bVersion, int? bBuild) {
  final byVersion = compareVersions(aVersion, bVersion);
  if (byVersion != 0 || aBuild == null || bBuild == null) return byVersion;
  return aBuild.compareTo(bBuild);
}
