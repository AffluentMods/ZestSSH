import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/rust_notices.dart'
    show appFeatures, forkNotice, forksDir, licenceTexts, noticesPath, separator, vendored, vncEngineName;

/// The licences of the Rust crates the native library ships (3.4) are in the app's licences page:
/// packages/zest_native/NOTICES, which Flutter reads into the page as it reads a Dart package's
/// LICENSE, split as Flutter splits it. Written by tool/rust_notices.dart from `cargo tree` for
/// the ten targets (its --check runs cargo); here, without cargo, it is held to Cargo.lock.
void main() {
  final text = File(noticesPath).readAsStringSync();
  final lock = File('packages/zest_native/rust/Cargo.lock').readAsStringSync();
  final locked = {for (final m in RegExp(r'^name = "([^"]+)"', multiLine: true).allMatches(lock)) m.group(1)!};

  /// The sections as flutter_tools' license_collector.dart reads them.
  List<({List<String> names, String text})> sections() => [
        for (final raw in text.split(separator))
          (names: raw.substring(0, raw.indexOf('\n\n')).split('\n'), text: raw.substring(raw.indexOf('\n\n') + 2)),
      ];

  test('it is split as Flutter splits a NOTICES file, with LF line ends', () {
    expect(text, isNot(contains('\r')), reason: '.gitattributes keeps it LF: CRLF would leave it one block');
    final all = sections();
    expect(all.length, greaterThan(10));
    for (final s in all) {
      expect(s.names, isNotEmpty);
      expect(s.text.trim(), isNotEmpty, reason: s.names.join(', '));
    }
  });

  test('every crate it names is in Cargo.lock (or vendored), and the library itself is not named', () {
    final named = {for (final s in sections()) ...s.names};
    expect(named.difference(locked).difference(vendored(appFeatures()).keys.toSet()), isEmpty);
    expect(named, isNot(contains('zest_native')));
  });

  test('the crates FTPS rests on are there, and no proc-macro (nothing of one ships)', () {
    final named = {for (final s in sections()) ...s.names};
    expect(named, containsAll(<String>[
      'suppaftp', 'rustls', 'ring', 'rustls-webpki', 'untrusted', 'webpki-roots', 'rustls-pki-types', 'sha2', //
      'serde_json', 'base64', 'regex', 'lazy-regex', 'chrono', 'subtle', 'rustls-platform-verifier',
    ]));
    expect(named.intersection({'serde_derive', 'thiserror-impl', 'lazy-regex-proc_macros', 'syn', 'quote'}), isEmpty);
  });

  test("a crate the app forks gives its licences and its notice of what changed from the fork's folder", () {
    // cargo keeps no copy of a crate it takes from a path, so the tool must not look for one
    // (4.0, RDP: ironrdp-graphics and ironrdp-session, used through [patch.crates-io]).
    final manifest = File('packages/zest_native/rust/Cargo.toml').readAsStringSync();
    final patched = [
      for (final m in RegExp(r'^([\w-]+) = \{ path = "vendor/([\w-]+)" \}', multiLine: true).allMatches(manifest))
        m.group(1)!,
    ];
    expect(patched, containsAll(<String>['ironrdp-graphics', 'ironrdp-session']));
    for (final name in patched) {
      final version = RegExp('name = "$name"\\r?\\nversion = "([^"]+)"').firstMatch(lock)!.group(1)!;
      final texts = licenceTexts(name, version);
      expect(texts.length, 3, reason: '$name: MIT, Apache-2.0, and what was changed');
      expect(texts.any((t) => t.contains('Apache License') && t.contains('Version 2.0')), isTrue, reason: name);
      expect(texts.any((t) => t.contains('Permission is hereby granted, free of charge')), isTrue, reason: name);
      expect(texts.last, startsWith("ZestSSH's copy of $name (this folder) is a fork"), reason: name);
      expect(texts.last, contains('What changed against $version'), reason: name);
      expect(File('$forksDir/$name/$forkNotice').existsSync(), isTrue);
      // A fork of another version than the lock's is refused, named.
      expect(() => licenceTexts(name, '0.0.0'), throwsStateError);
    }
  });

  test("with the app's features vnc and rdp: their crates, and the vendored engine's MIT and Apache notices", () {
    expect(appFeatures(), containsAll(<String>['vnc', 'rdp']),
        reason: "the app's pubspec turns the remote screen engine on, for VNC and for RDP");
    expect(appFeatures(), isNot(contains('probes')));
    final named = {for (final s in sections()) ...s.names};
    expect(named, containsAll(<String>[
      vncEngineName, 'tokio', 'tokio-rustls', 'flate2', 'miniz_oxide', 'zune-jpeg', 'num-bigint', 'md-5', 'aes', //
      'x509-cert', 'zeroize',
    ]));
    // RDP's crates (4.0): IronRDP's own, what signs in (sspi and its NTLM), TLS's X.509,
    // and the two the app forks, each listed with what was changed in it.
    expect(named, containsAll(<String>[
      'ironrdp-connector', 'ironrdp-session', 'ironrdp-graphics', 'ironrdp-pdu', 'ironrdp-svc', 'ironrdp-dvc', //
      'ironrdp-egfx', 'ironrdp-displaycontrol', 'sspi', 'picky',
    ]));
    // The clipboard is the app's own channel: IronRDP's clipboard crate, which also moves files,
    // is not in the library. Neither are the crates of a server.
    expect(named.where((n) => n == 'ironrdp-cliprdr' || n == 'ironrdp-acceptor' || n == 'ironrdp-server'), isEmpty);
    for (final fork in ['ironrdp-graphics', 'ironrdp-session']) {
      final texts = [for (final s in sections()) if (s.names.contains(fork)) s.text];
      expect(texts.any((t) => t.startsWith("ZestSSH's copy of $fork (this folder) is a fork")), isTrue, reason: fork);
    }
    final engine = [for (final s in sections()) if (s.names.contains(vncEngineName)) s.text];
    expect(engine.any((t) => t.contains('Copyright (c) 2022 Jovi Hsu')), isTrue, reason: "vnc-rs's MIT licence");
    expect(engine.any((t) => t.contains('Apache License') && t.contains('Version 2.0')), isTrue);
    expect(engine.any((t) => t.contains('whitequark')), isTrue, reason: "codec/zlib.rs's own MIT notice");
    // client/security/des.rs keeps Antoni Boucher's MIT notice at its top: it goes with the binary too.
    expect(engine.any((t) => t.startsWith('Copyright (c) 2016 Boucher, Antoni') && t.contains('Permission is hereby granted')),
        isTrue,
        reason: "client/security/des.rs's own MIT notice");
    expect(engine.where((t) => t.contains('Boucher')).single, isNot(contains(' * ')), reason: "the comment's stars are left out");
  });
}
