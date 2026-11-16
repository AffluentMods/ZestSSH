import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// How a save attempt ended.
enum TranscriptSaveOutcome { saved, cancelled, failed }

/// The desktop transcript flows, shared by the session bar's overflow menu
/// and the terminal's context menu so both offer the same three things and
/// neither can lose a recording:
///
///  * save what the terminal holds right now (scrollback and screen), whether
///    or not anything is being recorded;
///  * record from now on;
///  * stop recording, which SAVES the recording first. Stopping used to throw
///    the recording away unless the user had already exported it, with no
///    word about where anything went.
///
/// Every save goes through the OS "Save As" dialog (the destination is the
/// user's choice, so they know where the file is), then a toast with a
/// "Show in folder" action and an entry in the notification centre.
class TranscriptActions {
  TranscriptActions._();

  /// Start recording [sessionId] from now, and say what stopping does.
  static void startRecording(
      BuildContext context, String sessionId, String connectionLabel) {
    SessionTranscriptService.startRecording(sessionId, connectionLabel);
    showTopSnackBar(
        context, AppLocalizations.of(context)!.transcriptRecordingStarted);
  }

  /// Save the active recording, then stop it. A cancelled dialog or a failed
  /// write keeps the recording running so nothing is lost.
  static Future<void> stopAndSaveRecording(
      BuildContext context, WidgetRef ref, String sessionId) async {
    if (!SessionTranscriptService.isRecording(sessionId)) return;
    final outcome = await saveRecording(context, ref, sessionId);
    if (!context.mounted) return;
    switch (outcome) {
      case TranscriptSaveOutcome.saved:
        SessionTranscriptService.stopRecording(sessionId);
      case TranscriptSaveOutcome.cancelled:
        showTopSnackBar(context,
            AppLocalizations.of(context)!.transcriptRecordingContinues);
      case TranscriptSaveOutcome.failed:
        break; // the error toast already said so; still recording
    }
  }

  /// Save the active recording to a user-chosen file without stopping it.
  static Future<TranscriptSaveOutcome> saveRecording(
      BuildContext context, WidgetRef ref, String sessionId) {
    if (!SessionTranscriptService.isRecording(sessionId)) {
      showTopSnackBar(context,
          AppLocalizations.of(context)!.desktopTerminalAreaNothingToSave);
      return Future.value(TranscriptSaveOutcome.failed);
    }
    return _saveAs(
      context,
      ref,
      fileLabel: SessionTranscriptService.recordingLabel(sessionId),
      write: (path, encrypt) =>
          SessionTranscriptService.saveToPath(sessionId, path, encrypt: encrypt),
    );
  }

  /// Save everything the terminal currently holds, scrollback included, to a
  /// user-chosen file. Works whether or not the session is being recorded.
  static Future<TranscriptSaveOutcome> saveBufferSoFar(
    BuildContext context,
    WidgetRef ref, {
    required String connectionLabel,
    required dynamic terminal,
  }) {
    final text = SessionTranscriptService.getBufferText(terminal);
    if (text.trim().isEmpty) {
      showTopSnackBar(
          context, AppLocalizations.of(context)!.transcriptNothingToSave);
      return Future.value(TranscriptSaveOutcome.failed);
    }
    final transcript = SessionTranscriptService.bufferAsTranscript(terminal,
        connectionLabel: connectionLabel);
    return _saveAs(
      context,
      ref,
      fileLabel: connectionLabel,
      write: (path, encrypt) => SessionTranscriptService.saveTextToPath(
          transcript, path,
          encrypt: encrypt),
    );
  }

