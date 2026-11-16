// Checks the licence of every Dart package and Rust crate the app is built from against
// tool/licence_policy.yaml, and fails on a licence that is not allowed there, or that it cannot
// tell. Nothing is changed and nothing is fetched: it reads what `flutter pub get` and the Rust
// build already put on the machine.
//
// Dart: the packages the app's own `dependencies:` bring, followed through each package's
// pubspec (dev dependencies, which never ship, are left out), each found through
// .dart_tool/package_config.json; a package's licence is what its NOTICES, LICENSE or COPYING
// files say, recognised by their texts. A file can hold several licences (a package that bundles
// a C library gives that library's too): each of them must be allowed.
// Rust: every crate in packages/zest_native/rust/Cargo.lock (a superset of what ships: the build's
// own tools are in it too), by the `license` expression of its Cargo.toml, as cargo keeps it
// (~/.cargo/registry/src), or as the app's fork of it says (rust/vendor); an "OR" needs one
// allowed side, an "AND" both.
//
//   dart run tool/licence_check.dart          exit 1 on a licence that is not allowed or not known
//   dart run tool/licence_check.dart --list   also prints every package with its licences
//
// Gradle libraries, pods and the native libraries of the desktop builds are not checked here:
// their licences are listed by tool/native_notices.dart. test/tool/licence_check_test.dart holds
// this tool to the app's packages and to made-up ones.
import 'dart:convert';
import 'dart:io';

const policyPath = 'tool/licence_policy.yaml';
const cargoLock = 'packages/zest_native/rust/Cargo.lock';
const forksDir = 'packages/zest_native/rust/vendor';

/// What the policy file says: the allowed SPDX ids, and the licences given by hand per package.
typedef Policy = ({Set<String> allowed, Map<String, String> dart, Map<String, String> rust});

