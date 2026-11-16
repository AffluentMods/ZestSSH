import 'dart:async';
import 'dart:io';

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_native/ftps.dart' show FtpsErrorKind, FtpsException;
import 'package:zestssh/services/ftps/ftps_session.dart' show ftpsFailureText;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sftp_service.dart'
    show SftpFileTooLargeException, SftpNameNotInCommandException, SftpNotAFileException, SftpWrittenInPlaceException;
import 'package:zestssh/services/sftp_transfer_safety.dart' show SftpIntegrityException;
import 'package:zestssh/services/transfer_cancel_token.dart';

/// Human-readable messages for SFTP / transfer failures.
///
/// Everything the SFTP UI used to surface came through as a raw
/// `e.toString()` - "SftpStatusError: Failure(code 4)" tells the user
/// nothing about what went wrong or what to do next. These helpers map the
/// protocol status codes (and the common local `dart:io` failures) onto a
/// short sentence written for the person looking at the transfer queue, in
/// the app's language (3.0: they were English only).
///
/// Pure functions on purpose: no I/O, no context, so they are trivially
/// unit-testable and safe to call from any isolate. What a server or the
/// system said in its own words is passed on as it came.

/// What the user was trying to do, used to phrase the message naturally.
enum SftpOp {
  /// Listing a directory.
  list,

  /// Downloading (remote → local).
  download,

  /// Uploading (local → remote).
  upload,

  /// Deleting a file or directory.
  delete,

  /// Renaming or moving.
  rename,

  /// Creating a directory.
  mkdir,

  /// Changing permissions.
  chmod,

  /// Anything else / unknown.
  generic;

  /// "Permission denied" said for this operation on [target]: a sentence
  /// of its own for each, as languages put the verb in different places.
  String denied(AppLocalizations t, String target) => switch (this) {
        SftpOp.list => t.sftpErrDeniedOpen(target),
        SftpOp.download => t.sftpErrDeniedRead(target),
        SftpOp.upload => t.sftpErrDeniedWrite(target),
        SftpOp.delete => t.sftpErrDeniedDelete(target),
        SftpOp.rename => t.sftpErrDeniedRename(target),
        SftpOp.mkdir => t.sftpErrDeniedCreate(target),
        SftpOp.chmod => t.sftpErrDeniedChmod(target),
        SftpOp.generic => t.sftpErrDeniedAccess(target),
      };
}

/// What the sentences of this file end with in the languages the app
/// speaks: the full stop, and the full stops of Chinese and Japanese and of
/// Hindi.
final _sentenceEnds = ['.', String.fromCharCode(0x3002), String.fromCharCode(0x0964)];

/// [said] as a sentence that another can follow: with a full stop behind it
/// where it ends in what a server or a system said, which ends in none.
String _asSentence(String said) => _sentenceEnds.any(said.endsWith) ? said : '$said.';

