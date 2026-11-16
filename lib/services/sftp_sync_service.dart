import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:zestssh/database/daos/sftp_sync_manifest_dao.dart';
import 'package:zestssh/database/database.dart' show SftpSyncManifestRow;
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_sync_compare.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';

/// User-configurable options for an SFTP mirror/sync.
///
/// The sync is a single direction: local -> remote ("keep the remote in step
/// with my local copy"). Two-way sync is deliberately not implemented, because
/// conflict resolution needs a UX surface that would let users clobber either
/// side without confirmation.
class SftpSyncOptions {
  /// Descend into subdirectories.
  final bool recursive;

  /// Only update files that already exist on the remote, never add new ones.
  final bool existingOnly;

  /// Whitelist glob patterns, matched against FILE basenames only. Empty means
  /// "no whitelist". Directories are never filtered by the include list.
  final List<String> include;

  /// Blacklist glob patterns, matched against file AND directory basenames
  /// (an excluded directory is not descended into). Always wins over include.
  final List<String> exclude;

  /// Show a countdown banner then auto-run when SFTP opens for this host.
  final bool autoOnConnect;

  /// Countdown before auto-sync fires.
  final int countdownSeconds;

  /// Verify by CONTENT, not timestamp: for a file whose remote size matches,
  /// compare a SHA-256 of both ends (server-side `sha256sum` vs a local hash)
  /// and skip only when the hashes match. This is the reliable "only what
  /// changed" mode, immune to timestamps that a rebuild or an unzip reset. It
  /// costs one server-side hash per same-size file, so it is opt-in.
  final bool verifyContent;

  /// Ignore the identical check entirely and re-send every file (the "force
  /// re-upload everything" escape hatch, for a suspected corrupt/partial
  /// earlier upload).
  final bool forceReupload;

  /// Delete files that exist ONLY on the server (not in the local tree).
  /// Off by default and never implicit: the preview lists them by name and the
  /// deletes run last, only after every upload has succeeded.
  final bool deleteRemoteOnly;

  /// Allowed mtime difference in whole seconds when comparing by timestamp
  /// (rsync's --modify-window). SFTP mtime is second-resolution; FAT is 2s.
  final int mtimeToleranceSeconds;

  const SftpSyncOptions({
    this.recursive = true,
    this.existingOnly = false,
    this.include = const [],
    this.exclude = const ['*.tmp', '.DS_Store', 'Thumbs.db'],
    this.autoOnConnect = false,
    this.countdownSeconds = 3,
    this.verifyContent = false,
    this.forceReupload = false,
    this.deleteRemoteOnly = false,
    this.mtimeToleranceSeconds = SyncCompare.defaultToleranceSeconds,
  });

  SftpSyncOptions copyWith({
    bool? recursive,
    bool? existingOnly,
    List<String>? include,
    List<String>? exclude,
    bool? autoOnConnect,
    int? countdownSeconds,
    bool? verifyContent,
    bool? forceReupload,
    bool? deleteRemoteOnly,
    int? mtimeToleranceSeconds,
  }) =>
      SftpSyncOptions(
        recursive: recursive ?? this.recursive,
        existingOnly: existingOnly ?? this.existingOnly,
        include: include ?? this.include,
        exclude: exclude ?? this.exclude,
        autoOnConnect: autoOnConnect ?? this.autoOnConnect,
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
        verifyContent: verifyContent ?? this.verifyContent,
        forceReupload: forceReupload ?? this.forceReupload,
        deleteRemoteOnly: deleteRemoteOnly ?? this.deleteRemoteOnly,
        mtimeToleranceSeconds:
            mtimeToleranceSeconds ?? this.mtimeToleranceSeconds,
      );

  // Persisted options never include the one-shot flags (forceReupload,
  // deleteRemoteOnly, verifyContent are per-run choices, not saved defaults).
  Map<String, dynamic> toJson() => {
        'recursive': recursive,
        'existingOnly': existingOnly,
        'include': include,
        'exclude': exclude,
        'autoOnConnect': autoOnConnect,
        'countdownSeconds': countdownSeconds,
        'mtimeToleranceSeconds': mtimeToleranceSeconds,
      };

  factory SftpSyncOptions.fromJson(Map<String, dynamic> j) => SftpSyncOptions(
        recursive: j['recursive'] as bool? ?? true,
        existingOnly: j['existingOnly'] as bool? ?? false,
        include: (j['include'] as List?)?.cast<String>() ?? const [],
        exclude: (j['exclude'] as List?)?.cast<String>() ??
            const ['*.tmp', '.DS_Store', 'Thumbs.db'],
        autoOnConnect: j['autoOnConnect'] as bool? ?? false,
        countdownSeconds: j['countdownSeconds'] as int? ?? 3,
        mtimeToleranceSeconds: j['mtimeToleranceSeconds'] as int? ??
            SyncCompare.defaultToleranceSeconds,
      );
}

