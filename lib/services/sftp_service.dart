import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:path/path.dart' as path;
import 'package:zestssh/services/sftp_transfer_safety.dart';
import 'package:zestssh/services/ssh_service.dart' show shownHostText;
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/sudo_runner.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/file_manager.dart' show restrictFileToOwner;
import 'package:zestssh/utils/type_name.dart';

export 'package:zestssh/services/sudo_runner.dart'
    show
        SudoFailedException,
        SudoNeedsTerminalException,
        SudoNotAllowedException,
        SudoPasswordException,
        SudoRefusedException,
        SudoTimeoutException,
        SudoUnavailableException;

/// Represents a file or directory in SFTP browsing.
class SftpEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedAt;
  final String? permissions;

  /// True when the entry is a symbolic link.
  ///
  /// `readdir` reports link attributes without following them, so this is
  /// mutually exclusive with [isDirectory] even when the link points at a
  /// directory. Recursive operations MUST check this before descending:
  /// following a link during a recursive delete can destroy data outside the
  /// tree the user selected, and following one during a recursive copy can
  /// loop forever.
  final bool isSymlink;

  /// Raw Unix mode bits when the server reported them, else null. Retained
  /// so a transfer can reproduce the source permissions on the destination.
  final int? modeBits;

  /// For a symlink, the raw path it points at (from `readlink`), resolved
  /// best-effort during listing. Null when not a link OR when the target could
  /// not be read. A BROKEN link still readlinks (readlink returns the stored
  /// target text, not the target's stat), so the row can show where it points
  /// even when the destination is gone - never a fallback "1970" stat.
  final String? linkTarget;

  /// "Hidden" in the DOTFILE / Hidden-attribute category - a leading dot on a
  /// POSIX source, or the Windows Hidden attribute. Hidden only at the
  /// "Hidden and system" level, never at the default.
  final bool isHidden;

  /// "Hidden" in the SYSTEM category - a protected-OS name ($RECYCLE.BIN, System
  /// Volume Information, pagefile, NTUSER.DAT, desktop.ini…), a deny-ACL compat
  /// junction, or the Windows System attribute. Hidden at the DEFAULT level.
  final bool isSystemHidden;

  /// The Windows attributes set on a LOCAL Windows entry, as letters in a
  /// fixed order: R (read-only), H (hidden), S (system); '' when none is set.
  /// Null for every other entry (remote, macOS, Linux), whose real Unix
  /// permissions are in [permissions]. NTFS has no Unix permission bits, so a
  /// Windows pane shows these instead of a made-up rwx string.
  final String? windowsAttributes;

  const SftpEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modifiedAt,
    this.permissions,
    this.isSymlink = false,
    this.modeBits,
    this.linkTarget,
    this.isHidden = false,
    this.isSystemHidden = false,
    this.windowsAttributes,
  });

  /// A copy carrying a resolved symlink [linkTarget]. Used by [listDirectory]
  /// after its parallel readlink pass, since [SftpEntry] is immutable.
  SftpEntry withLinkTarget(String? target) => SftpEntry(
        name: name,
        path: path,
        isDirectory: isDirectory,
        size: size,
        modifiedAt: modifiedAt,
        permissions: permissions,
        isSymlink: isSymlink,
        modeBits: modeBits,
        linkTarget: target,
        isHidden: isHidden,
        isSystemHidden: isSystemHidden,
        windowsAttributes: windowsAttributes,
      );

  /// A copy carrying the source-computed hidden flags. Used by the remote pane
  /// source, which builds entries via [listDirectory] then classifies them
  /// (leading dot → hidden; protected-OS name → system) in a second pass.
  SftpEntry withHiddenFlags({required bool hidden, required bool systemHidden}) =>
      SftpEntry(
        name: name,
        path: path,
        isDirectory: isDirectory,
        size: size,
        modifiedAt: modifiedAt,
        permissions: permissions,
        isSymlink: isSymlink,
        modeBits: modeBits,
        linkTarget: linkTarget,
        isHidden: hidden,
        isSystemHidden: systemHidden,
        windowsAttributes: windowsAttributes,
      );

  /// Human-readable file size.
  String get formattedSize {
    if (isDirectory) return '';
    // Symlinks / Windows junctions have no meaningful size of their own -
    // readdir reports the link, not its target - so a raw "0 B" wrongly reads
    // as an empty file. Show a placeholder dash instead. Genuinely empty
    // files (isSymlink == false, size == 0) still correctly show "0 B".
    if (isSymlink) return '-';
    return formatByteSize(size);
  }
}

/// Transfer progress callback.
typedef SftpProgressCallback = void Function(int transferred, int total);

/// How many bytes a download asks for, from [offset], of a file the host
/// reported [size] for. That many where it reported a size: a file that is
/// being written comes down as far as it went when its size was asked, and
/// is not followed for as long as it grows. Null where it reported none
/// (everything under /proc): then the file is read to where the host says
/// it ends, which is the only word there is of its length.
@visibleForTesting
int? bytesToAskFor({required int size, required int offset}) => size > 0 ? size - offset : null;

/// Thrown by a download of what is no file with contents of its own on the
/// host: a device, a pipe or a socket. Its size is reported as nothing, and
/// reading it has no end to wait for (a device that goes on for ever, a pipe
/// nobody writes to).
class SftpNotAFileException implements Exception, HasTypeName {
  const SftpNotAFileException(this.remotePath);
  final String remotePath;

  @override
  String toString() => 'SftpNotAFileException: "$remotePath" is a device, a pipe or a socket, not a file.';

  @override
  String get typeName => 'SftpNotAFileException';
}

/// Thrown where a remote file is to be followed ([SftpService.tailFile]) and
/// its path holds what a shell other than a POSIX one could read as part of
/// a command ([CommandText.standsInAnyShell]): nothing was sent to the host.
class SftpNameNotInCommandException implements Exception, HasTypeName {
  const SftpNameNotInCommandException(this.remotePath);
  final String remotePath;

  @override
  String toString() => 'SftpNameNotInCommandException: the path holds characters a shell could read as a command';

  @override
  String get typeName => 'SftpNameNotInCommandException';
}

/// Whether [remotePath] is how Windows' OpenSSH names a place on a drive
/// (`/C:/Users/...`, or `/C:` itself): a Windows host, where no `sha256sum`
/// or `sh` is there to run.
bool isWindowsDrivePath(String remotePath) => RegExp(r'^/[A-Za-z]:(/|$)').hasMatch(remotePath);

/// Refuses a download of [remotePath] where [attrs] say it is no file
/// ([SftpNotAFileException]). What says nothing of its kind is let through.
@visibleForTesting
void mustBeAFile(SftpFileAttrs attrs, String remotePath) {
  if (attrs.isBlockDevice || attrs.isCharacterDevice || attrs.isPipe || attrs.isSocket) {
    throw SftpNotAFileException(remotePath);
  }
}

/// Thrown by an upload that could only write a file on the host where it is
/// (its folder may not be written to, or a new file in its place would be
/// another owner's or another group's), where that writing broke off: what
/// the file holds now is part of the new content, and nothing of what it
/// held was kept beside it. [cause] is what the writing ended with.
class SftpWrittenInPlaceException implements Exception, HasTypeName {
  const SftpWrittenInPlaceException(this.remotePath, this.cause);
  final String remotePath;
  final Object cause;

  @override
  String toString() => 'SftpWrittenInPlaceException: "$remotePath" was written where it is, and that ended with: $cause';

  @override
  String get typeName => 'SftpWrittenInPlaceException';
}

/// Thrown by an upload on a host without the one-step rename, where the file
/// that was there was moved aside to make room, the new one then could not
/// be put under its name, and the old one could not be put back either (the
/// connection went in between): nothing is lost, and nothing is under the
/// name. What the file held is at [asidePath], the new content at
/// [stagedPath]. [cause] is what the putting in place ended with.
class SftpSetAsideException implements Exception, HasTypeName {
  const SftpSetAsideException(this.remotePath, this.asidePath, this.stagedPath, this.cause);
  final String remotePath;
  final String asidePath;
  final String stagedPath;
  final Object cause;

  @override
  String toString() => 'SftpSetAsideException: "$remotePath" was moved to "$asidePath" and not put back; '
      'the new content is at "$stagedPath". It ended with: $cause';

  @override
  String get typeName => 'SftpSetAsideException';
}

/// Thrown by [SftpService.downloadFile] when the remote file is larger than
/// the in-memory cap. Large files must stream to disk via
/// [SftpService.downloadFileToPath]; buffering a multi-GB file in memory
/// OOM-crashes the app. Callers can catch this to show a "too large" message.
class SftpFileTooLargeException implements Exception, HasTypeName {
  const SftpFileTooLargeException(this.remotePath, this.size, this.limit);
  final String remotePath;
  final int size;
  final int limit;

  @override
  String toString() =>
      'SftpFileTooLargeException: "$remotePath" is $size bytes, over the '
      '$limit-byte in-memory limit - stream it with downloadFileToPath.';

  @override
  String get typeName => 'SftpFileTooLargeException';
}

/// What [SftpService.fileAccess] tells of a file: its owner and group
/// ("root:root") and mode ("644") where the host said them, whether the login
/// account may write it, and whether sudo is on the host.
typedef RemoteFileAccess = ({String? owner, String? mode, bool writable, bool sudo});

/// A connection test's look at a host that is SFTP only: on [client], which
/// has signed in, its SFTP is opened and its first folder (where a session
/// starts) listed, as a session to it would, with no terminal asked for.
/// That folder and how many entries it holds; what opening or listing threw
/// otherwise. The SFTP it opened is closed again; [client] is left open.
Future<({String folder, int entries})> sftpFirstFolder(
  SSHClient client, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final sftp = SftpService(client);
  try {
    await sftp.open().timeout(timeout);
    final folder = await sftp.getHomeDirectory().timeout(timeout);
    final entries = await sftp.listDirectory(folder).timeout(timeout);
    return (folder: folder, entries: entries.length);
  } finally {
    await sftp.close();
  }
}

