import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:crypto/crypto.dart' show sha256;

import 'package:zestssh/utils/type_name.dart';

/// Pure decision logic that guards SFTP transfers.
///
/// Everything here is deliberately free of I/O so the risky rules - what a
/// server-supplied filename is allowed to become on disk, when a partial
/// transfer may be resumed, and whether a finished transfer actually moved
/// every byte - can be unit-tested exhaustively without a live server.

// ══════════════════════════════════════════════════════════════════
// Filename safety
// ══════════════════════════════════════════════════════════════════

/// Windows device names that are reserved at every directory level. Opening
/// or creating them does not touch the filesystem (`CON` is the console,
/// `NUL` discards writes), which turns "download this file" into something
/// the user never asked for. Reserved with OR without an extension, so the
/// check runs against the stem. `COM0` and `LPT0`, the superscript digits
/// (`COM¹`) and the console's `CONIN$` and `CONOUT$` are as well, on some
/// Windows or other: they cost a real file a `_` at the most.
const _windowsReservedStems = <String>{
  'con', 'prn', 'aux', 'nul', 'conin\$', 'conout\$',
  'com0', 'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'com¹', 'com²', 'com³',
  'lpt0', 'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  'lpt¹', 'lpt²', 'lpt³',
};

/// Longest single path component we will produce. Most filesystems cap a
/// component at 255 bytes; a hostile server can return far more and turn a
/// download into an unhandled OS error mid-tree.
const int maxComponentLength = 200;

/// The most bytes of UTF-8 a local file name is given: the 255 a name may
/// have on Linux, macOS and Android, less the 14 of `.zestpart.meta`, which
/// stands after it while the file is being downloaded.
const int maxComponentBytes = 241;

/// Reduce a server-supplied directory-entry name to ONE safe path component
/// before it is joined onto a destination directory.
///
/// A malicious or compromised SFTP server fully controls the names returned
/// by `listdir`. Without this, an absolute name (`/etc/cron.d/x`,
/// `C:\Windows\System32\x.dll`) makes `package:path`'s join DISCARD the
/// destination entirely - an arbitrary-file write - and `../..` walks out of
/// it. For an honest server every real entry name is already a single
/// component, so this is a no-op in practice.
///
/// [forWindows] enables the Win32-specific rules (reserved device names,
/// trailing dots/spaces, `:` alternate-data-streams). It defaults to the
/// host platform: applying them unconditionally would mangle legitimate
/// POSIX names like `aux.c`, which is common in real source trees.
String safeChildName(String name, {bool? forWindows}) {
  // (Nothing a server sends is worked on at any length.)
  if (name.length > 4096) name = name.substring(name.length - 4096);
  final windows = forWindows ?? Platform.isWindows;

  // Keep only the last component, treating BOTH separators as separators
  // regardless of host platform - a POSIX host must not accept a name
  // containing a backslash as a single component, because that same name is
  // later written on a Windows peer (and vice versa).
  var s = name.split('/').last.split('\\').last;

  // Strip C0/C1 control characters (NUL included). NUL truncates the path at
  // the syscall boundary on POSIX; the rest are invalid on Windows and can
  // be used to spoof what the UI displays.
  s = s.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');

  if (windows) {
    // `:` opens an NTFS alternate data stream ("notes.txt:hidden"), which
    // writes content the file listing never shows. The rest are simply
    // illegal in Win32 paths and would fail late instead of here.
    s = s.replaceAll(RegExp(r'[:*?"<>|]'), '_');
  }

  // Unicode direction overrides let a server render "exe.txt" while the real
  // name is "txt.exe". Drop the override characters, keep the text. The
  // direction MARKS and the characters that take no room go too (U+200E,
  // U+200F, U+061C, U+200B, U+2060, U+FEFF): with them, two names that look
  // the same were two files (found in a security audit). The two joiners
  // (U+200C, U+200D) stay: Persian and the Indic scripts spell with them,
  // and so do emoji.
  s = s.replaceAll(
      RegExp('[\u202a-\u202e\u2066-\u2069\u200e\u200f\u061c\u200b\u2060\ufeff]'), '');

  if (windows) {
    // Win32 silently strips trailing dots and spaces, so "evil " and "evil"
    // collide and an overwrite check on one can be defeated by the other.
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
  }

  s = s.trim();

  if (windows && s.isNotEmpty) {
    // (Older Windows reads `CON .txt` as the console too: spaces before the
    // first dot do not make it another name.)
    final stem = s.split('.').first.trimRight().toLowerCase();
    if (_windowsReservedStems.contains(stem)) {
      // Prefix rather than replace so the user still recognises the file.
      s = '_$s';
    }
  }

  s = _fitted(s);

  if (s.isEmpty || s == '.' || s == '..') s = 'file';
  return s;
}

