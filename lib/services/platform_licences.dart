import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The licences of the native libraries a platform's build carries that are
/// neither a Dart package nor a Rust crate (PDFium and the Firebase C++ SDK
/// on Windows, PDFium on Linux, the pods on iOS and macOS, the Gradle
/// libraries on Android): `assets/licenses/<platform>.txt`, written from the
/// build's own downloads by tool/native_notices.dart.
///
/// Flutter's licence registry holds only what its tool collected (each Dart
/// package's LICENSE or NOTICES, and the files under `flutter: licenses:` in
/// the pubspec), the same on every platform; these differ by platform, so the
/// running platform's file is added here, once, at start. A platform with no
/// file yet adds nothing. Nothing is read until the licences page asks.
void registerPlatformLicences({TargetPlatform? platform, AssetBundle? bundle}) {
  if (kIsWeb || _registered) return;
  final name = platformLicencesAsset(platform ?? defaultTargetPlatform);
  if (name == null) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    final String text;
    try {
      text = await (bundle ?? rootBundle).loadString(name, cache: false);
    } catch (_) {
      return; // no file for this platform in this build
    }
    yield* Stream.fromIterable(parsePlatformLicences(text));
  });
}

bool _registered = false;

/// Lets a test register again.
@visibleForTesting
void resetPlatformLicencesForTest() => _registered = false;

/// The asset with [platform]'s native licences, or null where there is none.
String? platformLicencesAsset(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows => 'assets/licenses/windows.txt',
  TargetPlatform.linux => 'assets/licenses/linux.txt',
  TargetPlatform.macOS => 'assets/licenses/macos.txt',
  TargetPlatform.iOS => 'assets/licenses/ios.txt',
  TargetPlatform.android => 'assets/licenses/android.txt',
  TargetPlatform.fuchsia => null,
};

/// The entries of a NOTICES-style [text], read as Flutter reads the app's own
/// NOTICES: sections split by a line of 80 hyphens, each its names (one per
/// line), a blank line, then the licence.
List<LicenseEntry> parsePlatformLicences(String text) {
  final entries = <LicenseEntry>[];
  for (final raw in text.replaceAll('\r\n', '\n').split('\n${'-' * 80}\n')) {
    final split = raw.indexOf('\n\n');
    if (split <= 0) continue;
    final names = raw.substring(0, split).split('\n').where((n) => n.trim().isNotEmpty).toList();
    final body = raw.substring(split + 2).trim();
    if (names.isEmpty || body.isEmpty) continue;
    entries.add(LicenseEntryWithLineBreaks(names, body));
  }
  return entries;
}
