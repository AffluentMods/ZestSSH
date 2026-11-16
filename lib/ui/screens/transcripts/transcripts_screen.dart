import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/l10n/time_text.dart';

/// The folder the list reads: the app's own folder of transcripts.
final transcriptsFolderProvider = FutureProvider<Directory>(
    (ref) async => Directory(await SessionTranscriptService.defaultTranscriptsDirPath()));

/// The transcripts saved on this device, to open and to delete (3.0, 17
/// October 2026). A recording a phone saved, or one a computer saved
/// encrypted, could be opened nowhere: nothing listed them, and nothing in
/// the app read one. A computer also opens one saved elsewhere.
class TranscriptsScreen extends ConsumerStatefulWidget {
  const TranscriptsScreen({super.key});

  @override
  ConsumerState<TranscriptsScreen> createState() => _TranscriptsScreenState();
}

class _TranscriptsScreenState extends ConsumerState<TranscriptsScreen> {
  late Future<List<SavedTranscript>> _list = _read();

  Future<List<SavedTranscript>> _read() async =>
      SessionTranscriptService.listSaved(folder: await ref.read(transcriptsFolderProvider.future));

  void _reload() => setState(() {
        _list = _read();
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The names are masked by a plain function: rebuilt when recording mode
    // flips.
    ref.watch(recordingModeProvider);
    return ResponsiveScaffold(
      title: l10n.transcriptsTitle,
      actions: [
        if (isDesktopPlatform)
          IconButton(
            key: const ValueKey('transcripts-open-file'),
            tooltip: l10n.transcriptsOpenFile,
            icon: const Icon(LucideIcons.folderOpen),
            onPressed: _openFile,
          ),
      ],
      body: FutureBuilder<List<SavedTranscript>>(
        future: _list,
        builder: (context, snap) {
          if (snap.hasError) {
            return LoadErrorState(
              message: l10n.transcriptsNotListed,
              where: 'Listing the saved transcripts',
              error: snap.error!,
              stack: snap.stackTrace,
              onRetry: _reload,
            );
          }
          final items = snap.data;
          if (items == null) return const Center(child: CircularProgressIndicator());
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.transcriptsEmpty,
                  key: const ValueKey('transcripts-empty'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _row(items[i], l10n),
          );
        },
      ),
    );
  }

  Widget _row(SavedTranscript t, AppLocalizations l10n) {
    final when = DateFormat.yMMMd(l10n.localeName).add_Hm().formatPlain(t.modified);
    final kind = t.encrypted ? l10n.transcriptsEncrypted : l10n.transcriptsPlainText;
    return ListTile(
      key: ValueKey('transcript-${t.name}'),
      leading: Icon(t.encrypted ? LucideIcons.lock : LucideIcons.fileText, color: AppColors.textSecondary),
      title: Text(Redactable.freeText(t.name).display, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$when · ${formatByteSize(t.size, l10n: l10n)} · $kind'),
      onTap: () => context.push(Routes.transcriptView, extra: t.path),
      trailing: IconButton(
        key: ValueKey('transcript-delete-${t.name}'),
        tooltip: l10n.delete,
        icon: const Icon(LucideIcons.trash2),
        onPressed: () => _delete(t),
      ),
    );
  }

  /// Deleted after asking: a transcript is the only copy of what a session
  /// printed.
  Future<void> _delete(SavedTranscript t) async {
    final l10n = AppLocalizations.of(context)!;
    final sure = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.transcriptsDeleteTitle,
      body: l10n.transcriptsDeleteBody(Redactable.freeText(t.name).display),
      confirmLabel: l10n.delete,
    );
    if (sure != true || !mounted) return;
    try {
      await File(t.path).delete();
    } catch (e) {
      if (mounted) showTopSnackBar(context, l10n.transcriptsNotDeleted, isError: true, details: '$e');
    }
    if (mounted) _reload();
  }

  /// A computer: a transcript saved anywhere, picked from its folder.
  Future<void> _openFile() async {
    final l10n = AppLocalizations.of(context)!;
    String? path;
    try {
      final folder = await ref.read(transcriptsFolderProvider.future);
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: l10n.transcriptsOpenFile,
        type: FileType.custom,
        allowedExtensions: const ['zesttx', 'txt'],
        initialDirectory: folder.path,
        lockParentWindow: true,
      );
      path = picked?.files.single.path;
    } catch (e) {
      if (mounted) showTopSnackBar(context, l10n.transcriptsPickerFailed, isError: true, details: '$e');
      return;
    }
    if (path == null || !mounted) return;
    await context.push(Routes.transcriptView, extra: path);
  }
}