/// Per-file action the sync engine decided on.
enum SyncAction {
  upload,
  skipUpToDate,
  skipExcluded,
  skipNotExisting,

  /// A name this device cannot match unambiguously (a case-folded or
  /// Unicode-form collision on the server, or a remote name that differs from
  /// a local file only by case). Never uploaded over, never deleted.
  skipCaseCollision,

  /// A local symbolic link. Links are never followed (spec 3), so the link is
  /// neither uploaded nor allowed to mark its remote namesake "only on the
  /// server".
  skipLink,

  /// A local FILE whose remote namesake is a DIRECTORY (or vice versa). An
  /// upload would fail at the final rename and leave a `.zestpart` stub, so it
  /// is reported instead of attempted.
  skipTypeConflict,
  deleteRemote,
}

/// One entry in the sync plan. Previewable before running.
class SyncPlanItem {
  final String localPath;
  final String remotePath;
  final SyncAction action;
  final int size;
  final String reason;

  /// True when the destination did not exist (a genuinely new file), so the
  /// preview can separate "new" from "changed".
  final bool isNew;

  /// The local mtime (whole seconds) the plan compared. Recorded to the
  /// manifest only if the file still has it after its upload.
  final int? localMtimeS;

  /// The local SHA-256 computed when Verify-by-content decided this item, so
  /// the manifest can store it without hashing the file twice.
  final String? localHash;

  /// This skip came from the level-0 manifest hit (spec 4), so the run can
  /// refresh its manifest row rather than let it age out.
  final bool fromManifest;

  /// Verify-by-content was requested but a hash could not be obtained for one
  /// end, so this verdict fell back to the size+time heuristic.
  final bool hashUnavailable;

  const SyncPlanItem({
    required this.localPath,
    required this.remotePath,
    required this.action,
    required this.size,
    required this.reason,
    this.isNew = false,
    this.localMtimeS,
    this.localHash,
    this.fromManifest = false,
    this.hashUnavailable = false,
  });
}

/// Aggregated counters returned at the end of [SftpSyncService.runSync].
class SyncSummary {
  final int uploaded;
  final int skippedUpToDate;
  final int skippedExcluded;
  final int skippedNotExisting;
  final int deletedRemote;
  final int failed;
  final int totalBytes;
  final List<String> errors;

  /// Each failure: the file's path and what was thrown, for what is said
  /// about it and its report (3.0: [errors] is the raw text).
  final List<({String path, Object error})> failures;

  /// Remote-only deletions the user opted into that were NOT issued, because an
  /// upload failed or the run was cancelled. Deletes only ever run after every
  /// upload succeeded (spec 6), so the server is never left short a file.
  final int deletesSkipped;

  /// Files Verify-by-content could not actually verify (no hash tool on the
  /// server, or a read error), which were decided by the size+time heuristic
  /// instead. Zero unless verify mode was on.
  final int unverified;

  /// The run stopped early because the caller cancelled it.
  final bool cancelled;

  /// True when a post-upload read-back showed the server did NOT keep the mtime
  /// we set (chrooted / hardened servers reject SETSTAT). Comparison by
  /// timestamp is unreliable for this root; the engine has already switched
  /// the root to size-only comparison for future runs (spec 5c) and the UI
  /// should say so once. Never set on an inconclusive read-back.
  final bool mtimeNotPreserved;

  const SyncSummary({
    required this.uploaded,
    required this.skippedUpToDate,
    required this.skippedExcluded,
    required this.skippedNotExisting,
    required this.deletedRemote,
    required this.failed,
    required this.totalBytes,
    required this.errors,
    this.failures = const [],
    this.deletesSkipped = 0,
    this.unverified = 0,
    this.cancelled = false,
    this.mtimeNotPreserved = false,
  });
}

/// Result of [SftpSyncService.buildPlan]: the plan plus the warnings surfaced
/// during the scan.
class SyncPlan {
  final List<SyncPlanItem> items;

  /// "README.md / readme.md" pairs the remote holds in one directory that this
  /// device cannot tell apart (case-folded on a case-insensitive local volume,
  /// or two Unicode forms of one name); both members are left untouched.
  final List<String> caseCollisions;

  /// Local directories that could not be listed (permissions, a dead
  /// junction). They were skipped entirely: nothing under them is uploaded AND
  /// nothing under their remote counterpart is planned for deletion, because
  /// an unreadable folder must never be mistaken for an empty one.
  final List<String> unreadableDirs;

  /// The walk hit [SftpSyncService.maxEntries] and stopped early, so this plan
  /// is partial. The caller must refuse to run it (a partial plan would mistake
  /// un-walked files for "only on the server" and offer to delete them).
  final bool truncated;

  /// The caller cancelled the scan; the plan is partial and must not run.
  final bool cancelled;

  /// This (server, remote root) was proven on an earlier run to drop the mtime
  /// we set (a hardened or chrooted server that refuses SETSTAT), so comparison
  /// by timestamp is meaningless here and the engine is already comparing by
  /// size only. The preview says so, because a same-size content change can be
  /// missed unless Verify by content is on.
  final bool mtimeUnreliable;

