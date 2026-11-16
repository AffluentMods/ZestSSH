import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/command_history/history_demo.dart';
import 'package:zestssh/features/command_history/history_table.dart';
import 'package:zestssh/features/snippets/run_snippet.dart' show runCommandOnHost;
import 'package:zestssh/features/snippets/save_snippet.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/zest_page_header.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/locked_feature_view.dart';
import 'package:zestssh/l10n/time_text.dart';

/// How the History page runs a command again on a host: the way a snippet
/// runs ([runCommandOnHost]: the risky-command check and its questions, in
/// the host's open session or in one opened to it), exactly as it was typed:
/// a `${...}` in it is part of the command, never a snippet's question. A
/// seam so a test can see what was asked for.
typedef HistoryRunOnHost = Future<bool> Function(
  BuildContext context,
  WidgetRef ref, {
  required ConnectionWithDetails host,
  required String command,
});

final historyRunOnHostProvider = Provider<HistoryRunOnHost>(
  (_) => (context, ref, {required host, required command}) =>
      runCommandOnHost(context, ref, host: host, command: command, literal: true),
);

// The table's columns, left to right after the command (which takes the rest).
const double _hostW = 150;
const double _folderW = 180;
const double _resultW = 92;
const double _tookW = 68;
const double _timeW = 52;
const double _gap = 16;

/// A computer's History page (3.0):
/// one full-width table of the commands run in terminals, grouped by day,
/// newest first. Each row: the host, the command (with how many times it
/// ran in a row), the folder, the result, how long it took and when. Folder,
/// result and run time come from the host's shell integration and stay
/// empty where it sent none. Trivial commands (cd, ls, clear...) are hidden
/// per day behind a line that names them, with Show. Under the mouse a row
/// offers Run again, Copy and Save as snippet; a click opens it: when it
/// started, the full folder, Delete, Save as snippet and Run again on its
/// host.
class HistoryView extends ConsumerStatefulWidget {
  const HistoryView({super.key});

