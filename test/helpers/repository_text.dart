import 'dart:io';

/// Where the repository's own text lives. What is fetched or built (packages
/// from the registry, build output, generated code) is not its text.
const _roots = ['lib', 'test', 'docs', 'tool', 'packages', 'installer', 'infra'];
// (target: what cargo builds the Rust crate into, ignored by git.)
const _skipped = {'node_modules', 'build', '.dart_tool', 'generated', 'target'};
const _kinds = {
  'dart', 'arb', 'md', 'yaml', 'yml', 'json', 'txt', 'html', 'iss', 'sh', 'ps1', 'py', 'js', 'mjs', 'xml', 'plist', //
  'gradle', 'kts', 'cmake', 'cc', 'cpp', 'h', 'rc', 'swift', 'kt', 'java', 'svg', 'css', 'toml',
};

bool _isText(String name) => _kinds.contains(name.split('.').last.toLowerCase());

String _name(FileSystemEntity entry) => entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

Iterable<File> _under(Directory dir) sync* {
  for (final entry in dir.listSync(followLinks: false)) {
    if (entry is Directory) {
      if (!_skipped.contains(_name(entry))) yield* _under(entry);
    } else if (entry is File && _isText(_name(entry))) {
      yield entry;
    }
  }
}

/// The files git would publish from [base]: tracked ones, and new ones not
/// ignored. Null where git cannot say (no repository), and then every file
/// on the disk counts. What git ignores (local notes
/// listed in .git/info/exclude, build output, a cargo target folder) is never
/// part of the published tree, so the tests that look at that tree skip it.
Set<String>? _published(Directory base) {
  try {
    final run = Process.runSync('git', ['-C', base.path, 'ls-files', '-z', '--cached', '--others', '--exclude-standard']);
    if (run.exitCode != 0) return null;
    return (run.stdout as String).split('\u0000').where((p) => p.isNotEmpty).toSet();
  } on ProcessException {
    return null;
  }
}

/// Every text file of the repository at [base], for the tests that look
/// through all of it: what lies under its [_roots], and the files at its
/// top, that git would publish. Each with its path from [base], with
/// forward slashes.
Iterable<({String path, String text})> repositoryText(Directory base) sync* {
  final published = _published(base);
  final files = [
    for (final root in _roots)
      if (Directory('${base.path}/$root').existsSync()) ..._under(Directory('${base.path}/$root')),
    ...base.listSync(followLinks: false).whereType<File>().where((f) => _isText(_name(f))),
  ];
  for (final file in files) {
    final path = file.path.replaceAll('\\', '/').substring(base.path.replaceAll('\\', '/').length + 1);
    if (published != null && !published.contains(path)) continue;
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      continue; // not text after all
    }
    yield (path: path, text: text);
  }
}
