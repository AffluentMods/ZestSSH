import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/transfer_scan.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// An in-memory source: directory path -> its entries. Counts listings.
class _MemFs extends PaneFileSource {
  _MemFs({this.posix = true, this.unlistable = const {}});

  final bool posix;
  final Set<String> unlistable;
  final Map<String, List<PaneFileEntry>> dirs = {};
  final List<String> listed = [];

  /// Adds [name] under [parent]: a folder when [files] or [folder] is given.
  PaneFileEntry add(
    String parent,
    String name, {
    int size = 0,
    DateTime? mtime,
    bool folder = false,
    bool symlink = false,
  }) {
    final path = join(parent, name);
    final entry = PaneFileEntry(
      name: name,
      path: path,
      isDirectory: folder,
      size: size,
      modifiedAt: mtime,
      isSymlink: symlink,
    );
    dirs.putIfAbsent(parent, () => []).add(entry);
    if (folder) dirs.putIfAbsent(path, () => []);
    return entry;
  }

  @override
  String get sourceId => 'mem';
  @override
  bool get isPosix => posix;
  @override
  Future<String> homeDirectory() async => posix ? '/' : r'C:\';

  @override
  Future<List<PaneFileEntry>> list(String path,
      {bool includeHidden = true}) async {
    listed.add(path);
    if (unlistable.contains(path)) throw Exception('Permission denied');
    final entries = dirs[path];
    if (entries == null) throw Exception('No such directory: $path');
    return entries;
  }

  // Unused surface.
  @override
  Future<PaneFileEntry?> stat(String path) async => null;
  @override
  Future<bool> exists(String path) async => dirs.containsKey(path);
  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {}
  @override
  Future<void> rename(String oldPath, String newPath) async {}
  @override
  Future<void> deleteFile(String path) async {}
  @override
  Future<void> deleteDirectoryRecursive(String path,
      {void Function(String deletedPath)? onDeleted,
      bool Function()? isCancelled}) async {}
  @override
  Future<int> countEntriesRecursive(String path) async => 0;
  @override
  Future<void> chmod(String path, int mode) async {}
  @override
  Future<void> chmodRecursive(String path, int mode,
      {void Function(String path)? onDone, bool Function()? isCancelled}) async {}
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async =>
      Uint8List(0);
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
  @override
  Future<void> downloadFile(String remotePath, String localPath,
      {PaneTransferProgress? onProgress,
      TransferCancelToken? cancelToken,
      int? maxBytes,
      bool bulk = false}) async {}
  @override
  Future<void> uploadFile(String localPath, String remotePath,
      {PaneTransferProgress? onProgress,
      TransferCancelToken? cancelToken,
      bool bulk = false}) async {}
}

final _t1 = DateTime(2026, 9, 1, 12);
final _t2 = DateTime(2026, 9, 9, 13);

Future<TransferScan> _scan(
  _MemFs src,
  _MemFs dst,
  List<PaneFileEntry> roots,
  String destPath, {
  int destListLimit = 400,
}) =>
    scanTransferTree(
      src: src,
      dst: dst,
      roots: roots,
      destPath: destPath,
      safeChild: (n) => n,
      destListLimit: destListLimit,
    );

