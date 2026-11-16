import 'package:zestssh/services/sftp_sync_compare.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_selection_dialog.dart';

/// What the pre-transfer scan found before any byte moves: the tree the
/// selection dialog shows, and which files will stop for a conflict prompt,
/// so that prompt can say "Conflict 1 of 4" instead of a running count.
class TransferScan {
  const TransferScan({
    required this.root,
    required this.conflicts,
    required this.ambiguous,
    required this.conflictsComplete,
    required this.truncated,
  });

  /// The selection dialog's tree (see [TransferNode]).
  final TransferNode root;

  /// Source paths of the files that will stop for a conflict prompt: the
  /// destination already has one by that name, and it is not the same file by
  /// size and time (the transfer skips those without asking).
  final List<String> conflicts;

  /// The part of [conflicts] a content compare may still settle at transfer
  /// time (same size, but the times disagree or one is missing), plus links
  /// whose kind decides whether they transfer at all. Each may or may not
  /// prompt, so any of them makes the count a bound, not a promise.
  final Set<String> ambiguous;

  /// False when the scan stopped comparing against the destination (too many
  /// folders, too slow, or one it could not list): [conflicts] is then a floor.
  final bool conflictsComplete;

  /// True when the source walk hit its cap: the tree and every count are
  /// floors.
  final bool truncated;

  /// How many conflicts fall outside the subtrees the person pruned in the
  /// selection dialog.
  int conflictCountExcluding(Set<String> excluded) =>
      conflicts.where((c) => !isUnderAny(c, excluded)).length;

  /// Whether [conflictCountExcluding] is exactly how many prompts the transfer
  /// will show.
  bool isExactExcluding(Set<String> excluded) =>
      conflictsComplete &&
      !truncated &&
      !ambiguous.any((c) => !isUnderAny(c, excluded));

  /// Whether [path] is one of [roots] or inside one (either separator, since
  /// a Windows source uses backslashes).
  static bool isUnderAny(String path, Set<String> roots) {
    for (final r in roots) {
      if (path == r || path.startsWith('$r/') || path.startsWith('$r\\')) {
        return true;
      }
    }
    return false;
  }
}