  @override
  ConsumerState<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends ConsumerState<HistoryView> {
  final _search = TextEditingController();
  String _query = '';

  /// The host shown ([historyHostKey]); empty for every host.
  String _host = '';
  bool _hideTrivial = true;
  bool _failedOnly = false;

  /// The days whose trivial commands were shown with Show.
  final Set<DateTime> _shownDays = {};

  /// The row opened by a click, by its entry's id.
  String? _openId;

  @override
  void initState() {
    super.initState();
    // Opened by a link for one host (the Inspector's History).
    final wanted = ref.read(historyHostWantedProvider);
    if (wanted != null) {
      _host = wanted;
      Future.microtask(() => ref.read(historyHostWantedProvider.notifier).state = null);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The page is kept while another is in front: a link for one host that
    // comes then shows that host.
    ref.listen<String?>(historyHostWantedProvider, (_, wanted) {
      if (wanted == null) return;
      setState(() {
        _host = wanted;
        _openId = null;
      });
      Future.microtask(() => ref.read(historyHostWantedProvider.notifier).state = null);
    });
    final isPro = ref.watch(isProProvider);
    // Recording mode: Strict hides the history outright (a command can say
    // anything about the setup); Layout keeps the page but every command,
    // host and folder is a harmless stand-in.
    final hidden = ref.watch(recordingModeProvider) &&
        ref.watch(recordingRedactLevelProvider) == RedactLevel.strict;
    final entries = ref.watch(recentCommandHistoryProvider).valueOrNull ??
        const <CommandHistoryEntry>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestPageBand(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
            child: _header(l10n, entries, tools: isPro && !hidden),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: ZestTokens.surfaceBase,
            child: hidden
                ? ZestEmptyState(
                    icon: LucideIcons.eyeOff,
                    title: l10n.cmdhHiddenRecordingTitle,
                    message: l10n.cmdhHiddenRecordingMessage,
                  )
                : isPro
                    ? _body(l10n, entries)
                    // Before Squeezed: the page in use, faded, with
                    // made-up commands, and what it gives (4.0).
                    // It was a line and Upgrade.
                    : LockedFeatureView(
                        icon: LucideIcons.history,
                        title: l10n.lockedHistoryTitle,
                        benefits: lockedHistoryBenefits(l10n),
                        preview: _table(l10n, demoHistoryEntries(DateTime.now())),
                      ),
          ),
        ),
      ],
    );
  }

  // ── Header, toolbar and banners ────────────────────────────────────────

  /// The hosts the history names, for the host picker: by saved host where
  /// there is one, by the name it was recorded under otherwise, by name. A
  /// host picked that the history no longer names is let go.
  List<MapEntry<String, String>> _hostItems(List<CommandHistoryEntry> entries) {
    final hosts = <String, String>{};
    for (final e in entries) {
      final key = historyHostKey(e);
      final label = e.hostLabel;
      if (key != null && label != null && label.isNotEmpty) hosts.putIfAbsent(key, () => label);
    }
    if (_host.isNotEmpty && !hosts.containsKey(_host)) _host = '';
    return hosts.entries.toList()..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
  }

  /// The title and, with [tools], the search, the host picker, Hide trivial,
  /// Failed only and the page's menu: on one row where the pane is wide,
  /// the tools under the title where not.
  Widget _header(AppLocalizations l10n, List<CommandHistoryEntry> entries, {required bool tools}) {
    final title = Text(
      l10n.histPageTitle,
      style: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: ZestTokens.textPrimary,
        height: 1.2,
      ),
    );
    if (!tools) return Row(children: [title]);
    final hostItems = _hostItems(entries);
    final search = ZestListSearchField(
      controller: _search,
      hintText: l10n.cmdhSearchCommands,
      onChanged: (v) => setState(() => _query = v),
    );
    final filters = <Widget>[
      SizedBox(
        width: 190,
        child: ZestSelect<String>(
          key: const ValueKey('history-host-filter'),
          value: _host,
          items: [
            ZestSelectItem('', l10n.commonAllHosts),
            for (final h in hostItems) ZestSelectItem(h.key, Redactable.host(h.value).displayIn(ref)),
          ],
          onChanged: (v) => setState(() => _host = v),
        ),
      ),
      const SizedBox(width: ZestSizing.buttonGap),
      _FilterToggle(
        key: const ValueKey('history-hide-trivial'),
        label: l10n.histPageHideTrivial,
        value: _hideTrivial,
        onChanged: (v) => setState(() => _hideTrivial = v),
      ),
      const SizedBox(width: ZestSizing.buttonGap),
      _FilterToggle(
        key: const ValueKey('history-failed-only'),
        label: l10n.histPageFailedOnly,
        value: _failedOnly,
        onChanged: (v) => setState(() => _failedOnly = v),
      ),
    ];
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 980) {
        return Row(
          children: [
            title,
            const SizedBox(width: 16),
            Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: search)),
            const SizedBox(width: ZestSizing.buttonGap),
            ...filters,
            const Spacer(),
            const SizedBox(width: 12),
            _overflow(l10n),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [Expanded(child: title), _overflow(l10n)]),
          const SizedBox(height: 10),
          Row(children: [Expanded(child: search), const SizedBox(width: ZestSizing.buttonGap), ...filters]),
        ],
      );
    });
  }

  Widget _body(AppLocalizations l10n, List<CommandHistoryEntry> entries) {
    final recording = ref.watch(commandHistoryEnabledProvider);
    final secrets = ref.watch(commandHistoryIncludeSensitiveProvider);

    // Search what is on screen: while recording that is the stand-in text,
    // so a query never reveals a real command by matching it.
    final q = _query.trim().toLowerCase();
    final filtered = [
      for (final e in entries)
        if ((q.isEmpty || Redactable.command(e.command).displayIn(ref).toLowerCase().contains(q)) &&
            (_host.isEmpty || historyHostKey(e) == _host) &&
            (!_failedOnly || (e.exitCode != null && e.exitCode != 0)))
          e,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!recording)
          _offBanner(l10n)
        else if (secrets)
          _secretsBanner(l10n),
        _trustLine(l10n, secrets && recording),
        Expanded(
          child: entries.isEmpty
              ? ZestEmptyState(
                  icon: LucideIcons.history,
                  title: l10n.cmdhNoHistoryTitle,
                  message: l10n.cmdhNoHistoryMessage,
                )
              : filtered.isEmpty
                  ? ZestEmptyState(icon: LucideIcons.searchX, title: l10n.cmdhNoMatches)
                  : _table(l10n, filtered),
        ),
      ],
    );
  }

  Widget _overflow(AppLocalizations l10n) {
    final recording = ref.watch(commandHistoryEnabledProvider);
    return PopupMenuButton<String>(
      tooltip: l10n.zestCommonMoreActions,
      onSelected: (v) {
        if (v == 'recording') {
          ref.read(commandHistoryEnabledProvider.notifier).set(!recording);
        } else if (v == 'sensitive') {
          ref
              .read(commandHistoryIncludeSensitiveProvider.notifier)
              .set(!ref.read(commandHistoryIncludeSensitiveProvider));
        } else if (v == 'suggest') {
          ref.read(historySuggestionsProvider.notifier).set(!ref.read(historySuggestionsProvider));
        } else if (v == 'clear') {
          _confirmClear(l10n);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'recording',
          child: Text(recording ? l10n.cmdhRecordingOn : l10n.cmdhRecordingOff),
        ),
        // Commands that look like they hold a secret, saved too: only while
        // recording, as on a phone.
        if (recording)
          CheckedPopupMenuItem(
            key: const ValueKey('history-sensitive'),
            value: 'sensitive',
            checked: ref.read(commandHistoryIncludeSensitiveProvider),
            child: Text(l10n.cmdhSaveSecretCommands),
          ),
        CheckedPopupMenuItem(
          key: const ValueKey('history-suggest'),
          value: 'suggest',
          checked: ref.read(historySuggestionsProvider),
          child: Text(l10n.cmdhSuggestAsYouType),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'clear', child: Text(l10n.commonClearAll)),
      ],
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.border),
        ),
        child: Icon(LucideIcons.moreHorizontal, size: 16, color: ZestTokens.textSecondary),
      ),
    );
  }

  /// A box on the page, under the toolbar: raised a step, a hairline round it.
  Widget _box({required Key? key, required Widget child, Color? edge}) => Container(
        key: key,
        margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        constraints: const BoxConstraints(minHeight: 40),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: edge ?? ZestTokens.borderSubtle),
        ),
        child: child,
      );

  /// What is saved and what never is, in one line, with the long answer a
  /// click away.
  Widget _trustLine(AppLocalizations l10n, bool savingSecrets) => _box(
        key: const ValueKey('history-trust-line'),
        child: Row(
          children: [
            Icon(LucideIcons.shieldCheck, size: 15, color: ZestTokens.statusHealthy),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                savingSecrets ? l10n.histPageTrustSecretsOn : l10n.histPageTrust,
                style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary, height: 1.35),
              ),
            ),
            const SizedBox(width: 8),
            ZestButton(
              key: const ValueKey('history-how'),
              label: l10n.histPageHowItWorks,
              variant: ZestButtonVariant.ghost,
              onPressed: () => _showHowItWorks(l10n),
            ),
          ],
        ),
      );

  Widget _offBanner(AppLocalizations l10n) => _box(
        key: const ValueKey('history-off-banner'),
        child: Row(
          children: [
            Icon(LucideIcons.pause, size: 15, color: ZestTokens.textTertiary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l10n.cmdhRecordingOffBanner,
                  style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
            ),
            ZestButton(
              label: l10n.cmdhTurnOn,
              onPressed: () => ref.read(commandHistoryEnabledProvider.notifier).set(true),
            ),
          ],
        ),
      );

  /// While commands that look like they hold a secret are saved too.
  Widget _secretsBanner(AppLocalizations l10n) => _box(
        key: const ValueKey('history-secrets-banner'),
        edge: ZestTokens.statusWarning.withValues(alpha: 0.5),
        child: Row(
          children: [
            Icon(LucideIcons.alertTriangle, size: 15, color: ZestTokens.statusWarning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l10n.cmdhSavingSecretsBanner,
                  style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
            ),
          ],
        ),
      );

  Future<void> _showHowItWorks(AppLocalizations l10n) {
    Widget point(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, right: 10),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(color: ZestTokens.textTertiary, shape: BoxShape.circle),
                ),
              ),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
              ),
            ],
          ),
        );
    return ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.shieldCheck,
      title: l10n.histPageHowItWorks,
      body: Column(
        key: const ValueKey('history-how-body'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          point(l10n.histPageHow1),
          point(l10n.histPageHow2),
          point(l10n.histPageHow3),
          point(l10n.histPageHow4(l10n.cmdhSaveSecretCommands)),
          point(l10n.histPageHow5),
          point(l10n.histPageHow6),
        ],
      ),
    );
  }

  // ── The table ──────────────────────────────────────────────────────────

  Widget _table(AppLocalizations l10n, List<CommandHistoryEntry> entries) {
    final days = groupHistoryByDay(entries);
    final users = _usersByConnection();
    final items = <Widget>[];
    for (final day in days) {
      items.add(Padding(
        key: ValueKey('history-day-${_dayKey(day.day)}'),
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 0),
        child: ZestSectionHeader.category(label: _dayLabel(l10n, day.day), count: day.count),
      ));
      final trivial = day.trivialRuns;
      final hiding = _hideTrivial && trivial.isNotEmpty && !_shownDays.contains(day.day);
      if (_hideTrivial && trivial.isNotEmpty) {
        items.add(_trivialLine(l10n, day, trivial, hiding));
      }
      for (final run in day.runs) {
        if (hiding && run.trivial) continue;
        items.add(_HistoryRow(
          key: ValueKey('history-row-${run.entry.id}'),
          run: run,
          open: _openId == run.entry.id,
          user: users[run.entry.connectionId],
          onToggle: () => setState(() => _openId = _openId == run.entry.id ? null : run.entry.id),
          actions: this,
        ));
      }
    }
    return LayoutBuilder(builder: (context, box) {
      // A narrow window drops the folder first: the command keeps its room.
      final wide = box.maxWidth >= 920;
      return _Columns(
        wide: wide,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 2),
              child: _HeaderRow(l10n: l10n),
            ),
            Expanded(
              child: ZestScrollFade(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
                  children: items,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  /// The line at the top of a day whose trivial commands are hidden (or
  /// were shown): how many, on which host where they all ran on one, the
  /// first few, and Show (or Hide).
  Widget _trivialLine(AppLocalizations l10n, HistoryDay day, List<HistoryRun> trivial, bool hiding) {
    final count = trivial.fold<int>(0, (n, r) => n + r.repeat);
    final String text;
    if (hiding) {
      final distinct = <String>[];
      for (final r in trivial) {
        final shown = Redactable.command(r.entry.command).displayIn(ref);
        if (!distinct.contains(shown)) distinct.add(shown);
      }
      final examples = distinct.length > 3 ? '${distinct.take(3).join(', ')}, …' : distinct.join(', ');
      final hostKeys = {for (final r in trivial) historyHostKey(r.entry)};
      final label = trivial.first.entry.hostLabel;
      text = hostKeys.length == 1 && label != null && label.isNotEmpty
          ? l10n.histPageTrivialHiddenOnHost(count, Redactable.host(label).displayIn(ref), examples)
          : l10n.histPageTrivialHidden(count, examples);
    } else {
      text = l10n.histPageTrivialShown(count);
    }
    return Padding(
      key: ValueKey('history-trivial-${_dayKey(day.day)}'),
      padding: const EdgeInsets.fromLTRB(12, 6, 0, 2),
      child: Row(
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
            ),
          ),
          const SizedBox(width: 6),
          ZestButton(
            key: ValueKey('history-trivial-toggle-${_dayKey(day.day)}'),
            label: hiding ? l10n.histPageShow : l10n.histPageHide,
            variant: ZestButtonVariant.ghost,
            onPressed: () => setState(() {
              if (hiding) {
                _shownDays.add(day.day);
              } else {
                _shownDays.remove(day.day);
              }
            }),
          ),
        ],
      ),
    );
  }

  /// The user each saved host signs in as, by its id: its home folder is
  /// written `~` in the folder column.
  Map<String?, String?> _usersByConnection() {
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    return {for (final c in all) c.connection.id: c.identity?.username};
  }

  ConnectionWithDetails? _hostOf(CommandHistoryEntry e) {
    final id = e.connectionId;
    if (id == null) return null;
    for (final c in ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[]) {
      if (c.connection.id == id) return c;
    }
    return null;
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  String _dayLabel(AppLocalizations l10n, DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return l10n.historyGroupToday;
    if (diff == 1) return l10n.historyGroupYesterday;
    return day.year == now.year
        ? DateFormat.MMMd(l10n.localeName).format(day)
        : DateFormat.yMMMd(l10n.localeName).format(day);
  }

  // ── What a row does ────────────────────────────────────────────────────

  /// Why the actions that carry a command out are off for [e], or null where
  /// they are on: while the screen is recorded (they would carry the real
  /// command out of a screen that shows a stand-in).
  String? _offWhy(AppLocalizations l10n, CommandHistoryEntry e) {
    if (ref.read(recordingModeProvider)) return l10n.cmdhOffWhileRecording;
    return null;
  }

  Future<void> copy(CommandHistoryEntry e) async {
    if (ref.read(recordingModeProvider)) return;
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: e.command));
    if (mounted) showTopSnackBar(context, l10n.cmdhCommandCopied);
  }

  /// The snippet editor, its command filled in with [e]'s; a snippet is
  /// made when it is saved there.
  Future<void> saveAsSnippet(CommandHistoryEntry e) async {
    if (ref.read(recordingModeProvider)) return;
    final result = await showSnippetEditDialog(
      context: context,
      existingCategories: ref.read(snippetCategoriesProvider),
      initialCommand: e.command,
    );
    if (result == null || !mounted) return;
    final crud = ref.read(snippetCrudProvider);
    await saveSnippetSaying(
      context,
      name: result.label,
      added: true,
      write: () => crud.create(
        label: result.label,
        command: result.command,
        category: result.category,
        confirmBeforeRun: result.confirmBeforeRun,
        metadata: result.metadata,
      ),
    );
  }

  /// Runs [e] again on the host it ran on; where that host is no longer
  /// saved, on one picked ([runOn]).
  Future<void> runOnItsHost(CommandHistoryEntry e) async {
    final host = _hostOf(e);
    if (host == null) return runOn(e);
    await ref.read(historyRunOnHostProvider)(context, ref, host: host, command: e.command);
  }

  /// Runs [e] on a host picked in the host picker.
  Future<void> runOn(CommandHistoryEntry e) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await ConnectionPickerDialog.show(context,
        title: l10n.histPageRunOnTitle, needsTerminal: true, place: HostListPlace.runSnippet);
    final host = picked.connection;
    if (host == null || !mounted) return;
    await ref.read(historyRunOnHostProvider)(context, ref, host: host, command: e.command);
  }

  Future<void> delete(CommandHistoryEntry e) async {
    await ref.read(commandHistoryDaoProvider).deleteEntry(e.id);
    if (mounted && _openId == e.id) setState(() => _openId = null);
  }

  Future<void> _confirmClear(AppLocalizations l10n) async {
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.cmdhClearDialogTitle,
      body: l10n.cmdhClearDialogBody,
      confirmLabel: l10n.commonClearAll,
    );
    if (ok == true) {
      await ref.read(commandHistoryDaoProvider).clearAll();
      if (mounted) setState(() => _openId = null);
    }
  }
}

