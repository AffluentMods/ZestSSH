import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SftpStatusCode, SftpStatusError;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart' show SftpWrittenInPlaceException;
import 'package:zestssh/services/sftp_transfer_safety.dart' show safeChildName;
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/sudo_runner.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart' show TransferItem;
import 'package:zestssh/ui/widgets/sudo_password_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Retry with sudo (3.4):
/// a move, copy, delete, rename,
/// new folder, upload or download that the host refused with "Permission
/// denied" says so with a Retry with sudo beside it, on a computer and on a
/// phone. It asks for the sudo password as Save as root does (typed each
/// time, never stored), once for everything that failed together, and runs
/// the same as root ([SudoFileOps]).

/// Whether [error] is the host refusing for want of permission
/// (SSH_FX_PERMISSION_DENIED), also where a file written in place ended so.
bool isPermissionDenied(Object error) => switch (error) {
  SftpStatusError(:final code) => code == SftpStatusCode.permissionDenied,
  SftpWrittenInPlaceException(:final cause) => isPermissionDenied(cause),
  _ => false,
};

/// Says that the host refused [ops] ("Not allowed: you don't have permission
/// for /etc/nginx/nginx.conf.", [shownPath] being what the one is called),
/// with Retry with sudo beside it where [sudo] is there and every path may
/// stand in a command line. [details] is what was thrown, for Copy details.
/// [onDone] runs once something was done as root (to list the folder again).
/// [partly]: what was asked was done in part, and [said] says how much (in
/// place of "Not allowed"), as a warning.
void offerSudoRetry(
  BuildContext context, {
  required SudoFileOps? sudo,
  required String host,
  required List<SudoFileOp> ops,
  required String shownPath,
  String? details,
  VoidCallback? onDone,
  String? said,
  bool partly = false,
}) {
  if (ops.isEmpty) return;
  final l10n = AppLocalizations.of(context)!;
  final message = said ??
      (ops.length == 1 ? l10n.sftpSudoDenied(shownPath) : l10n.sftpSudoDeniedMany(l10n.sftpItemCount(ops.length)));
  final canRetry = sudo != null && ops.every((o) => o.runnable);
  showTopSnackBar(
    context,
    message,
    isError: !partly,
    isWarning: partly,
    details: details,
    duration: canRetry ? const Duration(seconds: 12) : null,
    actionLabel: canRetry ? l10n.sftpSudoRetry : null,
    onAction: canRetry
        ? () {
            if (context.mounted) runSudoRetry(context, sudo: sudo, host: host, ops: ops, onDone: onDone);
          }
        : null,
  );
}

/// [op] as the dialog shows it, its paths masked while the screen is
/// recorded (the 3.4 security review, L3).
String _shownOp(SudoFileOp op) {
  var shown = op.shown;
  for (final p in op.remotePaths) {
    shown = shown.replaceAll(p, Redactable.path(p).display);
  }
  return shown;
}