Policy readPolicy([String path = policyPath]) {
  final allowed = <String>{};
  final dart = <String, String>{};
  final rust = <String, String>{};
  var section = '';
  for (final raw in File(path).readAsLinesSync()) {
    final line = raw.replaceFirst(RegExp(r'\s+#.*$'), '').replaceFirst(RegExp(r'^\s*#.*$'), '');
    if (line.trim().isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    final text = line.trim();
    if (indent == 0) {
      section = text.replaceAll(':', '');
    } else if (section == 'allowed' && text.startsWith('- ')) {
      allowed.add(text.substring(2).trim());
    } else if (section == 'packages' && indent == 2) {
      section = 'packages.${text.replaceAll(':', '')}';
    } else if (section.startsWith('packages.') && indent == 2) {
      section = 'packages.${text.replaceAll(':', '')}';
    } else if (section.startsWith('packages.') && indent == 4) {
      final m = RegExp(r'^([\w-]+):\s*(.+)$').firstMatch(text);
      if (m == null) throw FormatException('$path: "$raw"');
      (section == 'packages.dart' ? dart : rust)[m.group(1)!] = m.group(2)!.trim();
    }
  }
  if (allowed.isEmpty) throw FormatException('$path: nothing allowed');
  return (allowed: allowed, dart: dart, rust: rust);
}

/// The licences a licence file's [text] holds, as SPDX ids, by the words each licence's text is
/// known by. Empty: none recognised.
Set<String> classify(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ');
  final found = <String>{};
  if (RegExp(r'GNU AFFERO GENERAL PUBLIC LICENSE').hasMatch(t)) found.add('AGPL');
  if (RegExp(r'GNU LESSER GENERAL PUBLIC LICENSE|GNU LIBRARY GENERAL PUBLIC LICENSE').hasMatch(t)) found.add('LGPL');
  if (RegExp(r'GNU GENERAL PUBLIC LICENSE').hasMatch(t)) found.add('GPL');
  if (RegExp(r'Server Side Public License|Business Source License|Commons Clause').hasMatch(t)) found.add('non-free');
  if (RegExp(r'Apache License,? Version 2\.0|Apache License Version 2\.0', caseSensitive: false).hasMatch(t)) {
    found.add('Apache-2.0');
  }
  if (t.contains('Permission is hereby granted, free of charge, to any person obtaining a copy')) found.add('MIT');
  if (t.contains('Redistribution and use in source and binary forms')) {
    final third = RegExp(
      r'Neither the name|names? of (its|the) (contributors|copyright holders?|authors?) may not|'
      r'name of the author may not be used|may be used to endorse or promote',
      caseSensitive: false,
    ).hasMatch(t);
    found.add(third ? 'BSD-3-Clause' : 'BSD-2-Clause');
  }
  if (RegExp(
    r'Permission to use, copy, modify, and(/or)? distribute this software for any purpose with or without fee',
  ).hasMatch(t)) {
    found.add('ISC');
  }
  if (t.contains('Mozilla Public License Version 2.0') || t.contains('Mozilla Public License, v. 2.0')) {
    found.add('MPL-2.0');
  }
  if (t.contains('This is free and unencumbered software released into the public domain')) found.add('Unlicense');
  if (t.contains("This software is provided 'as-is', without any express or implied") &&
      t.contains('Altered source versions must be plainly marked')) {
    found.add('Zlib');
  }
  if (t.contains('Boost Software License')) found.add('BSL-1.0');
  if (t.contains('CC0 1.0 Universal')) found.add('CC0-1.0');
  if (t.contains('SIL OPEN FONT LICENSE')) found.add('OFL-1.1');
  return found;
}

/// Whether the SPDX [expression] is allowed: "OR" (or the old "/") needs one allowed side, "AND"
/// each; "X WITH Y" is X; parentheses group.
bool expressionAllowed(String expression, Set<String> allowed) {
  final tokens = RegExp(
    r'\(|\)|[^\s()]+',
  ).allMatches(expression.replaceAll('/', ' OR ')).map((m) => m.group(0)!).toList();
  var i = 0;
  late bool Function() orExpr;
  bool atom() {
    if (i >= tokens.length) throw FormatException('licence expression "$expression" ends early');
    final t = tokens[i++];
    if (t == '(') {
      final v = orExpr();
      if (i >= tokens.length || tokens[i++] != ')') throw FormatException('"$expression": no ")"');
      return v;
    }
    if (i < tokens.length && tokens[i] == 'WITH') i += 2;
    return allowed.contains(t);
  }

  bool andExpr() {
    var v = atom();
    while (i < tokens.length && tokens[i] == 'AND') {
      i++;
      v = atom() && v;
    }
    return v;
  }

  orExpr = () {
    var v = andExpr();
    while (i < tokens.length && tokens[i] == 'OR') {
      i++;
      v = andExpr() || v;
    }
    return v;
  };
  final v = orExpr();
  if (i != tokens.length) throw FormatException('licence expression "$expression": "${tokens[i]}"');
  return v;
}

/// One package's verdict: its licences, and why it fails (null: it passes).
typedef Verdict = ({String name, String licences, String? problem});

/// The licence files a package's [dir] has, Flutter's choice (NOTICES) first.
final _licenceFile = RegExp(r'^(notices|licen[cs]e|copying|unlicense)([-._].*)?$', caseSensitive: false);

/// [name]'s verdict from the licence files in [dir], or from the policy's own line for it.
Verdict dartVerdict(String name, Directory dir, Policy policy) {
  final given = policy.dart[name];
  if (given != null) {
    return (
      name: name,
      licences: '$given (by hand)',
      problem: expressionAllowed(given, policy.allowed) ? null : 'not allowed: $given',
    );
  }
  List<File> filesIn(Directory d) => d.existsSync()
      ? (d.listSync().whereType<File>().where((f) => _licenceFile.hasMatch(f.uri.pathSegments.last)).toList())
      : <File>[];
  var files = filesIn(dir);
  // A package of the Flutter SDK itself (flutter_localizations and the like) has no licence file
  // of its own: the SDK's LICENSE at its top covers it.
  final sdk = dir.parent.parent;
  if (files.isEmpty && File('${sdk.path}/bin/flutter').existsSync()) {
    files = [File('${sdk.path}/LICENSE')].where((f) => f.existsSync()).toList();
  }
  if (files.isEmpty) return (name: name, licences: '-', problem: 'no licence file in ${dir.path}');
  final found = <String>{};
  for (final f in files) {
    found.addAll(classify(_read(f)));
  }
  if (found.isEmpty) {
    return (name: name, licences: '?', problem: 'licence not recognised in ${files.map((f) => f.path).join(', ')}');
  }
  final denied = found.where((l) => !policy.allowed.contains(l)).toList()..sort();
  return (
    name: name,
    licences: (found.toList()..sort()).join(' AND '),
    problem: denied.isEmpty ? null : 'not allowed: ${denied.join(', ')}',
  );
}

String _read(File f) {
  final bytes = f.readAsBytesSync();
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// The packages of package_config.json, by name, with their folders.
Map<String, Directory> packageFolders([String config = '.dart_tool/package_config.json']) {
  final json = jsonDecode(File(config).readAsStringSync()) as Map<String, Object?>;
  final base = File(config).absolute.parent.uri;
  return {
    for (final p in (json['packages']! as List).cast<Map<String, Object?>>())
      p['name']! as String: Directory.fromUri(
        base.resolve('${(p['rootUri']! as String).replaceFirst(RegExp(r'/$'), '')}/'),
      ),
  };
}

/// The keys of the top-level `dependencies:` block of the pubspec at [path].
List<String> pubspecDependencies(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  final out = <String>[];
  var inside = false;
  for (final raw in file.readAsLinesSync()) {
    if (raw.trim().isEmpty || raw.trimLeft().startsWith('#')) continue;
    final indent = raw.length - raw.trimLeft().length;
    if (indent == 0) {
      inside = raw.startsWith('dependencies:');
      continue;
    }
    if (inside && indent == 2) {
      final m = RegExp(r'^\s{2}([\w]+):').firstMatch(raw);
      if (m != null) out.add(m.group(1)!);
    }
  }
  return out;
}

/// The packages the app ships: its own dependencies and theirs, never a dev dependency.
List<String> shippedDartPackages(Map<String, Directory> folders, [String pubspec = 'pubspec.yaml']) {
  final seen = <String>{};
  final queue = [...pubspecDependencies(pubspec)];
  while (queue.isNotEmpty) {
    final name = queue.removeLast();
    if (!seen.add(name)) continue;
    final dir = folders[name];
    if (dir == null) throw StateError('$name is not in .dart_tool/package_config.json: run flutter pub get');
    queue.addAll(pubspecDependencies('${dir.path}pubspec.yaml'));
  }
  return seen.toList()..sort();
}

/// The crates of Cargo.lock that come from a registry (name and version), and the app's own
/// path crates left out.
List<(String, String)> lockedCrates([String lock = cargoLock]) {
  final out = <(String, String)>[];
  for (final block in File(lock).readAsStringSync().replaceAll('\r\n', '\n').split('\n[[package]]\n').skip(1)) {
    final name = RegExp(r'^name = "([^"]+)"', multiLine: true).firstMatch(block)?.group(1);
    final version = RegExp(r'^version = "([^"]+)"', multiLine: true).firstMatch(block)?.group(1);
    final source = RegExp(r'^source = "([^"]+)"', multiLine: true).firstMatch(block)?.group(1);
    if (name == null || version == null) continue;
    if (source == null && !Directory('$forksDir/$name').existsSync()) continue; // the app's own crate
    out.add((name, version));
  }
  return out;
}

String _registry() {
  final home =
      Platform.environment['CARGO_HOME'] ??
      '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']}${Platform.pathSeparator}.cargo';
  return '$home/registry/src';
}