/// SFTP file browser and transfer service.
///
/// Uses an existing [SSHClient] connection to open an SFTP subsystem.
/// Provides directory listing, upload, download, rename, delete operations.
class SftpService {
  final SSHClient _client;

  /// Path-separator splitter for the traversal guards. Compiled ONCE: the old
  /// inline `RegExp(...)` compiled a fresh pattern on every uploaded file, which
  /// a many-thousand-file folder drop paid per file.
  static final RegExp _pathSeparators = RegExp(r'[/\\]');

  /// The INTERACTIVE SFTP channel: directory listing, stat, rename, delete,
  /// chmod, and opening a file to edit all run here. Kept deliberately separate
  /// from the bulk-transfer channel below so a long-running queued transfer can
  /// never monopolise it and freeze the UI.
  SftpClient? _sftp;

  /// The dedicated BULK-TRANSFER SFTP channel: queued uploads / downloads move
  /// their bytes here instead of on [_sftp].
  ///
  /// SFTP multiplexes over SSH, and [SSHClient.sftp] opens a fresh subsystem
  /// channel on every call, so this is a second, fully independent channel over
  /// the SAME connection (its own request-id space and reply routing). While
  /// gigabytes stream over this channel, the interactive channel stays idle and
  /// responsive, so listing a directory or opening a file to edit mid-transfer
  /// no longer blocks behind the transfer's data.
  ///
  /// Opened lazily on the first in-flight bulk transfer and reference-counted:
  /// torn down the moment the last concurrent transfer finishes (so nothing is
  /// left open between batches), then reopened on demand for the next one.
  SftpClient? _transferSftp;

  /// In-flight open of [_transferSftp], shared by concurrent transfers that
  /// race to be the first to need it. One-shot: cleared as soon as the open
  /// settles (success or failure) so a failed attempt never poisons the next.
  Future<SftpClient>? _transferOpening;

  /// Number of bulk transfers currently holding [_transferSftp]. The channel is
  /// closed when this returns to zero.
  int _bulkRefs = 0;

  SftpService(this._client);

  /// Open the SFTP subsystem. Must be called before other operations.
  Future<void> open() async {
    AppLogger.info('Opening SFTP subsystem');
    _sftp = await _client.sftp();
    AppLogger.info('SFTP subsystem opened');
  }

  /// Close the SFTP subsystem.
  Future<void> close() async {
    _sftp?.close();
    _sftp = null;
    // Tear down the bulk-transfer channel too. It is reference-counted on the
    // normal completion path, but a session close must drop it regardless of
    // any in-flight count so no SFTP channel is left open on the server.
    _transferSftp?.close();
    _transferSftp = null;
    _transferOpening = null;
    _bulkRefs = 0;
    AppLogger.info('SFTP subsystem closed');
  }

  /// Whether it has a session that goes on: opened, not closed since, and
  /// not over. A session is over when its connection has dropped or the host
  /// has ended it, and then this is opened again, or another is opened on the
  /// connection that took the place of this one's. (It said that it was open
  /// until the app closed it, whatever had become of its session: a file
  /// pane went on with one whose connection had dropped, after its session
  /// was connected again.)
  bool get isOpen => !(_sftp?.isClosed ?? true);

  SftpClient get _sftpClient {
    if (_sftp == null) throw StateError('SFTP not open. Call open() first.');
    return _sftp!;
  }

  /// Acquire the dedicated bulk-transfer [SftpClient], opening it lazily on the
  /// first concurrent transfer. EVERY successful call MUST be paired with
  /// exactly one [_releaseTransferClient] (in a `finally`) - the channel is
  /// closed once the reference count returns to zero.
  Future<SftpClient> _acquireTransferClient() async {
    _bulkRefs++;
    try {
      final existing = _transferSftp;
      if (existing != null) return existing;
      return await (_transferOpening ??= _openTransferChannel());
    } catch (_) {
      // A failed open must not leave the ref count pinned (which would wedge the
      // channel state): undo this acquire before surfacing the error.
      _releaseTransferClient();
      rethrow;
    }
  }

  Future<SftpClient> _openTransferChannel() async {
    try {
      final client = await _client.sftp();
      _transferSftp = client;
      return client;
    } finally {
      // One-shot: clear whether the open succeeded or threw, so a failed
      // attempt doesn't leave a rejected Future cached for the next transfer.
      _transferOpening = null;
    }
  }

  /// Release one bulk-transfer reference. When the last in-flight transfer
  /// releases, the dedicated channel is closed so nothing is held open between
  /// batches; the next transfer reopens it lazily via [_acquireTransferClient].
  void _releaseTransferClient() {
    if (_bulkRefs == 0) return; // defensive: never go negative
    _bulkRefs--;
    if (_bulkRefs == 0) {
      final client = _transferSftp;
      _transferSftp = null;
      _transferOpening = null;
      client?.close();
    }
  }

  /// Get the current working directory (home directory).
  Future<String> getHomeDirectory() async {
    final absPath = await _sftpClient.absolute('.');
    return absPath;
  }

  /// The canonical absolute path of [path] (SSH_FXP_REALPATH).
  Future<String> realPath(String path) => _sftpClient.absolute(path);

  /// List contents of a directory.
  Future<List<SftpEntry>> listDirectory(String path) async {
    AppLogger.info('SFTP listing: $path');
    final items = await _sftpClient.listdir(path);

    final entries = <SftpEntry>[];
    for (final item in items) {
      final name = item.filename;
      // Skip . and ..
      if (name == '.' || name == '..') continue;

      final fullPath = path.endsWith('/')
          ? '$path$name'
          : '$path/$name';

      final isDir = item.attr.isDirectory;
      final size = item.attr.size ?? 0;

      DateTime? modTime;
      if (item.attr.modifyTime != null) {
        modTime = DateTime.fromMillisecondsSinceEpoch(
          item.attr.modifyTime! * 1000,
        );
      }

      entries.add(SftpEntry(
        name: name,
        path: fullPath,
        isDirectory: isDir,
        size: size,
        modifiedAt: modTime,
        permissions: _formatPermissions(item.attr.mode?.value),
        isSymlink: item.attr.isSymbolicLink,
        modeBits: item.attr.mode?.value,
      ));
    }

    // Resolve symlink targets (readlink) concurrently - best-effort, and just
    // one round trip of added latency no matter how many links the dir holds.
    // A broken link still readlinks (it returns the stored target text), so the
    // row can show where it points even when the destination is gone.
    final linkJobs = <Future<void>>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (!e.isSymlink) continue;
      linkJobs.add(() async {
        try {
          entries[i] = e.withLinkTarget(await _sftpClient.readlink(e.path));
        } catch (_) {
          // Leave linkTarget null - the row renders the link with no target.
        }
      }());
    }
    if (linkJobs.isNotEmpty) await Future.wait(linkJobs);