void main() {
  test('only files that will prompt count, nested ones included, and a folder '
      'that already exists is not a conflict by itself', () async {
    // Uploading pipeline/ and site-assets/ into a destination that has both.
    final src = _MemFs()..dirs['/src'] = [];
    final pipeline = src.add('/src', 'pipeline', folder: true);
    src.add(pipeline.path, 'app.py', size: 61800, mtime: _t2); // changed
    src.add(pipeline.path, 'worker.py', size: 900, mtime: _t1); // identical
    src.add(pipeline.path, 'new.py', size: 10, mtime: _t2); // not there yet
    final corpus = src.add('/src', 'site-assets', folder: true);
    final docs = src.add(corpus.path, 'docs', folder: true);
    src.add(docs.path, 'a.md', size: 50, mtime: _t2); // changed
    final fresh = src.add(corpus.path, 'fresh', folder: true);
    src.add(fresh.path, 'a.md', size: 1, mtime: _t2); // new folder: no conflict

    final dst = _MemFs()..dirs['/dst'] = [];
    final dPipeline = dst.add('/dst', 'pipeline', folder: true);
    dst.add(dPipeline.path, 'app.py', size: 60000, mtime: _t1);
    dst.add(dPipeline.path, 'worker.py', size: 900, mtime: _t1);
    final dCorpus = dst.add('/dst', 'site-assets', folder: true);
    final dDocs = dst.add(dCorpus.path, 'docs', folder: true);
    dst.add(dDocs.path, 'a.md', size: 40, mtime: _t1);

    final scan = await _scan(src, dst, [pipeline, corpus], '/dst');
    expect(scan.conflicts, ['/src/pipeline/app.py', '/src/site-assets/docs/a.md']);
    expect(scan.ambiguous, isEmpty);
    expect(scan.conflictsComplete, isTrue);
    expect(scan.conflictCountExcluding(const {}), 2);
    expect(scan.isExactExcluding(const {}), isTrue);
    // Folders missing at the destination are never listed there.
    expect(dst.listed, isNot(contains('/dst/site-assets/fresh')));
    // The tree still carries everything, with recursive totals.
    expect(scan.root.children.map((n) => n.name), ['pipeline', 'site-assets']);
  });

  test('pruned subtrees drop their conflicts, and a same-size file with other '
      'times makes the count a bound until it is pruned', () async {
    final src = _MemFs()..dirs['/src'] = [];
    final app = src.add('/src', 'app', folder: true);
    src.add(app.path, 'main.dart', size: 100, mtime: _t2); // changed
    final gen = src.add(app.path, 'gen', folder: true);
    src.add(gen.path, 'out.js', size: 500, mtime: _t2); // same size, new time

    final dst = _MemFs()..dirs['/dst'] = [];
    final dApp = dst.add('/dst', 'app', folder: true);
    dst.add(dApp.path, 'main.dart', size: 90, mtime: _t1);
    final dGen = dst.add(dApp.path, 'gen', folder: true);
    dst.add(dGen.path, 'out.js', size: 500, mtime: _t1);

    final scan = await _scan(src, dst, [app], '/dst');
    expect(scan.conflicts, hasLength(2));
    expect(scan.ambiguous, {'/src/app/gen/out.js'});
    expect(scan.isExactExcluding(const {}), isFalse,
        reason: 'a content compare may still skip out.js');

    final pruned = {'/src/app/gen'};
    expect(scan.conflictCountExcluding(pruned), 1);
    expect(scan.isExactExcluding(pruned), isTrue);
  });

  test('a flat drag of files compares each with the destination folder, listed once',
      () async {
    final src = _MemFs()..dirs['/src'] = [];
    final a = src.add('/src', 'a.txt', size: 3, mtime: _t2);
    final b = src.add('/src', 'b.txt', size: 4, mtime: _t1);
    final c = src.add('/src', 'c.txt', size: 5, mtime: _t1);
    final dst = _MemFs()..dirs['/dst'] = [];
    dst.add('/dst', 'a.txt', size: 9, mtime: _t1); // changed
    dst.add('/dst', 'b.txt', size: 4, mtime: _t1); // identical

    final scan = await _scan(src, dst, [a, b, c], '/dst');
    expect(scan.conflicts, ['/src/a.txt']);
    expect(scan.isExactExcluding(const {}), isTrue);
    expect(dst.listed, ['/dst']);
  });

  test('on a Windows destination names match regardless of case, as NTFS does',
      () async {
    final src = _MemFs()..dirs['/src'] = [];
    final readme = src.add('/src', 'README.md', size: 10, mtime: _t2);
    final dst = _MemFs(posix: false);
    const root = r'C:\dst';
    dst.dirs[root] = [];
    dst.add(root, 'readme.md', size: 7, mtime: _t1);

    final scan = await _scan(src, dst, [readme], root);
    expect(scan.conflicts, ['/src/README.md']);
  });

  test('a link colliding with a destination name is a conflict that may not '
      'happen', () async {
    final src = _MemFs()..dirs['/src'] = [];
    final dir = src.add('/src', 'site', folder: true);
    src.add(dir.path, 'current', symlink: true);
    final dst = _MemFs()..dirs['/dst'] = [];
    final dSite = dst.add('/dst', 'site', folder: true);
    dst.add(dSite.path, 'current', size: 4, mtime: _t1);

    final scan = await _scan(src, dst, [dir], '/dst');
    expect(scan.ambiguous, {'/src/site/current'});
    expect(scan.isExactExcluding(const {}), isFalse);
  });

  test('past the listing budget, or at a folder it cannot list, the count is '
      'a floor', () async {
    final src = _MemFs()..dirs['/src'] = [];
    final a = src.add('/src', 'a', folder: true);
    final b = src.add(a.path, 'b', folder: true);
    src.add(b.path, 'x.txt', size: 1, mtime: _t2);
    final dst = _MemFs()..dirs['/dst'] = [];
    final dA = dst.add('/dst', 'a', folder: true);
    final dB = dst.add(dA.path, 'b', folder: true);
    dst.add(dB.path, 'x.txt', size: 2, mtime: _t1);

    final full = await _scan(src, dst, [a], '/dst');
    expect(full.conflicts, ['/src/a/b/x.txt']);
    expect(full.isExactExcluding(const {}), isTrue);

    final capped = await _scan(src, dst, [a], '/dst', destListLimit: 2);
    expect(capped.conflictsComplete, isFalse);
    expect(capped.isExactExcluding(const {}), isFalse);

    final locked = _MemFs(unlistable: {'/dst/a/b'})..dirs.addAll(dst.dirs);
    final denied = await _scan(src, locked, [a], '/dst');
    expect(denied.conflictsComplete, isFalse);
  });
}