/// [name] [version]'s licence expression, from the app's fork or cargo's copy of the crate.
String? crateLicence(String name, String version) {
  final candidates = [
    File('$forksDir/$name/Cargo.toml'),
    if (Directory(_registry()).existsSync())
      for (final index in Directory(_registry()).listSync().whereType<Directory>())
        File('${index.path}/$name-$version/Cargo.toml'),
  ];
  for (final f in candidates) {
    if (!f.existsSync()) continue;
    final m = RegExp(r'^license\s*=\s*"([^"]+)"', multiLine: true).firstMatch(f.readAsStringSync());
    if (m != null) return m.group(1);
  }
  return null;
}

Verdict rustVerdict(String name, String version, Policy policy) {
  final given = policy.rust[name];
  final expression = given ?? crateLicence(name, version);
  if (expression == null) {
    return (
      name: '$name $version',
      licences: '-',
      problem: 'no license field found (cargo fetch, or a line in $policyPath)',
    );
  }
  return (
    name: '$name $version',
    licences: given == null ? expression : '$expression (by hand)',
    problem: expressionAllowed(expression, policy.allowed) ? null : 'not allowed: $expression',
  );
}

void main(List<String> args) {
  final policy = readPolicy();
  final folders = packageFolders();
  final dart = [for (final p in shippedDartPackages(folders)) dartVerdict(p, folders[p]!, policy)];
  final rust = [for (final (n, v) in lockedCrates()) rustVerdict(n, v, policy)];
  if (args.contains('--list')) {
    for (final v in [...dart, ...rust]) {
      stdout.writeln('${v.name}: ${v.licences}${v.problem == null ? '' : '  <- ${v.problem}'}');
    }
  }
  final failed = [...dart, ...rust].where((v) => v.problem != null).toList();
  stdout.writeln('${dart.length} Dart packages, ${rust.length} Rust crates; ${failed.length} not allowed or not known');
  for (final v in failed) {
    stderr.writeln('  ${v.name}: ${v.problem}');
  }
  if (failed.isNotEmpty) exit(1);
}