  /// Ask encrypted or plain, open Save As, write through [write], then
  /// confirm with a "Show in folder" toast and a notification-centre entry.
  static Future<TranscriptSaveOutcome> _saveAs(
    BuildContext context,
    WidgetRef ref, {
    required String? fileLabel,
    required Future<String?> Function(String path, bool encrypt) write,
  }) async {
    final l10n = AppLocalizations.of(context)!;

    // Ask encrypt vs plain text (with a warning) BEFORE the location picker,
    // so the user chooses how it is stored and where it goes.
    final encrypt = await _askEncryption(context);
    if (encrypt == null) return TranscriptSaveOutcome.cancelled;
    if (!context.mounted) return TranscriptSaveOutcome.cancelled;

    final initialDir =
        await SessionTranscriptService.defaultTranscriptsDirPath();
    if (!context.mounted) return TranscriptSaveOutcome.cancelled;

    String? targetPath;
    try {
      targetPath = await FilePicker.platform.saveFile(
        dialogTitle: l10n.desktopTerminalAreaSaveTranscriptDialogTitle,
        fileName: SessionTranscriptService.suggestedFileNameFor(fileLabel,
            encrypt: encrypt),
        initialDirectory: initialDir,
        lockParentWindow: true,
      );
    } catch (e) {
      if (!context.mounted) return TranscriptSaveOutcome.failed;
      showTopSnackBar(
        context,
        l10n.desktopTerminalAreaSaveDialogError,
        isError: true,
        details: e.toString(),
      );
      return TranscriptSaveOutcome.failed;
    }
    if (targetPath == null) return TranscriptSaveOutcome.cancelled;

    final savedPath = await write(targetPath, encrypt);
    if (!context.mounted) {
      return savedPath == null
          ? TranscriptSaveOutcome.failed
          : TranscriptSaveOutcome.saved;
    }
    if (savedPath == null) {
      // With what stopped it to copy (it was only logged).
      showTopSnackBar(
        context,
        l10n.desktopTerminalAreaSaveTranscriptError,
        isError: true,
        details: '${SessionTranscriptService.lastSaveError ?? 'Not saved'}',
      );
      return TranscriptSaveOutcome.failed;
    }

    // The suggested file name embeds the host label, so the painted path
    // goes through the free-text rule; the reveal action uses the real path.
    final shownPath = Redactable.freeText(savedPath).display;
    showTopSnackBar(
      context,
      encrypt
          ? l10n.terminalExportSaved(shownPath)
          : l10n.desktopTerminalAreaSavedAsPlainText(shownPath),
      isSuccess: true,
      actionLabel: l10n.desktopTerminalAreaShowInFolder,
      // A folder that does not open is said (it was
      // swallowed).
      onAction: () async {
        if (await revealInFileManager(savedPath) || !context.mounted) return;
        showTopSnackBar(context, l10n.logViewCouldNotOpenFolder, isError: true, details: savedPath);
      },
    );
    // The toast passes; the bell keeps the path.
    ref
        .read(notificationCenterProvider.notifier)
        .success(l10n.transcriptSavedTitle, body: shownPath);
    return TranscriptSaveOutcome.saved;
  }

  /// Ask whether to encrypt the saved transcript or write it as plain text.
  /// Returns true (encrypt), false (plain text), or null (cancelled). Plain
  /// text carries a visible warning because a transcript can hold passwords,
  /// keys, or other sensitive output the session printed.
  static Future<bool?> _askEncryption(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The app's dialog (the dialog rules, 3.4): Encrypt is the main button;
    // plain text, never the easy way, is the side option bottom left, with
    // what it means in its amber sentence.
    return showZestModal<bool>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.fileText,
          title: l10n.desktopTerminalAreaSaveTranscript,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.desktopTerminalAreaEncryptExplain,
                style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
              ),
              const SizedBox(height: 12),
              ZestCallout(l10n.desktopTerminalAreaPlainTextWarning),
            ],
          ),
          tertiaryKey: const ValueKey('transcript-plain-text'),
          tertiaryAction: (label: l10n.desktopTerminalAreaPlainText, onPressed: () => Navigator.pop(ctx, false)),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(ctx)),
          primaryKey: const ValueKey('transcript-encrypt'),
          primaryAction: (label: l10n.desktopTerminalAreaEncrypt, icon: null, onPressed: () => Navigator.pop(ctx, true)),
        ),
      ),
    );
  }

  /// Reveal [path] in the desktop file manager, highlighting the file where
  /// the platform supports it (Explorer `/select` on Windows, Finder `-R` on
  /// macOS) or opening its containing folder (Linux). False when that could
  /// not be done (the program is missing, or says it failed), for the caller
  /// to say so. Explorer's exit code means nothing and is not read.
  static Future<bool> revealInFileManager(String path) async {
    try {
      if (Platform.isWindows) {
        // Explorer wants backslashes and returns a non-zero exit code even
        // on success, so we normalise the path and ignore the exit code.
        final winPath = path.replaceAll('/', r'\');
        await Process.run(windowsExplorer, ['/select,', winPath]);
        return true;
      } else if (Platform.isMacOS) {
        return (await Process.run('open', ['-R', path])).exitCode == 0;
      } else if (Platform.isLinux) {
        // No portable "select the file" on Linux; open its folder instead.
        return (await Process.run('xdg-open', [File(path).parent.path])).exitCode == 0;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