/// Short, human explanation of [error], phrased for the SFTP UI.
///
/// [name] is the file or directory the operation targeted (a basename reads
/// better than a full path in a toast); [op] tunes the wording; [l10n] is the
/// language, the app's own when not given.
///
/// Falls back to the exception's own message rather than inventing text, so
/// an unexpected error is still actionable for a bug report.
String sftpErrorMessage(
  Object error, {
  String? name,
  SftpOp op = SftpOp.generic,
  AppLocalizations? l10n,
}) {
  final t = l10n ?? gl10n;
  final target = (name == null || name.isEmpty) ? t.sftpErrTheItem : t.sftpErrNamed(name);

  // User-initiated cancel is not a failure - callers generally filter this
  // out, but phrase it sanely if it does reach the UI.
  if (error is TransferCancelledException) {
    return t.sftpErrCancelled;
  }

  // FTPS (3.4): the native library's kinds, said as SFTP's are where they are
  // the same, and in FTPS's own words where they are its own.
  if (error is FtpsException) {
    final detail = _cleanServerText(error.message);
    return switch (error.kind) {
      FtpsErrorKind.cancelled => t.sftpErrCancelled,
      FtpsErrorKind.tooLarge => t.sftpErrTooLarge,
      FtpsErrorKind.connection || FtpsErrorKind.closed || FtpsErrorKind.refused => t.sftpErrConnectionLost,
      FtpsErrorKind.local => detail == null ? t.sftpErrLocal : t.sftpErrLocalSaid(detail),
      FtpsErrorKind.reply when op == SftpOp.upload && error.notThere && detail == null => t.sftpErrDestinationGone,
      FtpsErrorKind.reply => detail == null ? t.sftpErrServerCode(error.code ?? 0) : t.sftpErrServerSaid(detail),
      _ => ftpsFailureText(t, error),
    };
  }

  if (error is SftpFileTooLargeException) {
    return t.sftpErrTooLarge;
  }

  // A name a shell other than a POSIX one could read as part of a command:
  // nothing was sent with it.
  if (error is SftpNameNotInCommandException) {
    return t.remoteNameNotInCommand;
  }

  // A device, a pipe or a socket: nothing of it comes down.
  if (error is SftpNotAFileException) {
    return t.sftpErrNotAFile(target);
  }

  // Another number of bytes at the far end than were sent: how many, and
  // that what arrived was not kept. (It said its own name, the whole path,
  // and the rest in English.)
  if (error is SftpIntegrityException) {
    return '${t.sftpErrCameShort(error.expected, error.actual)} ${t.sftpErrNotKept}';
  }

  // Written where it is, and broken off: what broke it off, and what that
  // leaves on the server. Where fewer bytes arrived than were sent, that is
  // the file with part of the new content, and not that nothing was touched.
  if (error is SftpWrittenInPlaceException) {
    final cause = error.cause;
    final why = cause is SftpIntegrityException
        ? t.sftpErrCameShort(cause.expected, cause.actual)
        : sftpErrorMessage(cause, name: name, op: op, l10n: t);
    return '${_asSentence(why)} ${t.sftpErrWrittenInPlace(target)}';
  }

  if (error is SftpStatusError) {
    switch (error.code) {
      case SftpStatusCode.noSuchFile:
        return op == SftpOp.upload
            // On upload this almost always means the destination directory
            // is gone, not the file we're writing.
            ? t.sftpErrDestinationGone
            : t.sftpErrGoneOnServer(target);
      case SftpStatusCode.permissionDenied:
        return op.denied(t, target);
      case SftpStatusCode.failure:
        // Code 4 is the protocol's catch-all. The server's own text is
        // usually the only signal (e.g. "Disk quota exceeded", "Directory
        // not empty"), so surface it when it says anything useful.
        final detail = _cleanServerText(error.message);
        if (detail != null) return t.sftpErrRefusedBecause(detail);
        return switch (op) {
          SftpOp.delete => t.sftpErrRefusedDelete(target),
          SftpOp.upload => t.sftpErrRefusedUpload,
          SftpOp.rename => t.sftpErrRefusedRename,
          _ => t.sftpErrRefusedOn(target),
        };
      case SftpStatusCode.badMessage:
        return t.sftpErrBadMessage;
      case SftpStatusCode.noConnection:
      case SftpStatusCode.connectionLost:
        return t.sftpErrConnectionLost;
      case SftpStatusCode.opUnsupported:
        return t.sftpErrUnsupported;
    }
    final detail = _cleanServerText(error.message);
    return detail == null ? t.sftpErrServerCode(error.code) : t.sftpErrServerSaid(detail);
  }

  if (error is SftpAbortError) {
    return t.sftpErrSessionClosed;
  }

  if (error is SftpExtensionUnsupportedError ||
      error is SftpExtensionVersionMismatchError) {
    return t.sftpErrUnsupported;
  }

  // Text where SFTP was to answer (a shell that prints when a session
  // starts): said as that, with what to look at. What came is in the report.
  if (error is SftpNotSftpError) {
    return t.sftpErrNotSftp;
  }

  // A folder past what a listing takes, or a server that says so of one.
  if (error is SftpListingTooLongError) {
    return t.sftpErrListingTooLong(error.maxNames);
  }

  if (error is SftpError) {
    final detail = _cleanServerText(error.message);
    return detail ?? t.sftpErrFailed;
  }

  // ── The connection under it ────────────────────────────────────
  if (_connectionLost(error)) {
    return t.sftpErrConnectionLost;
  }
  if (error is TimeoutException) {
    return t.sftpErrorTimeout;
  }

  // ── Local filesystem failures ──────────────────────────────────
  if (error is PathAccessException) {
    return t.sftpErrLocalDeniedHint(target);
  }
  if (error is PathNotFoundException) {
    return t.sftpErrGoneHere(target);
  }
  if (error is FileSystemException) {
    final os = error.osError;
    if (os != null) {
      // errno 28 (POSIX ENOSPC) / Windows 112 (ERROR_DISK_FULL).
      if (os.errorCode == 28 || os.errorCode == 112) {
        return t.sftpErrNoSpace;
      }
      // POSIX EACCES/EPERM, Windows ERROR_ACCESS_DENIED.
      if (os.errorCode == 13 || os.errorCode == 1 || os.errorCode == 5) {
        return t.sftpErrLocalDenied(target);
      }
      final detail = _cleanServerText(os.message);
      if (detail != null) return t.sftpErrLocalSaid(detail);
    }
    final detail = _cleanServerText(error.message);
    return detail == null ? t.sftpErrLocal : t.sftpErrLocalSaid(detail);
  }

  if (error is ArgumentError) {
    // Our own path-traversal / validation rejections land here.
    final detail = _cleanServerText(error.message?.toString());
    return detail == null ? t.sftpErrPathNotAllowed : t.sftpErrPathNotAllowedBecause(detail);
  }

  final detail = _cleanServerText(error.toString());
  return detail ?? t.sftpErrOperationFailed;
}

