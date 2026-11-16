// Writes lib/features/help/guides/guides_index.g.dart, the index of the
// feature guides that Help > Guides searches, from the guides themselves
// (the Markdown pages of the docs site, ZestSSH-Docs/src/content/docs/guides).
// The guides' own words are fetched from docs.zestssh.com when one is opened;
// what is compiled in is only what search needs (a few KB, offline).
//
//   dart tool/guides_index.dart [path to ZestSSH-Docs]       writes the index
//   dart tool/guides_index.dart --check [path]               changes nothing; fails when the index is not current
//
// The docs repository is looked for beside this one by default. A page is a
// feature guide when its frontmatter has `features` (the app's feature ids
// whose "?" opens it).
import 'dart:convert';
import 'dart:io';

const indexPath = 'lib/features/help/guides/guides_index.g.dart';

/// One guide's frontmatter, as the index needs it.
class GuideFrontmatter {
  GuideFrontmatter({
    required this.slug,
    required this.title,
    required this.summary,
    required this.keywords,
    required this.platforms,
    required this.features,
    required this.appliesTo,
    required this.order,
  });

  final String slug;
  final String title;
  final String summary;
  final List<String> keywords;
  final List<String> platforms;
  final List<String> features;
  final String appliesTo;
  final int order;
}

/// The frontmatter's fields, read the way the guides write them: one
/// `key: value` to a line, lists in brackets (`[a, b]`). Null when the page
/// has no frontmatter.
Map<String, Object>? readFrontmatter(String markdown) {
  final lines = const LineSplitter().convert(markdown);
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  final out = <String, Object>{};
  for (final line in lines.skip(1)) {
    if (line.trim() == '---') return out;
    final colon = line.indexOf(':');
    if (colon <= 0 || line.startsWith(' ')) continue;
    final key = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    if (value.startsWith('[') && value.endsWith(']')) {
      out[key] = [
        for (final item in value.substring(1, value.length - 1).split(','))
          if (_unquote(item.trim()).isNotEmpty) _unquote(item.trim()),
      ];
    } else {
      out[key] = _unquote(value);
    }
  }
  return null;
}

String _unquote(String s) {
  if (s.length >= 2 && ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
    return s.substring(1, s.length - 1).replaceAll("''", "'").replaceAll(r'\"', '"');
  }
  return s;
}

/// The feature guides in [dir], in their order.
List<GuideFrontmatter> readGuides(Directory dir) {
  final guides = <GuideFrontmatter>[];
  for (final file in dir.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('.md') || name == 'index.md') continue;
    final fm = readFrontmatter(file.readAsStringSync());
    if (fm == null || fm['features'] is! List) continue;
    List<String> list(String key) => [for (final v in (fm[key] as List?) ?? const []) '$v'];
    guides.add(GuideFrontmatter(
      slug: name.substring(0, name.length - 3),
      title: '${fm['title'] ?? ''}',
      summary: '${fm['summary'] ?? fm['description'] ?? ''}',
      keywords: list('keywords'),
      platforms: list('platforms'),
      features: list('features'),
      appliesTo: '${fm['applies_to'] ?? ''}',
      order: int.tryParse('${fm['guide_order'] ?? ''}') ?? 999,
    ));
  }
  guides.sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.slug.compareTo(b.slug));
  return guides;
}

/// What is wrong with [guides] as an index: a slug the app would not fetch,
/// a field left empty, a feature id given to two guides.
List<String> guideIndexProblems(List<GuideFrontmatter> guides) {
  final problems = <String>[];
  final slug = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');
  final featureOwner = <String, String>{};
  for (final g in guides) {
    if (!slug.hasMatch(g.slug)) problems.add('${g.slug}: not a slug the app fetches');
    if (g.title.isEmpty) problems.add('${g.slug}: no title');
    if (g.summary.isEmpty) problems.add('${g.slug}: no summary');
    if (g.keywords.isEmpty) problems.add('${g.slug}: no keywords');
    if (g.features.isEmpty) problems.add('${g.slug}: no feature ids');
    if (g.appliesTo.isEmpty) problems.add('${g.slug}: no applies_to');
    for (final f in g.features) {
      final before = featureOwner[f];
      if (before != null) problems.add('feature $f is given to $before and ${g.slug}');
      featureOwner[f] = g.slug;
    }
  }
  return problems;
}

String _dart(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

String _list(List<String> items) => '[${items.map(_dart).join(', ')}]';

/// The Dart file, from [guides].
String guidesIndexSource(List<GuideFrontmatter> guides) {
  final out = StringBuffer()
    ..writeln('// Written by tool/guides_index.dart from the feature guides of the docs site')
    ..writeln('// (ZestSSH-Docs/src/content/docs/guides). Not edited by hand: change a guide\'s')
    ..writeln('// frontmatter and run `dart tool/guides_index.dart`.')
    ..writeln('// ignore_for_file: lines_longer_than_80_chars')
    ..writeln()
    ..writeln("import 'package:zestssh/features/help/guides/guide_entry.dart';")
    ..writeln()
    ..writeln('/// Every feature guide, in the order of the docs site.')
    ..writeln('const List<GuideEntry> kGuidesIndex = [');
  for (final g in guides) {
    out
      ..writeln('  GuideEntry(')
      ..writeln('    slug: ${_dart(g.slug)},')
      ..writeln('    title: ${_dart(g.title)},')
      ..writeln('    summary: ${_dart(g.summary)},')
      ..writeln('    keywords: ${_list(g.keywords)},')
      ..writeln('    platforms: ${_list(g.platforms)},')
      ..writeln('    features: ${_list(g.features)},')
      ..writeln('    appliesTo: ${_dart(g.appliesTo)},')
      ..writeln('  ),');
  }
  out.writeln('];');
  return out.toString();
}

void main(List<String> args) {
  final check = args.contains('--check');
  final rest = args.where((a) => a != '--check').toList();
  final docs = rest.isNotEmpty ? rest.first : '../ZestSSH-Docs';
  final dir = Directory('$docs/src/content/docs/guides');
  if (!dir.existsSync()) {
    stderr.writeln('No guides at ${dir.path}: give the path to ZestSSH-Docs.');
    exit(2);
  }
  final guides = readGuides(dir);
  final problems = guideIndexProblems(guides);
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    exit(1);
  }
  final source = guidesIndexSource(guides);
  final file = File(indexPath);
  final current = file.existsSync() ? file.readAsStringSync().replaceAll('\r\n', '\n') : '';
  if (check) {
    if (current != source) {
      stderr.writeln('$indexPath is not current: run dart tool/guides_index.dart');
      exit(1);
    }
    stdout.writeln('$indexPath is current (${guides.length} guides).');
    return;
  }
  file.writeAsStringSync(source);
  stdout.writeln('Wrote $indexPath (${guides.length} guides).');
}
