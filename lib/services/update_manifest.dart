/// The update manifest's trust: what makes the app believe that a release
/// it is told about is ZestSSH's, and that the file it downloads for it is
/// the one that was released (3.0, the in-app updater).
///
/// ## The design
///
/// The website serves one static file, https://zestssh.com/app/latest.json.
/// Apps before 3.0 read its top-level `version`, `url`, `notes` and
/// `critical`, which keep their meaning. 3.0 reads two more:
///
/// ```json
/// {
///   "version": "3.0.1", "build": 281, "url": "https://zestssh.com/download",
///   "notes": "...", "critical": false,
///   "platforms": {
///     "windows": {"url": "https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe", "sha256": "<64 hex>", "size": 22123456},
///     "linux":   {"url": "https://zestssh.com/downloads/ZestSSH-3.0.1-linux-x64.tar.gz", "sha256": "...", "size": ...},
///     "macos":   {"url": "https://zestssh.com/downloads/ZestSSH-3.0.1.dmg", "sha256": "...", "size": ...}
///   },
///   "signature": "<base64 Ed25519 signature>"
/// }
/// ```
///
/// The signature is made at release time by the website's release script
/// (ZestSSH-Website scripts/update-manifest-sign.mjs) with the release key,
/// whose private half is kept off this repository and never leaves the
/// release machine. It is made over the UTF-8
/// bytes of [kUpdateSignaturePrefix] followed by the manifest's CANONICAL
/// JSON ([canonicalManifestBytes]): every key but `signature`, object keys
/// sorted at every level, no white space, whole numbers only. The prefix
/// keeps the key's signatures from meaning anything anywhere else.
///
/// The app checks the signature over the manifest AS IT PARSED IT (the
/// canonical bytes are written again from the parsed values), so what was
/// checked is exactly what is used: a manifest that parses two ways (a key
/// twice, odd spacing) cannot show the check one thing and the installer
/// another.
///
/// What the app refuses, before anything is downloaded:
/// * a manifest naming a newer version that is not signed, or whose
///   signature does not verify with a key in [kUpdateSigningPublicKeys]
///   (one that names no newer version is only "up to date": nothing is
///   done with it, and the manifest out before 3.0 was unsigned);
/// * a package whose URL is not https on [kUpdateDownloadHost] under
///   [kUpdateDownloadPath], has a user or a port in it, or whose sha256 is
///   not 64 hex digits or whose size is not a whole number in range
///   ([UpdatePackage.parse]);
/// * a version that is not higher than the running one (no downgrade: an
///   old signed manifest served again says "up to date" and nothing more);
///   of the same version, only a higher `build` than the running copy's,
///   where both are known (compareReleases in update_check_service.dart).
///
/// A TEST build may read its manifest from another URL, chosen when it is
/// compiled (ZEST_UPDATE_MANIFEST_URL, update_check_service.dart), never at
/// runtime and only https on zestssh.com; every check above applies to it
/// unchanged, the release key's signature first.
///
/// And after the download: a file whose size or SHA-256 is not the one the
/// signed manifest names (lib/services/app_updater.dart). The download
/// follows no redirect elsewhere, and the update check and the download
/// send nothing about the device: no version, no id, only plain requests.
///
/// What this does not cover: someone who holds the private key can sign an
/// update every app installs (so the key is kept offline and backed up);
/// someone who can block zestssh.com can keep an app from hearing of an
/// update (it then says "up to date" or "could not check", never installs
/// anything). Of the installers only the Mac's is code-signed (a Developer
/// ID signature, notarized, since 3.4.0); the Windows setup is not (SmartScreen
/// warns of it), so there the signature here is what the app
/// trusts.
library;

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/config/official_identity.dart';

/// The release public keys (raw Ed25519, base64): a manifest signed by any
/// of them is ZestSSH's. A second key can be added here a release before a
/// key is replaced, so that apps out by then take both.
///
/// They are the build's (lib/config/official_identity.dart: ZEST_UPDATE_KEY,
/// ZEST_UPDATE_KEY_2), the release's own unless a build names others. With
/// none, no manifest verifies and no update is offered.
List<String> get kUpdateSigningPublicKeys => [
      if (kZestUpdateKey != '') kZestUpdateKey,
      if (kZestUpdateKey2 != '') kZestUpdateKey2,
    ];

/// What the signed bytes start with: the signature is for this and nothing
/// else.
const String kUpdateSignaturePrefix = 'ZestSSH update manifest v1\n';

/// The one host a release is downloaded from (the website's R2 downloads,
/// served by the site itself: ZestSSH-Website src/lib/releases.js).
String get kUpdateDownloadHost => kZestUpdateHost;

/// Whether this build has an updater at all: a host its releases come from
/// and a key they are signed with. A build that names neither (a community
/// build) asks nobody for a newer version and offers no check.
bool get updaterSetUp => kUpdateDownloadHost != '' && kUpdateSigningPublicKeys.isNotEmpty;

