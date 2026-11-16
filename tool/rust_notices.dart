// Writes packages/zest_native/NOTICES: the licence of every Rust crate the native library ships
// (3.4), for the app's licences page. Flutter reads a package's NOTICES (else its LICENSE) into the
// app's own list of licences: sections split by a line of 80 hyphens, each its packages' names, one
// per line, then a blank line, then the text (flutter_tools license_collector.dart). Settings >
// Licences then lists each crate by its name, as it lists the Dart packages.
//
// Which crates ship: `cargo tree` for the ten targets the app builds (rust-toolchain.toml), with the
// cargo features the app's pubspec turns on (hooks: user_defines: zest_native: cargo_features, as
// hook/build.dart reads them; 4.0: vnc), normal dependencies only, without proc-macros (they run at
// build time, nothing of them is in the library) and without zest_native itself. Code vendored
// into zest_native, which cargo tree cannot see, is added by hand ([vendored]: the VNC engine,
// forked from vnc-rs, with its licences). Each crate's licence files come from cargo's own copy of
// it (~/.cargo/registry/src), as published, and identical texts are listed once with every crate
// they cover. A crate with no licence file stops the tool, named. A crate the app forks
// (packages/zest_native/rust/vendor/<name>, used through [patch.crates-io]) gives its licences
// from that folder, with its NOTICE-ZESTSSH, which says what was changed: cargo keeps no copy of
// a crate it takes from a path.
//
//   dart tool/rust_notices.dart           writes the file (cargo must be installed; no network)
//   dart tool/rust_notices.dart --check   changes nothing; fails when the file is not current
//   dart tool/rust_notices.dart --as-if=vnc,rdp
//                                         changes nothing; says what the file would hold with those
//                                         cargo features, and fails when a crate of theirs has no
//                                         licence file (before a feature goes into the pubspec)
//
// Run it after any change to packages/zest_native/rust/Cargo.lock.
// test/docs/rust_notices_test.dart holds the file to Cargo.lock without cargo.
import 'dart:io';

const noticesPath = 'packages/zest_native/NOTICES';
const crateDir = 'packages/zest_native/rust';

/// The targets the app ships (packages/zest_native/rust/rust-toolchain.toml).
const shippedTargets = [
  'aarch64-linux-android',
  'armv7-linux-androideabi',
  'x86_64-linux-android',
  'aarch64-apple-ios',
  'aarch64-apple-ios-sim',
  'x86_64-apple-ios',
  'aarch64-apple-darwin',
  'x86_64-apple-darwin',
  'x86_64-pc-windows-msvc',
  'x86_64-unknown-linux-gnu',
];

/// What separates two licences in a NOTICES file (flutter_tools: licenseSeparator).
final separator = '\n${'-' * 80}\n';

/// A licence file's name: LICENSE, LICENCE, COPYING, UNLICENSE, with or without an ending.
final _licenceFile = RegExp(r'^(licen[cs]e|copying|unlicense)([-._].*)?$', caseSensitive: false);

String _cargo() {
  final home = Platform.environment['CARGO_HOME'] ??
      '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']}${Platform.pathSeparator}.cargo';
  for (final c in ['$home/bin/cargo.exe', '$home/bin/cargo']) {
    if (File(c).existsSync()) return c;
  }
  return 'cargo';
}

String _registry() {
  final home = Platform.environment['CARGO_HOME'] ??
      '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']}/.cargo';
  return '$home/registry/src';
}

/// The cargo features the app's builds turn on: `cargo_features` under `hooks: user_defines:
/// zest_native:` in the root pubspec ([pubspec], the app's by default), a flow list (`[vnc]`) or a
/// block list, as hook/build.dart takes them from the build's user-defines.
List<String> appFeatures([String pubspec = 'pubspec.yaml']) {
  final lines = File(pubspec).readAsLinesSync();
  var path = <(int, String)>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].replaceFirst(RegExp(r'\s+#.*$'), '');
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    final m = RegExp(r'^\s*([A-Za-z_][\w-]*):\s*(.*)$').firstMatch(line);
    if (m == null) continue;
    path = [...path.where((p) => p.$1 < indent), (indent, m.group(1)!)];
    final keys = path.map((p) => p.$2).toList();
    if (keys.join('.') != 'hooks.user_defines.zest_native.cargo_features') continue;
    final value = m.group(2)!.trim();
    if (value.startsWith('[')) {
      return [
        for (final f in value.replaceAll(RegExp(r'[\[\]]'), '').split(','))
          if (f.trim().isNotEmpty) f.trim(),
      ];
    }
    return [
      for (var j = i + 1; j < lines.length && RegExp(r'^\s*-\s*').hasMatch(lines[j]); j++)
        lines[j].replaceFirst(RegExp(r'^\s*-\s*'), '').trim(),
    ];
  }
  return const [];
}