/// [s] cut to what a file name may be: at most [maxComponentLength] UTF-16
/// units and [maxComponentBytes] bytes of UTF-8, cut between two characters
/// and never inside one, with its extension kept (it drives the icon, the
/// editor's binary sniffing, and the person's ability to open the result).
///
/// It was cut at 200 UTF-16 units wherever that fell: inside a character
/// beyond the basic plane (the half that was left is no character, and the
/// file could not be made), and 200 units of Chinese or Japanese are 600
/// bytes, over the 255 a name may have on Linux, macOS and Android (found in a security
/// audit).
String _fitted(String s) {
  bool fits(String t) => t.length <= maxComponentLength && utf8.encode(t).length <= maxComponentBytes;
  if (fits(s)) return s;
  final dot = s.lastIndexOf('.');
  final ext = dot > 0 && s.length - dot <= 16 ? s.substring(dot) : '';
  final stem = (ext.isEmpty ? s : s.substring(0, dot)).runes.take(maxComponentLength).toList();
  var kept = stem.length;
  while (kept > 0 && !fits(String.fromCharCodes(stem, 0, kept) + ext)) {
    kept--;
  }
  return String.fromCharCodes(stem, 0, kept) + ext;
}

// ══════════════════════════════════════════════════════════════════
// Resume
// ══════════════════════════════════════════════════════════════════

/// Sidecar written next to a `.zestpart` staging file recording WHICH remote
/// file the partial belongs to.
///
/// Without it, resuming is unsound: the staging file alone cannot tell us
/// whether the remote file changed (or is even the same file) since the
/// partial was written, and appending to a stale partial silently produces a
/// corrupt result that passes every size check.
///
/// It also records which server ([source]): the same path with the same size
/// on another host is another file, and a partial of host A went on with
/// host B's bytes, a file made of two halves that passed for complete (found in a
/// security audit).
class SftpPartialMeta {
  const SftpPartialMeta({
    required this.remotePath,
    required this.remoteSize,
    this.remoteMtime,
    this.source,
  });

  /// The server the partial came from ([transferSource]); none in a note
  /// written before 4.0, which is never resumed.
  final String? source;

  /// Absolute remote path the partial was being downloaded from.
  final String remotePath;

  /// Remote size, in bytes, at the time the partial was written.
  final int remoteSize;

  /// Remote mtime in seconds since the epoch, when the server reported one.
  final int? remoteMtime;

  Map<String, Object?> toJson() => {
        'v': 1,
        'remote': remotePath,
        'size': remoteSize,
        if (remoteMtime != null) 'mtime': remoteMtime,
        if (source != null) 'from': source,
      };

  String encode() => jsonEncode(toJson());

