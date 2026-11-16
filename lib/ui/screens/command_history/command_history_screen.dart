import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/command_history/history_demo.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/locked_feature_view.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/utils/line_breaks.dart';

/// Searchable, synced command history (Squeezed / Pro). Tapping an entry copies
/// it; entries can be deleted individually or cleared, and recording can be
/// switched off per device.
class CommandHistoryScreen extends ConsumerStatefulWidget {
  const CommandHistoryScreen({super.key, this.embedded = false});

  /// When true, render without a Scaffold/AppBar so the screen can sit inside
  /// a desktop section (the Terminal tools hub). The record + clear actions
  /// move to an inline toolbar row. Mobile keeps the default full screen.
  final bool embedded;

  @override
  ConsumerState<CommandHistoryScreen> createState() =>
      _CommandHistoryScreenState();
}

class _CommandHistoryScreenState extends ConsumerState<CommandHistoryScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final recording = ref.watch(commandHistoryEnabledProvider);
    final includeSensitive = ref.watch(commandHistoryIncludeSensitiveProvider);
    // Recording mode: Strict hides the history outright; Layout shows the
    // page with every command replaced by a stand-in (Redactable.command).
    final hidden = ref.watch(recordingModeProvider) &&
        ref.watch(recordingRedactLevelProvider) == RedactLevel.strict;
    final content = hidden
        ? ZestEmptyState(
            icon: LucideIcons.eyeOff,
            title: l10n.cmdhHiddenRecordingTitle,
            message: l10n.cmdhHiddenRecordingMessage,
          )
        : isPro
            ? _proBody(recording, includeSensitive)
            : _upgradeBody(context);
    final actions = isPro && !hidden
        ? _actions(recording, includeSensitive)
        : const <Widget>[];

    if (widget.embedded) {
      return Column(
        children: [
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            ),
          Expanded(child: content),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cmdhTitle),
        actions: actions.isEmpty ? null : actions,
      ),
      body: content,
    );
  }

  /// The record toggle + overflow (secrets opt-in, clear all), shared by the
  /// AppBar (mobile) and the inline toolbar (embedded desktop).
  List<Widget> _actions(bool recording, bool includeSensitive) {
    final l10n = AppLocalizations.of(context)!;
    return [
      IconButton(
        tooltip: recording ? l10n.cmdhRecordingOn : l10n.cmdhRecordingOff,
        icon: Icon(
          recording ? LucideIcons.circle : LucideIcons.pause,
          color:
              recording ? AppColors.v3AccentInk : AppColors.textSecondary,
        ),
        onPressed: () =>
            ref.read(commandHistoryEnabledProvider.notifier).set(!recording),
      ),
      PopupMenuButton<String>(
        icon: const Icon(LucideIcons.moreHorizontal),
        onSelected: (v) {
          switch (v) {
            case 'sensitive':
              ref
                  .read(commandHistoryIncludeSensitiveProvider.notifier)
                  .set(!includeSensitive);
            case 'suggest':
              ref
                  .read(historySuggestionsProvider.notifier)
                  .set(!ref.read(historySuggestionsProvider));
            case 'clear':
              _confirmClear();
          }
        },
        itemBuilder: (_) => [
          // The secrets opt-in only appears once recording is on.
          if (recording)
            CheckedPopupMenuItem(
              value: 'sensitive',
              checked: includeSensitive,
              child: Text(l10n.cmdhSaveSecretCommands),
            ),
          // Suggestions as you type draw on what is recorded (3.0).
          CheckedPopupMenuItem(
            key: const ValueKey('cmdh-suggest'),
            value: 'suggest',
            checked: ref.read(historySuggestionsProvider),
            child: Text(l10n.cmdhSuggestAsYouType),
          ),
          PopupMenuItem(value: 'clear', child: Text(l10n.commonClearAll)),
        ],
      ),
    ];
  }

  /// Before Squeezed: the page in use, faded, with made-up commands, and
  /// what it gives (4.0). It was a line and Upgrade.
  Widget _upgradeBody(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final demo = demoHistoryEntries(DateTime.now());
    return LockedFeatureView(
      icon: LucideIcons.history,
      title: l10n.lockedHistoryTitle,
      benefits: lockedHistoryBenefits(l10n),
      preview: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        itemCount: demo.length,
        itemBuilder: (context, i) => _HistoryTile(demo[i], onCopy: () {}, onDelete: () {}),
      ),
    );
  }

  Widget _proBody(bool recording, bool includeSensitive) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        if (!recording) _banner(
          icon: LucideIcons.pause,
          // Its last two words on one line ("saved." was alone on a
          // phone's: found in a design audit).
          text: noOrphan(l10n.cmdhRecordingOffBanner),
          tone: AppColors.textSecondary,
          action: TextButton(
            onPressed: () =>
                ref.read(commandHistoryEnabledProvider.notifier).set(true),
            child: Text(l10n.cmdhTurnOn),
          ),
        )
        else if (includeSensitive) _banner(
          icon: LucideIcons.alertTriangle,
          text: l10n.cmdhSavingSecretsBanner,
          tone: AppColors.warning,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: l10n.cmdhSearchCommands,
              prefixIcon: const Icon(LucideIcons.search, size: 20),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      tooltip: AppLocalizations.of(context)!.emptyClearSearch,
                      icon: const Icon(LucideIcons.x, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
              isDense: true,
              filled: true,
              fillColor: AppColors.surfaceLight,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: _query.trim().isEmpty ? _recentList() : _searchList(),
        ),
      ],
    );
  }

  Widget _banner({
    required IconData icon,
    required String text,
    required Color tone,
    Widget? action,
  }) {
    return Container(
      width: double.infinity,
      color: tone.withValues(alpha: 0.10),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, color: tone)),
          ),
          ?action,
        ],
      ),
    );
  }

  Widget _recentList() {
    final l10n = AppLocalizations.of(context)!;
    final async = ref.watch(recentCommandHistoryProvider);
    return async.when(
      // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Text(l10n.cmdhCouldNotLoad,
            style: TextStyle(color: AppColors.textSecondary)),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return ZestEmptyState(
            icon: LucideIcons.history,
            title: l10n.cmdhNoHistoryTitle,
            message: l10n.cmdhNoHistoryMessage,
          );
        }
        return _list(entries);
      },
    );
  }

  Widget _searchList() {
    final l10n = AppLocalizations.of(context)!;
    // Under recording mode the DB search would match real commands the
    // screen never shows, so search the stand-in text instead.
    if (ref.watch(recordingModeProvider)) {
      final q = _query.trim().toLowerCase();
      final entries = (ref.watch(recentCommandHistoryProvider).valueOrNull ??
              const <CommandHistoryEntry>[])
          .where((e) => Redactable.command(e.command)
              .displayIn(ref)
              .toLowerCase()
              .contains(q))
          .toList(growable: false);
      if (entries.isEmpty) {
        return ZestEmptyState(icon: LucideIcons.searchX, title: l10n.cmdhNoMatches);
      }
      return _list(entries);
    }
    return FutureBuilder<List<CommandHistoryEntry>>(
      future: ref.read(commandHistoryDaoProvider).search(_query),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snap.data!;
        if (entries.isEmpty) {
          return ZestEmptyState(
            icon: LucideIcons.searchX,
            title: l10n.cmdhNoMatches,
          );
        }
        return _list(entries);
      },
    );
  }

  Widget _list(List<CommandHistoryEntry> entries) {
    // Copy would carry the REAL command out of a list that only shows
    // stand-ins, so it is off while recording (delete stays).
    final recording = ref.watch(recordingModeProvider);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: entries.length,
      itemBuilder: (context, i) => _HistoryTile(
        entries[i],
        onCopy: recording ? null : () => _copy(entries[i].command),
        onDelete: () =>
            ref.read(commandHistoryDaoProvider).deleteEntry(entries[i].id),
      ),
    );
  }

  Future<void> _copy(String command) async {
    if (ref.read(recordingModeProvider)) return;
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: command));
    if (mounted) showTopSnackBar(context, l10n.cmdhCommandCopied);
  }

  Future<void> _confirmClear() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.cmdhClearDialogTitle,
      body: l10n.cmdhClearDialogBody,
      confirmLabel: l10n.commonClearAll,
    );
    if (ok == true) {
      await ref.read(commandHistoryDaoProvider).clearAll();
    }
  }
}