/// The crates that ship, as `name version`, with the app's cargo features or [features].
Future<List<(String, String)>> shippedCrates([List<String>? features]) async {
  features ??= appFeatures();
  final r = await Process.run(
    _cargo(),
    [
      'tree', '--locked', '--offline', '-e', 'normal,no-proc-macro', '--prefix', 'none', '--format', '{p}',
      if (features.isNotEmpty) ...['--features', features.join(',')],
      for (final t in shippedTargets) ...['--target', t],
    ],
    workingDirectory: crateDir,
  );
  if (r.exitCode != 0) throw StateError('cargo tree failed: ${r.stderr}');
  final out = <(String, String)>{};
  for (final line in (r.stdout as String).split(RegExp(r'\r?\n'))) {
    final m = RegExp(r'^(\S+) v(\S+)').firstMatch(line.trim());
    if (m == null || m.group(1) == 'zest_native') continue;
    out.add((m.group(1)!, m.group(2)!));
  }
  return out.toList()..sort((a, b) => a.$1.compareTo(b.$1));
}

/// Where the licence files of a crate published without them are kept, by the crate's name
/// (suppaftp: its repository's LICENSE-MIT and LICENSE-APACHE, which its package leaves out; for
/// RDP, ironrdp-bulk and ironrdp-rdpei: IronRDP's two, as its other crates publish them, and
/// winscard: sspi-rs's two, as sspi publishes them; each crate's manifest says MIT or Apache-2.0).
const keptLicences = '$crateDir/licences';

List<String> _textsIn(Directory dir) {
  final files = dir.listSync().whereType<File>().where((f) => _licenceFile.hasMatch(f.uri.pathSegments.last)).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final f in files) _plainDashes(f.readAsStringSync().replaceAll('\r\n', '\n').trimRight())];
}

/// A licence's text with its long dashes as plain hyphens: this repository keeps no em or en dash
/// in any file, a crate's licence included (ICU4X's has one, alone on a line, between its two
/// notices). Nothing else of a text is changed.
String _plainDashes(String text) =>
    text.replaceAll(String.fromCharCode(0x2014), '-').replaceAll(String.fromCharCode(0x2013), '-');

/// Where the app's forks of crates are, by the crate's name ([patch.crates-io] in Cargo.toml).
const forksDir = '$crateDir/vendor';

/// The file in a fork's folder that says whose the crate is and what was changed in it.
const forkNotice = 'NOTICE-ZESTSSH';

/// [name] [version]'s licence texts: from the app's fork of it when there is one (its licence
/// files, then its notice of what changed), else from cargo's copy of the crate, else from
/// [keptLicences].
List<String> licenceTexts(String name, String version) {
  final fork = Directory('$forksDir/$name');
  if (fork.existsSync()) {
    final manifest = File('${fork.path}/Cargo.toml').readAsStringSync();
    final forked = RegExp(r'^version = "([^"]+)"', multiLine: true).firstMatch(manifest)?.group(1);
    if (forked != version) throw StateError('$forksDir/$name is $forked, Cargo.lock has $version');
    final notice = File('${fork.path}/$forkNotice');
    if (!notice.existsSync()) throw StateError('$forksDir/$name has no $forkNotice');
    return [..._textsIn(fork), notice.readAsStringSync().replaceAll('\r\n', '\n').trimRight()];
  }
  final registry = Directory(_registry());
  for (final index in registry.listSync().whereType<Directory>()) {
    final dir = Directory('${index.path}/$name-$version');
    if (!dir.existsSync()) continue;
    final texts = _textsIn(dir);
    final kept = Directory('$keptLicences/$name');
    return texts.isEmpty && kept.existsSync() ? _textsIn(kept) : texts;
  }
  throw StateError('$name $version is not in $registry (cargo fetch)');
}