  const SyncPlan({
    required this.items,
    required this.caseCollisions,
    this.unreadableDirs = const [],
    this.truncated = false,
    this.cancelled = false,
    this.mtimeUnreliable = false,
  });
}

/// One file's verdict from the comparison ladder.
class _Verdict {
  const _Verdict(this.action, this.reason,
      {this.hash, this.hashUnavailable = false});
  final SyncAction action;
  final String reason;
  final String? hash;
  final bool hashUnavailable;
}

/// Coordinates a one-way (local -> remote) sync between a local root and a
/// remote root using an existing [SftpService].
class SftpSyncService {
  final SftpService sftp;

  /// Optional device-local manifest for the level-0 fast skip (spec §4). When
  /// provided (with [hostId]), a file still matching its recorded size + mtime
  /// is skipped without any remote compare, and every successful upload is
  /// recorded. Null disables it, and the sync still works via the remote scan.
  final SftpSyncManifestDao? manifest;

  /// A key that is STABLE across sessions and UNIQUE per server, so two
  /// connections to different servers never share a manifest (a shared manifest
  /// would make the second server look "unchanged" and never receive the
  /// files). The caller derives it from the server identity, never from a
  /// display label.
  final String? hostId;

  SftpSyncService(this.sftp, {this.manifest, this.hostId});

  static const _sync = SyncCompare();

  // Set at [buildPlan] and reused by [runSync] on the same instance.
  String _localRoot = '';
  String _remoteRoot = '';
  Map<String, SftpSyncManifestRow> _manifestMap = const {};

  /// Spec 5c: this root's server refused to keep our SETSTAT mtime on an
  /// earlier run, so comparison by time is meaningless here. Loaded at
  /// [buildPlan]; [runSync] updates it from the read-back probe.
  bool _mtimeUnreliable = false;

  /// Hard cap on entries walked (files, directories AND remote-only entries),
  /// mirroring the pull-path bound, so a hostile or pathological tree on either
  /// side cannot exhaust memory.
  static const int _maxEntries = 100000;

  /// Public view of the entry cap so the UI can name it when a tree exceeds it.
  static const int maxEntries = _maxEntries;

  /// Directory nesting beyond which the walk stops (a real tree this deep is
  /// pathological; symlinks are not followed, so this is a plain safety net).
  static const int _maxDepth = 200;

  /// Build the plan without changing anything on the remote (directory
  /// listings only). Present it as a preview, then [runSync] to apply it.
  /// [shouldCancel] is polled once per directory; a cancelled scan returns a
  /// plan flagged [SyncPlan.cancelled] that must not run.
  Future<SyncPlan> buildPlan({
    required String localRoot,
    required String remoteRoot,
    required SftpSyncOptions options,
    bool Function()? shouldCancel,
    void Function(int dirsScanned)? onProgress,
  }) async {
    _localRoot = localRoot;
    _remoteRoot = _normalizeRoot(remoteRoot);
    _manifestMap = (manifest != null && hostId != null)
        ? await manifest!.forRoot(hostId!, _remoteRoot)
        : const {};
    _mtimeUnreliable = await _loadMtimeUnreliable();
    final plan = <SyncPlanItem>[];
    final collisions = <String>[];
    final unreadable = <String>[];
    final counter = _Counter();
    await _walkAndPlan(
      localDir: Directory(localRoot),
      remoteDir: remoteRoot,
      options: options,
      plan: plan,
      collisions: collisions,
      unreadable: unreadable,
      visitedRemote: <String>{},
      counter: counter,
      depth: 0,
      shouldCancel: shouldCancel,
      onProgress: onProgress,
    );
    return SyncPlan(
      items: plan,
      caseCollisions: collisions,
      unreadableDirs: unreadable,
      truncated: counter.truncated,
      cancelled: counter.cancelled,
      mtimeUnreliable: _mtimeUnreliable,
    );
  }