/// Why SFTP could not be started on a connection, [error] being what opening
/// it threw: the connection was lost, or the host did not start it (its
/// server may not offer SFTP, or may allow no more sessions). What it threw
/// belongs in the report.
String sftpStartFailure(Object error, {AppLocalizations? l10n}) {
  final t = l10n ?? gl10n;
  return _connectionLost(error) ? t.sftpErrConnectionLost : t.sftpStartRefused;
}

/// The network or the SSH connection under SFTP is gone. (What the system or
/// the library said, with the host's address in it, is for a report.)
bool _connectionLost(Object error) =>
    error is SocketException ||
    error is SSHSocketError ||
    // Given up because the host stopped answering.
    error is SSHNoAnswerError ||
    // Ended by the host itself, which the session says with its reason.
    error is SSHDisconnectError ||
    (error is SSHStateError && error.message.toLowerCase().contains('closed'));

/// A leading label naming what was thrown ("SftpError: ", "Exception: ",
/// "Bad state: "), which says nothing to the person reading.
final RegExp _label = RegExp(r'^(?:[A-Z][A-Za-z]*(?:Error|Exception)|Exception|Bad state)\s*:\s*');

/// What was thrown, written as its name around its words
/// ("SSHStateError(Transport is closed)").
final RegExp _wrapped = RegExp(r'^[A-Z][A-Za-z]*(?:Error|Exception)\((.*)\)$', dotAll: true);

/// Tidy a server- or OS-supplied message for display: trims, drops a
/// trailing period (the caller supplies punctuation), and rejects text that
/// is empty or just a class name so we don't show "Instance of ...".
String? _cleanServerText(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('Instance of')) return null;
  // Strip a redundant leading exception label ("SftpError: ...").
  final labelled = _label.firstMatch(s);
  if (labelled != null) s = s.substring(labelled.end).trim();
  final wrapped = _wrapped.firstMatch(s);
  if (wrapped != null) s = wrapped[1]!.trim();
  if (s.isEmpty) return null;
  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s.isEmpty ? null : s;
}
