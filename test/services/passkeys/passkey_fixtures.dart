import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ZestSSH Cloud's own passkey options and the responses its software
/// authenticator gives them (soft_authenticator.json beside this file, made
/// by soft_authenticator_fixtures.js from the backend's src/lib/passkeys.js
/// and test/helpers/soft_authenticator.js): what the server's own tests show
/// it accepts. A fresh copy on each call.
Map<String, Object?> softAuthenticator() =>
    jsonDecode(File('test/services/passkeys/soft_authenticator.json').readAsStringSync()) as Map<String, Object?>;

/// [path] of [json], a map at each step.
Map<String, Object?> at(Map<String, Object?> json, List<String> path) {
  Object? here = json;
  for (final key in path) {
    here = (here! as Map)[key];
  }
  return here! as Map<String, Object?>;
}

/// [actual] has every field of [expected], at every depth, with the same
/// value and nothing more: each difference is said by its path.
void expectSameFields(Object? actual, Object? expected, [String path = r'$']) {
  if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    final got = actual! as Map;
    expect(got.keys.toSet(), expected.keys.toSet(), reason: '$path: its fields');
    for (final key in expected.keys) {
      expectSameFields(got[key], expected[key], '$path.$key');
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    final got = actual! as List;
    expect(got.length, expected.length, reason: '$path: its length');
    for (var i = 0; i < expected.length; i++) {
      expectSameFields(got[i], expected[i], '$path[$i]');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

/// [b64u] (base64url without padding) as bytes.
List<int> bytesOf(String b64u) => base64Url.decode(base64Url.normalize(b64u));