  /// Execute [plan]. Uploads run first; any [SyncAction.deleteRemote] items run
  /// LAST, only when [SftpSyncOptions.deleteRemoteOnly] is set AND every upload
  /// succeeded AND the run was not cancelled, so a failed upload never leaves
  /// the remote short a file it just deleted. Deletions that were opted into
  /// but not issued are reported in [SyncSummary.deletesSkipped].
  Future<SyncSummary> runSync({
    required List<SyncPlanItem> plan,
    required SftpSyncOptions options,
    bool Function()? shouldCancel,
    void Function(SyncPlanItem item, int index, int total)? onItem,
  }) async {
    int uploaded = 0;
    int skippedUp = 0;
    int skippedEx = 0;
    int skippedNe = 0;
    int deleted = 0;
    int failed = 0;
    int totalBytes = 0;
    int unverified = 0;
    final errors = <String>[];
    final failures = <({String path, Object error})>[];
    var cancelled = false;

    // Spec 5c probe state. Tri-state: null = no conclusive read-back yet.
    bool? mtimeVerdict;
    var probeAttempts = 0;

    // One cancel token for the whole run so a Cancel mid-file aborts the
    // stream instead of waiting for a multi-gigabyte upload to finish.
    final token = TransferCancelToken();
    bool cancelRequested() {
      if (cancelled) return true;
      if (shouldCancel?.call() == true) {
        cancelled = true;
        token.cancel();
      }
      return cancelled;
    }

    // Uploads first, deletes second (see runSync doc).
    final uploads = plan.where((i) => i.action == SyncAction.upload).toList();
    final deletes = options.deleteRemoteOnly
        ? plan.where((i) => i.action == SyncAction.deleteRemote).toList()
        : const <SyncPlanItem>[];
    final total = uploads.length + deletes.length;
    var idx = 0;
    // Directories already created/verified this run: createDirectoryRecursive
    // STATs every path component, so calling it per file would cost depth
    // round trips per upload (spec 3 forbids per-file stat in the plan; the
    // run should not throw that away).
    final ensured = <String>{};
    // Level-0 hits whose manifest rows are still current: refreshed in one
    // batch so a stable tree never ages out of the manifest.
    final stillCurrent = <String>[];

    for (final item in uploads) {
      if (cancelRequested()) break;
      try {
        await _ensureRemoteDir(_posixDirname(item.remotePath), ensured);
        // Stat immediately before AND after the upload: a file rewritten while
        // its bytes were streaming (a build tool, an editor autosave) must not
        // get a manifest row carrying the NEW size/mtime, or the next run would
        // skip it forever while the server holds old or torn content.
        final pre = await File(item.localPath).stat();
        await sftp.uploadFileFromPath(
          item.localPath,
          item.remotePath,
          cancelToken: token,
          useTransferChannel: true,
        );
        uploaded++;
        totalBytes += item.size;
        if (manifest != null && hostId != null) {
          try {
            final post = await File(item.localPath).stat();
            final preS = pre.modified.millisecondsSinceEpoch ~/ 1000;
            final postS = post.modified.millisecondsSinceEpoch ~/ 1000;
            if (pre.size == post.size && preS == postS) {
              // Record ONLY after the upload fully succeeded (spec §4): the
              // service returns only after the staged write, size check,
              // SETSTAT and rename. The cache is best-effort: never fail a
              // sync because a manifest write failed.
              await manifest!.record(
                hostId: hostId!,
                remoteRoot: _remoteRoot,
                relPath: _rel(item.localPath),
                size: pre.size,
                mtimeSeconds: preS,
                contentHash: item.localHash,
              );
            }
          } catch (_) {/* cache only */}
        }
        // Spec 5c: confirm that the server kept the mtime we set. Read back
        // until we get a CONCLUSIVE answer (a failed stat proves nothing and
        // must not become a false "this server rejects timestamps" warning).
        if (mtimeVerdict == null && probeAttempts < 3) {
          probeAttempts++;
          mtimeVerdict = await _mtimeStuck(
              item.localPath, item.remotePath, options.mtimeToleranceSeconds);
        }
      } on TransferCancelledException {
        cancelled = true;
        break;
      } catch (e) {
        if (cancelRequested()) break;
        failed++;
        errors.add('${item.localPath}: $e');
        failures.add((path: item.localPath, error: e));
        AppLogger.warning('SftpSyncService: upload failed ${item.localPath}: $e');
      }
      onItem?.call(item, idx++, total);
    }

    // Deletes run ONLY when every upload landed and nothing was cancelled. A
    // renamed file is "upload new name + delete old name": if the upload failed
    // and the delete still ran, the server would have neither.
    var deletesSkipped = 0;
    if (deletes.isNotEmpty) {
      if (failed > 0 || cancelRequested()) {
        deletesSkipped = deletes.length;
      } else {
        for (final item in deletes) {
          if (cancelRequested()) {
            deletesSkipped++;
            continue;
          }
          try {
            await sftp.deleteFile(item.remotePath);
            deleted++;
          } catch (e) {
            failed++;
            errors.add('${item.remotePath}: $e');
            failures.add((path: item.remotePath, error: e));
            AppLogger.warning(
                'SftpSyncService: delete failed ${item.remotePath}: $e');
          }
          onItem?.call(item, idx++, total);
        }
      }
    }

    // Plan-time skip tallies (not re-walked here; counted from the plan).
    for (final i in plan) {
      switch (i.action) {
        case SyncAction.skipUpToDate:
          skippedUp++;
          if (i.fromManifest) stillCurrent.add(_rel(i.localPath));
          if (i.hashUnavailable) unverified++;
          break;
        case SyncAction.skipExcluded:
        case SyncAction.skipCaseCollision:
        case SyncAction.skipLink:
        case SyncAction.skipTypeConflict:
          skippedEx++;
          break;
        case SyncAction.skipNotExisting:
          skippedNe++;
          break;
        case SyncAction.upload:
          if (i.hashUnavailable) unverified++;
          break;
        case SyncAction.deleteRemote:
          break;
      }
    }

    if (manifest != null && hostId != null) {
      try {
        await manifest!.touch(
            hostId: hostId!, remoteRoot: _remoteRoot, relPaths: stillCurrent);
        await manifest!.prune();
      } catch (_) {/* best effort */}
    }

    // Spec 5c: a CONFIRMED refusal degrades this root to size-only comparison
    // for future runs (and a confirmed success clears an old degrade, so a
    // server that starts honouring SETSTAT recovers).
    if (mtimeVerdict != null && mtimeVerdict != !_mtimeUnreliable) {
      _mtimeUnreliable = !mtimeVerdict;
      await _saveMtimeUnreliable(_mtimeUnreliable);
    }

    return SyncSummary(
      uploaded: uploaded,
      skippedUpToDate: skippedUp,
      skippedExcluded: skippedEx,
      skippedNotExisting: skippedNe,
      deletedRemote: deleted,
      failed: failed,
      totalBytes: totalBytes,
      errors: errors,
      failures: failures,
      deletesSkipped: deletesSkipped,
      unverified: unverified,
      cancelled: cancelled,
      mtimeNotPreserved: mtimeVerdict == false,
    );
  }