/// Walks the source under [roots] and compares it with the destination under
/// [destPath], the way the transfer will: each folder that already exists at
/// the destination is listed ONCE and its files matched by name, and a folder
/// that does not exist yet cannot hold a conflict. Destination listings stop
/// after [destListLimit] folders or [destTimeLimit], and the count is then
/// marked incomplete, so a huge tree never holds the dialog up for long.
///
/// A directory node's [TransferNode.size] / [TransferNode.items] are recursive
/// (its whole subtree). The source walk is capped at [walkLimit] descents
/// (a pathological source, a million-file tree or `/`, cannot freeze the UI);
/// past it `truncated` is set and every count is a floor.
///
/// [safeChild] turns a source name into the destination leaf name, exactly as
/// the transfer does, so the match looks where the file will actually land.
Future<TransferScan> scanTransferTree({
  required PaneFileSource src,
  required PaneFileSource dst,
  required List<PaneFileEntry> roots,
  required String destPath,
  required String Function(String name) safeChild,
  int walkLimit = 5000,
  int destListLimit = 400,
  Duration destTimeLimit = const Duration(seconds: 4),
}) async {
  final conflicts = <String>[];
  final ambiguous = <String>{};
  var conflictsComplete = true;
  var destListings = 0;
  final clock = Stopwatch()..start();

  // A Windows local destination (NTFS) matches names regardless of case, as
  // the transfer's own exists check does there; a POSIX one exactly.
  String key(String name) {
    final leaf = safeChild(name);
    return dst.isPosix ? leaf : leaf.toLowerCase();
  }

  Future<Map<String, PaneFileEntry>?> destEntries(String dir) async {
    if (!conflictsComplete) return null;
    if (destListings >= destListLimit || clock.elapsed > destTimeLimit) {
      conflictsComplete = false;
      return null;
    }
    destListings++;
    try {
      final listed = await dst.list(dir);
      return {
        for (final e in listed) dst.isPosix ? e.name : e.name.toLowerCase(): e,
      };
    } catch (_) {
      // Unlistable here: the transfer finds its conflicts as it goes.
      conflictsComplete = false;
      return null;
    }
  }

  void compareFile(PaneFileEntry file, PaneFileEntry? existing) {
    if (existing == null) return;
    if (file.isSymlink) {
      // A link to a file transfers (and may prompt); a link to a folder is
      // skipped. Telling which would take another round trip, so it counts
      // as a conflict that may not happen.
      conflicts.add(file.path);
      ambiguous.add(file.path);
      return;
    }
    switch (kSftpSyncCompare.classify(
      localSize: file.size,
      localMtime: file.modifiedAt,
      remoteSize: existing.size,
      remoteMtime: existing.modifiedAt,
    )) {
      case SyncVerdict.identical:
        return;
      case SyncVerdict.different:
        conflicts.add(file.path);
      case SyncVerdict.sameSizeUnknownTime:
        conflicts.add(file.path);
        ambiguous.add(file.path);
    }
  }

  var visited = 0;
  var truncated = false;

  // [destDir] is the destination folder [e] merges into when it already
  // exists there, else null (a new folder cannot hold a conflict).
  Future<TransferNode> build(PaneFileEntry e, String? destDir) async {
    visited++;
    final hidden = e.isHidden || e.isSystemHidden;
    if (!e.isDirectory) {
      return TransferNode(
        path: e.path,
        name: e.name,
        isDir: false,
        isHidden: hidden,
        size: e.size,
        items: 0,
      );
    }
    final children = <TransferNode>[];
    var size = 0;
    var items = 0; // files + folders inside this directory (recursive)
    if (visited <= walkLimit) {
      try {
        final listed = await src.list(e.path);
        final existing = destDir == null ? null : await destEntries(destDir);
        for (final c in listed) {
          final there = existing?[key(c.name)];
          // Symlinked dirs aren't followed by the transfer, so don't preview
          // links as branches - listing them would over-count.
          if (c.isSymlink) {
            compareFile(c, there);
            continue;
          }
          if (!c.isDirectory) compareFile(c, there);
          final node = await build(
            c,
            c.isDirectory && there != null && there.isDirectory
                ? dst.join(destDir!, safeChild(c.name))
                : null,
          );
          children.add(node);
          size += node.size;
          items += 1 + node.items; // the child itself + its own contents
          if (visited > walkLimit) {
            truncated = true;
            break;
          }
        }
      } catch (_) {
        // Can't list - leave it empty; the transfer surfaces the real error.
      }
    } else {
      truncated = true;
    }
    // Folders first, then largest first within each group - this is what
    // surfaces the heavy folder at the top of the tree with no special casing.
    children.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final bySize = b.size.compareTo(a.size);
      return bySize != 0
          ? bySize
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return TransferNode(
      path: e.path,
      name: e.name,
      isDir: true,
      isHidden: hidden,
      size: size,
      items: items,
      children: children,
    );
  }

  // Every root lands directly in [destPath]: list it once for all of them.
  final top = await destEntries(destPath);
  final topLevel = <TransferNode>[];
  for (final root in roots) {
    final there = top?[key(root.name)];
    if (root.isDirectory) {
      topLevel.add(await build(
        root,
        there != null && there.isDirectory
            ? dst.join(destPath, safeChild(root.name))
            : null,
      ));
    } else {
      compareFile(root, there);
      topLevel.add(await build(root, null));
    }
  }
  // A single dragged directory shows its CONTENTS as the top level (the
  // folder itself is created at the destination, named by the "To" row), so
  // the tree matches the transfer without an extra wrapper row. A multi-item
  // drag shows the dragged items themselves.
  final TransferNode rootNode;
  if (topLevel.length == 1 && topLevel.single.isDir) {
    rootNode = topLevel.single;
  } else {
    rootNode = TransferNode(
      path: '',
      name: '',
      isDir: true,
      isHidden: false,
      size: 0,
      items: 0,
      children: topLevel,
    );
  }
  return TransferScan(
    root: rootNode,
    conflicts: conflicts,
    ambiguous: ambiguous,
    conflictsComplete: conflictsComplete,
    truncated: truncated,
  );
}
