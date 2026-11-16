/// The single definition of "these two files are the same" for SFTP transfers.
///
/// Both the top-level and the recursive transfer loops in
/// `sftp_dual_pane_screen.dart` MUST call this. There is deliberately no second
/// copy: the size-and-mtime predicate used to be inlined at both call sites and
/// the two copies were exactly the kind of thing that drifts apart over time.
/// A source-gate test asserts no inline size+mtime comparison reappears in the
/// SFTP screen.
///
/// Why an mtime comparison is meaningful at all (the "timestamps mean nothing"
/// concern): this is NOT the server's clock. Uploads default to
/// `preserveTimestamp: true`, so after each upload the remote mtime is set to
/// the LOCAL file's mtime via SETSTAT (ACMODTIME). Level 2 therefore compares a
/// local value against a value this app itself wrote, so server clock, timezone
/// and drift never enter into it. When a server refuses that SETSTAT write, or
/// the files were re-stamped by something else (a rebuilt `build/` tree, an
/// unzip, a `cp` without `-p`), the timestamps stop agreeing while the bytes
/// are still the same: [isSameContent] settles that case with a content hash
/// of both ends rather than treating every file as changed.
class SyncCompare {
  const SyncCompare({this.mtimeToleranceSeconds = defaultToleranceSeconds});

  /// THE default mtime window (spec 5a: "a single constant, not repeated at
  /// call sites"). Every other default in the sync path derives from this.
  static const int defaultToleranceSeconds = 1;

  /// Largest file the content fallback will hash. Hashing reads the whole
  /// file at both ends (a server-side `sha256sum`, a local streaming hash),
  /// always cheaper than sending the same bytes over the wire, but on a
  /// multi-GB file it is still tens of seconds of silence before the transfer
  /// starts; past this size the file is simply transferred.
  static const int defaultMaxHashBytes = 2 * 1024 * 1024 * 1024;

  /// Allowed difference between the two mtimes, in whole seconds. SFTP v3
  /// carries mtime as 32-bit seconds so sub-second precision never survives the
  /// round trip, and FAT/exFAT store 2-second granularity, so a small tolerance
  /// (rsync's `--modify-window`) avoids spurious "changed" verdicts. One second
  /// by default; 0 for exact, 2 for FAT-backed remotes.
  final int mtimeToleranceSeconds;

  /// Whether the destination already holds a byte-identical copy: same size and
  /// the same mtime within [mtimeToleranceSeconds]. Compared as whole seconds
  /// since the Unix epoch, which is timezone-independent (millisecondsSinceEpoch
  /// is an absolute instant), so no `.toUtc()` normalisation is needed.
  ///
  /// A genuine change differs in size or mtime and is never reported identical.
  /// The heuristic's one blind spot, an edit that keeps the exact byte length
  /// and lands within the tolerance window, is the same one rsync ships by
  /// default; a content hash (opt-in) is the way to be certain.
  /// The same predicate with a different mtime tolerance (spec 5a lets a
  /// FAT-backed remote use 2s, or an exact compare use 0), without forking the
  /// definition.
  SyncCompare withTolerance(int seconds) =>
      SyncCompare(mtimeToleranceSeconds: seconds);

  bool isIdentical({
    required int localSize,
    required DateTime localMtime,
    required int remoteSize,
    required DateTime remoteMtime,
  }) {
    if (localSize != remoteSize) return false;
    final l = localMtime.millisecondsSinceEpoch ~/ 1000;
    final r = remoteMtime.millisecondsSinceEpoch ~/ 1000;
    return (l - r).abs() <= mtimeToleranceSeconds;
  }

  /// The cheap verdict from size and mtime alone, before any hashing.
  SyncVerdict classify({
    required int localSize,
    required DateTime? localMtime,
    required int remoteSize,
    required DateTime? remoteMtime,
  }) {
    if (localSize != remoteSize) return SyncVerdict.different;
    if (localMtime != null &&
        remoteMtime != null &&
        isIdentical(
          localSize: localSize,
          localMtime: localMtime,
          remoteSize: remoteSize,
          remoteMtime: remoteMtime,
        )) {
      return SyncVerdict.identical;
    }
    return SyncVerdict.sameSizeUnknownTime;
  }

  /// Whether the two files hold the same bytes, so a "replace changed files"
  /// transfer can skip this one.
  ///
  /// Size and mtime settle it cheaply in both directions ([classify]). The
  /// ambiguous case, same size but the timestamps disagree, is what a rebuilt
  /// tree, an unzip, a `cp` without `-p` or a server that refused SETSTAT all
  /// produce for files whose bytes never changed: [hashLocal] and [hashRemote]
  /// are then both run (concurrently) and the file is the same only when both
  /// digests exist and match. Any doubt, a hash that failed, a file over
  /// [maxHashBytes], answers "changed", the safe direction, which is to
  /// transfer. Two empty files are the same without hashing.
  Future<bool> isSameContent({
    required int localSize,
    required DateTime? localMtime,
    required int remoteSize,
    required DateTime? remoteMtime,
    required Future<String?> Function() hashLocal,
    required Future<String?> Function() hashRemote,
    int maxHashBytes = defaultMaxHashBytes,
  }) async {
    switch (classify(
      localSize: localSize,
      localMtime: localMtime,
      remoteSize: remoteSize,
      remoteMtime: remoteMtime,
    )) {
      case SyncVerdict.identical:
        return true;
      case SyncVerdict.different:
        return false;
      case SyncVerdict.sameSizeUnknownTime:
        if (localSize == 0) return true;
        if (localSize > maxHashBytes) return false;
        final digests = await Future.wait([
          _digest(hashLocal),
          _digest(hashRemote),
        ]);
        final a = digests[0];
        final b = digests[1];
        return a != null && b != null && a == b;
    }
  }

  /// A hasher that throws counts as "unavailable", never as a verdict.
  static Future<String?> _digest(Future<String?> Function() hash) async {
    try {
      final d = await hash();
      if (d == null || d.isEmpty) return null;
      return d.toLowerCase();
    } catch (_) {
      return null;
    }
  }
}

/// [SyncCompare.classify]'s answer for a source / destination pair.
enum SyncVerdict {
  /// Same size, same mtime within tolerance: the same bytes, skip.
  identical,

  /// Different size: certainly different, transfer.
  different,

  /// Same size but the mtimes disagree, or one is unknown. Only a content
  /// hash can tell a re-stamped copy from a real same-length edit.
  sameSizeUnknownTime,
}

/// The shared instance both SFTP transfer loops use. A single tolerance value,
/// not a constant repeated at call sites.
const SyncCompare kSftpSyncCompare = SyncCompare();