  // ── Internals ──────────────────────────────────────────────────

  Future<void> _walkAndPlan({
    required Directory localDir,
    required String remoteDir,
    required SftpSyncOptions options,
    required List<SyncPlanItem> plan,
    required List<String> collisions,
    required List<String> unreadable,
    required Set<String> visitedRemote,
    required _Counter counter,
    required int depth,
    bool Function()? shouldCancel,
    void Function(int dirsScanned)? onProgress,
  }) async {
    if (shouldCancel?.call() == true) {
      counter.cancelled = true;
      return;
    }
    if (!await localDir.exists()) return;
    if (!visitedRemote.add(remoteDir)) return; // loop guard
    if (counter.n >= _maxEntries || depth > _maxDepth) {
      counter.truncated = true;
      return;
    }
    counter.dirs++;
    onProgress?.call(counter.dirs);

    // One READDIR per directory (spec 3): size + mtime for every entry in a
    // single response, keyed by NFC-normalised name so a decomposed (macOS)
    // name matches its composed (Linux) form.
    final remoteByName = <String, SftpEntry>{};
    // Case-fold groups on a case-insensitive local volume (spec 5d).
    final collidedFolds = <String>{};
    // Two remote names that normalise to the SAME key (both Unicode forms of
    // one name, e.g. an NFD upload beside an NFC original): neither can be
    // matched unambiguously, so both are left alone and the pair is warned.
    final dupKeys = <String>{};
    try {
      final remoteEntries = await sftp.listDirectory(remoteDir);
      final seenFold = <String, String>{};
      for (final e in remoteEntries) {
        final key = unorm.nfc(e.name);
        final prior = remoteByName[key];
        if (prior != null) {
          dupKeys.add(key);
          collisions.add('${prior.name} / ${e.name}');
        }
        remoteByName[key] = e;
        if (_localCaseInsensitive) {
          final fold = key.toLowerCase();
          final priorKey = seenFold[fold];
          if (priorKey != null && priorKey != key) {
            collidedFolds.add(fold);
            collisions.add('$priorKey / ${e.name}');
          }
          seenFold[fold] = key;
        }
      }
    } catch (_) {
      // Unreadable / not there yet: treated as empty. That direction is safe:
      // an empty listing can only make files look NEW (over-upload), it can
      // never produce a "remote-only" item, so nothing is deleted on a hiccup.
    }

    final includeRe = _compileGlobs(options.include);
    final excludeRe = _compileGlobs(options.exclude);
    final matched = <String>{};
    // Case-folds of every matched local name, so a remote name that differs
    // from a local file ONLY by case is never treated as "only on the server".
    final matchedFolds = <String>{};
    void mark(String key) {
      matched.add(key);
      if (_localCaseInsensitive) matchedFolds.add(key.toLowerCase());
    }

    // Symlinks are NOT followed (spec 3): a link is reported as such, never
    // walked, so a link to `..` or `/` cannot drag the whole disk into the
    // plan and a link loop cannot recurse. An unreadable directory is skipped
    // WHOLE and reported: treating it as empty would plan every remote file
    // under it for deletion.
    final List<FileSystemEntity> localItems;
    try {
      localItems = await localDir.list(followLinks: false).toList();
    } catch (_) {
      unreadable.add(localDir.path);
      return;
    }

    for (final item in localItems) {
      if (shouldCancel?.call() == true) {
        counter.cancelled = true;
        return;
      }
      if (counter.n >= _maxEntries) {
        counter.truncated = true;
        return;
      }
      final name = p.basename(item.path);
      final key = unorm.nfc(name);
      final remotePath =
          remoteDir.endsWith('/') ? '$remoteDir$name' : '$remoteDir/$name';

      if (item is Link) {
        counter.n++;
        mark(key);
        plan.add(_item(item.path, remotePath, SyncAction.skipLink, 0,
            'Symbolic link (not followed)'));
        continue;
      }
      if (item is Directory) {
        if (!options.recursive) continue;
        counter.n++;
        mark(key);
        // The exclude list applies to directories too, so `node_modules` or
        // `.git` in it is neither walked nor counted against the cap.
        if (excludeRe != null && excludeRe.hasMatch(name)) continue;
        await _walkAndPlan(
          localDir: item,
          remoteDir: remotePath,
          options: options,
          plan: plan,
          collisions: collisions,
          unreadable: unreadable,
          visitedRemote: visitedRemote,
          counter: counter,
          depth: depth + 1,
          shouldCancel: shouldCancel,
          onProgress: onProgress,
        );
        if (counter.cancelled || counter.truncated) return;
        continue;
      }
      if (item is! File) continue;
      counter.n++;
      mark(key);

      if (excludeRe != null && excludeRe.hasMatch(name)) {
        plan.add(_item(item.path, remotePath, SyncAction.skipExcluded, 0,
            'Matches exclude pattern'));
        continue;
      }
      if (includeRe != null && !includeRe.hasMatch(name)) {
        plan.add(_item(item.path, remotePath, SyncAction.skipExcluded, 0,
            'Not in include list'));
        continue;
      }

      // A name this device cannot match unambiguously on the server: skip
      // rather than guess (spec 5d), whichever way the ambiguity arose.
      if (dupKeys.contains(key)) {
        plan.add(_item(item.path, remotePath, SyncAction.skipCaseCollision, 0,
            'Remote has two Unicode forms of this name'));
        continue;
      }
      if (_localCaseInsensitive && collidedFolds.contains(key.toLowerCase())) {
        plan.add(_item(item.path, remotePath, SyncAction.skipCaseCollision, 0,
            'Remote has a case-colliding name'));
        continue;
      }

      final remote = remoteByName[key];
      if (options.existingOnly && remote == null) {
        plan.add(_item(item.path, remotePath, SyncAction.skipNotExisting, 0,
            'Existing-only mode, remote missing'));
        continue;
      }

      final stat = await item.stat();
      final mtimeS = stat.modified.millisecondsSinceEpoch ~/ 1000;
      // Level 0 (spec §4): a file still matching its recorded size + mtime was
      // uploaded unchanged before, so skip it without a content compare. The
      // manifest is a cache, never the truth: the READDIR already in hand is
      // consulted, so a file deleted or replaced on the server out of band is
      // still re-sent. Verify-by-content and Force deliberately bypass it.
      if (manifest != null &&
          !options.verifyContent &&
          !options.forceReupload &&
          remote != null &&
          !remote.isDirectory) {
        final rec = _manifestMap[_rel(item.path)];
        if (rec != null &&
            rec.localSize == stat.size &&
            remote.size == stat.size &&
            rec.localMtimeS == mtimeS) {
          plan.add(SyncPlanItem(
            localPath: item.path,
            remotePath: remotePath,
            action: SyncAction.skipUpToDate,
            size: stat.size,
            reason: 'Unchanged since last sync',
            localMtimeS: mtimeS,
            fromManifest: true,
          ));
          continue;
        }
      }
      final v = await _decide(item, stat, remote, remotePath, options);
      plan.add(SyncPlanItem(
        localPath: item.path,
        remotePath: remotePath,
        action: v.action,
        size: stat.size,
        reason: v.reason,
        isNew: remote == null,
        localMtimeS: mtimeS,
        localHash: v.hash,
        hashUnavailable: v.hashUnavailable,
      ));
    }

    // Files present only on the server (spec 6): planned as deleteRemote so the
    // preview can list them; runSync only executes them if deleteRemoteOnly.
    // Anything this device could not match unambiguously is NEVER a deletion
    // candidate (spec 5d "never guess"): both members of a collided pair, both
    // Unicode forms of one name, and a remote name that differs from a local
    // file only by case (a case-only rename; on a case-insensitive server the
    // just-uploaded file and the "old" name are the same inode).
    for (final entry in remoteByName.entries) {
      if (entry.value.isDirectory) continue; // never auto-delete remote dirs
      if (matched.contains(entry.key)) continue;
      if (dupKeys.contains(entry.key)) continue;
      if (counter.n >= _maxEntries) {
        counter.truncated = true;
        return;
      }
      counter.n++;
      final rp = remoteDir.endsWith('/')
          ? '$remoteDir${entry.value.name}'
          : '$remoteDir/${entry.value.name}';
      final localPath = p.join(localDir.path, entry.value.name);
      if (_localCaseInsensitive) {
        final fold = entry.key.toLowerCase();
        if (collidedFolds.contains(fold)) continue; // pair already warned
        if (matchedFolds.contains(fold)) {
          plan.add(_item(localPath, rp, SyncAction.skipCaseCollision,
              entry.value.size,
              'Differs only by case from a local file; left on the server'));
          continue;
        }
      }
      plan.add(_item(localPath, rp, SyncAction.deleteRemote,
          entry.value.size, 'Only on the server'));
    }
  }

