import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/file_manager.dart';
import 'package:zestssh/utils/platform_utils.dart';

// A file was written (3.0 UI: every pop-up helpful): what was saved
// and where, readable and selectable, copied in one tap, and on a computer
// shown in the file manager. As the dialog rules of 3.4 have it: a green tick
// for done, the file's name first and its folder under it in the system's
// own style, Copy path an icon on the file, the actions in the footer, and a
// button that says Done.

/// Says a file was saved at [path]: [title], [message] under it, the file,
/// and Show in folder (a computer) and Done in the footer.
Future<void> showFileSavedDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String path,
}) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    // (Enter is Done: the button takes the keyboard as it opens.)
    child: Builder(
      builder: (ctx) => fileSavedShell(
        ctx,
        title: title,
        subtitle: message,
        path: path,
        onDone: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

/// The dialog of [showFileSavedDialog], on its own for a dialog that ends in
/// it in place (Export a backup: the same dialog, not a second one).
ZestDialogShell fileSavedShell(
  BuildContext context, {
  required String title,
  required String? subtitle,
  required String path,
  required VoidCallback onDone,
}) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell(
    size: ZestModalSize.compact,
    tone: ZestDialogTone.success,
    icon: LucideIcons.check,
    title: title,
    subtitle: subtitle,
    onClose: onDone,
    body: FileSavedBody(path: path, showInFolder: false),
    secondaryKey: const ValueKey('file-saved-show'),
    secondaryAction: isDesktopPlatform
        ? (label: l10n.fileSavedShowInFolder, onPressed: () => unawaited(revealFileInFileManager(path)))
        : null,
    primaryKey: const ValueKey('file-saved-done'),
    primaryAction: (label: l10n.done, icon: null, onPressed: onDone),
    autofocusPrimary: true,
  );
}

/// A saved file: its name first, the folder it is in under it, both in the
/// system's own style and selectable, with Copy path on it. [message], where
/// given, above it. [showInFolder]: a Show in folder link under it (a
/// computer), for a dialog whose footer has other work.
class FileSavedBody extends StatelessWidget {
  const FileSavedBody({super.key, this.message, required this.path, this.showInFolder = true});

  final String? message;
  final String path;
  final bool showInFolder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shown = systemPath(path);
    final parts = splitSystemPath(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message != null && message!.isNotEmpty) ...[
          Text(message!, style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary)),
          const SizedBox(height: 10),
        ],
        Container(
          key: const ValueKey('file-saved-path'),
          padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.file, size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      parts.name,
                      key: const ValueKey('file-saved-name'),
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                        color: AppColors.v3TextPrimary,
                      ),
                    ),
                    if (parts.folder.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      SelectableText(
                        parts.folder,
                        key: const ValueKey('file-saved-folder'),
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12,
                          height: 1.35,
                          color: AppColors.v3TextTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // A small icon on the file, so its name has the width.
              IconButton(
                key: const ValueKey('file-saved-copy'),
                tooltip: l10n.fileSavedCopyPath,
                iconSize: 15,
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(32),
                  minimumSize: const Size.square(32),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                color: AppColors.v3TextSecondary,
                icon: const Icon(LucideIcons.copy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: shown));
                  if (context.mounted) showTopSnackBar(context, l10n.fileSavedPathCopied, isSuccess: true);
                },
              ),
            ],
          ),
        ),
        if (showInFolder && isDesktopPlatform) ...[
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('file-saved-show'),
              onPressed: () => unawaited(revealFileInFileManager(path)),
              icon: const Icon(LucideIcons.folderOpen, size: 14),
              label: Text(l10n.fileSavedShowInFolder),
            ),
          ),
        ],
      ],
    );
  }
}
