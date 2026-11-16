// The file browser on an FTPS host (3.4): a [PaneFileSource] over an [FtpsClient], beside the
// local and the SFTP ones, so the browser, its queue and its editor work on FTPS as they do on
// SFTP where FTP can do the same.
//
// What FTP cannot do is left as a source without it does: no free space, no trash, no links made.
// A transfer runs on a connection of its own (FTP moves one file at a time on a connection), so
// browsing goes on beside it; it goes through a `.zestpart` file and is put in place only when
// whole, as SFTP's are, and a download that broke off resumes from what came; an upload that broke
// off with the connection resumes from what the server has, after a restart of the app too
// ([FtpsUploadResume]).
import 'dart:convert' show utf8;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:zest_native/ftps.dart';
import 'package:zestssh/services/ftps/ftps_upload_resume.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/utils/logger.dart';

class FtpsPaneFileSource extends PaneFileSource {
  FtpsPaneFileSource({
    required FtpsClient client,
    required this.sourceId,
    FtpsUploadResume? uploads,
    Future<FtpsClient> Function()? reconnect,
  })  : _client = client,
        _reconnect = reconnect,
        _uploads = uploads ?? FtpsUploadResume();

  /// The browsing connection; another takes its place where it dropped ([_browse]).
  FtpsClient _client;

  /// Connects the session again (FtpsShellService.reconnect), for a connection that dropped:
  /// once, on the next action, as an SFTP pane opens its channel again.
  final Future<FtpsClient> Function()? _reconnect;

  @override
  final String sourceId;

  /// The connection transfers run on, opened at the first one (with the browsing connection's
  /// certificate and no other) and kept while the source is.
  FtpsClient? _transfers;
  Future<FtpsClient>? _opening;

  /// Uploads that broke off with the connection, by where their bytes went on the server: from
  /// which file of this device, at which size and time, so the same upload again goes on from
  /// what the server has, in this run of the app or a later one.
  final FtpsUploadResume _uploads;

  String _uploadKey(String staged) => FtpsUploadResume.keyOf(
      host: _client.options.host, port: _client.options.port, user: _client.options.username, stagedPath: staged);

  /// The browsing connection (for a test, or for whoever holds the session).
  FtpsClient get client => _client;

  /// Whether [e] says the connection itself is gone (not a refusal, not a slow data port).
  static bool _dropped(FtpsException e) => e.kind == FtpsErrorKind.connection || e.kind == FtpsErrorKind.closed;

  /// [op] on the browsing connection; where the connection dropped, the session connects
  /// again once (no question for a certificate already trusted) and [op] runs once more on the
  /// new one. The transfer connection goes with the old one: the next transfer opens its own.
  Future<T> _browse<T>(Future<T> Function(FtpsClient c) op) async {
    final before = _client;
    try {
      return await op(before);
    } on FtpsException catch (e) {
      final again = _reconnect;
      if (again == null || !_dropped(e)) rethrow;
      final FtpsClient fresh;
      try {
        // Another action may have connected again already.
        fresh = identical(_client, before) ? await again() : _client;
      } catch (_) {
        throw e;
      }
      _client = fresh;
      final t = _transfers;
      _transfers = null;
      _opening = null;
      unawaited(t?.close());
      AppLogger.info('FTPS: connected again after a dropped connection (${e.kind.name})');
      return op(fresh);
    }
  }

  @override
  bool get isPosix => true;

  @override
  Future<String> homeDirectory() async => _client.home;

  Future<FtpsClient> _transferClient() async {
    final t = _transfers;
    if (t != null && !t.isClosed) return t;
    // (Its own connection, made from the browsing one's certificate: it does not need the
    // browsing connection to be alive.)
    return _opening ??= _client.another().then((c) {
      _transfers = c;
      _opening = null;
      return c;
    }, onError: (Object e) {
      _opening = null;
      throw e;
    });
  }

  /// Ends the transfer connection (the browsing one is the session's).
  Future<void> close() async {
    final t = _transfers;
    _transfers = null;
    await t?.close();
  }

