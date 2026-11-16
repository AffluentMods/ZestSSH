// Builds the Rust crate in rust/ for the platform being built (Dart build hooks, 3.4) and hands
// the library to the build as the code asset of lib/src/bindings.dart, which the app's @Native
// functions resolve against.
//
// cargo runs through rustup's proxy in rust/, so the toolchain and targets pinned in
// rust/rust-toolchain.toml are used (rustup installs them on the first build). rustup is looked
// for on PATH, then in ~/.cargo/bin, its default place (an install that left PATH alone still
// builds, as does a shell started before rustup was installed). The Android settings follow
// native_toolchain_rust (MIT, Gregory Conrad), which this replaces: its versions that run under
// Flutter 3.38's pins look for rustup on PATH only, and it links Android at API 35 where this
// uses the app's own minimum.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// The library's name in rust/Cargo.toml.
const _crate = 'zest_native';

/// The asset the Dart side names (lib/src/bindings.dart).
const _assetName = 'src/bindings.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final triple = _rustTarget(code);
    final linkMode = switch (code.linkModePreference) {
      LinkModePreference.static || LinkModePreference.preferStatic => StaticLinking(),
      _ => DynamicLoadingBundled(),
    };
    final crate = input.packageRoot.resolve('rust/');
    final features = _cargoFeatures(input.userDefines['cargo_features']);
    final targetDir = input.outputDirectoryShared.resolve('cargo/');
    final cargo = _findCargo();
    final crateDir = Directory.fromUri(crate).path;
    // The caller's environment without what would move the build off the pinned toolchain, then
    // the build's own (found in a review before 4.0).
    final environment = cargoEnvironment(Platform.environment, {
      ..._androidEnvironment(code, triple),
      ..._appleEnvironment(code),
      ..._pathRemaps(crateDir),
    });
    _checkPinnedToolchain(cargo, crate, crateDir, environment);
    final result = await Process.run(
      cargo,
      [
        'build',
        '--release',
        '--locked',
        '--manifest-path',
        File.fromUri(crate.resolve('Cargo.toml')).path,
        '--target',
        triple,
        '--target-dir',
        Directory.fromUri(targetDir).path,
        if (features.isNotEmpty) ...['--features', features.join(',')],
      ],
      workingDirectory: crateDir,
      environment: environment,
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'cargo build of $_crate for $triple failed (exit ${result.exitCode}):\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
    final library = targetDir.resolve('$triple/release/${code.targetOS.libraryFileName(_crate, linkMode)}');
    if (!File.fromUri(library).existsSync()) {
      throw StateError('cargo built $_crate for $triple, but ${library.toFilePath()} is not there');
    }
    output.assets.code.add(CodeAsset(package: input.packageName, name: _assetName, linkMode: linkMode, file: library));
    // Built again when the crate, its lock file, its toolchain or any of its sources change.
    output.dependencies.addAll([
      crate.resolve('Cargo.toml'),
      crate.resolve('Cargo.lock'),
      crate.resolve('rust-toolchain.toml'),
      for (final f in Directory.fromUri(crate.resolve('src/')).listSync(recursive: true))
        if (f is File) f.uri,
    ]);
  });
}

/// Cargo features of the build (4.0): `hooks: user_defines: zest_native: cargo_features: [vnc]`
/// in the pubspec of the app being built (only the root package's pubspec counts). The app turns
/// on `vnc` and `rdp` (remote screens), `sound` (an RDP session's sound, 4.0) and `mosh`
/// (the built-in Mosh client); `probes` is for the developer example only (a test in the app
/// checks its library has no probe symbol). Only the features listed here; anything else stops
/// the build.
const _features = {'vnc', 'rdp', 'sound', 'mosh', 'probes'};

List<String> _cargoFeatures(Object? value) {
  if (value == null) return const [];
  final list = switch (value) {
    final String s => s.split(',').map((f) => f.trim()).where((f) => f.isNotEmpty).toList(),
    final List<Object?> l => [for (final f in l) '$f'.trim()],
    _ => throw StateError('hooks.user_defines.$_crate.cargo_features: a list of feature names, not $value'),
  };
  for (final f in list) {
    if (!_features.contains(f)) {
      throw StateError('hooks.user_defines.$_crate.cargo_features: no feature "$f" (only ${_features.join(', ')})');
    }
  }
  return list..sort();
}