    // Sort: directories first, then alphabetical
    entries.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return entries;
  }

  /// Free / total bytes on the volume holding [path], via the OpenSSH
  /// `statvfs@openssh.com` extension. Returns null when the server doesn't
  /// advertise the extension (older / restricted SFTP servers) - the caller
  /// simply omits the free-space readout rather than showing a wrong number.
  Future<({int freeBytes, int totalBytes})?> statvfs(String path) async {
    try {
      final vfs = await _sftpClient.statvfs(path);
      // f_frsize is the fundamental block size the free/total counts are in;
      // fall back to f_bsize if a server reports 0.
      final unit = vfs.fundamentalBlockSize != 0
          ? vfs.fundamentalBlockSize
          : vfs.blockSize;
      // Block counts + unit are server-controlled uint64s. Reject non-positive
      // or absurd values, and anything whose byte product would overflow 63-bit
      // int (which wraps silently to a negative "free space"). This readout is
      // display-only, so when it can't be trusted we just omit it.
      const maxSaneBytes = 1 << 60; // ~1 EB - larger than any real volume.
      if (unit <= 0 ||
          vfs.totalBlocks < 0 ||
          vfs.freeBlocksForNonRoot < 0 ||
          vfs.totalBlocks > maxSaneBytes ~/ unit ||
          vfs.freeBlocksForNonRoot > maxSaneBytes ~/ unit) {
        return null;
      }
      return (
        freeBytes: vfs.freeBlocksForNonRoot * unit,
        totalBytes: vfs.totalBlocks * unit,
      );
    } catch (_) {
      return null;
    }
  }

  /// SHA-256 of a remote file, computed ON THE SERVER via `sha256sum` (falling
  /// back to `shasum -a 256`). Returns the lowercase hex digest, or null when
  /// neither tool exists / the command fails - so verification reports
  /// "couldn't verify" rather than a false mismatch. Used by verify-after-
  /// transfer to checksum both ends.
  ///
  /// The path goes into a command line the host's shell reads, so a path
  /// that holds what a shell other than a POSIX one could read as part of a
  /// command is not checked ([CommandText.standsInAnyShell]), and neither is a
  /// Windows host's (`/C:/...`), which has neither tool: null, and the check
  /// says it could not be done.
  Future<String?> sha256Remote(String remotePath) async {
    if (!CommandText.standsInAnyShell(remotePath) || isWindowsDrivePath(remotePath)) return null;
    final q = CommandText.quoted(remotePath);
    final cmd =
        'sha256sum $q 2>/dev/null || shasum -a 256 $q 2>/dev/null';
    try {
      // At most this much is read, for this long, and the channel is closed
      // then: a timeout alone stopped only the wait, and a host that went on
      // sending filled the memory for as long as the connection lasted.
      final bytes = await _client.runCapped(cmd, maxBytes: 4096, timeout: const Duration(seconds: 60));
      // sha256sum output is ASCII: "<64 hex>  <filename>".
      final text = String.fromCharCodes(bytes);
      final m = RegExp(r'([0-9a-fA-F]{64})').firstMatch(text);
      return m?.group(1)?.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// What runs on the host to tell the file editor a file's owner and mode,
  /// whether the login account may write it, and whether sudo is there to
  /// save it as root (3.4, Save as root): a script for `sh`, given the path as
  /// its first argument, that prints three lines.
  @visibleForTesting
  static const String accessScript = r'p="$1"; '
      r'(stat -c "%U:%G %a" -- "$p" 2>/dev/null || stat -f "%Su:%Sg %Lp" "$p" 2>/dev/null || echo "?"); '
      r'if [ -w "$p" ]; then echo w; else echo r; fi; '
      r'if command -v sudo >/dev/null 2>&1; then echo sudo; else echo nosudo; fi';

  /// What [accessScript] printed, read; null where it is not its three lines.
  @visibleForTesting
  static RemoteFileAccess? readAccess(String printed) {
    final lines = const LineSplitter().convert(printed.trim()).map((l) => l.trim()).toList();
    if (lines.length < 3) return null;
    final who = lines[lines.length - 3];
    final w = lines[lines.length - 2];
    final s = lines[lines.length - 1];
    if ((w != 'w' && w != 'r') || (s != 'sudo' && s != 'nosudo')) return null;
    final m = RegExp(r'^(\S+:\S+)\s+([0-7]{3,4})$').firstMatch(who);
    return (
      owner: m?.group(1),
      mode: m?.group(2),
      writable: w == 'w',
      sudo: s == 'sudo',
    );
  }

  /// A file's owner ("root:root"), its mode ("644"), whether the login
  /// account may write it, and whether sudo is on the host: asked of the
  /// host's shell, so null on a host without one (SFTP only), for a path that
  /// may not stand in a command line ([CommandText.standsInAnyShell]), and on
  /// a Windows host.
  Future<RemoteFileAccess?> fileAccess(String remotePath) async {
    if (!CommandText.standsInAnyShell(remotePath) || isWindowsDrivePath(remotePath)) return null;
    final cmd = "sh -c '$accessScript' sh ${CommandText.quoted(remotePath)}";
    try {
      final bytes = await _client.runCapped(cmd, maxBytes: 4096, timeout: const Duration(seconds: 20));
      return readAccess(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  /// The command that copies [temp] over [target] as root ([SudoRunner]):
  /// `cp` onto a file that is there writes into it, so its owner and mode
  /// stay as they are.
  @visibleForTesting
  static String sudoCopyCommand(String temp, String target) =>
      SudoRunner.commandFor('cp -- ${CommandText.quoted(temp)} ${CommandText.quoted(target)}');

  /// Why sudo refused, from what it said on its error stream
  /// ([SudoRunner.refusal]).
  @visibleForTesting
  static Exception sudoRefusal(String said, {int? exitCode}) => SudoRunner.refusal(said, exitCode: exitCode);

  /// Runs the app's own commands as root through sudo on this connection
  /// (3.4: Save as root, Retry with sudo).
  SudoRunner sudoRunner() => SudoRunner(sshSudoExec(_client));

  /// The files' actions as root through sudo on this connection (3.4, Retry
  /// with sudo).
  SudoFileOps sudoFileOps() => SudoFileOps.over(this);

  /// A new file in /tmp with a name nobody can guess, that only the login
  /// account may read (made new, never one that is there): for what sudo
  /// copies into place.
  Future<(String, SftpFile)> _openPrivateTemp() async {
    final rnd = Random.secure();
    final temp = '/tmp/.zestssh-edit-${List.generate(12, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final file = await _sftpClient.open(
      temp,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.exclusive | SftpFileOpenMode.write,
      attrs: SftpFileAttrs(mode: const SftpFileMode.value(0x180)),
    );
    return (temp, file);
  }

  /// Sends the file at [localPath] on this device into a new file of its own
  /// in /tmp on the host, that only the login account may read; its path.
  /// For an upload that sudo copies into place (Retry with sudo).
  Future<String> putPrivateTempFile(String localPath) async {
    final (temp, file) = await _openPrivateTemp();
    try {
      await file.write(File(localPath).openRead().map(Uint8List.fromList)).done;
    } catch (_) {
      await file.close();
      await removePrivateTempFile(temp);
      rethrow;
    }
    await file.close();
    return temp;
  }

  /// Removes a file [putPrivateTempFile] made; one that cannot be removed
  /// goes with the host's next clean of /tmp (only the account may read it).
  Future<void> removePrivateTempFile(String temp) async {
    try {
      await _sftpClient.remove(temp);
    } catch (_) {}
  }

  /// What Save as root runs (sudo before it): [temp] put in the place of
  /// [remotePath] as an upload done again as root is
  /// ([SudoFileOps.uploadScript]): refused where [remotePath] is a symbolic
  /// link, checked in the same command (the 3.4 security review), and
  /// written beside the file and renamed, so a write that stops halfway
  /// leaves the file as it was (found in a code audit).
  @visibleForTesting
  static String rootWriteProgram(String temp, String remotePath) =>
      "sh -c '${SudoFileOps.uploadScript}' sh ${CommandText.quoted(temp)} ${CommandText.quoted(remotePath)}";

  /// Writes [data] over [remotePath] as root, for a file the login account
  /// may not write (3.4, Save as root): the text goes into a file of its own
  /// in /tmp that only the account may read (made new, never one that is
  /// there), sudo copies it over the file, which keeps its owner and mode,
  /// and the file in /tmp is removed. [password] goes to sudo on its standard
  /// input for this one copy and is kept nowhere. Throws a
  /// [SudoRefusedException] where sudo refused, [SudoFailedException] with
  /// what the host said otherwise.
  Future<void> writeFileAsRoot(String remotePath, Uint8List data, String password) async {
    if (!CommandText.standsInAnyShell(remotePath) || isWindowsDrivePath(remotePath)) {
      throw SftpNameNotInCommandException(remotePath);
    }
    AppLogger.info('Saving a file as root (${data.length} bytes)');
    final (temp, file) = await _openPrivateTemp();
    try {
      try {
        await file.writeBytes(data);
      } finally {
        await file.close();
      }
      await sudoRunner().run(rootWriteProgram(temp, remotePath), password, idle: const Duration(seconds: 60));
    } finally {
      await removePrivateTempFile(temp);
    }
  }

  /// What runs on the host to follow a file, as a script for `sh` that is
  /// given the file's path as its first argument.
  ///
  /// `tail -f` reads nothing, so it does not notice that nobody listens any
  /// more: with the app's side of its channel closed it went on running on
  /// the host, one more for every time a file was followed, until the whole
  /// connection ended. So it runs beside a `cat`, which does read: when the
  /// app's side closes, that is the end of `cat`'s input, `cat` ends, and
  /// the script ends `tail`. And where `tail` ends by itself (no such file,
  /// no `tail` on the host), a loop that looks at it every second ends the
  /// script, so that the lines end for whoever listens.
  @visibleForTesting
  static String tailScript(int lines) => 'tail -n $lines -f "' r'$1" & t=$!; '
      r'( while kill -0 "$t" 2>/dev/null; do sleep 1; done; kill "$$" 2>/dev/null ) >/dev/null 2>&1 & w=$!; '
      r'cat >/dev/null 2>&1; kill "$t" "$w" 2>/dev/null';

  /// Live-tail a remote file - `tail -n <initialLines> -f <path>` - as a stream
  /// of lines plus a cancel that ends the follow, on the host as well
  /// ([tailScript]). Lets a sysadmin watch a log instead of downloading a
  /// dead snapshot. If the server has no `tail`, the file is not
  /// there or may not be read, the stream ends, and `said` is what the
  /// program on the host said of it ("No such file or directory",
  /// "Permission denied"), as text and nothing else: it completes when the
  /// lines have ended, with nothing where nothing was said or the follow was
  /// ended from here.
  ///
  /// The path goes into the command line as [sha256Remote]'s does: one that
  /// may not ([CommandText.standsInAnyShell]) is not followed, and
  /// [SftpNameNotInCommandException] says why.
  Future<({Stream<String> lines, Future<void> Function() cancel, Future<String> said})> tailFile(
    String remotePath, {
    int initialLines = 200,
  }) async {
    if (!CommandText.standsInAnyShell(remotePath)) throw SftpNameNotInCommandException(remotePath);
    final q = CommandText.quoted(remotePath);
    // Run by `sh`, whatever the account's own shell is: the script is in
    // its words.
    final session = await _client.execute("sh -c '${tailScript(initialLines)}' sh $q");
    final controller = StreamController<String>();
    var buffer = '';
    late final StreamSubscription<String> sub;
    // What the program says when it cannot follow the file comes on its
    // error stream: the first of it is kept, for whoever shows why the
    // lines ended.
    final errors = BytesBuilder();
    session.stderr.listen((chunk) {
      if (errors.length < 4096) errors.add(chunk);
    });
    final said = Completer<String>();
    // What the file holds is text in UTF-8, and a letter of more than one
    // byte may come in two pieces: it is put together across them. (Each
    // byte was taken for a letter, so every umlaut, accent and letter of
    // another alphabet came out as two or three wrong ones.)
    sub = session.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
      (text) {
        // Line-buffer: emit complete lines, hold a trailing partial until its
        // newline arrives.
        buffer += text;
        final idx = buffer.lastIndexOf('\n');
        if (idx >= 0) {
          for (final line in buffer.substring(0, idx).split('\n')) {
            if (!controller.isClosed) controller.add(line);
          }
          buffer = buffer.substring(idx + 1);
        }
        // Bound the trailing partial line: a hostile server tailing a
        // newline-less flood would otherwise grow this buffer without limit
        // (OOM). Flush an over-long partial as its own line instead of holding
        // it forever. 1 MB is far past any real log line.
        const maxPartialLine = 1 << 20;
        if (buffer.length > maxPartialLine) {
          if (!controller.isClosed) controller.add(buffer);
          buffer = '';
        }
      },
      onError: (_) {},
      onDone: () {
        if (buffer.isNotEmpty && !controller.isClosed) controller.add(buffer);
        // (What it said as errors has come by now: a session's output ends
        // for both of its streams at once.)
        if (!said.isCompleted) {
          said.complete(shownHostText(utf8.decode(errors.takeBytes(), allowMalformed: true)));
        }
        if (!controller.isClosed) controller.close();
      },
    );
    Future<void> cancel() async {
      // Ended from here: whatever the program says of being ended is no reason.
      if (!said.isCompleted) said.complete('');
      // The end of its input ends the `cat` on the host, and with it the
      // rest ([tailScript]).
      try {
        session.close();
      } catch (_) {}
      await sub.cancel();
      if (!controller.isClosed) await controller.close();
    }
    return (lines: controller.stream, cancel: cancel, said: said.future);
  }

  /// Recursively search under [root] for entries whose name contains [query]
  /// (case-insensitive substring - a plain name search, NOT a filter
  /// language). Breadth-first, capped at [maxResults] and [maxDepth], and
  /// cancellable via [isCancelled]. Never descends symlinked directories (loop
  /// / escape safety). Unreadable directories are skipped, not fatal.
  Future<List<SftpEntry>> searchRecursive(
    String root,
    String query, {
    int maxResults = 500,
    int maxDepth = 12,
    bool Function()? isCancelled,
  }) async {
    final q = query.toLowerCase();
    if (q.isEmpty) return const [];
    final results = <SftpEntry>[];
    final queue = <(String, int)>[(root, 0)];
    final visited = <String>{};
    while (queue.isNotEmpty) {
      if (results.length >= maxResults) break;
      if (isCancelled?.call() == true) break;
      final (dir, depth) = queue.removeAt(0);
      if (!visited.add(dir)) continue;
      List<SftpEntry> entries;
      try {
        entries = await listDirectory(dir);
      } catch (_) {
        continue; // permission denied / gone - skip this subtree
      }
      for (final e in entries) {
        if (e.name.toLowerCase().contains(q)) {
          results.add(e);
          if (results.length >= maxResults) break;
        }
        if (e.isDirectory && !e.isSymlink && depth < maxDepth) {
          queue.add((e.path, depth + 1));
        }
      }
    }
    return results;
  }

  /// Largest file [downloadFile] will buffer into memory. Anything bigger
  /// must stream via [downloadFileToPath] - a growable in-memory buffer of a
  /// multi-GB file OOM-crashes the app.
  static const int maxInMemoryDownloadBytes = 64 * 1024 * 1024; // 64 MB

  /// Download a file to bytes (in memory).
  ///
  /// For small files only (config/text to edit). Throws
  /// [SftpFileTooLargeException] above [maxInMemoryDownloadBytes]; for large
  /// files use [downloadFileToPath], which streams directly to disk.
  Future<Uint8List> downloadFile(
    String remotePath, {
    SftpProgressCallback? onProgress,
    int? maxBytes,
  }) async {
    AppLogger.info('SFTP downloading: $remotePath');
    // What it is, and how large, is asked by its name before it is opened:
    // opening a pipe waits for whoever writes to it, and the host answers
    // nothing else on this session while it waits.
    final stat = await _sftpClient.stat(remotePath);
    mustBeAFile(stat, remotePath);
    final totalSize = stat.size ?? 0;

    // The effective ceiling is the caller's cap (e.g. an editor's 4 MB limit)
    // if tighter, else the in-memory hard cap. Both are checked below against
    // the bytes ACTUALLY received, not just this advertised size - a hostile
    // server can under-report the READDIR/FSTAT size to slip a huge file past
    // an up-front size gate, then stream gigabytes into this buffer and OOM.
    final effectiveCap = maxBytes != null
        ? (maxBytes < maxInMemoryDownloadBytes
            ? maxBytes
            : maxInMemoryDownloadBytes)
        : maxInMemoryDownloadBytes;
    // One that the size the host reports says is too large is not opened.
    if (totalSize > effectiveCap) {
      throw SftpFileTooLargeException(remotePath, totalSize, effectiveCap);
    }
    final file = await _sftpClient.open(remotePath);

    // BytesBuilder(copy: false) keeps the native chunk buffers as-is instead
    // of boxing every byte the way a growable List<int> does (~8x heap
    // blow-up that crashed large reads), and takeBytes() hands them over
    // without a second full copy.
    final builder = BytesBuilder(copy: false);
    var transferred = 0;

    try {
      await for (final chunk in file.read(length: bytesToAskFor(size: totalSize, offset: 0))) {
        builder.add(chunk);
        transferred += chunk.length;
        if (transferred > effectiveCap) {
          // Server under-reported its size and is now over the ceiling - stop
          // buffering before it exhausts memory.
          throw SftpFileTooLargeException(remotePath, transferred, effectiveCap);
        }
        onProgress?.call(transferred, totalSize);
      }
    } finally {
      // Read to its end or not, the file is let go of on the host. What the
      // host says to that takes nothing from what was read and adds nothing
      // to what the read failed with. (A read that failed left the file
      // open for as long as the session lasted, and a close that the host
      // refused was an error thrown at nobody.)
      file.close().ignore();
    }
    // The file ended elsewhere than the size the host reported (or it
    // reported none): what came is the whole of it, and is told as that.
    if (transferred != totalSize) onProgress?.call(transferred, transferred);

    AppLogger.info('SFTP download complete: ${builder.length} bytes');
    return builder.takeBytes();
  }

  /// Whether a download keeps a host's owner-only file to its owner here:
  /// on macOS and Linux, where a file is made readable by everyone unless it
  /// is told otherwise. [debugKeepsOwnerOnly] stands in for that in tests.
  static bool get _keepsOwnerOnly => debugKeepsOwnerOnly ?? (Platform.isMacOS || Platform.isLinux);

  @visibleForTesting
  static bool? debugKeepsOwnerOnly;

  /// Download a file directly to disk (streaming).
  ///
  /// Writes chunks to [localPath] as they arrive, keeping memory
  /// usage constant regardless of file size.
  Future<void> downloadFileToPath(
    String remotePath,
    String localPath, {
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    bool allowResume = true,
    bool preserveTimestamp = true,
    int? maxBytes,
    bool useTransferChannel = false,
  }) async {
    // A queued bulk transfer passes useTransferChannel:true so its (potentially
    // multi-GB) stream runs on the dedicated transfer channel, leaving the
    // interactive channel free for listing / open-to-edit. Interactive callers
    // (e.g. the editor's readBytes) keep the default and stay on the primary
    // channel. The channel is reference-counted around the whole transfer so it
    // stays open for the life of a batch and is released on completion, cancel,
    // or error.
    if (useTransferChannel) {
      final sftp = await _acquireTransferClient();
      try {
        await _downloadFileToPath(
          sftp,
          remotePath,
          localPath,
          onProgress: onProgress,
          cancelToken: cancelToken,
          allowResume: allowResume,
          preserveTimestamp: preserveTimestamp,
          maxBytes: maxBytes,
        );
      } finally {
        _releaseTransferClient();
      }
      return;
    }
    await _downloadFileToPath(
      _sftpClient,
      remotePath,
      localPath,
      onProgress: onProgress,
      cancelToken: cancelToken,
      allowResume: allowResume,
      preserveTimestamp: preserveTimestamp,
      maxBytes: maxBytes,
    );
  }

  /// Byte-mover behind [downloadFileToPath]. Runs on the caller-supplied
  /// [sftp] channel (interactive or the dedicated transfer channel) so channel
  /// selection lives in one place while this streaming/resume/verify logic
  /// stays identical for both.
  Future<void> _downloadFileToPath(
    SftpClient sftp,
    String remotePath,
    String localPath, {
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    bool allowResume = true,
    bool preserveTimestamp = true,
    int? maxBytes,
  }) async {
    // Security: reject path traversal in the raw input (before normalization
    // could silently resolve it away) to prevent writes outside the intended
    // download directory via malicious SFTP filenames containing "../".
    // Reject a genuine `..` path SEGMENT (real traversal) rather than any
    // substring - the old `contains('..')` also rejected legitimate names
    // like "backup..old.tar" while still missing some encodings.
    if (localPath.split(RegExp(r'[/\\]')).contains('..')) {
      throw ArgumentError(
        'Path traversal detected in local path: $localPath',
      );
    }
    final normalized = path.normalize(localPath);

    AppLogger.info('SFTP streaming download: $remotePath → $normalized');
    // What it is, and how large, is asked by its name before it is opened:
    // opening a pipe waits for whoever writes to it, and the host answers
    // nothing else on this session while it waits.
    final stat = await sftp.stat(remotePath);
    mustBeAFile(stat, remotePath);
    final totalSize = stat.size ?? 0;
    final remoteMtime = stat.modifyTime;
    // One that the size the host reports says is larger than may be
    // downloaded is refused here, before it is opened and before anything is
    // made on this device for it. (It was refused once what it is written
    // to had been opened and the note of what that belongs to written: both
    // were left behind, the first one open for as long as the app ran, and
    // a download of the same file that had been broken off was cut to
    // nothing.) What comes is held against the limit below as well, since a
    // host can report less than it sends.
    if (maxBytes != null && totalSize > maxBytes) {
      throw SftpFileTooLargeException(remotePath, totalSize, maxBytes);
    }
    // The folder it goes to is made where it is not there yet (an iPhone
    // never makes an app's folder for downloads: the staging file could not
    // be opened there, and the download never ended). Before the file on the
    // host is opened, so a folder that cannot be made leaves nothing open.
    await Directory(path.dirname(normalized)).create(recursive: true);
    final remoteFile = await sftp.open(remotePath);

    final localFile = File(normalized);
    // Stage to a sibling temp file, never directly to the destination.
    // `openWrite()` truncates on open, so writing straight to `normalized`
    // would destroy the user's existing file the instant the transfer
    // starts - a cancel or a mid-transfer connection drop would then leave
    // them with nothing (or a truncated stub). Writing to `.zestpart` and
    // renaming onto the destination only after every byte lands makes the
    // replacement atomic: the original survives intact through any cancel
    // or error, and there is no truncated file left behind. (Same-dir
    // sibling → same filesystem → atomic rename on all target platforms.)
    final tempFile = File('$normalized.zestpart');
    final metaFile = File('$normalized.zestpart.meta');

    // ── Resume ────────────────────────────────────────────────────
    // A previous attempt that was cancelled or dropped its connection
    // leaves its `.zestpart` behind together with a sidecar recording which
    // remote file (and which size/mtime) those bytes came from. If the
    // remote file still matches, pick up where we stopped instead of
    // re-pulling gigabytes. Any mismatch - different file, changed size,
    // changed mtime, unreadable sidecar, partial longer than the source -
    // falls back to a clean restart, because a wrong resume corrupts the
    // result silently while a redundant restart only costs bandwidth.
    final partialExists = await tempFile.exists();
    final partialLength = partialExists ? await tempFile.length() : 0;
    // Which server this is: its host key and the user signed in as.
    final hostKey = _client.verifiedHostKey;
    final source =
        hostKey == null ? null : transferSource('sftp', [...hostKey, 0, ...utf8.encode(_client.username)]);
    SftpPartialMeta? partialMeta;
    if (partialExists) {
      try {
        partialMeta = SftpPartialMeta.decode(await metaFile.readAsString());
      } catch (_) {
        partialMeta = null; // missing/unreadable sidecar → restart
      }
    }
    final resume = decideResume(
      allowResume: allowResume,
      partialExists: partialExists,
      partialLength: partialLength,
      meta: partialMeta,
      remotePath: remotePath,
      remoteSize: totalSize,
      remoteMtime: remoteMtime,
      source: source,
    );
    if (resume.discardPartial && partialExists) {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
    if (resume.isResume) {
      AppLogger.info(
          'SFTP download ${resume.reason} of $totalSize bytes: $remotePath');
    }

    // Record what this partial belongs to BEFORE moving any bytes, so a
    // crash (not just a clean cancel) still leaves a resumable staging file.
    try {
      await metaFile.writeAsString(SftpPartialMeta(
        remotePath: remotePath,
        remoteSize: totalSize,
        remoteMtime: remoteMtime,
        source: source,
      ).encode());
    } catch (_) {
      // A sidecar we cannot write only costs us resume on the next attempt.
    }

    // A file only its owner may read on the host is kept to its owner here
    // too, before a byte of it is written (macOS and Linux: a key at 600
    // there landed readable by everyone here, as a folder's defaults have
    // it; Windows keeps a person's folders to them).
    if (_keepsOwnerOnly && isOwnerOnly(stat.mode?.value)) {
      if (!await tempFile.exists()) await tempFile.create();
      await restrictFileToOwner(tempFile);
    }

    final sink = tempFile.openWrite(
      mode: resume.isResume ? FileMode.append : FileMode.write,
    );
    // Hard byte ceiling, independent of any server-advertised size. The FSTAT
    // size a caller gated on (READDIR) is server-controlled and can lie: a
    // hostile server advertises 1 KB to pass a "small enough to open in the
    // editor" check, then streams gigabytes. Enforce the cap against the bytes
    // actually received so a lying server can't bypass it.
    var transferred = resume.startOffset;
    var completed = false;
    var overSizeCap = false;

    try {
      // Bound the IOSink's in-memory write buffer. `sink.add` doesn't block,
      // so without periodically awaiting `flush()` a fast server (or a slow
      // destination like a OneDrive-synced folder) lets un-drained chunks
      // pile up faster than disk can absorb them and OOM-crashes on multi-GB
      // pulls. Awaiting flush also pauses the SFTP read generator (an async*
      // that suspends at `yield` when its consumer pauses), so backpressure
      // propagates end-to-end and memory stays ~constant.
      const flushThresholdBytes = 8 * 1024 * 1024; // ~8 MB ceiling
      var sinceFlush = 0;
      var lastReportedPercent = -1;
      // TIME-throttle progress to ~10/s: each emit rebuilds the
      // Activity panel, so on a fast LAN transfer per-percent alone can fire
      // 50+/s and jank the UI. Emit only when the percent changed AND ≥100ms
      // elapsed (or at 100%), whichever is less frequent.
      var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
      // Resuming starts the read at the offset already on disk; a fresh
      // transfer starts at 0. The read asks for the bytes up to the size
      // the host reported, so an already-complete partial yields no chunks
      // and falls straight through to the publish step below; where the
      // host reported no size, it goes to where the host says the file
      // ends ([bytesToAskFor]).
      final reading = remoteFile.read(
        offset: resume.startOffset,
        length: bytesToAskFor(size: totalSize, offset: resume.startOffset),
      );
      await for (final chunk in reading) {
        cancelToken?.throwIfCancelled(); // per 32 KB chunk → near-instant stop
        sink.add(chunk);
        transferred += chunk.length;
        sinceFlush += chunk.length;
        if (maxBytes != null && transferred > maxBytes) {
          // A server that under-reported its size is now over the ceiling.
          // Abort immediately; the finally block deletes the staging file and
          // its sidecar so nothing partial is left to resume.
          overSizeCap = true;
          throw SftpFileTooLargeException(remotePath, transferred, maxBytes);
        }
        if (sinceFlush >= flushThresholdBytes) {
          await sink.flush();
          sinceFlush = 0;
        }
        // Throttle progress to integer-percent changes. The SFTP read
        // generator yields 32 KB chunks, so firing onProgress every chunk
        // means ~196k UI rebuilds on a 3 GB file - enough to jank/ANR the
        // very transfer we just stopped from OOMing. At most 101 callbacks
        // now; unknown-size files (rare) fall back to per-chunk.
        if (onProgress != null) {
          if (totalSize > 0) {
            final percent = transferred * 100 ~/ totalSize;
            if (percent != lastReportedPercent) {
              final now = DateTime.now();
              if (percent >= 100 ||
                  now.difference(lastEmitAt).inMilliseconds >= 100) {
                lastReportedPercent = percent;
                lastEmitAt = now;
                onProgress(transferred, totalSize);
              }
            }
          } else {
            onProgress(transferred, totalSize);
          }
        }
      }
      // Integrity gate: every byte that came is in the staged file, before
      // it replaces anything. What came is what counts: the file up to the
      // size the host reported, or to where the host said it ends where
      // that was sooner, or where it reported none. It was held against the
      // reported size, which is not the file's length for every file: a few
      // bytes under /sys are reported as a page, and could not be
      // downloaded at all. And the size was asked a second time for the
      // read itself, so that a log which had grown between the two could
      // not be downloaded either. (A read that breaks off fails, and gets
      // nowhere near this.) A mismatch leaves the destination untouched and
      // the partial on disk.
      await sink.flush();
      final stagedLength = await tempFile.length();
      verifyTransferSize(
        path: remotePath,
        expected: transferred,
        actual: stagedLength,
      );
      completed = true;
      // The file ended elsewhere than the size the host reported (or it
      // reported none): what came is the whole of it, and is told as that.
      if (transferred != totalSize) onProgress?.call(transferred, transferred);
    } finally {
      // Close the sink first so the file handle is released before we
      // rename or delete (Windows won't touch an open file).
      await sink.flush();
      await sink.close();
      // (What the host says to the close is nobody's: see [downloadFile].)
      remoteFile.close().ignore();
      if (completed) {
        // Put in place in one step ([publishDownload]): what was there goes
        // only as the complete new file takes its name.
        await publishDownload(tempFile, localFile);
        // The staging file is gone, so its sidecar is now noise.
        try {
          if (await metaFile.exists()) await metaFile.delete();
        } catch (_) {}
        // Carry the source timestamp across so the copy is recognisably the
        // same file: mtime is what sync comparisons, build tools and
        // "sort by date" all key off. Best-effort - a filesystem that
        // refuses the change must not fail an otherwise-good transfer.
        if (preserveTimestamp && remoteMtime != null) {
          try {
            await localFile.setLastModified(
              DateTime.fromMillisecondsSinceEpoch(remoteMtime * 1000),
            );
          } catch (_) {}
        }
      } else if (overSizeCap) {
        // Over the byte ceiling: this is not a resumable state (the whole
        // point is we refuse to store this file), so drop the staging file and
        // its sidecar rather than leaving them to be resumed next time.
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        try {
          if (await metaFile.exists()) await metaFile.delete();
        } catch (_) {}
      } else {
        // Cancel or error: KEEP the partial and its sidecar so the next
        // attempt can resume from here. The user's existing file at
        // `normalized` is still untouched - nothing was published.
      }
    }

    AppLogger.info('SFTP streaming download complete: $transferred bytes');
  }

  /// Uploads [data] to [remotePath]: what the editor saves, which holds the
  /// text and no file. It goes the way every upload goes ([_upload]): beside
  /// the file, and into its place once the host has all of it. (It was
  /// written into the file itself, which was cut to nothing first: a
  /// connection that dropped then left a file with part of the new text, and
  /// the text it had held was gone.)
  Future<void> uploadFile(String remotePath, Uint8List data) async {
    AppLogger.info('SFTP uploading to: $remotePath (${data.length} bytes)');
    await _upload(_sftpClient, remotePath, bytes: Stream.value(data), totalSize: data.length);
    AppLogger.info('SFTP upload complete');
  }

  /// Upload a local file to the remote server (streaming).
  ///
  /// Reads from [localPath] in 32 KB chunks, keeping memory
  /// usage constant regardless of file size.
  Future<void> uploadFileFromPath(
    String localPath,
    String remotePath, {
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    bool preserveTimestamp = true,
    bool preservePermissions = true,
    bool useTransferChannel = false,
  }) async {
    // A queued bulk transfer passes useTransferChannel:true so its stream runs
    // on the dedicated transfer channel, leaving the interactive channel free
    // for listing / open-to-edit. Interactive callers (e.g. the editor's
    // writeBytes save-back) keep the default and stay on the primary channel.
    // Reference-counted around the whole upload so the channel lives for the
    // batch and is released on completion, cancel, or error.
    if (useTransferChannel) {
      final sftp = await _acquireTransferClient();
      try {
        await _uploadFileFromPath(
          sftp,
          localPath,
          remotePath,
          onProgress: onProgress,
          cancelToken: cancelToken,
          preserveTimestamp: preserveTimestamp,
          preservePermissions: preservePermissions,
        );
      } finally {
        _releaseTransferClient();
      }
      return;
    }
    await _uploadFileFromPath(
      _sftpClient,
      localPath,
      remotePath,
      onProgress: onProgress,
      cancelToken: cancelToken,
      preserveTimestamp: preserveTimestamp,
      preservePermissions: preservePermissions,
    );
  }

  /// Byte-mover behind [uploadFileFromPath]. Runs on the caller-supplied [sftp]
  /// channel (interactive or the dedicated transfer channel) so channel
  /// selection lives in one place while this staging / verify / metadata logic
  /// stays identical for both.
  Future<void> _uploadFileFromPath(
    SftpClient sftp,
    String localPath,
    String remotePath, {
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    bool preserveTimestamp = true,
    bool preservePermissions = true,
  }) async {
    // Security: reject path traversal to prevent reading files outside the
    // intended directory via crafted local paths.
    // Reject a genuine `..` path SEGMENT (real traversal) rather than any
    // substring - the old `contains('..')` also rejected legitimate names
    // like "backup..old.tar" while still missing some encodings.
    if (localPath.split(_pathSeparators).contains('..')) {
      throw ArgumentError(
        'Path traversal detected in local path: $localPath',
      );
    }
    final localFile = File(localPath);
    // ONE local stat per file: it carries the size (so no separate length()
    // round-trip to the io threadpool) and is reused by _applyUploadMetadata,
    // which used to stat the file a second time. Two stats per file is a real
    // cost when a folder drop is thousands of tiny files.
    final localStat = await localFile.stat();
    final totalSize = localStat.size;
    AppLogger.info(
        'SFTP streaming upload: $localPath → $remotePath ($totalSize bytes)');

    await _upload(
      sftp,
      remotePath,
      // openRead yields Uint8List at runtime; the cast avoids a copy while
      // staying correct if that ever changes.
      bytes: localFile.openRead().map<Uint8List>((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
      totalSize: totalSize,
      onProgress: onProgress,
      cancelToken: cancelToken,
      // Reproduce the source metadata on the copy while its handle is held:
      // applied to the file beside the one it replaces, it comes into place
      // with the content. The permissions are the local file's for a file
      // that is new on the host only: one that replaces another has that
      // one's.
      whenWritten: (written, {required replaces}) => _applyUploadMetadata(
        written,
        localFile,
        stat: localStat,
        preserveTimestamp: preserveTimestamp,
        preservePermissions: preservePermissions && !replaces,
      ),
    );
    AppLogger.info('SFTP streaming upload complete: $totalSize bytes');
  }

  /// Writes [bytes], [totalSize] of them, to [remotePath]: what every upload
  /// does, of a file on this device and of the text an editor holds.
  ///
  /// Never straight into the file where it can be helped: opening it with
  /// `truncate` would destroy what it holds the instant the upload starts,
  /// so a cancel or an error in the middle would leave nothing of it. The
  /// bytes go to `<destination>.zestpart` beside it, which is put in its
  /// place only when the host has all of them, so the file stays as it was
  /// through any cancel or error, and is replaced in one step.
  ///
  /// A file that is replaced stays what it was: where it is (a link that
  /// leads to it stays a link), with its permissions, and its owner's and
  /// its group's ([_placeOf], [_fileToWrite]).
  ///
  /// [whenWritten] is called with the file while it is still open, once
  /// everything is written to it and before it is closed.
  Future<void> _upload(
    SftpClient sftp,
    String remotePath, {
    required Stream<Uint8List> bytes,
    required int totalSize,
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    Future<void> Function(SftpFile written, {required bool replaces})? whenWritten,
  }) async {
    final place = await _placeOf(sftp, remotePath);
    final destination = place.path;
    final replaced = place.file;
    final tempPath = '$destination.zestpart';
    final writing = await _fileToWrite(sftp, destination, tempPath, replaced);
    final remoteFile = writing.file;
    final inPlace = writing.inPlace;

    try {
      // ONE writer for the whole file, not one per chunk.
      //
      // [SftpFileWriter] already splits the stream into 32 KB SFTP writes and
      // keeps up to `maxBytesOnTheWire` (1 MB) of them in flight, pausing the
      // source stream when the unacknowledged window fills. The previous code
      // built a fresh writer per 128 KB block and awaited its `done` before
      // reading the next block, which capped in-flight data at that block -
      // roughly an eighth of the window - and forced a full round-trip stall
      // between blocks. On a link with any latency that is the difference
      // between streaming and ping-ponging. Handing the writer the entire
      // stream lets its own flow control do the pipelining it was built for.
      var lastReportedPercent = -1;
      var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
      final writer = remoteFile.write(
        bytes,
        onProgress: (acked) {
          if (onProgress == null) return;
          // Same throttle as the download path: the writer acks every 32 KB,
          // which is ~196k callbacks on a 3 GB upload - enough UI churn to
          // jank the transfer it is reporting on. Per-percent AND ≥100ms apart
          // so a fast LAN upload can't outrun the display.
          if (totalSize > 0) {
            final percent = acked * 100 ~/ totalSize;
            if (percent != lastReportedPercent) {
              final now = DateTime.now();
              if (percent >= 100 ||
                  now.difference(lastEmitAt).inMilliseconds >= 100) {
                lastReportedPercent = percent;
                lastEmitAt = now;
                onProgress(acked, totalSize);
              }
            }
          } else {
            onProgress(acked, totalSize);
          }
        },
      );

      if (cancelToken != null) {
        // Race the write against cancellation so a wedged upload (a stalled
        // channel, a dropped link) can be torn down the instant the user hits
        // Cancel - rather than hanging on `await` with no chance to observe
        // the flag until the write finishes, which it may never do.
        // abort() completes the writer's `done` immediately.
        await Future.any([writer.done, cancelToken.whenCancelled]);
        if (cancelToken.isCancelled) {
          await writer.abort();
          throw const TransferCancelledException();
        }
      } else {
        await writer.done;
      }

      // Integrity gate, before anything is put in place. Ask the SERVER how
      // big the file it wrote is rather than trusting our own byte count:
      // that catches a server that silently dropped or short-wrote data. A
      // mismatch throws, so nothing is put in place and the file that was
      // there is left exactly as it was.
      _heldAgainst(remotePath, sent: totalSize, has: (await remoteFile.stat()).size, inPlace: inPlace);

      await whenWritten?.call(remoteFile, replaces: replaced != null);

      // The host has it when it has closed it, and not before: a close that
      // it refuses (a home folder on a network with a limit says only then
      // that it is full) is an upload that failed, and what it did not keep
      // is not put in the place of the file.
      await remoteFile.close();
    } catch (e) {
      // What is still open is closed, and its failing now is nobody's: the
      // upload has failed already.
      remoteFile.close().ignore();
      // Written where it is, there is no whole file beside it to fall back
      // on: what it holds now is part of the new content, and whoever asked
      // for this is told so.
      if (inPlace) throw SftpWrittenInPlaceException(destination, e);
      // Cancel or error: drop what is beside the file, which is itself
      // completely untouched.
      try {
        await sftp.remove(tempPath);
      } catch (_) {}
      rethrow;
    }
    // Only now that the host has all of it and has closed it. If this fails,
    // the bytes remain beside the file (they are not removed), so the upload
    // is recoverable rather than destroyed.
    if (!inPlace) await _putInPlace(sftp, tempPath, destination);
  }

  /// Holds what was [sent] against what the host says the file it wrote
  /// [has], and throws where they say that the host kept less.
  ///
  /// Beside the file, nobody else writes to what is written, so the two are
  /// the same or the upload failed. Written [inPlace] they need not be: a
  /// program on the host that appends to the file meanwhile makes it longer,
  /// and Linux reports no size for a file that its kernel makes up as it is
  /// read, and a whole page for a few bytes (a setting under /proc or /sys,
  /// which can only be written where it is). There, fewer bytes than were
  /// sent, and more than none, is what says that the host kept less.
  static void _heldAgainst(String remotePath, {required int sent, required int? has, required bool inPlace}) {
    if (has == null) return;
    if (inPlace && (has == 0 || has > sent)) return;
    verifyTransferSize(path: remotePath, expected: sent, actual: has);
  }

  /// Where an upload to [remotePath] goes, and the file that is there
  /// already: the path itself, or, where that is a link to a file, the file
  /// the link leads to (so that the link stays a link, and the file it leads
  /// to is what changes). No file where there is none yet, or where what is
  /// there is no file.
  ///
  /// A link that leads to anything but a file is not followed: the upload
  /// takes the place of the link, as it does of one that leads nowhere.
  /// (Followed, the upload took the place of what the link led to: of a
  /// pipe, and of a device where the account may do that, which is what a
  /// unit that is switched off is a link to.)
  Future<({String path, SftpFileAttrs? file})> _placeOf(SftpClient sftp, String remotePath) async {
    final SftpFileAttrs there;
    try {
      there = await sftp.stat(remotePath, followLink: false);
    } on SftpStatusError {
      return (path: remotePath, file: null);
    }
    if (!there.isSymbolicLink) return (path: remotePath, file: there.isFile ? there : null);
    try {
      final led = await sftp.absolute(remotePath);
      final target = await sftp.stat(led);
      if (target.isFile) return (path: led, file: target);
    } on SftpStatusError {
      // A link that leads nowhere: the upload takes its place, as it did.
    }
    return (path: remotePath, file: null);
  }

  /// The file an upload writes to: one beside [destination] ([tempPath]),
  /// which is put in its place once it is whole, or [destination] itself
  /// where a file beside it could not be the file it replaces ([replaced],
  /// what is there now).
  ///
  /// Beside it, the new file is made with the permissions of the one it
  /// replaces: an upload over a file that only its owner may read came back
  /// readable by everyone, and was that while it was written. Made with
  /// them, and not given them once it is there: whoever opens a file while
  /// everyone may read it goes on reading it afterwards. The file itself is
  /// written where its folder takes no new file, and where a new file
  /// would be another owner's or another group's than the one it replaces;
  /// unless the file itself may not be written, where it is replaced after
  /// all, as it always was.
  Future<({SftpFile file, bool inPlace})> _fileToWrite(
    SftpClient sftp,
    String destination,
    String tempPath,
    SftpFileAttrs? replaced,
  ) async {
    final whole = SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate;
    final itself = SftpFileOpenMode.write | SftpFileOpenMode.truncate;
    if (replaced == null) return (file: await sftp.open(tempPath, mode: whole), inPlace: false);

    final permissions = replaced.mode;
    final kept = permissions == null ? null : SftpFileAttrs(mode: SftpFileMode.value(permissions.value & 0x1FF));
    final SftpFile beside;
    try {
      beside = await sftp.open(tempPath, mode: whole, attrs: kept);
    } on SftpStatusError catch (e) {
      // Its folder takes no new file: the file itself is written. It may not
      // be written to; or it is one that the kernel of the host makes up
      // (/proc), where a file that is not there cannot be made, and the host
      // says of the one that was to be made that there is no such file. (Its
      // folder is there, since the file in it is.)
      if (e.code != SftpStatusCode.permissionDenied && e.code != SftpStatusCode.noSuchFile) rethrow;
      return (file: await sftp.open(destination, mode: itself), inPlace: true);
    }
    try {
      final made = await beside.stat();
      if (made.userID != replaced.userID || made.groupID != replaced.groupID) {
        SftpFile? opened;
        try {
          opened = await sftp.open(destination, mode: itself);
        } on SftpStatusError catch (e) {
          if (e.code != SftpStatusCode.permissionDenied) rethrow;
        }
        if (opened != null) {
          await _discard(sftp, beside, tempPath);
          return (file: opened, inPlace: true);
        }
      }
      // Its permissions exactly, where the host narrowed what it was made
      // with. (Asked only then: a file system that has no permissions of its
      // own, a memory stick in a host, refuses to be told any, and gives
      // every file the same.)
      final asMade = made.mode;
      if (kept != null && (asMade == null || asMade.value & 0x1FF != kept.mode!.value)) await beside.setStat(kept);
      return (file: beside, inPlace: false);
    } catch (_) {
      await _discard(sftp, beside, tempPath);
      rethrow;
    }
  }

  /// Closes and removes a staged file that is not going to be used.
  Future<void> _discard(SftpClient sftp, SftpFile staged, String tempPath) async {
    try {
      await staged.close();
      await sftp.remove(tempPath);
    } catch (_) {}
  }

  /// Whether files on this device have Unix permissions to send with an
  /// upload: null for what the system is. (A test on Windows sets it to see
  /// an upload from a system that has them.)
  @visibleForTesting
  static bool? debugUnixPermissions;

  /// The one-step rename is used where the host has it. (A test turns it off
  /// to see a host that has not.)
  @visibleForTesting
  static bool debugOneStepRename = true;

  /// Puts the staged upload [tempPath] in the place of [destination]. In one
  /// step where the host can (rename(2), an extension of OpenSSH's): there
  /// is no moment with no file under the name, and nothing is removed for
  /// it, so nothing is lost where it fails. Where the host cannot: SFTP's
  /// own rename is refused for a name that is taken on most servers, so what
  /// is there is moved aside first, and removed only once the new file is
  /// under the name ([replaceByRename]).
  ///
  /// The name it is moved aside to is this upload's own ([asideName]): a file
  /// already there under a name like it (one of the person's, or one an
  /// upload that broke off left) is never removed or written over, as SFTP's
  /// rename refuses a name that is taken.
  Future<void> _putInPlace(SftpClient sftp, String tempPath, String destination) async {
    if (debugOneStepRename && await sftp.canPosixRename) {
      await sftp.posixRename(tempPath, destination);
      return;
    }
    final aside = asideName(destination);
    await replaceByRename(
      rename: () => sftp.rename(tempPath, destination),
      moveAside: () => sftp.rename(destination, aside),
      putBack: () => sftp.rename(aside, destination),
      discard: () => sftp.remove(aside),
      setAside: (cause) => SftpSetAsideException(destination, aside, tempPath, cause),
    );
  }

  /// SFTP's own rename of a staged file onto its name, on a host without the
  /// one-step rename. When the host may be saying the name is taken (SFTP
  /// version 3 answers "failure" for it, later versions "file already
  /// exists"), what is there is moved aside ([moveAside]), the rename made
  /// again, and what was moved aside removed ([discard]) only when the new
  /// file is under the name. The file that was there is never removed before
  /// that: "failure" is what version 3 answers for many things, and between
  /// removing a file and renaming another onto its name a connection can end.
  ///
  /// So: any other refusal of the first rename (no permission, no such
  /// folder, a lost connection) goes to the caller with the file left where
  /// it is and the new content beside it. So does the first refusal where
  /// nothing could be moved aside (the name was not what was wrong). Where
  /// the second rename fails, the file is put back ([putBack]) and that
  /// failure goes to the caller. Where it cannot be put back either, the
  /// caller gets [setAside]'s exception, which says where both now are.
  @visibleForTesting
  static Future<void> replaceByRename({
    required Future<void> Function() rename,
    required Future<void> Function() moveAside,
    required Future<void> Function() putBack,
    required Future<void> Function() discard,
    Object Function(Object cause)? setAside,
  }) async {
    try {
      await rename();
      return;
    } on SftpStatusError catch (e) {
      if (e.code != SftpStatusCode.failure && e.code != _sftpFileAlreadyExists) rethrow;
      try {
        await moveAside();
      } catch (_) {
        throw e;
      }
    }
    try {
      await rename();
    } catch (e) {
      try {
        await putBack();
      } catch (_) {
        throw setAside?.call(e) ?? e;
      }
      rethrow;
    }
    try {
      await discard();
    } catch (_) {
      // The new file is in place; what was there stays beside it under its other name.
    }
  }

  /// Where one upload moves the file it replaces aside ([_putInPlace]): beside
  /// it, under a name of this upload's own.
  @visibleForTesting
  static String asideName(String destination, [Random? random]) {
    final r = random ?? Random.secure();
    final tag = [for (var i = 0; i < 4; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    return '$destination.zestold-$tag';
  }

  /// SSH_FX_FILE_ALREADY_EXISTS (SFTP version 5 and later).
  static const _sftpFileAlreadyExists = 11;

  /// Copy the local file's timestamp and permission bits onto a freshly
  /// uploaded remote file.
  ///
  /// Without this every upload lands with "now" as its mtime and the
  /// server's default umask as its mode, which loses the executable bit on
  /// scripts and makes any mtime-based sync comparison (including our own
  /// [SftpSyncService]) treat an unchanged file as newer forever.
  ///
  /// Best-effort: a server that rejects SETSTAT (read-only mounts, object
  /// stores, restrictive chroots) must not fail an otherwise-good upload.
  Future<void> _applyUploadMetadata(
    SftpFile remoteFile,
    File localFile, {
    required bool preserveTimestamp,
    required bool preservePermissions,
    FileStat? stat,
  }) async {
    if (!preserveTimestamp && !preservePermissions) return;
    try {
      // Reuse the caller's stat when it has one; only re-stat if not supplied.
      final localStat = stat ?? await localFile.stat();

      int? accessTime;
      int? modifyTime;
      if (preserveTimestamp) {
        // SFTP v3 carries atime and mtime as ONE attribute pair: the
        // acmodtime flag promises both fields are present, so sending a lone
        // mtime produces a short, malformed packet. Always send the pair.
        modifyTime = localStat.modified.millisecondsSinceEpoch ~/ 1000;
        accessTime = localStat.accessed.millisecondsSinceEpoch ~/ 1000;
      }

      SftpFileMode? mode;
      if (preservePermissions && (debugUnixPermissions ?? !Platform.isWindows)) {
        // Windows has no Unix mode - dart:io synthesises one, and pushing
        // that to a POSIX server writes nonsense permissions. Elsewhere,
        // keep only the 9 rwx bits: setuid/setgid/sticky are deliberately
        // dropped so an upload can never create a privileged binary.
        mode = SftpFileMode.value(localStat.mode & 0x1FF);
      }

      if (accessTime == null && mode == null) return;
      await remoteFile.setStat(SftpFileAttrs(
        accessTime: accessTime,
        modifyTime: modifyTime,
        mode: mode,
      ));
    } catch (e) {
      AppLogger.info('SFTP upload metadata not applied (server refused): $e');
    }
  }

  /// Delete a file.
  Future<void> deleteFile(String remotePath) async {
    AppLogger.info('SFTP deleting file: $remotePath');
    await _sftpClient.remove(remotePath);
  }

  /// Delete a directory (must be empty).
  Future<void> deleteDirectory(String remotePath) async {
    AppLogger.info('SFTP deleting directory: $remotePath');
    await _sftpClient.rmdir(remotePath);
  }

  /// Deepest directory nesting a recursive walk will follow.
  ///
  /// A backstop, not a limit users should meet: real trees are far
  /// shallower, and a server that keeps reporting nested directories
  /// forever (buggy, hostile, or an exotic filesystem) would otherwise
  /// recurse until the isolate dies.
  static const int maxRecursionDepth = 64;

  /// Delete a directory recursively.
  ///
  /// Walks the directory tree depth-first, deleting files and then
  /// removing empty directories on the way back up.
  ///
  /// **Symlinks are removed, never followed.** This is the difference
  /// between deleting the folder the user selected and deleting whatever it
  /// happened to point at: a link named `backups -> /` inside the target
  /// would otherwise send this walk through the entire remote filesystem,
  /// deleting as it went. Refusing to descend into links also makes cycles
  /// impossible, since a link is the only way a directory tree can contain
  /// itself.
  Future<void> deleteDirectoryRecursive(
    String remotePath, {
    int depth = 0,
    void Function(String deletedPath)? onDeleted,
    bool Function()? isCancelled,
  }) async {
    if (depth == 0) AppLogger.info('SFTP recursive delete: $remotePath');
    if (depth > maxRecursionDepth) {
      throw SftpError(
        'Refusing to delete deeper than $maxRecursionDepth levels '
        '(at "$remotePath") - the server may be reporting a cyclic tree.',
      );
    }

    final entries = await listDirectory(remotePath);

    for (final entry in entries) {
      // Cancellation leaves a PARTIAL delete on purpose - the caller marks the
      // operation cancelled and re-lists, so the not-yet-deleted files are
      // simply still there. Checking before every removal (and before the
      // parent rmdir below) means cancel never removes "one more" than the user
      // saw stop, and a non-empty parent is never rmdir'd after a cancel.
      if (isCancelled?.call() ?? false) return;

      // A link - of any kind, including one pointing at a directory - is
      // unlinked with REMOVE. That deletes the link itself and leaves the
      // target untouched, which is what the user asked for.
      if (entry.isSymlink) {
        await deleteFile(entry.path);
        onDeleted?.call(entry.path);
        continue;
      }

      if (entry.isDirectory) {
        // Defence in depth: `readdir` is specified to report link
        // attributes without following them, but a non-conforming or
        // hostile server can answer with the TARGET's attributes, which
        // would make a link to a directory look like a real subdirectory
        // here. Confirm with an explicit non-following stat before we
        // descend into something destructive.
        if (await _isSymlinkStrict(entry.path)) {
          await deleteFile(entry.path);
          onDeleted?.call(entry.path);
          continue;
        }
        await deleteDirectoryRecursive(
          entry.path,
          depth: depth + 1,
          onDeleted: onDeleted,
          isCancelled: isCancelled,
        );
        if (isCancelled?.call() ?? false) return;
      } else {
        await deleteFile(entry.path);
        onDeleted?.call(entry.path);
      }
    }

    if (isCancelled?.call() ?? false) return;
    await deleteDirectory(remotePath);
    onDeleted?.call(remotePath);
    if (depth == 0) {
      AppLogger.info('SFTP recursive delete complete: $remotePath');
    }
  }

  /// Read-only recursive count of everything [deleteDirectoryRecursive] would
  /// remove under [remotePath] - each file, each symlink, and each directory
  /// including [remotePath] itself - so a delete can show determinate "N of M"
  /// progress. Symlink-safe: a link counts as one and is never descended.
  /// Best-effort: an unreadable subtree contributes only what it could
  /// enumerate rather than aborting the whole count.
  Future<int> countEntriesRecursive(String remotePath, {int depth = 0}) async {
    if (depth > maxRecursionDepth) return 1;
    var count = 1; // remotePath itself (the directory removed on the way up)
    final List<SftpEntry> entries;
    try {
      entries = await listDirectory(remotePath);
    } catch (_) {
      return count; // unreadable dir - count it, don't descend
    }
    for (final entry in entries) {
      if (entry.isSymlink) {
        count++;
      } else if (entry.isDirectory) {
        if (await _isSymlinkStrict(entry.path)) {
          count++;
        } else {
          count += await countEntriesRecursive(entry.path, depth: depth + 1);
        }
      } else {
        count++;
      }
    }
    return count;
  }

  /// Non-following stat: true when [remotePath] is itself a symbolic link.
  ///
  /// Fails CLOSED - an unreadable stat returns true so the caller treats the
  /// entry as a link and unlinks it rather than recursing into it.
  Future<bool> _isSymlinkStrict(String remotePath) async {
    try {
      final attrs = await _sftpClient.stat(remotePath, followLink: false);
      return attrs.isSymbolicLink;
    } catch (_) {
      return true;
    }
  }

  /// Create a directory.
  Future<void> createDirectory(String remotePath) async {
    AppLogger.info('SFTP creating directory: $remotePath');
    await _sftpClient.mkdir(remotePath);
  }

  /// Create a directory and all missing parents.
  Future<void> createDirectoryRecursive(String remotePath) async {
    AppLogger.info('SFTP creating directory (recursive): $remotePath');
    final parts = remotePath.split('/')..removeWhere((p) => p.isEmpty);
    var current = remotePath.startsWith('/') ? '' : '.';

    for (final part in parts) {
      current = '$current/$part';
      try {
        await _sftpClient.stat(current);
      } catch (_) {
        // Directory doesn't exist, create it
        await _sftpClient.mkdir(current);
      }
    }
  }

  /// Rename a file or directory.
  Future<void> rename(String oldPath, String newPath) async {
    AppLogger.info('SFTP renaming: $oldPath → $newPath');
    await _sftpClient.rename(oldPath, newPath);
  }

  /// Get file attributes.
  Future<SftpFileAttrs> stat(String path) async {
    return _sftpClient.stat(path);
  }

  /// Stat that returns null instead of throwing when the target is
  /// missing (or unreadable). Convenient for "does this exist, and if
  /// so how big / how old" - powers the overwrite-conflict prompt.
  Future<SftpFileAttrs?> statOrNull(String path) async {
    try {
      return await _sftpClient.stat(path);
    } catch (_) {
      return null;
    }
  }

  /// Change file/directory permissions (chmod).
  ///
  /// [mode] is the 9-bit Unix permission mask (e.g. 0x1FF = 777).
  Future<void> chmod(String path, int mode) async {
    AppLogger.info('SFTP chmod: $path → ${mode.toRadixString(8)}');
    await _sftpClient.setStat(
      path,
      SftpFileAttrs(mode: SftpFileMode.value(mode)),
    );
  }

  /// Apply [mode] to [remotePath] and everything under it, mirroring
  /// `chmod -R <mode>`: the SAME mode is set on files AND directories (no
  /// separate dir/file masks), the directory itself included.
  ///
  /// Structured like [deleteDirectoryRecursive]: same [maxRecursionDepth]
  /// backstop, and the same symlink safety. **Symbolic links are skipped -
  /// never chmod'd and never descended.** A SETSTAT on a link would follow it
  /// and change the mode of whatever it points at (data outside the selected
  /// tree), and descending one could loop forever, so the walk leaves links
  /// alone. Directory entries are re-checked with [_isSymlinkStrict] before we
  /// descend, defending against a server that reports a link as a real dir.
  ///
  /// Children are processed before the directory itself so the walk keeps its
  /// read/execute rights while listing, then tightens the directory last.
  ///
  /// [isCancelled] is polled before every chmod (and before descending); a
  /// true result returns early, leaving a PARTIAL apply on purpose - the caller
  /// re-lists and the untouched entries simply keep their old mode. [onDone]
  /// fires once per entry whose mode was set, for determinate progress.
  Future<void> chmodRecursive(
    String remotePath,
    int mode, {
    int depth = 0,
    void Function(String path)? onDone,
    bool Function()? isCancelled,
  }) async {
    if (depth == 0) {
      AppLogger.info('SFTP recursive chmod: $remotePath → '
          '${mode.toRadixString(8)}');
    }
    if (depth > maxRecursionDepth) {
      throw SftpError(
        'Refusing to chmod deeper than $maxRecursionDepth levels '
        '(at "$remotePath") - the server may be reporting a cyclic tree.',
      );
    }

    final entries = await listDirectory(remotePath);

    for (final entry in entries) {
      if (isCancelled?.call() ?? false) return;

      // Links are left untouched: chmod would follow to the target, and we
      // never descend one. Skip without firing onDone (it was not modified).
      if (entry.isSymlink) continue;

      if (entry.isDirectory) {
        // Defence in depth against a server reporting a link as a real dir -
        // an explicit non-following stat before we descend / chmod it.
        if (await _isSymlinkStrict(entry.path)) continue;
        await chmodRecursive(
          entry.path,
          mode,
          depth: depth + 1,
          onDone: onDone,
          isCancelled: isCancelled,
        );
        if (isCancelled?.call() ?? false) return;
      } else {
        await chmod(entry.path, mode);
        onDone?.call(entry.path);
      }
    }

    if (isCancelled?.call() ?? false) return;
    // The directory itself, last - so its own read/execute survived the walk.
    await chmod(remotePath, mode);
    onDone?.call(remotePath);
    if (depth == 0) {
      AppLogger.info('SFTP recursive chmod complete: $remotePath');
    }
  }

  /// Format Unix permissions to rwxrwxrwx string.
  String? _formatPermissions(int? mode) {
    if (mode == null) return null;

    final perms = StringBuffer();
    final permissions = mode & 0x1FF; // last 9 bits

    for (var i = 8; i >= 0; i--) {
      if (permissions & (1 << i) != 0) {
        switch (i % 3) {
          case 2:
            perms.write('r');
          case 1:
            perms.write('w');
          case 0:
            perms.write('x');
        }
      } else {
        perms.write('-');
      }
    }
    return perms.toString();
  }
}

/// Whether a file of the permissions [mode] (as a host gives them) may be
/// read by its owner alone: none of the group's and others' bits set.
bool isOwnerOnly(int? mode) => mode != null && mode & 0x3F == 0;