/// The VNC engine's folder: vnc-rs 0.6.0 forked into zest_native (feature vnc), MIT or Apache-2.0.
const vncEngineDir = '$crateDir/src/vnc/engine';

/// The name the licences page lists the vendored VNC engine under.
const vncEngineName = 'vnc-rs';

/// Licences of code vendored into zest_native, by the name the licences page shows, for the
/// [features] the app builds with: the VNC engine's LICENSE-MIT and LICENSE-APACHE, and the MIT
/// notices two of its files carry at their top, each kept with its file: codec/zlib.rs's
/// (whitequark's) and client/security/des.rs's (Antoni Boucher's, the DES of VNC's password
/// sign-in), the latter without its comment's leading stars.
Map<String, List<String>> vendored(List<String> features) {
  if (!features.contains('vnc')) return const {};
  String read(String name) => File('$vncEngineDir/$name').readAsStringSync().replaceAll('\r\n', '\n');
  String header(String name) {
    final source = read(name);
    final end = source.indexOf('*/');
    if (!source.startsWith('/*') || end < 0) throw StateError('$vncEngineDir/$name no longer starts with its licence');
    return source.substring(2, end).trim();
  }

  final des = header('client/security/des.rs')
      .split('\n')
      .map((line) => line.replaceFirst(RegExp(r'^\s*\* ?'), '').trimRight())
      .join('\n')
      .trim();
  return {
    vncEngineName: [
      read('LICENSE-MIT').trimRight(),
      read('LICENSE-APACHE').trimRight(),
      header('codec/zlib.rs'),
      des,
    ],
  };
}

/// The NOTICES file for [crates], and the [extra] vendored licences.
String notices(List<(String, String)> crates, {Map<String, List<String>> extra = const {}}) {
  final byText = <String, Set<String>>{};
  for (final MapEntry(key: name, value: texts) in extra.entries) {
    for (final t in texts) {
      byText.putIfAbsent(t, () => <String>{}).add(name);
    }
  }
  final missing = <String>[];
  for (final (name, version) in crates) {
    final texts = licenceTexts(name, version);
    if (texts.isEmpty) missing.add('$name $version');
    for (final t in texts) {
      byText.putIfAbsent(t, () => <String>{}).add(name);
    }
  }
  if (missing.isNotEmpty) throw StateError('no licence file in: ${missing.join(', ')}');
  final sections = [
    for (final e in byText.entries) (names: (e.value.toList()..sort()), text: e.key),
  ]..sort((a, b) {
      final n = a.names.first.compareTo(b.names.first);
      return n != 0 ? n : a.text.compareTo(b.text);
    });
  return '${sections.map((s) => '${s.names.join('\n')}\n\n${s.text}').join(separator)}\n';
}

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final asIf = args.where((a) => a.startsWith('--as-if=')).map((a) => a.substring(8)).firstOrNull;
  if (asIf != null) {
    final features = [for (final f in asIf.split(',')) if (f.trim().isNotEmpty) f.trim()];
    final crates = await shippedCrates(features);
    final text = notices(crates, extra: vendored(features));
    final forks = [for (final (name, _) in crates) if (Directory('$forksDir/$name').existsSync()) name];
    stdout.writeln('with ${features.join(', ')}: ${crates.length} crates, each with a licence file, '
        '${text.split(separator).length} licence texts${forks.isEmpty ? '' : '; forks: ${forks.join(', ')}'}');
    return;
  }
  final crates = await shippedCrates();
  final extra = vendored(appFeatures());
  final text = notices(crates, extra: extra);
  final file = File(noticesPath);
  if (check) {
    final now = file.existsSync() ? file.readAsStringSync().replaceAll('\r\n', '\n') : '';
    if (now != text) {
      stderr.writeln('$noticesPath is not current: run dart tool/rust_notices.dart');
      exit(1);
    }
    stdout.writeln('${crates.length} crates${extra.isEmpty ? '' : ' and ${extra.keys.join(', ')}'}, $noticesPath is current');
    return;
  }
  file.writeAsStringSync(text);
  stdout.writeln('${crates.length} crates${extra.isEmpty ? '' : ' and ${extra.keys.join(', ')}'} written to $noticesPath');
}
