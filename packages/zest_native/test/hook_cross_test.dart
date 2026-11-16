// The build hook for the platforms this computer is not: Android on any computer with an Android
// NDK, iOS and macOS on a Mac. Each builds the Rust library the way the Flutter tool asks the hook
// to, and checks the file is a library for that CPU. Skipped where the tools are missing.
import 'dart:io';
import 'dart:typed_data';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart' show PackageUserDefines, PackageUserDefinesSource;
import 'package:test/test.dart';

import '../hook/build.dart' as hook;

/// The newest NDK under the Android SDK (ANDROID_NDK_HOME, else ANDROID_HOME or
/// ANDROID_SDK_ROOT, else the SDK's default place), or null.
Directory? _ndk() {
  final env = Platform.environment;
  if (env['ANDROID_NDK_HOME'] case final h? when Directory(h).existsSync()) return Directory(h);
  final sdk =
      env['ANDROID_HOME'] ??
      env['ANDROID_SDK_ROOT'] ??
      (Platform.isWindows
          ? '${env['LOCALAPPDATA']}\\Android\\Sdk'
          : Platform.isMacOS
          ? '${env['HOME']}/Library/Android/sdk'
          : '${env['HOME']}/Android/Sdk');
  final dir = Directory('$sdk${Platform.pathSeparator}ndk');
  if (!dir.existsSync()) return null;
  final versions = dir.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
  return versions.isEmpty ? null : versions.last;
}

/// The NDK's clang, archiver and linker, as the Flutter tool hands them to a hook.
CCompilerConfig _ndkCompiler(Directory ndk) {
  final host = Platform.isWindows ? 'windows-x86_64' : (Platform.isMacOS ? 'darwin-x86_64' : 'linux-x86_64');
  final exe = Platform.isWindows ? '.exe' : '';
  final bin = Uri.directory(ndk.path).resolve('toolchains/llvm/prebuilt/$host/bin/');
  return CCompilerConfig(
    compiler: bin.resolve('clang$exe'),
    linker: bin.resolve('ld.lld$exe'),
    archiver: bin.resolve('llvm-ar$exe'),
  );
}

/// The ELF machine of a shared library (EM_ value), or null if [bytes] are not ELF.
int? _elfMachine(Uint8List bytes) {
  if (bytes.length < 20 || bytes[0] != 0x7f || bytes[1] != 0x45 || bytes[2] != 0x4c || bytes[3] != 0x46) return null;
  return bytes[18] | (bytes[19] << 8);
}

/// The smallest alignment of the loadable segments (PT_LOAD) of a 64-bit ELF library: Google Play
/// asks 64-bit libraries for 16 KB pages (16384 or more) on Android 15 and later.
int _smallestLoadAlignment64(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  final phoff = d.getUint64(0x20, Endian.little);
  final size = d.getUint16(0x36, Endian.little);
  final count = d.getUint16(0x38, Endian.little);
  var smallest = 1 << 30;
  for (var i = 0; i < count; i++) {
    final at = phoff + i * size;
    if (d.getUint32(at, Endian.little) != 1) continue; // PT_LOAD
    final align = d.getUint64(at + 0x30, Endian.little);
    if (align < smallest) smallest = align;
  }
  return smallest;
}

/// The cargo features the app's pubspec turns on (4.0: the remote screen engine), so these
/// builds are the app's (its 16 KB pages and its size with them).
const appFeatures = ['vnc'];

/// Builds through the hook for [os] on [arch]; returns the library's file name and its bytes (read
/// while the test's build folder still exists).
Future<({String name, Uint8List bytes})> _built(
  OS os,
  Architecture arch, {
  CCompilerConfig? cc,
  int? ndkApi,
  IOSSdk? sdk,
  LinkModePreference link = LinkModePreference.dynamic,
  List<String> features = appFeatures,
}) async {
  late ({String name, Uint8List bytes}) built;
  await testCodeBuildHook(
    mainMethod: hook.main,
    userDefines: PackageUserDefines(
      workspacePubspec: PackageUserDefinesSource(defines: {'cargo_features': features}, basePath: Directory.current.uri),
    ),
    targetOS: os,
    targetArchitecture: arch,
    cCompiler: cc,
    targetAndroidNdkApi: ndkApi ?? 26,
    targetIOSSdk: sdk ?? IOSSdk.iPhoneOS,
    iOSDeploymentVersion: AppleVersion(15), // the app's minimum (ios/Podfile)
    macOSDeploymentVersion: AppleVersion(11),
    linkModePreference: link,
    check: (input, output) {
      final assets = output.assets.code;
      expect(assets, hasLength(1));
      expect(assets.single.id, 'package:zest_native/src/bindings.dart');
      final file = File.fromUri(assets.single.file!);
      expect(file.existsSync(), isTrue, reason: '${file.path} was built');
      built = (name: file.uri.pathSegments.last, bytes: file.readAsBytesSync());
    },
  );
  return built;
}

void main() {
  final ndk = _ndk();
  group('Android (the app\'s minimum, API 26)', () {
    for (final (arch, machine) in [
      (Architecture.arm64, 183), // EM_AARCH64
      (Architecture.arm, 40), // EM_ARM
      (Architecture.x64, 62), // EM_X86_64
    ]) {
      test(
        '$arch: an ELF library for that CPU',
        () async {
          final f = await _built(OS.android, arch, cc: _ndkCompiler(ndk!), ndkApi: 26);
          expect(f.name, 'libzest_native.so');
          expect(_elfMachine(f.bytes), machine);
          if (arch != Architecture.arm) {
            expect(_smallestLoadAlignment64(f.bytes), greaterThanOrEqualTo(16384), reason: '16 KB pages (Play)');
          }
        },
        skip: ndk == null ? 'no Android NDK on this computer' : false,
        timeout: const Timeout(Duration(minutes: 10)),
      );
    }
  });

  group('Apple', () {
    final skip = Platform.isMacOS ? false : 'Apple targets build on a Mac only (Xcode)';
    for (final arch in [Architecture.arm64, Architecture.x64]) {
      test(
        'macOS $arch: a dynamic library',
        () async {
          final f = await _built(OS.macOS, arch);
          expect(f.name, 'libzest_native.dylib');
        },
        skip: skip,
        timeout: const Timeout(Duration(minutes: 10)),
      );
    }
    for (final (sdk, label) in [(IOSSdk.iPhoneOS, 'device'), (IOSSdk.iPhoneSimulator, 'simulator')]) {
      test(
        'iOS $label, arm64: a dynamic library (Flutter bundles it as a framework)',
        () async {
          final f = await _built(OS.iOS, Architecture.arm64, sdk: sdk);
          expect(f.name, 'libzest_native.dylib');
        },
        skip: skip,
        timeout: const Timeout(Duration(minutes: 10)),
      );
      test(
        'iOS $label, arm64: a static library, where a build asks for one',
        () async {
          final f = await _built(OS.iOS, Architecture.arm64, sdk: sdk, link: LinkModePreference.static);
          expect(f.name, 'libzest_native.a');
        },
        skip: skip,
        timeout: const Timeout(Duration(minutes: 10)),
      );
    }
  });
}