class _HistoryTile extends StatelessWidget {
  final CommandHistoryEntry entry;

  /// Null while recording mode is on: the tile does not copy.
  final VoidCallback? onCopy;
  final VoidCallback onDelete;

  const _HistoryTile(this.entry, {required this.onCopy, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final host = entry.hostLabel;
    final metaStyle =
        TextStyle(fontSize: 11.5, color: AppColors.textSecondary);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onCopy,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Redactable: recording mode masks any fleet host/address
                    // that appears in the command (e.g. `ssh user@host`).
                    RedactedText(
                      Redactable.command(entry.command),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 13,
                        height: 1.3,
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        if (host != null && host.isNotEmpty) ...[
                          Flexible(
                            child: RedactedText(
                              Redactable.host(host),
                              overflow: TextOverflow.ellipsis,
                              style: metaStyle,
                            ),
                          ),
                          Text('  ·  ', style: metaStyle),
                        ],
                        Text(_ago(entry.createdAt, l10n), style: metaStyle),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(LucideIcons.copy, size: 18),
                tooltip: onCopy == null ? l10n.cmdhOffWhileRecording : l10n.copy,
                onPressed: onCopy,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: Icon(LucideIcons.trash2,
                    size: 18, color: AppColors.textSecondary),
                tooltip: l10n.delete,
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// When a command ran, after its host and a dot: the shared compact words
  /// begun small, weeks under five, then its date.
  static String _ago(DateTime t, AppLocalizations l10n) {
    if (DateTime.now().difference(t).inDays < 35) return timeAgoInSentence(l10n, t, keepCounting: true);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}