/// Asks for the sudo password and runs [ops] as root with it, in order, as
/// one batch: sudo refusing (a wrong password, an account that may not, no
/// sudo, sudo wanting a terminal, no answer) is said in the dialog with its
/// code, and what is left runs with the password typed next; a command that
/// failed as root is said once all have run. [onDone] runs where anything
/// was done.
Future<void> runSudoRetry(
  BuildContext context, {
  required SudoFileOps sudo,
  required String host,
  required List<SudoFileOp> ops,
  VoidCallback? onDone,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final shownHost = Redactable.host(host).display;
  final left = [...ops];
  final failures = <({SudoFileOp op, Object error})>[];
  var done = 0;
  final finished = await askSudoPassword(
    context,
    title: l10n.sftpSudoTitle,
    subtitle: shownHost,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.sftpSudoBody(shownHost),
          key: const ValueKey('sftp-sudo-body'),
          style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: Container(
            key: const ValueKey('sftp-sudo-commands'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              border: Border.all(color: AppColors.v3BorderSubtle),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final op in ops)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Text(
                        'sudo ${_shownOp(op)}',
                        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: AppColors.v3TextPrimary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
    helperText: l10n.sftpSudoPasswordHelp,
    actionLabel: l10n.sftpSudoRun,
    run: (password) async {
      while (left.isNotEmpty) {
        final op = left.first;
        try {
          await sudo.run(op, password);
          done++;
        } on SudoFailedException catch (e) {
          // It ran as root and failed: said once all have run.
          failures.add((op: op, error: e));
        } on FileSystemException catch (e) {
          // This device could not keep a download.
          failures.add((op: op, error: e));
        }
        // (Anything else, sudo refusing or the connection, is said in the
        // dialog; this one and the rest wait for the next password.)
        left.removeAt(0);
      }
    },
    said: (e) => sudoRefusalSaid(e, l10n, host: shownHost) ?? sftpErrorMessage(e, l10n: l10n),
    fieldKey: const ValueKey('sftp-sudo-password'),
    primaryKey: const ValueKey('sftp-sudo-run'),
  );
  if (done > 0 || failures.isNotEmpty) onDone?.call();
  if (!finished || !context.mounted) return;
  final details = failures.isEmpty ? null : [for (final f in failures) '${f.error}'].join('\n');
  if (failures.isEmpty) {
    showTopSnackBar(context, l10n.sftpSudoDone(l10n.sftpItemCount(done)), isSuccess: true);
  } else if (done == 0 && failures.length == 1) {
    final e = failures.single.error;
    showTopSnackBar(
      context,
      l10n.sftpSudoFailed(e is SudoFailedException ? sudoWordsShown(e.said) : sftpErrorMessage(e, l10n: l10n)),
      isError: true,
      details: details,
    );
  } else {
    showTopSnackBar(
      context,
      l10n.sftpSudoSomeFailed(done, ops.length),
      isError: done == 0,
      isWarning: done > 0,
      details: details,
    );
  }
}

/// The command as root that does what the transfer [item] from [src] to
/// [dst] was to do: an upload, a download, or a copy within one host.
SudoFileOp sudoOpForTransfer(PaneFileSource src, PaneFileSource dst, TransferItem item) {
  // (A transfer item keeps where it came from as localPath, where it went as
  // remotePath, whichever end is which.)
  final srcHere = src is LocalPaneFileSource;
  final dstHere = dst is LocalPaneFileSource;
  if (!srcHere && !dstHere) return SudoCopy(item.localPath, item.remotePath);
  if (!srcHere) return SudoDownload(item.localPath, item.remotePath);
  return SudoUpload(item.localPath, item.remotePath);
}

/// What runs as root to put the folder [srcDir] of [src] at [destDir] of
/// [dst], where the host refused to make it: the folder copied with `cp -rp`
/// within one host; for an upload, the folder and each one in it made and
/// each file sent (what the person left out, [excluded], stays out). Null
/// for a download, or between two hosts.
List<SudoFileOp>? sudoOpsForFolder(
  PaneFileSource src,
  PaneFileSource dst,
  String srcDir,
  String destDir,
  Set<String> excluded,
) {
  final srcHere = src is LocalPaneFileSource;
  final dstHere = dst is LocalPaneFileSource;
  if (!srcHere && !dstHere) {
    return src.sharesBackendWith(dst) ? [SudoCopy(srcDir, destDir, folder: true)] : null;
  }
  if (!srcHere || dstHere) return null;
  final ops = <SudoFileOp>[SudoMkdir(destDir)];
  final files = <SudoFileOp>[];
  try {
    final walked = Directory(srcDir).listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final e in walked) {
      if (excluded.any((x) => e.path == x || p.isWithin(x, e.path))) continue;
      final rel = p.split(p.relative(e.path, from: srcDir)).map(safeChildName).join('/');
      final to = dst.join(destDir, rel);
      if (e is Directory) {
        ops.add(SudoMkdir(to));
      } else if (e is File) {
        files.add(SudoUpload(e.path, to));
      }
    }
  } on FileSystemException {
    return null;
  }
  return [...ops, ...files];
}
