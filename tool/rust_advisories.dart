// Asks whether any Rust crate the native library ships has a published advisory (4.0, RDP;
// found in a review before 4.0: nothing checked on a schedule, and `rdp` brings three).
//
// Which crates: the same list tool/rust_notices.dart writes licences for (`cargo tree` for the ten
// targets with the app's cargo features, or the ones named). Whom it asks: OSV (api.osv.dev), which
// carries the RustSec database, the unmaintained notices among it. What it sends: crate names and
// versions, nothing else. An advisory that was looked at and taken is in
// packages/zest_native/rust/advisories-accepted.txt with why; any other ends the tool with 1.
//
//   dart tool/rust_advisories.dart                      the features the app builds with
//   dart tool/rust_advisories.dart --features=vnc,rdp   a feature set the app does not build yet
//
// Needs cargo and the network. Run it before a release and before a cargo feature goes into the
// pubspec.
import 'dart:convert';
import 'dart:io';

import 'rust_notices.dart' show appFeatures, shippedCrates;

const acceptedPath = 'packages/zest_native/rust/advisories-accepted.txt';

/// The advisories taken as they are: `ID | crate | why`, one a line (`#` starts a comment).
Map<String, ({String crate, String why})> accepted([String path = acceptedPath]) {
  final out = <String, ({String crate, String why})>{};
  final file = File(path);
  if (!file.existsSync()) return out;
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split('|').map((p) => p.trim()).toList();
    if (parts.length < 3 || parts[2].isEmpty) throw FormatException('$path: "$line" is not "ID | crate | why"');
    out[parts[0]] = (crate: parts[1], why: parts.sublist(2).join(' | '));
  }
  return out;
}

Future<Map<String, dynamic>> _json(HttpClient client, String method, String url, [Object? body]) async {
  final request = await client.openUrl(method, Uri.parse(url));
  request.headers.contentType = ContentType.json;
  if (body != null) request.write(jsonEncode(body));
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) throw HttpException('$url: ${response.statusCode} $text');
  return jsonDecode(text) as Map<String, dynamic>;
}

/// The advisory ids OSV has for each of [crates] (those with none are left out).
Future<Map<(String, String), List<String>>> advisories(HttpClient client, List<(String, String)> crates) async {
  final out = <(String, String), List<String>>{};
  // OSV takes up to 1000 queries a call.
  for (var from = 0; from < crates.length; from += 500) {
    final batch = crates.sublist(from, from + 500 > crates.length ? crates.length : from + 500);
    final answer = await _json(client, 'POST', 'https://api.osv.dev/v1/querybatch', {
      'queries': [
        for (final (name, version) in batch)
          {
            'package': {'name': name, 'ecosystem': 'crates.io'},
            'version': version,
          },
      ],
    });
    final results = answer['results'] as List;
    if (results.length != batch.length) throw StateError('OSV answered ${results.length} of ${batch.length}');
    for (var i = 0; i < batch.length; i++) {
      final found = ((results[i] as Map)['vulns'] as List?) ?? const [];
      if (found.isNotEmpty) out[batch[i]] = [for (final v in found) (v as Map)['id'] as String];
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final named = args.where((a) => a.startsWith('--features=')).map((a) => a.substring(11)).firstOrNull;
  final features = named == null
      ? appFeatures()
      : [for (final f in named.split(',')) if (f.trim().isNotEmpty) f.trim()];
  final crates = await shippedCrates(features);
  final taken = accepted();
  final client = HttpClient();
  var open = 0;
  try {
    final found = await advisories(client, crates);
    final ids = {for (final list in found.values) ...list};
    for (final MapEntry(key: (name, version), value: list) in found.entries) {
      for (final id in list) {
        final detail = await _json(client, 'GET', 'https://api.osv.dev/v1/vulns/$id');
        // RustSec's notices that are not vulnerabilities say so for each affected package.
        final kind = [
              for (final a in (detail['affected'] as List?) ?? const [])
                ((a as Map)['database_specific'] as Map?)?['informational'] as String?,
            ].whereType<String>().firstOrNull ??
            'vulnerability';
        final summary = (detail['summary'] as String?) ?? '';
        final ok = taken[id];
        if (ok == null || ok.crate != name) open++;
        stdout.writeln('${ok != null && ok.crate == name ? 'accepted' : 'OPEN    '} $id $name $version ($kind): $summary');
        if (ok != null && ok.crate == name) stdout.writeln('         ${ok.why}');
      }
    }
    for (final MapEntry(key: id, value: entry) in taken.entries) {
      // The crate still ships and the advisory no longer applies to it: the entry can go.
      if (!ids.contains(id) && crates.any((c) => c.$1 == entry.crate)) {
        stdout.writeln('note: $id is accepted, but ${entry.crate} as locked no longer has it: take the entry out');
      }
    }
  } finally {
    client.close();
  }
  stdout.writeln('${crates.length} crates with ${features.join(', ')}: $open advisories not accepted');
  if (open > 0) exit(1);
}