/// The folder the releases are served from on [kUpdateDownloadHost].
const String kUpdateDownloadPath = '/downloads/';

/// The largest file an update may be: the installers are 20 to 60 MB.
const int kUpdateMaxSize = 1024 * 1024 * 1024;

/// The computers that update themselves, as the manifest names them.
enum UpdatePlatform {
  windows,
  linux,
  macos;

  /// The one this app runs on; null on a phone or a tablet.
  static UpdatePlatform? get current {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isLinux) return UpdatePlatform.linux;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    return null;
  }
}

/// One platform's file of a release, as the signed manifest names it.
class UpdatePackage {
  const UpdatePackage({required this.url, required this.sha256, required this.size});

  final Uri url;

  /// Lower-case hex, 64 digits.
  final String sha256;

  /// In bytes.
  final int size;

  /// The file's name, as the URL ends.
  String get fileName => url.pathSegments.isEmpty ? 'update' : url.pathSegments.last;

  /// [raw] read as a package, or null where any of it is not as a release
  /// writes it.
  static UpdatePackage? parse(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    final sha = raw['sha256'];
    final size = raw['size'];
    if (url is! String || sha is! String || size is! int) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !isAllowedDownloadUrl(uri)) return null;
    final hex = sha.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
    if (size <= 0 || size > kUpdateMaxSize) return null;
    return UpdatePackage(url: uri, sha256: hex, size: size);
  }
}

/// Whether [url] is one a release is downloaded from: https on
/// [kUpdateDownloadHost], under [kUpdateDownloadPath], with no user, no
/// port of its own, no query and no fragment, and a file name of letters,
/// digits, dots, dashes and underscores.
bool isAllowedDownloadUrl(Uri url) {
  if (url.scheme != 'https') return false;
  // (No host of its own: nothing is a download of this build's.)
  if (kUpdateDownloadHost == '' || url.host.toLowerCase() != kUpdateDownloadHost) return false;
  if (url.userInfo.isNotEmpty) return false;
  if (url.hasPort && url.port != 443) return false;
  if (url.hasQuery || url.hasFragment) return false;
  final path = url.path;
  if (!path.startsWith(kUpdateDownloadPath)) return false;
  final name = path.substring(kUpdateDownloadPath.length);
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(name) && !name.contains('..');
}

/// Whether [url] is a page the app may open for a release (the download
/// page): https on zestssh.com, with no user and no port of its own.
bool isAllowedReleasePage(Uri url) =>
    url.scheme == 'https' &&
    kUpdateDownloadHost != '' &&
    url.host.toLowerCase() == kUpdateDownloadHost &&
    url.userInfo.isEmpty &&
    (!url.hasPort || url.port == 443);

/// The manifest's canonical JSON, without its `signature`, prefixed with
/// [kUpdateSignaturePrefix]: the bytes its signature is made over. Throws a
/// [FormatException] on what a release never writes (a fraction, a value
/// that is no JSON).
Uint8List canonicalManifestBytes(Map<String, Object?> manifest) {
  final rest = Map<String, Object?>.of(manifest)..remove('signature');
  return Uint8List.fromList(utf8.encode(kUpdateSignaturePrefix + _canonical(rest)));
}

String _canonical(Object? v) {
  if (v == null || v is bool || v is String) return jsonEncode(v);
  if (v is int) return '$v';
  if (v is List) return '[${v.map(_canonical).join(',')}]';
  if (v is Map) {
    final keys = [for (final k in v.keys) k as String]..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(v[k])}').join(',')}}';
  }
  throw FormatException('The update manifest holds a value that is not signed: $v');
}

/// How a manifest's signature stands.
enum ManifestSignature {
  /// Verified with a release key.
  good,

  /// There is none.
  missing,

  /// There is one and it does not verify (the manifest was changed, or
  /// signed with another key), or the manifest cannot be written in the
  /// canonical form.
  bad,
}

/// Checks [manifest]'s `signature` against [trustedKeys] (the release keys
/// unless a test gives its own).
Future<ManifestSignature> verifyManifestSignature(
  Map<String, Object?> manifest, {
  List<String>? trustedKeys,
}) async {
  trustedKeys ??= kUpdateSigningPublicKeys;
  final raw = manifest['signature'];
  if (raw == null) return ManifestSignature.missing;
  if (raw is! String || raw.isEmpty) return ManifestSignature.bad;
  final List<int> sig;
  final Uint8List bytes;
  try {
    sig = base64.decode(raw);
    bytes = canonicalManifestBytes(manifest);
  } on FormatException {
    return ManifestSignature.bad;
  }
  if (sig.length != 64) return ManifestSignature.bad;
  final ed = Ed25519();
  for (final key in trustedKeys) {
    final List<int> pub;
    try {
      pub = base64.decode(key);
    } on FormatException {
      continue;
    }
    if (pub.length != 32) continue;
    final ok = await ed.verify(
      bytes,
      signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
    );
    if (ok) return ManifestSignature.good;
  }
  return ManifestSignature.bad;
}