// ── Columns ──────────────────────────────────────────────────────────────

/// Whether the table has room for the folder column, for every row below.
class _Columns extends InheritedWidget {
  const _Columns({required this.wide, required super.child});

  final bool wide;

  static bool wideOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Columns>()?.wide ?? true;

  @override
  bool updateShouldNotify(_Columns old) => old.wide != wide;
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final wide = _Columns.wideOf(context);
    Widget head(String text, {double? width, TextAlign align = TextAlign.left}) {
      final t = Text(
        text.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
          color: ZestTokens.textMuted,
        ),
      );
      return width == null ? Expanded(child: t) : SizedBox(width: width, child: t);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          head(l10n.histPageColHost, width: _hostW),
          const SizedBox(width: _gap),
          head(l10n.histPageColCommand),
          if (wide) ...[
            const SizedBox(width: _gap),
            head(l10n.histPageColFolder, width: _folderW),
          ],
          const SizedBox(width: _gap),
          head(l10n.histPageColResult, width: _resultW),
          const SizedBox(width: _gap),
          head(l10n.histPageColTook, width: _tookW),
          const SizedBox(width: _gap),
          head(l10n.histPageColTime, width: _timeW),
        ],
      ),
    );
  }
}

// ── A row ────────────────────────────────────────────────────────────────