  PaneFileEntry _entry(String dir, FtpsEntry e) {
    final mode = e.mode;
    return PaneFileEntry(
      name: e.name,
      path: join(dir, e.name),
      isDirectory: e.isDirectory,
      size: e.size,
      modifiedAt: e.modified?.toLocal(),
      permissions: mode == null ? null : _perms(mode, dir: e.isDirectory, link: e.isSymlink),
      isSymlink: e.isSymlink,
      modeBits: mode,
      linkTarget: e.linkTarget,
      isHidden: e.name.startsWith('.'),
      isSystemHidden: isWindowsSystemFile(e.name),
    );
  }

  static String _perms(int mode, {required bool dir, required bool link}) {
    String t(int b) => '${b & 4 != 0 ? 'r' : '-'}${b & 2 != 0 ? 'w' : '-'}${b & 1 != 0 ? 'x' : '-'}';
    return '${link ? 'l' : dir ? 'd' : '-'}${t((mode >> 6) & 7)}${t((mode >> 3) & 7)}${t(mode & 7)}';
  }

  @override
  Future<List<PaneFileEntry>> list(String path, {bool includeHidden = true}) async {
    final entries = [for (final e in await _browse((c) => c.list(path))) _entry(path, e)];
    if (includeHidden) return entries;
    return entries.where((e) => !e.isHidden && !e.isSystemHidden).toList();
  }

  @override
  Future<PaneFileEntry?> stat(String path) async {
    try {
      final e = await _browse((c) => c.stat(path));
      return e == null ? null : _entry(parentOf(path), e);
    } on FtpsException catch (e) {
      if (e.notThere) return null;
      rethrow;
    }
  }

  @override
  Future<bool> exists(String path) async => (await stat(path)) != null;

  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {
    if (!recursive) return _browse((c) => c.mkdir(path));
    // Each folder on the way that is not there yet.
    final parts = p.posix.split(p.posix.normalize(path));
    var at = parts.first == '/' ? '/' : '';
    for (final part in parts) {
      if (part == '/') continue;
      at = at.isEmpty ? part : join(at, part);
      final there = await stat(at);
      if (there == null) {
        final dir = at;
        await _browse((c) => c.mkdir(dir));
      } else if (!there.isDirectory) {
        throw FtpsException(FtpsErrorKind.reply, '$at is not a folder', code: 550);
      }
    }
  }

  @override
  Future<void> rename(String oldPath, String newPath) => _browse((c) => c.rename(oldPath, newPath));

  @override
  Future<void> deleteFile(String path) => _browse((c) => c.delete(path));

  /// Everything under [path], deepest first; a link is removed as itself and never followed
  /// (the SFTP rule: following one could delete outside the tree that was chosen).
  @override
  Future<void> deleteDirectoryRecursive(
    String path, {
    void Function(String deletedPath)? onDeleted,
    bool Function()? isCancelled,
  }) async {
    for (final e in await _browse((c) => c.list(path))) {
      if (isCancelled?.call() ?? false) return;
      final child = join(path, e.name);
      if (e.isDirectory && !e.isSymlink) {
        await deleteDirectoryRecursive(child, onDeleted: onDeleted, isCancelled: isCancelled);
        if (isCancelled?.call() ?? false) return;
      } else {
        await _browse((c) => c.delete(child));
        onDeleted?.call(child);
      }
    }
    if (isCancelled?.call() ?? false) return;
    await _browse((c) => c.rmdir(path));
    onDeleted?.call(path);
  }

  @override
  Future<int> countEntriesRecursive(String path) async {
    var n = 1;
    for (final e in await _browse((c) => c.list(path))) {
      n += e.isDirectory && !e.isSymlink ? await countEntriesRecursive(join(path, e.name)) : 1;
    }
    return n;
  }

  @override
  Future<void> chmod(String path, int mode) => _browse((c) => c.chmod(path, mode & 0x0fff));