  /// Decide upload-vs-skip for one file whose local [stat] is known and whose
  /// [remote] entry (if any) came from the directory listing. This is the
  /// comparison ladder: force > new > (content hash | size+mtime).
  Future<_Verdict> _decide(
    File item,
    FileStat stat,
    SftpEntry? remote,
    String remotePath,
    SftpSyncOptions options,
  ) async {
    if (remote != null && remote.isDirectory) {
      // Uploading a file over a directory fails at the final rename and leaves
      // a .zestpart stub; report it instead (a forced run included).
      return const _Verdict(SyncAction.skipTypeConflict,
          'A folder with this name exists on the server');
    }
    if (options.forceReupload) {
      return const _Verdict(SyncAction.upload, 'Forced re-upload');
    }
    if (remote == null) {
      return const _Verdict(SyncAction.upload, 'New file');
    }

    if (options.verifyContent) {
      // Timestamp plays no part here. Different size is definitely changed;
      // same size is decided by a content hash of both ends.
      if (remote.size != stat.size) {
        return const _Verdict(SyncAction.upload, 'Changed (size differs)');
      }
      final localHash = await _sha256OfFile(item);
      final remoteHash = await sftp.sha256Remote(remotePath);
      if (localHash == null || remoteHash == null) {
        // Cannot hash one end (no tool / read error / timeout): fall back to
        // the size+time heuristic rather than a false verdict, say why in the
        // reason, and count it so the summary can report "N not verified".
        final same = _sameByHeuristic(stat, remote, options);
        return same
            ? _Verdict(SyncAction.skipUpToDate,
                'Same size and time (hash unavailable)',
                hash: localHash, hashUnavailable: true)
            : _Verdict(SyncAction.upload, 'Changed (hash unavailable)',
                hash: localHash, hashUnavailable: true);
      }
      return localHash == remoteHash
          ? _Verdict(SyncAction.skipUpToDate, 'Identical (content verified)',
              hash: localHash)
          : _Verdict(SyncAction.upload, 'Changed (content differs)',
              hash: localHash);
    }

    if (_mtimeUnreliable) {
      // Spec 5c degrade: this server does not keep our timestamps, so time
      // says nothing. Size is the only free signal left; Verify by content is
      // the honest option and the UI recommends it.
      return remote.size == stat.size
          ? const _Verdict(SyncAction.skipUpToDate,
              'Same size (timestamps unreliable on this server)')
          : const _Verdict(SyncAction.upload, 'Changed (size differs)');
    }

    // Default: same size AND mtime within tolerance means unchanged. Uploads
    // preserve mtime, so an unchanged file matches after a prior sync.
    return _sameByHeuristic(stat, remote, options)
        ? const _Verdict(SyncAction.skipUpToDate, 'Remote already up to date')
        : const _Verdict(SyncAction.upload, 'Changed');
  }