  /// Parse a sidecar. Returns null for anything malformed - a bad sidecar
  /// must degrade to "start over", never to a bogus resume.
  static SftpPartialMeta? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final remote = decoded['remote'];
      final size = decoded['size'];
      if (remote is! String || remote.isEmpty) return null;
      if (size is! int || size < 0) return null;
      final mtime = decoded['mtime'];
      final from = decoded['from'];
      return SftpPartialMeta(
        remotePath: remote,
        remoteSize: size,
        remoteMtime: mtime is int ? mtime : null,
        source: from is String && from.isNotEmpty ? from : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Which server a download comes from, as the note beside a partial keeps
/// it: the [kind] of server ('sftp', 'ftps') and a hash of what tells one
/// from another ([identity]: an SSH server's host key and the user name, an
/// FTPS server's address, port and user name). A hash, since the note lies
/// in the folder the person downloads to.
String transferSource(String kind, List<int> identity) =>
    '$kind:${sha256.convert(identity).toString().substring(0, 32)}';

/// Outcome of the resume check.
class ResumeDecision {
  const ResumeDecision._(this.startOffset, this.discardPartial, this.reason);

  /// Byte offset the download should start from. 0 means "from scratch".
  final int startOffset;

  /// Whether an existing staging file must be deleted before starting.
  final bool discardPartial;

  /// Why this decision was reached - logged, and useful in tests.
  final String reason;

  bool get isResume => startOffset > 0;

  /// Start over, throwing away any existing partial.
  static ResumeDecision fresh(String reason) =>
      ResumeDecision._(0, true, reason);

  /// Continue an existing partial from [offset].
  static ResumeDecision resume(int offset) =>
      ResumeDecision._(offset, false, 'resuming at $offset');

  /// The partial already covers the whole file - nothing left to transfer.
  static ResumeDecision complete(int size) =>
      ResumeDecision._(size, false, 'partial already complete');
}

/// Decide whether a `.zestpart` staging file may be resumed.
///
/// Conservative by construction: ANY mismatch or missing signal falls back
/// to a fresh transfer, because a wrong resume corrupts the user's file
/// silently while a redundant restart merely costs bandwidth.
ResumeDecision decideResume({
  required bool allowResume,
  required bool partialExists,
  required int partialLength,
  required SftpPartialMeta? meta,
  required String remotePath,
  required int remoteSize,
  int? remoteMtime,
  required String? source,
}) {
  if (!partialExists || partialLength <= 0) {
    return ResumeDecision.fresh('no usable partial');
  }
  if (!allowResume) return ResumeDecision.fresh('resume disabled');
  if (meta == null) return ResumeDecision.fresh('no sidecar metadata');
  if (meta.remotePath != remotePath) {
    return ResumeDecision.fresh('partial belongs to a different file');
  }
  // The same path on another server is another file. One that cannot say
  // which server it is, or a note that names none, starts over.
  if (source == null || meta.source != source) {
    return ResumeDecision.fresh('partial came from another server');
  }
  if (remoteSize <= 0) {
    // Unknown remote size: we cannot bound the partial, so we cannot trust it.
    return ResumeDecision.fresh('remote size unknown');
  }
  if (meta.remoteSize != remoteSize) {
    return ResumeDecision.fresh('remote file size changed');
  }
  // Only compare mtimes when BOTH sides reported one; plenty of servers omit
  // it, and treating "absent" as "changed" would disable resume everywhere.
  if (meta.remoteMtime != null &&
      remoteMtime != null &&
      meta.remoteMtime != remoteMtime) {
    return ResumeDecision.fresh('remote file modified since partial');
  }
  if (partialLength > remoteSize) {
    return ResumeDecision.fresh('partial larger than remote file');
  }
  if (partialLength == remoteSize) return ResumeDecision.complete(remoteSize);
  return ResumeDecision.resume(partialLength);
}

// ══════════════════════════════════════════════════════════════════
// Integrity
// ══════════════════════════════════════════════════════════════════

/// Thrown when a transfer finished but moved the wrong number of bytes.
///
/// The staging-file design means this is recoverable: the destination has
/// not been replaced yet, so the user still has their original file. What
/// was written into the file itself is not: it is thrown inside an
/// [SftpWrittenInPlaceException] then, which says so, and this does not say
/// what became of the destination.
class SftpIntegrityException implements Exception, HasTypeName {
  const SftpIntegrityException({
    required this.path,
    required this.expected,
    required this.actual,
  });

  final String path;
  final int expected;
  final int actual;

  @override
  String toString() =>
      'SftpIntegrityException: "$path" should be $expected bytes but $actual bytes were transferred.';

  @override
  String get typeName => 'SftpIntegrityException';
}

/// Verify a completed transfer moved exactly [expected] bytes.
///
/// A short copy is the dangerous case: a truncated file that renames cleanly
/// onto the destination looks like success to the user and to any later
/// size-based sync comparison. What [expected] is depends on who asks. A
/// download and a copy on this device ask with the bytes that were read, to
/// the end the source said it has, against what is in the staged file: the
/// size a source reports for itself beforehand is not asked about, since
/// Linux reports none under /proc and a whole page under /sys. An upload
/// asks with the size of the file on this device against the size the host
/// reports for what it wrote. Nothing to compare (0) is skipped.
void verifyTransferSize({
  required String path,
  required int expected,
  required int actual,
}) {
  if (expected <= 0) return;
  if (expected == actual) return;
  throw SftpIntegrityException(
    path: path,
    expected: expected,
    actual: actual,
  );
}

/// Puts a finished download in place: [staged] takes [destination]'s name, and
/// what was there before goes in that one step.
///
/// The old file used to be deleted first, for a rename that "throws if the
/// target exists on Windows". It does not: a rename replaces the target on
/// every platform the app runs on (tried on Windows 11, and it is what POSIX
/// says). Deleting first left a moment with no file at all, and when the
/// rename then failed (the staged file held by a virus scanner, say) the
/// person's old file was gone and the new one sat under its staging name
/// (found in two security
/// audits). Now the old file is there until the new one has its name, and
/// stays if the rename fails: the staged file stays too, complete, for the
/// next try.
Future<void> publishDownload(File staged, File destination) async {
  await staged.rename(destination.path);
}
