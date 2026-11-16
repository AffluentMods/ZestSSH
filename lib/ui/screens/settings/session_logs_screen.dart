import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/settings_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../utils/platform_utils.dart';
import '../../widgets/redacted_text.dart';
import '../../widgets/responsive_scaffold.dart';
import '../../widgets/zest_dialog.dart';
import 'package:zestssh/utils/byte_size.dart';

/// The session log files on this device, newest first, with Share and
/// Delete. On a phone the log folder is the app's private documents area,
/// so this screen is the only way to get a log out.
///
/// File names carry the connection label, so they render through the
/// recording-mode mask like any other host name.
class SessionLogsScreen extends ConsumerStatefulWidget {
  const SessionLogsScreen({super.key});

  @override
  ConsumerState<SessionLogsScreen> createState() => _SessionLogsScreenState();
}

class _SessionLogsScreenState extends ConsumerState<SessionLogsScreen> {
  List<FileSystemEntity>? _files;

  Future<void> _load(String dir) async {
    List<FileSystemEntity> files = const [];
    try {
      files = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.log'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    } catch (_) {
      // A missing or unreadable folder simply lists nothing.
    }
    if (mounted) setState(() => _files = files);
  }

  Future<void> _delete(File f) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.delete,
      body: l10n.sessionLogDeleteConfirm,
      confirmLabel: l10n.delete,
    );
    if (ok != true) return;
    try {
      await f.delete();
    } catch (_) {
      // Already gone or locked by an open session: the list refresh shows
      // whichever it is.
    }
    if (!mounted) return;
    setState(() => _files = _files?.where((e) => e.path != f.path).toList());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dir = ref.watch(sessionLogEffectiveDirProvider);

    ref.listen<AsyncValue<String>>(sessionLogEffectiveDirProvider, (_, next) {
      final path = next.valueOrNull;
      if (path != null) _load(path);
    });
    if (_files == null && dir.hasValue) {
      // First build with a resolved folder: list it once.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _files == null) _load(dir.value!);
      });
    }

    final files = _files;
    return ResponsiveScaffold(
      title: l10n.settingsSessionLogBrowse,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: files == null
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
              ? _Empty(text: l10n.sessionLogsEmpty)
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: files.length + 1,
                  separatorBuilder: (_, i) =>
                      i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Text(
                          l10n.sessionLogSizeCount(files.length),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.v3TextTertiary,
                          ),
                        ),
                      );
                    }
                    final f = files[i - 1] as File;
                    final stat = f.statSync();
                    final name = f.uri.pathSegments.last;
                    return ListTile(
                      leading: const Icon(LucideIcons.fileText),
                      title: RedactedText(
                        Redactable.host(name),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${_size(stat.size)} · ${_when(stat.modified)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'JetBrainsMono',
                          color: AppColors.v3TextTertiary,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: l10n.sessionLogShare,
                            icon: const Icon(LucideIcons.share2, size: 20),
                            onPressed: () => Share.shareXFiles(
                              [XFile(f.path, mimeType: 'text/plain')],
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.delete,
                            icon: Icon(LucideIcons.trash2,
                                size: 20, color: AppColors.v3Error),
                            onPressed: () => _delete(f),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }

  static String _size(int bytes) => formatByteSize(bytes);

  static String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.fileText, size: 40, color: AppColors.v3TextTertiary),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