  @override
  Future<void> chmodRecursive(
    String path,
    int mode, {
    void Function(String path)? onDone,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) return;
    await chmod(path, mode);
    onDone?.call(path);
    final here = await stat(path);
    if (here == null || !here.isDirectory || here.isSymlink) return;
    for (final e in await _browse((c) => c.list(path))) {
      if (isCancelled?.call() ?? false) return;
      if (e.isSymlink) continue;
      final child = join(path, e.name);
      if (e.isDirectory) {
        await chmodRecursive(child, mode, onDone: onDone, isCancelled: isCancelled);
      } else {
        await chmod(child, mode);
        onDone?.call(child);
      }
    }
  }

  /// Into memory only, never through a file of this device (as SFTP's).
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) => _browse((c) => c.read(path, maxBytes: maxBytes));

  /// Beside the file, then into its place ([_putInPlace]).
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    final staged = '$path.zestpart';
    await _browse((c) => c.write(staged, bytes));
    await _putInPlace(_client, staged, path, expected: bytes.length);
  }

  /// [staged] (the whole new file) in the place of [dest]: the server's size of it is held
  /// against what was sent first, so a short file never takes the place of one. Where the server
  /// does not rename over a file (IIS), the old one goes first.
  Future<void> _putInPlace(FtpsClient c, String staged, String dest, {required int expected}) async {
    final has = await c.size(staged);
    verifyTransferSize(path: dest, expected: expected, actual: has);
    try {
      await c.rename(staged, dest);
    } on FtpsException catch (e) {
      // Only where the refusal is the file already there: otherwise the old file stays, and the
      // new one beside it.
      if (e.kind != FtpsErrorKind.reply || await c.stat(dest) == null) rethrow;
      await c.delete(dest);
      await c.rename(staged, dest);
    }
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    int? maxBytes,
    bool bulk = false,
  }) async {
    if (localPath.split(RegExp(r'[/\\]')).contains('..')) {
      throw ArgumentError('Path traversal detected in local path: $localPath');
    }
    final there = await stat(remotePath);
    if (there == null) throw FtpsException(FtpsErrorKind.reply, 'not found: $remotePath', code: 550);
    if (there.isDirectory) throw FtpsException(FtpsErrorKind.reply, 'a folder, not a file: $remotePath', code: 550);
    final total = there.size;
    if (maxBytes != null && total > maxBytes) {
      throw FtpsException(FtpsErrorKind.tooLarge, '$remotePath is $total bytes');
    }
    final target = p.normalize(localPath);
    final part = File('$target.zestpart');
    final metaFile = File('$target.zestpart.meta');
    final mtime = there.modifiedAt == null ? null : there.modifiedAt!.millisecondsSinceEpoch ~/ 1000;
    final partExists = await part.exists();
    // Which server this is: its address, port and the user signed in as.
    final at = _client.options;
    final source = transferSource('ftps', utf8.encode('${at.host.toLowerCase()} ${at.port} ${at.username}'));
    SftpPartialMeta? meta;
    if (partExists) {
      try {
        meta = SftpPartialMeta.decode(await metaFile.readAsString());
      } catch (_) {}
    }
    final resume = decideResume(
      allowResume: true,
      partialExists: partExists,
      partialLength: partExists ? await part.length() : 0,
      meta: meta,
      remotePath: remotePath,
      remoteSize: total,
      remoteMtime: mtime,
      source: source,
    );
    if (resume.discardPartial && partExists) await part.delete();
    try {
      await metaFile.writeAsString(
          SftpPartialMeta(remotePath: remotePath, remoteSize: total, remoteMtime: mtime, source: source).encode());
    } catch (_) {}
    if (resume.isResume) AppLogger.info('FTPS download ${resume.reason} of $total bytes');
    final c = bulk ? await _transferClient() : _client;
    try {
      if (!(resume.isResume && resume.startOffset == total)) {
        await c.download(
          remotePath,
          part.path,
          offset: resume.startOffset,
          maxBytes: maxBytes,
          onProgress: onProgress == null ? null : (done) => onProgress(done, total),
          whenCancelled: cancelToken?.whenCancelled,
        );
      }
    } on FtpsException catch (e) {
      _forgetIfDropped(c, e);
      if (e.kind == FtpsErrorKind.cancelled) {
        // Cancelled: nothing of it is kept. Broken off: kept, to go on from next time.
        await _deleteQuietly(part);
        await _deleteQuietly(metaFile);
        throw const TransferCancelledException();
      }
      if (e.kind == FtpsErrorKind.tooLarge) {
        await _deleteQuietly(part);
        await _deleteQuietly(metaFile);
      }
      rethrow;
    }
    verifyTransferSize(path: remotePath, expected: total, actual: await part.length());
    // In one step, as an SFTP download is ([publishDownload]): what was
    // there goes only as the complete new file takes its name.
    final dest = File(target);
    await publishDownload(part, dest);
    await _deleteQuietly(metaFile);
    final when = there.modifiedAt;
    if (when != null) {
      try {
        await File(target).setLastModified(when);
      } catch (_) {}
    }
  }

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    bool bulk = false,
  }) async {
    final local = File(localPath);
    final stat = await local.stat();
    final total = stat.size;
    final staged = '$remotePath.zestpart';
    final c = bulk ? await _transferClient() : _client;
    // Goes on from what the server has where the same file of this device, unchanged, broke off
    // there (in this run or before a restart): the server's size of the .zestpart first, and only
    // from a size the file has.
    var offset = 0;
    final key = _uploadKey(staged);
    final broken = await _uploads.take(key);
    if (broken != null && broken.isOf(localPath, total, stat.modified)) {
      try {
        final has = await c.size(staged);
        if (has > 0 && has <= total) offset = has;
      } on FtpsException catch (_) {}
    }
    if (offset > 0) AppLogger.info('FTPS upload resumed at $offset of $total bytes');
    Future<void> send(int from) => c.upload(
          localPath,
          staged,
          offset: from,
          onProgress: onProgress == null ? null : (done) => onProgress(done, total),
          whenCancelled: cancelToken?.whenCancelled,
        );
    try {
      try {
        await send(offset);
      } on FtpsException catch (e) {
        // A server that takes neither REST before STOR nor APPE: the whole file again (STOR
        // replaces what the .zestpart held).
        if (offset == 0 || e.kind != FtpsErrorKind.reply) rethrow;
        AppLogger.info('FTPS upload: the server would not resume (${e.code}); sent from the start');
        offset = 0;
        await send(0);
      }
    } on FtpsException catch (e) {
      if (e.kind == FtpsErrorKind.cancelled) {
        try {
          await c.delete(staged);
        } catch (_) {}
        throw const TransferCancelledException();
      }
      _forgetIfDropped(c, e);
      // The connection broke: what came stays beside the file, to go on from.
      if (e.kind == FtpsErrorKind.connection || e.kind == FtpsErrorKind.timeout || e.kind == FtpsErrorKind.closed) {
        try {
          await _uploads.remember(key, localPath: localPath, size: total, modified: stat.modified);
        } catch (_) {}
      } else {
        try {
          await c.delete(staged);
        } catch (_) {}
      }
      rethrow;
    }
    await _putInPlace(c, staged, remotePath, expected: total);
  }

  /// A transfer connection that dropped is let go, so the next transfer (Retry in the queue)
  /// opens a new one rather than failing on it again.
  void _forgetIfDropped(FtpsClient c, FtpsException e) {
    if (!_dropped(e) || !identical(c, _transfers)) return;
    _transfers = null;
    unawaited(c.close());
  }

  /// The server's SHA-256 of [path], where it can say one (HASH, XSHA256); else null, and a
  /// transfer is held to its size only.
  Future<String?> sha256(String path) async {
    if (!_client.features.hash) return null;
    try {
      return await _client.sha256(path);
    } on FtpsException catch (_) {
      return null;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