/// The Rust target for the platform being built (each one listed in rust-toolchain.toml).
String _rustTarget(CodeConfig code) => switch ((code.targetOS, code.targetArchitecture)) {
  (OS.android, Architecture.arm64) => 'aarch64-linux-android',
  (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
  (OS.android, Architecture.x64) => 'x86_64-linux-android',
  (OS.iOS, Architecture.arm64) when code.iOS.targetSdk == IOSSdk.iPhoneSimulator => 'aarch64-apple-ios-sim',
  (OS.iOS, Architecture.arm64) => 'aarch64-apple-ios',
  (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',
  (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
  (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
  (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
  (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
  (final os, final arch) => throw UnsupportedError(
    '$_crate is not built for $os on $arch: add its Rust target to rust/rust-toolchain.toml '
    'and to hook/build.dart',
  ),
};

/// The build machine's own folders never go into the library: the paths of the
/// crates (cargo's registry under the person's home, rustup's toolchain, this
/// crate's checkout) that panic messages and debug data carry are rewritten to
/// neutral ones, so a release built anywhere names nobody (the release privacy
/// check greps every shipped file for the build account's folder). Passed as
/// CARGO_ENCODED_RUSTFLAGS: a path with spaces stays one argument. The last
/// prefix that matches wins, so the home folder goes first and the narrower
/// folders inside it after.
Map<String, String> _pathRemaps(String crateDir) {
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  String strip(String p) => p.endsWith(sep) ? p.substring(0, p.length - 1) : p;
  final remaps = <String, String>{
    if (home != null && home.isNotEmpty) strip(home): '/home',
    strip(env['CARGO_HOME'] ?? (home == null ? '' : '$home$sep.cargo')): '/cargo',
    strip(env['RUSTUP_HOME'] ?? (home == null ? '' : '$home$sep.rustup')): '/rustup',
    strip(crateDir): '/zest_native',
  }..remove('');
  return {
    'CARGO_ENCODED_RUSTFLAGS': [
      for (final e in remaps.entries) '--remap-path-prefix=${e.key}=${e.value}',
    ].join('\x1f'),
  };
}

/// What cargo is run with: [parent] (the caller's environment) without the variables that would
/// move the build off the toolchain rust/rust-toolchain.toml pins or change what it compiles, then
/// [ours] (found in a review before 4.0).
///
/// Left out: another toolchain (RUSTUP_TOOLCHAIN), another compiler or a program put in front of
/// it (RUSTC, RUSTC_WRAPPER, RUSTC_WORKSPACE_WRAPPER, RUSTDOC), flags (RUSTFLAGS, RUSTDOCFLAGS and
/// their CARGO_ENCODED forms: ours are set after), nightly features on a stable compiler
/// (RUSTC_BOOTSTRAP), another output folder (CARGO_TARGET_DIR: the hook names its own), and cargo's
/// own settings given by environment for the build, its profiles and its targets (CARGO_BUILD_*,
/// CARGO_PROFILE_*, CARGO_TARGET_*, CARGO_UNSTABLE_*). The two wrappers are also set empty, which
/// tells cargo to use none whatever a config file says.
///
/// Kept: everything else, so a proxy, a registry mirror (the lock file's checksums still hold what
/// is downloaded to what was locked), CARGO_HOME and RUSTUP_HOME, and a C compiler named for crates
/// with C code go on working.
Map<String, String> cargoEnvironment(Map<String, String> parent, Map<String, String> ours) => {
  for (final e in parent.entries)
    if (!movesTheBuild(e.key)) e.key: e.value,
  'RUSTC_WRAPPER': '',
  'RUSTC_WORKSPACE_WRAPPER': '',
  ...ours,
};

/// Whether the environment variable [name] is one [cargoEnvironment] leaves out.
bool movesTheBuild(String name) {
  final n = name.toUpperCase();
  const exact = {
    'RUSTUP_TOOLCHAIN',
    'RUSTC',
    'RUSTC_WRAPPER',
    'RUSTC_WORKSPACE_WRAPPER',
    'RUSTDOC',
    'RUSTFLAGS',
    'RUSTDOCFLAGS',
    'CARGO_ENCODED_RUSTFLAGS',
    'CARGO_ENCODED_RUSTDOCFLAGS',
    'RUSTC_BOOTSTRAP',
    'CARGO_TARGET_DIR',
  };
  return exact.contains(n) ||
      n.startsWith('CARGO_BUILD_') ||
      n.startsWith('CARGO_PROFILE_') ||
      n.startsWith('CARGO_TARGET_') ||
      n.startsWith('CARGO_UNSTABLE_');
}

/// What is wrong with the cargo that was found, or null: [versionOutput] is what `cargo --version`
/// printed when run in the crate's folder, [channel] what rust/rust-toolchain.toml pins. rustup's
/// cargo runs the pinned toolchain there; a cargo that is not rustup's (a system package's, first
/// on PATH) ignores the pin and builds with whatever it is. Only a pin that is a version is
/// compared: a channel by name ("stable") names no version to hold it to.
String? pinnedToolchainProblem({required String channel, required String versionOutput, required String cargo}) {
  if (!RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(channel)) return null;
  final found = RegExp(r'^cargo (\d+\.\d+\.\d+)').firstMatch(versionOutput.trim())?.group(1);
  final pinned = channel.split('.').length == 2 ? '$channel.' : channel;
  if (found != null && (found == pinned || (pinned.endsWith('.') && found.startsWith(pinned)))) return null;
  return 'The cargo at $cargo is ${found == null ? 'not one this build can read the version of' : 'version $found'}, '
      'not the $channel that rust/rust-toolchain.toml pins. $_crate is built with the pinned toolchain only: '
      'a cargo that is not rustup\'s ignores the pin. Install rustup (https://rustup.rs) and put its folder '
      '(~/.cargo/bin) before any other cargo on PATH, then build again '
      '(BUILDING.md at the top of the repository, section "Rust").';
}

/// Stops the build where [cargo] would not build with the pinned toolchain ([pinnedToolchainProblem]).
void _checkPinnedToolchain(String cargo, Uri crate, String crateDir, Map<String, String> environment) {
  final toml = File.fromUri(crate.resolve('rust-toolchain.toml'));
  final channel = toml.existsSync()
      ? RegExp(r'^\s*channel\s*=\s*"([^"]+)"', multiLine: true).firstMatch(toml.readAsStringSync())?.group(1)
      : null;
  if (channel == null) return;
  final ProcessResult version;
  try {
    version = Process.runSync(
      cargo,
      const ['--version'],
      workingDirectory: crateDir,
      environment: environment,
      includeParentEnvironment: false,
    );
  } on ProcessException catch (e) {
    throw StateError('The cargo at $cargo could not be run: ${e.message}');
  }
  final problem = pinnedToolchainProblem(channel: channel, versionOutput: '${version.stdout}', cargo: cargo);
  if (problem != null) throw StateError(problem);
}

/// rustup's cargo: on PATH, else in ~/.cargo/bin (or CARGO_HOME/bin). Whether it is rustup's is
/// held by [_checkPinnedToolchain], not assumed.
String _findCargo() {
  final exe = Platform.isWindows ? 'cargo.exe' : 'cargo';
  final env = Platform.environment;
  final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  final dirs = [
    ...?env['PATH']?.split(Platform.isWindows ? ';' : ':'),
    if (env['CARGO_HOME'] case final c?) '$c${Platform.pathSeparator}bin',
    if (home != null) [home, '.cargo', 'bin'].join(Platform.pathSeparator),
  ];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final f = File('$dir${Platform.pathSeparator}$exe');
    if (f.existsSync()) return f.path;
  }
  throw StateError(
    'cargo was not found on PATH or in ~/.cargo/bin. $_crate is written in Rust: '
    'install rustup (https://rustup.rs), then build again '
    '(BUILDING.md at the top of the repository, section "Rust").',
  );
}

/// For Android, the NDK's clang for the target at the app's minimum API (the Flutter tool hands
/// the hook the NDK's compiler; the per-target wrappers sit beside it), as linker and C compiler
/// (crates with C code, such as ring, need it), and its archiver.
Map<String, String> _androidEnvironment(CodeConfig code, String triple) {
  if (code.targetOS != OS.android) return const {};
  final cc = code.cCompiler;
  if (cc == null) throw StateError('The build gave no Android NDK compiler for $triple');
  final bin = File.fromUri(cc.compiler).parent.path;
  final ndkTriple = triple == 'armv7-linux-androideabi' ? 'armv7a-linux-androideabi' : triple;
  final api = code.android.targetNdkApi;
  final suffix = Platform.isWindows ? '.cmd' : '';
  final clang = '$bin${Platform.pathSeparator}$ndkTriple$api-clang$suffix';
  final clangpp = '$bin${Platform.pathSeparator}$ndkTriple$api-clang++$suffix';
  if (!File(clang).existsSync()) {
    throw StateError('The Android NDK has no $clang: is the NDK too old for API $api?');
  }
  final t = triple.replaceAll('-', '_');
  return {
    'CARGO_TARGET_${t.toUpperCase()}_LINKER': clang,
    'CC_$t': clang,
    'CXX_$t': clangpp,
    'AR_$t': File.fromUri(cc.archiver).path,
  };
}

/// For Apple platforms, the app's minimum version, so the library is built for it. On macOS also
/// the SDK: ring's C code includes TargetConditionals.h, and a hook run by `flutter build macos`
/// has no SDKROOT, so clang found no system headers (iOS builds get theirs from cc's own xcrun).
Map<String, String> _appleEnvironment(CodeConfig code) => switch (code.targetOS) {
  OS.macOS => {
    'MACOSX_DEPLOYMENT_TARGET': _appleTarget(code.macOS.deploymentVersion),
    'SDKROOT': ?_macSdk(),
  },
  OS.iOS => {'IPHONEOS_DEPLOYMENT_TARGET': _appleTarget(code.iOS.deploymentVersion)},
  _ => const {},
};

/// An Apple minimum as the deployment target variables take it ("15.0", "10.15", "17.2.1").
String _appleTarget(AppleVersion v) => v.patch == 0 ? '${v.major}.${v.minor}' : '${v.major}.${v.minor}.${v.patch}';

/// The macOS SDK's folder, as xcrun names it; null off a Mac or without Xcode's tools.
String? _macSdk() {
  final given = Platform.environment['SDKROOT'];
  if (given != null && given.isNotEmpty) return given;
  if (!Platform.isMacOS) return null;
  try {
    final r = Process.runSync('xcrun', ['--sdk', 'macosx', '--show-sdk-path']);
    final path = (r.stdout as String).trim();
    return r.exitCode == 0 && path.isNotEmpty ? path : null;
  } on ProcessException {
    return null;
  }
}