  /// The single size+mtime predicate ([SyncCompare]); a missing remote mtime
  /// never counts as identical (the safe direction is to upload).
  bool _sameByHeuristic(
          FileStat stat, SftpEntry remote, SftpSyncOptions options) =>
      remote.modifiedAt != null &&
      _sync.withTolerance(options.mtimeToleranceSeconds).isIdentical(
            localSize: stat.size,
            localMtime: stat.modified,
            remoteSize: remote.size,
            remoteMtime: remote.modifiedAt!,
          );

  /// Stream a SHA-256 of a local file without buffering it whole (safe for any
  /// size). Lowercase hex, or null on a read error.
  Future<String?> _sha256OfFile(File f) async {
    try {
      Digest? out;
      final sink = ChunkedConversionSink<Digest>.withCallback(
          (digests) => out = digests.single);
      final input = sha256.startChunkedConversion(sink);
      await for (final chunk in f.openRead()) {
        input.add(chunk);
      }
      input.close();
      return out?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Read the remote mtime back after an upload and compare it with the local
  /// one through [SyncCompare]. True: the server honoured our SETSTAT. False:
  /// it did not (comparison by time is unreliable for this root). Null: the
  /// read-back itself failed, which proves nothing either way.
  Future<bool?> _mtimeStuck(
      String localPath, String remotePath, int tolerance) async {
    try {
      final local = await File(localPath).stat();
      final remote = await sftp.stat(remotePath);
      final rt = remote.modifyTime;
      if (rt == null) return null;
      return _sync.withTolerance(tolerance).isIdentical(
            localSize: local.size,
            localMtime: local.modified,
            remoteSize: local.size,
            remoteMtime: DateTime.fromMillisecondsSinceEpoch(rt * 1000),
          );
    } catch (_) {
      return null;
    }
  }

  SyncPlanItem _item(String localPath, String remotePath, SyncAction action,
          int size, String reason) =>
      SyncPlanItem(
        localPath: localPath,
        remotePath: remotePath,
        action: action,
        size: size,
        reason: reason,
      );

  Future<void> _ensureRemoteDir(String path, Set<String> ensured) async {
    if (path.isEmpty || path == '/') return;
    if (!ensured.add(path)) return;
    try {
      await sftp.createDirectoryRecursive(path);
    } catch (_) {
      // Best-effort; the upload fails loudly if the parent truly cannot exist.
      ensured.remove(path);
    }
  }

  String _posixDirname(String path) {
    final i = path.lastIndexOf('/');
    if (i <= 0) return '/';
    return path.substring(0, i);
  }

  /// A local path as a manifest-stable relative key: relative to the sync root,
  /// forward slashes on every OS, NFC-normalised (spec 5b).
  String _rel(String localPath) =>
      unorm.nfc(p.relative(localPath, from: _localRoot).replaceAll(r'\', '/'));

  /// Remote root without a trailing slash, matching the manifest's stored form.
  String _normalizeRoot(String r) =>
      (r.length > 1 && r.endsWith('/')) ? r.substring(0, r.length - 1) : r;

  /// The local volume is case-insensitive on Windows and macOS; case-sensitive
  /// on Linux. Drives the case-collision guard (spec 5d).
  bool get _localCaseInsensitive => Platform.isWindows || Platform.isMacOS;

  // Spec 5c persistence: one flag per (server, remote root), device-local.
  String? get _unreliableKey => hostId == null
      ? null
      : 'sftp_sync_mtime_unreliable:$hostId:$_remoteRoot';

  Future<bool> _loadMtimeUnreliable() async {
    final k = _unreliableKey;
    if (k == null) return false;
    try {
      return (await appPreferences()).getBool(k) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveMtimeUnreliable(bool v) async {
    final k = _unreliableKey;
    if (k == null) return;
    try {
      final prefs = await appPreferences();
      if (v) {
        await prefs.setBool(k, true);
      } else {
        await prefs.remove(k);
      }
    } catch (_) {/* best effort */}
  }

  // Per-(server, local root, remote root) memory of the Verify-by-content
  // choice, device-local. New folder pairs default to size+mtime (false); a
  // pair last synced with Verify on comes back on, so a rebuild-heavy deploy
  // folder does not need the toggle re-ticked each time. Keyed on the local
  // root too, so two different local sources to one remote root keep
  // independent choices. Local paths in the key are never parsed back, only
  // matched, so a Windows drive colon is harmless.
  String? _verifyKeyFor(String localRoot, String remoteRoot) => hostId == null
      ? null
      : 'sftp_sync_verify_content:$hostId:$localRoot:${_normalizeRoot(remoteRoot)}';

  Future<bool> loadRememberedVerify(String localRoot, String remoteRoot) async {
    final k = _verifyKeyFor(localRoot, remoteRoot);
    if (k == null) return false;
    try {
      return (await appPreferences()).getBool(k) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveRememberedVerify(
      String localRoot, String remoteRoot, bool value) async {
    final k = _verifyKeyFor(localRoot, remoteRoot);
    if (k == null) return;
    try {
      final prefs = await appPreferences();
      if (value) {
        await prefs.setBool(k, true);
      } else {
        await prefs.remove(k);
      }
    } catch (_) {/* best effort */}
  }

  RegExp? _compileGlobs(List<String> globs) {
    final patterns = globs.where((g) => g.trim().isNotEmpty).toList();
    if (patterns.isEmpty) return null;
    final escaped = patterns.map((g) {
      final buf = StringBuffer();
      for (final ch in g.split('')) {
        if (ch == '*') {
          buf.write('.*');
        } else if (ch == '?') {
          buf.write('.');
        } else if ('.+^\$()[]{}|\\'.contains(ch)) {
          buf.write('\\$ch');
        } else {
          buf.write(ch);
        }
      }
      return '^${buf.toString()}\$';
    }).join('|');
    return RegExp(escaped, caseSensitive: false);
  }
}

/// Mutable walk counter (bounds the scan without threading an int return).
class _Counter {
  int n = 0;
  int dirs = 0;
  bool truncated = false;
  bool cancelled = false;
}

/// Persists [SftpSyncOptions] per connection id (SharedPreferences, not the
/// Drift schema, since it is UI state). Device-local, never synced.
class SftpSyncSettingsStore {
  static String _key(String connectionId) => 'sftp_sync_$connectionId';

  static Future<SftpSyncOptions?> load(String connectionId) async {
    try {
      final prefs = await appPreferences();
      final raw = prefs.getString(_key(connectionId));
      if (raw == null) return null;
      return SftpSyncOptions.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
      String connectionId, SftpSyncOptions options) async {
    final prefs = await appPreferences();
    await prefs.setString(_key(connectionId), jsonEncode(options.toJson()));
  }

  static Future<void> clear(String connectionId) async {
    final prefs = await appPreferences();
    await prefs.remove(_key(connectionId));
  }
}