class _HistoryRow extends ConsumerStatefulWidget {
  const _HistoryRow({
    super.key,
    required this.run,
    required this.open,
    required this.user,
    required this.onToggle,
    required this.actions,
  });

  final HistoryRun run;
  final bool open;

  /// The user its host signs in as, for writing its home `~`.
  final String? user;
  final VoidCallback onToggle;
  final _HistoryViewState actions;

  @override
  ConsumerState<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends ConsumerState<_HistoryRow> {
  bool _hover = false;

  /// While the Run again menu is open: the mouse is over the menu, not the
  /// row, and the row's buttons stay where the menu came from.
  bool _menuOpen = false;

  CommandHistoryEntry get e => widget.run.entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // What the actions may do changes with recording mode.
    ref.watch(recordingModeProvider);
    final wide = _Columns.wideOf(context);
    final showActions = (_hover || _menuOpen) && !widget.open;
    final raised = _hover || _menuOpen || widget.open;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: raised ? ZestTokens.surfaceRaisedAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: widget.open ? ZestTokens.border : (raised ? ZestTokens.borderSubtle : Colors.transparent)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    SizedBox(width: _hostW, child: Align(alignment: Alignment.centerLeft, child: _hostChip())),
                    const SizedBox(width: _gap),
                    Expanded(child: _command(l10n)),
                    if (showActions)
                      _hoverActions(l10n, wide)
                    else ...[
                      if (wide) ...[
                        const SizedBox(width: _gap),
                        SizedBox(width: _folderW, child: _folder()),
                      ],
                      const SizedBox(width: _gap),
                      SizedBox(width: _resultW, child: _result(l10n)),
                      const SizedBox(width: _gap),
                      SizedBox(width: _tookW, child: _took(l10n)),
                      const SizedBox(width: _gap),
                      SizedBox(width: _timeW, child: _mono(DateFormat.Hm(l10n.localeName).formatPlain(e.createdAt))),
                    ],
                  ],
                ),
              ),
              if (widget.open) _details(l10n),
            ],
          ),
        ),
      ),
    );
  }

  /// [child] with [why] it is off as its tooltip, where it is off.
  static Widget _why(String? why, Widget child) => why == null ? child : Tooltip(message: why, child: child);

  Widget _hostChip() {
    final label = e.hostLabel;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The host's own icon, where it is still among the hosts.
          if (widget.actions._hostOf(e) case final host?) ...[
            HostGlyph(host: host.connection, group: host.group, size: 14),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: RedactedText(
              Redactable.host(label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _command(AppLocalizations l10n) => Row(
        children: [
          Flexible(
            child: RedactedText(
              Redactable.command(e.command.replaceAll('\n', ' ')),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestTokens.textPrimary),
            ),
          ),
          if (widget.run.repeat > 1) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: l10n.histPageRepeatTooltip(widget.run.repeat),
              child: Container(
                key: ValueKey('history-repeat-${e.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceChip,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  l10n.histPageRepeatCount(widget.run.repeat),
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, color: ZestTokens.textTertiary),
                ),
              ),
            ),
          ],
        ],
      );

  Widget _folder() {
    final cwd = e.cwd;
    if (cwd == null || cwd.isEmpty) return const SizedBox.shrink();
    return RedactedText(
      Redactable.path(shortenHomeFolder(cwd, widget.user)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textTertiary),
    );
  }

  Widget _result(AppLocalizations l10n) {
    final code = e.exitCode;
    if (code == null) return const SizedBox.shrink();
    final ok = code == 0;
    final color = zestStatusColor(ok ? ZestStatusKind.healthy : ZestStatusKind.critical);
    return Row(
      key: ValueKey('history-result-${e.id}'),
      children: [
        Icon(ok ? LucideIcons.check : LucideIcons.x, size: 13, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            ok ? l10n.histPageResultOk : l10n.histPageResultExit(code),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: color),
          ),
        ),
      ],
    );
  }

  Widget _took(AppLocalizations l10n) {
    final ms = e.durationMs;
    if (ms == null) return const SizedBox.shrink();
    return _mono(formatTook(
      ms,
      seconds: l10n.histPageTookSeconds,
      minutes: l10n.histPageTookMinutes,
      hours: l10n.histPageTookHours,
      decimalSeparator: NumberFormat.decimalPattern(l10n.localeName).symbols.DECIMAL_SEP,
    ));
  }

  Widget _mono(String text) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textSecondary),
      );

  /// Under the mouse, in place of the folder, result, run time and time:
  /// Run again (where, from its menu), Copy and Save as snippet.
  Widget _hoverActions(AppLocalizations l10n, bool wide) {
    final a = widget.actions;
    final off = a._offWhy(l10n, e);
    final runOff = off;
    final host = a._hostOf(e);
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuAnchor(
          onOpen: () => setState(() => _menuOpen = true),
          onClose: () => setState(() => _menuOpen = false),
          alignmentOffset: const Offset(0, 4),
          menuChildren: [
            if (host != null)
              MenuItemButton(
                key: const ValueKey('history-run-host'),
                leadingIcon: Icon(LucideIcons.play, size: 14, color: ZestTokens.textSecondary),
                onPressed: () => a.runOnItsHost(e),
                child: Text(l10n.docCheckSnippetRunOnHost(Redactable.host(host.connection.label).displayIn(ref))),
              ),
            MenuItemButton(
              key: const ValueKey('history-run-on'),
              leadingIcon: Icon(LucideIcons.server, size: 14, color: ZestTokens.textSecondary),
              onPressed: () => a.runOn(e),
              child: Text(l10n.zestSnippetsRunOn),
            ),
          ],
          builder: (context, controller, _) => _why(
            runOff,
            ZestButton(
              key: ValueKey('history-run-again-${e.id}'),
              label: l10n.histPageRunAgain,
              icon: LucideIcons.play,
              trailingIcon: LucideIcons.chevronDown,
              onPressed: runOff != null ? null : () => controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _why(
          off,
          ZestButton(
            key: ValueKey('history-copy-${e.id}'),
            label: l10n.copy,
            onPressed: off != null ? null : () => a.copy(e),
          ),
        ),
        const SizedBox(width: 6),
        _why(
          off,
          ZestButton(
            key: ValueKey('history-save-${e.id}'),
            label: l10n.historySaveAsSnippet,
            onPressed: off != null ? null : () => a.saveAsSnippet(e),
          ),
        ),
      ],
    );
    // A click on a button that is off (or between the buttons) is not a
    // click on the row: it neither opens nor closes it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Padding(padding: const EdgeInsets.only(left: _gap), child: buttons),
    );
  }

  /// The opened row: when it started and the whole folder, then Delete,
  /// Save as snippet and Run again on its host.
  Widget _details(AppLocalizations l10n) {
    final a = widget.actions;
    final off = a._offWhy(l10n, e);
    final runOff = off;
    final host = a._hostOf(e);
    final now = DateTime.now();
    final started = (e.createdAt.year == now.year
            ? DateFormat.MMMd(l10n.localeName)
            : DateFormat.yMMMd(l10n.localeName))
        .add_Hms()
        .format(e.createdAt);
    Widget fact(String label, Widget value) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
            const SizedBox(width: 6),
            Flexible(child: value),
          ],
        );
    final cwd = e.cwd;
    return Padding(
      padding: const EdgeInsets.only(left: _hostW + _gap, bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 20,
              runSpacing: 4,
              children: [
                fact(l10n.histPageStarted,
                    Text(started, style: TextStyle(fontSize: 12, color: ZestTokens.textPrimary))),
                if (cwd != null && cwd.isNotEmpty)
                  fact(
                    l10n.histPageColFolder,
                    RedactedText(
                      Redactable.path(cwd),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textPrimary),
                    ),
                  ),
                if (off != null || runOff != null)
                  Text(off ?? runOff!, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ZestButton(
            key: ValueKey('history-delete-${e.id}'),
            label: l10n.delete,
            variant: ZestButtonVariant.danger,
            onPressed: () => a.delete(e),
          ),
          const SizedBox(width: 6),
          ZestButton(
            key: ValueKey('history-open-save-${e.id}'),
            label: l10n.historySaveAsSnippet,
            onPressed: off != null ? null : () => a.saveAsSnippet(e),
          ),
          const SizedBox(width: 6),
          ZestButton(
            key: ValueKey('history-open-run-${e.id}'),
            label: host != null
                ? l10n.histPageRunAgainOn(Redactable.host(host.connection.label).displayIn(ref))
                : l10n.zestSnippetsRunOn,
            icon: LucideIcons.play,
            variant: ZestButtonVariant.primary,
            onPressed: runOff != null ? null : () => host != null ? a.runOnItsHost(e) : a.runOn(e),
          ),
        ],
      ),
    );
  }
}

// ── A filter toggle ──────────────────────────────────────────────────────

/// A toolbar toggle as tall as the search field and the select: a check
/// and a filled chip while it is on, a hairline outline while it is off.
class _FilterToggle extends StatefulWidget {
  const _FilterToggle({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_FilterToggle> createState() => _FilterToggleState();
}

class _FilterToggleState extends State<_FilterToggle> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.value;
    return Semantics(
      button: true,
      toggled: on,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onChanged(!on)),
        },
        child: GestureDetector(
          onTap: () => widget.onChanged(!on),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: on ? ZestTokens.surfaceChip : (_hover ? ZestTokens.surfaceHover : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _focus ? ZestTokens.brand : (on ? ZestTokens.borderStrong : ZestTokens.border),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (on) ...[
                  Icon(LucideIcons.check, size: 14, color: ZestTokens.textPrimary),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: on ? FontWeight.w500 : FontWeight.w400,
                    color: on ? ZestTokens.textPrimary : ZestTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
