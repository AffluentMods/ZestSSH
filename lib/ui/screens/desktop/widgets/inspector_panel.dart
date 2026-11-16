import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/command_history/history_table.dart' show historyHostWantedProvider;
import 'package:intl/intl.dart' show DateFormat;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/widgets/host_panel_sections.dart' show addPortForwardFor;
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart' show portForwardRulesForConnectionProvider;
import 'package:zestssh/router/link_pages.dart' show openShellSection;
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_slide_panel.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippet_detail_view.dart' show snippetCommandChipSpans;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalTheme;
import 'package:zestssh/models/enums.dart' show TerminalCursorShape;
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/hosts/widgets/section_label.dart';
import 'package:zestssh/utils/number_text.dart';

/// The Inspector's three tabs.
enum InspectorTab { session, tools, appearance }

/// The tab the Inspector shows; kept while the app runs (Tools first: it is
/// what people reach for while they work).
final inspectorTabProvider =
    StateProvider<InspectorTab>((_) => InspectorTab.tools);

/// Width of the Inspector beside the terminals.
const double kInspectorWidth = 340;

/// The Inspector (3.0), docked right of the session, describing the session
/// that has focus. Session: the host and the connection (what was
/// negotiated, the route, the load when Server Monitor watches it). Tools:
/// snippets to run here, and the commands already run on this host.
class InspectorPanel extends ConsumerWidget {
  const InspectorPanel({
    super.key,
    required this.sessionId,
    required this.sessionState,
    required this.onClose,
  });

  final String sessionId;
  final SessionState sessionState;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tab = ref.watch(inspectorTabProvider);
    return Container(
      width: kInspectorWidth,
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(left: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sessionHeaderInspector,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: ZestColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      RedactedText(
                        Redactable.host(sessionState.connectionLabel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5, color: ZestColors.textTertiary),
                      ),
                    ],
                  ),
                ),
                _IconAction(
                  key: const ValueKey('inspector-close'),
                  icon: LucideIcons.x,
                  tooltip: l10n.sessionDetailsClosePanel,
                  onTap: onClose,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _Segmented(
              value: tab,
              labels: {
                InspectorTab.session: l10n.inspectorTabSession,
                InspectorTab.tools: l10n.inspectorTabTools,
                // "Look".
                InspectorTab.appearance: l10n.termToolsTabLook,
              },
              onChanged: (t) =>
                  ref.read(inspectorTabProvider.notifier).state = t,
            ),
          ),
          Divider(height: 1, color: ZestColors.borderDefault),
          Expanded(
            child: switch (tab) {
              InspectorTab.session => SessionDetailsBody(
                  sessionId: sessionId,
                  sessionState: sessionState,
                ),
              InspectorTab.tools => InspectorTools(
                  sessionId: sessionId,
                  sessionState: sessionState,
                ),
              InspectorTab.appearance => const InspectorAppearance(),
            },
          ),
        ],
      ),
    );
  }
}

/// The snippets the Inspector's Tools tab offers for the host
/// [connectionId] (3.0: this
/// host's snippets). A snippet belongs to a host by its "Default host" (it
/// has no other tie to one): first those whose default host is this one,
/// then those whose default host is in this host's folder, each in the
/// library's order. Then, to fill [limit], the ones run most on this device
/// ([usage]) that are not listed already, as [often].
({List<Snippet> forHost, List<Snippet> often}) inspectorSnippetsFor({
  required List<Snippet> snippets,
  required String? connectionId,
  required List<ConnectionWithDetails> hosts,
  required Map<String, SnippetUsage> usage,
  int limit = 6,
}) {
  final groupOf = {for (final h in hosts) h.connection.id: h.connection.groupId};
  final folder = connectionId == null ? null : groupOf[connectionId];
  final own = <Snippet>[];
  final inFolder = <Snippet>[];
  if (connectionId != null) {
    for (final s in snippets) {
      final id = parseSnippetMetadata(s.metadata).defaultConnectionId;
      if (id == null) continue;
      if (id == connectionId) {
        own.add(s);
      } else if (folder != null && groupOf[id] == folder) {
        inFolder.add(s);
      }
    }
  }
  final forHost = [...own, ...inFolder].take(limit).toList();
  final listed = {for (final s in forHost) s.id};
  final used = [
    for (final s in snippets)
      if (!listed.contains(s.id) && usage[s.id] != null) s,
  ]..sort((a, b) {
      final ua = usage[a.id]!, ub = usage[b.id]!;
      final byCount = ub.runCount.compareTo(ua.runCount);
      return byCount != 0 ? byCount : ub.lastRunAt.compareTo(ua.lastRunAt);
    });
  return (forHost: forHost, often: used.take(limit - forHost.length).toList());
}

/// The Tools tab (3.0): this host's snippets, the commands run here lately,
/// and this host's port forwards, each run through the app's own path.
class InspectorTools extends ConsumerStatefulWidget {
  const InspectorTools({
    super.key,
    required this.sessionId,
    required this.sessionState,
  });

  final String sessionId;
  final SessionState sessionState;

  @override
  ConsumerState<InspectorTools> createState() => _InspectorToolsState();
}

class _InspectorToolsState extends ConsumerState<InspectorTools> {
  final _search = TextEditingController();

  /// How many commands of this host's history are listed.
  static const _recentShown = 6;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Runs [s] in this session by the one snippet path (its variables asked
  /// for, the risky command check, its own "confirm before running"), and
  /// counts the run as the library counts one.
  Future<void> _runSnippet(Snippet s, Terminal terminal) async {
    final usage = ref.read(snippetUsageProvider.notifier);
    final ran = await runSnippetIn(context, ref, s, terminal, listOptions: listOptionsFrom(widget.sessionState));
    if (ran) usage.recordRun(s.id);
  }

  /// Runs [command] from history again in this session: entered, once the
  /// risky command check (when it is on) has asked about it. Its text is
  /// what ran then, so nothing in it is taken for a snippet's variable.
  Future<void> _runAgain(String command, Terminal terminal) async {
    if (ref.read(dangerousCommandProtectionProvider)) {
      final dangers = DangerousCommandService.checkFilled(command);
      if (dangers.isNotEmpty) {
        final updater = ref.read(settingsUpdaterProvider);
        final result = await showDangerousCommandDialog(
          Navigator.of(context, rootNavigator: true).context,
          command: command,
          matches: dangers,
        );
        if (result.dontAskAgain) await updater.setDangerousCommandProtection(false);
        if (!result.proceed) return;
      }
    }
    terminal.textInput(CommandText.entered(command));
  }

  /// The command goes to the clipboard as it is: through the recording
  /// reveal gate, as every copy of a real value.
  Future<void> _copy(String command) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await confirmRevealWhileRecording(context, ref)) return;
    await Clipboard.setData(ClipboardData(text: command));
    if (mounted) showTopSnackBar(context, l10n.termToolsCommandCopied, duration: const Duration(seconds: 2));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final terminal = widget.sessionState.session?.terminal;
    final connId = widget.sessionState.connectionId;
    final query = _search.text.trim().toLowerCase();
    final all = ref.watch(snippetsProvider).valueOrNull ?? const <Snippet>[];

    // This host's snippets, or what the search finds among all of them.
    final List<Snippet> forHost;
    final List<Snippet> often;
    if (query.isEmpty) {
      final picked = inspectorSnippetsFor(
        snippets: all,
        connectionId: connId,
        hosts: ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [],
        usage: ref.watch(snippetUsageProvider),
      );
      forHost = picked.forHost;
      often = picked.often;
    } else {
      forHost = all
          .where((s) =>
              s.label.toLowerCase().contains(query) ||
              s.command.toLowerCase().contains(query) ||
              (s.category?.toLowerCase().contains(query) ?? false))
          .take(20)
          .toList();
      often = const [];
    }

    final historyOn = ref.watch(commandHistoryEnabledProvider);
    final here = connId == null
        ? const <CommandHistoryEntry>[]
        : (ref.watch(recentCommandHistoryProvider).valueOrNull ?? const <CommandHistoryEntry>[])
            .where((e) => e.connectionId == connId)
            .take(_recentShown)
            .toList();

    final forwards = connId == null
        ? const <PortForwardRule>[]
        : (ref.watch(portForwardRulesForConnectionProvider(connId)).valueOrNull ?? const <PortForwardRule>[]);

    Widget snippetCard(Snippet s) => _SnippetCard(
          key: ValueKey('inspector-snippet-${s.id}'),
          snippet: s,
          onRun: terminal == null ? null : () => _runSnippet(s, terminal),
        );

    return ZestScrollFade(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        children: [
          // ── For this host ──
          _SectionHead(
            label: l10n.termToolsForThisHost,
            action: l10n.termToolsAllCount(all.length),
            actionKey: const ValueKey('inspector-snippets-all'),
            onAction: () => openShellSection(ref, NavSection.snippets),
          ),
          ZestListSearchField(
            key: const ValueKey('inspector-snippet-search'),
            controller: _search,
            hintText: l10n.inspectorSearchSnippets,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          if (forHost.isEmpty && often.isEmpty)
            _Note(query.isNotEmpty
                ? l10n.inspectorNoSnippetMatch
                : all.isEmpty
                    ? l10n.inspectorNoSnippets
                    : l10n.termToolsNoHostSnippets)
          else ...[
            for (final s in forHost) snippetCard(s),
            if (often.isNotEmpty) ...[
              if (forHost.isEmpty) _Note(l10n.termToolsNoHostSnippets),
              _SectionHead(label: l10n.termToolsOftenUsed),
              for (final s in often) snippetCard(s),
            ],
          ],

          // ── Recent here ──
          _SectionHead(
            label: l10n.termToolsRecentHere,
            action: l10n.narrowSidebarHistory,
            actionKey: const ValueKey('inspector-history-all'),
            // Opens History showing this session's host.
            onAction: () {
              if (connId != null) ref.read(historyHostWantedProvider.notifier).state = 'id:$connId';
              openShellSection(ref, NavSection.commandHistory);
            },
          ),
          if (!historyOn)
            _Note(
              l10n.inspectorHistoryOff,
              action: l10n.inspectorHistoryTurnOn,
              onAction: () => ref.read(commandHistoryEnabledProvider.notifier).set(true),
            )
          else if (here.isEmpty)
            _Note(l10n.inspectorHistoryNone)
          else
            for (final e in here)
              _HistoryRow(
                key: ValueKey('inspector-history-${e.id}'),
                entry: e,
                onTap: terminal == null ? null : () => terminal.textInput(CommandText.typed(e.command)),
                onRunAgain: terminal == null ? null : () => _runAgain(e.command, terminal),
                onCopy: () => _copy(e.command),
              ),

          // ── Port forwards ──
          _SectionHead(
            label: l10n.hpanelPortForwards,
            action: connId == null ? null : '+ ${l10n.hpanelAdd}',
            actionKey: const ValueKey('inspector-forward-add'),
            onAction: connId == null ? null : () => addPortForwardFor(context, ref, connId),
          ),
          if (forwards.isEmpty)
            _Note(l10n.termToolsNoForwards)
          else
            for (final r in forwards) _ForwardRow(key: ValueKey('inspector-forward-${r.id}'), rule: r),
        ],
      ),
    );
  }
}

/// One of this host's port forwards: how it maps, its name, whether it runs
/// now, and Start or Stop, as the Port forwarding page and the host's panel
/// do it (a start that fails says why in the notifications).
class _ForwardRow extends ConsumerWidget {
  const _ForwardRow({super.key, required this.rule});

  final PortForwardRule rule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final running = ref.watch(activeForwardIdsProvider).contains(rule.id);
    final remote = Redactable.address('${rule.remoteHost}:${rule.remotePort}').displayIn(ref);
    final mapping = switch (rule.type) {
      'dynamic' => 'localhost:${rule.bindPort}',
      'remote' => '$remote → ${rule.bindPort}',
      _ => '${rule.bindPort} → $remote',
    };
    final name = (rule.label ?? '').trim();
    final sessions = ref.read(activeSessionsProvider.notifier);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ZestColors.surfaceChip,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: ZestColors.borderSubtle),
            ),
            child: Text(
              switch (rule.type) { 'remote' => 'R', 'dynamic' => 'D', _ => 'L' },
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: ZestColors.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mapping,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textPrimary),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    ZestStatusPill(
                      key: ValueKey('inspector-forward-state-${rule.id}'),
                      kind: running ? ZestStatusKind.healthy : ZestStatusKind.neutral,
                      label: running ? l10n.zestPfStateRunning : l10n.zestPfStateStopped,
                    ),
                    if (name.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ZestButton(
            key: ValueKey('inspector-forward-toggle-${rule.id}'),
            label: running ? l10n.portForwardStop : l10n.portForwardStart,
            icon: running ? LucideIcons.square : LucideIcons.play,
            variant: ZestButtonVariant.secondary,
            size: ZestButtonSize.medium,
            // ignore: discarded_futures
            onPressed: () => running ? sessions.stopSavedForward(rule.id) : sessions.connectThenStartForward(rule),
          ),
        ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label, this.action, this.actionKey, this.onAction});

  final String label;
  final String? action;
  final Key? actionKey;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    // The Blueprint's section head: the brand tick, the name, a rule.
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: ZestSectionHeader(
        label: label,
        trailing: action == null ? null : SectionLink(key: actionKey, label: action!, onTap: onAction),
      ),
    );
  }
}

/// The Inspector's Appearance tab (3.0, the Blueprint): the terminal's text
/// size, its cursor and its colours, with "Match terminal to app theme" over
/// the colours. They are the app's own settings, so they change every
/// session, as the note under them says, and "More appearance settings"
/// opens Settings on Appearance.
class InspectorAppearance extends ConsumerWidget {
  const InspectorAppearance({super.key});

  /// The colour sets offered here (every one is in Settings).
  static const themes = [
    TerminalThemes.zestNight,
    TerminalThemes.light,
    TerminalThemes.tokyoNight,
    TerminalThemes.dracula,
    TerminalThemes.nord,
    TerminalThemes.solarizedDark,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final size = ref.watch(terminalFontSizeProvider);
    final cursor = ref.watch(cursorStyleProvider);
    final themeId = ref.watch(shownTerminalThemeIdProvider);
    final updater = ref.read(settingsUpdaterProvider);
    final label = TextStyle(fontSize: 12.5, color: ZestColors.textPrimary, fontWeight: FontWeight.w500);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      children: [
        _SectionHead(label: l10n.inspectorText),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: Text(l10n.inspectorFontSize, style: label)),
            _Stepper(
              value: size,
              // The updater holds it between the shared ends (8 to 28).
              onChanged: updater.setTerminalFontSize,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: Text(l10n.inspectorCursor, style: label)),
            _Choice<TerminalCursorShape>(
              value: cursor,
              options: {
                TerminalCursorShape.block: l10n.cursorShapeBlock,
                TerminalCursorShape.verticalBar: l10n.inspectorCursorBar,
                TerminalCursorShape.underline: l10n.cursorShapeUnderline,
              },
              onChanged: updater.setTerminalCursorShape,
            ),
          ],
        ),
        _SectionHead(label: l10n.inspectorColors),
        const SizedBox(height: 4),
        // The same switch as Settings > Appearance: on, the terminal's colours
        // follow the app's theme, and a pick below sets the app's too.
        Row(
          children: [
            Expanded(child: Text(l10n.settingsInlineMatchTerminalToApp, style: label)),
            ZestSwitch(
              key: const ValueKey('inspector-match-app-theme'),
              value: ref.watch(themesSyncedProvider),
              onChanged: (v) => ref.read(themeSyncCoordinatorProvider).setSyncEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.25,
          children: [
            for (final id in themes)
              if (TerminalThemes.builtIn[id] case final theme?)
                _ThemeSwatch(
                  key: ValueKey('inspector-theme-$id'),
                  name: TerminalThemes.builtInNames[id] ?? id,
                  theme: theme,
                  selected: id == themeId,
                  // Through the coordinator, so with "Match terminal to app
                  // theme" on the app theme follows and the pick is shown.
                  onTap: () => ref.read(themeSyncCoordinatorProvider).setTerminalTheme(id),
                ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          l10n.inspectorAppearanceEverySession,
          style: TextStyle(fontSize: 11.5, height: 1.4, color: ZestColors.textTertiary),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SectionLink(
            key: const ValueKey('inspector-more-appearance'),
            label: l10n.inspectorMoreAppearance,
            // The terminal's colours and font are Terminal and SSH's (4.0).
            onTap: () => jumpToDesktopSettings(ref, SettingsJumpTarget.terminal),
          ),
        ),
      ],
    );
  }
}

/// A number with a minus and a plus either side. A click on the number lets
/// a size be typed: Enter or leaving
/// the box keeps it, Esc leaves the size as it was.
class _Stepper extends StatefulWidget {
  const _Stepper({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_Stepper> createState() => _StepperState();
}

class _StepperState extends State<_Stepper> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _typing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  String get _shown {
    // The language's decimal mark ("13,5" in German): [_commit] reads a
    // comma as well as a point.
    return formatDecimalUpTo(widget.value);
  }

  void _startTyping() {
    _controller.value = TextEditingValue(
      text: _shown,
      selection: TextSelection(baseOffset: 0, extentOffset: _shown.length),
    );
    setState(() => _typing = true);
    _focus.requestFocus();
  }

  void _commit() {
    if (!_typing) return;
    // A decimal comma where the keyboard's language has one. What cannot be
    // read leaves the size as it was; the updater holds the rest between
    // the shared ends (8 to 28).
    final typed = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    setState(() => _typing = false);
    if (typed != null) widget.onChanged(typed);
  }

  void _cancel() {
    setState(() => _typing = false);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget button(IconData icon, double by, String key, String tip) => Tooltip(
          message: tip,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey(key),
              onTap: () => widget.onChanged(widget.value + by),
              child: SizedBox(width: 30, height: 30, child: Icon(icon, size: 14, color: ZestColors.textSecondary)),
            ),
          ),
        );
    final style = TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestColors.textPrimary);
    return Container(
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(LucideIcons.minus, -1, 'inspector-font-smaller', l10n.shortcutNameZoomOut),
          SizedBox(
            width: 44,
            height: 30,
            child: _typing
                ? CallbackShortcuts(
                    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
                    child: Center(
                      child: TextField(
                        key: const ValueKey('inspector-font-size-field'),
                        controller: _controller,
                        focusNode: _focus,
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                          LengthLimitingTextInputFormatter(4),
                        ],
                        style: style,
                        decoration: const InputDecoration.collapsed(hintText: null),
                        onSubmitted: (_) => _commit(),
                      ),
                    ),
                  )
                : Tooltip(
                    message: l10n.inspectorFontSizeType(
                      kTerminalFontSizeMin.round(),
                      kTerminalFontSizeMax.round(),
                    ),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.text,
                      child: GestureDetector(
                        key: const ValueKey('inspector-font-size'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _startTyping,
                        child: Center(child: Text(_shown, style: style)),
                      ),
                    ),
                  ),
          ),
          button(LucideIcons.plus, 1, 'inspector-font-larger', l10n.shortcutNameZoomIn),
        ],
      ),
    );
  }
}

/// A few words side by side, the one chosen lit.
class _Choice<T> extends StatelessWidget {
  const _Choice({required this.value, required this.options, required this.onChanged});
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in options.entries)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onChanged(e.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: e.key == value ? ZestColors.bgSurface : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    e.value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: e.key == value ? FontWeight.w600 : FontWeight.w400,
                      color: e.key == value ? ZestColors.textPrimary : ZestColors.textTertiary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A terminal colour set as a small preview: its background with a prompt
/// in its green, and its name.
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({super.key, required this.name, required this.theme, required this.selected, required this.onTap});
  final String name;
  final TerminalTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: ZestColors.chromeElevated,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: selected ? ZestColors.accentPrimary : ZestColors.borderDefault, width: selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.background,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: ZestColors.borderDefault),
                  ),
                  child: Text(r'$ ls', style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 9.5, color: theme.green)),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: ZestColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [command] in mono, each variable in it a chip as the Snippets page draws
/// it (its placeholder as written, in the brand's tint: here it was the bare
/// name in grey, found in a design audit), so what will be asked
/// for stands out. In recording mode the command's stand-in is shown as it
/// is, without chips.
class _CommandLine extends ConsumerWidget {
  const _CommandLine(this.command);

  final String command;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono', color: ZestColors.textSecondary);
    final shown = Redactable.command(command).displayIn(ref);
    if (shown != command) {
      return Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    return Text.rich(
      TextSpan(style: style, children: snippetCommandChipSpans(command, style)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SnippetCard extends StatelessWidget {
  const _SnippetCard({super.key, required this.snippet, required this.onRun});

  final Snippet snippet;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 10),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snippet.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: ZestColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 5),
                _CommandLine(snippet.command),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _RunIcon(tooltip: l10n.snippetRunAction, onTap: onRun),
        ],
      ),
    );
  }
}

/// A command run on this host: a click puts it at the prompt (nothing
/// runs); beside it, when it ran (or its exit status in red, when it
/// failed), Copy and Run again.
class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onRunAgain,
    required this.onCopy,
  });

  final CommandHistoryEntry entry;
  final VoidCallback? onTap;
  final VoidCallback? onRunAgain;
  final VoidCallback onCopy;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _hover = false;

  /// The time it ran today, else its day.
  String _when(BuildContext context) {
    final t = widget.entry.createdAt.toLocal();
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    return DateFormat.MMMd(Localizations.localeOf(context).toLanguageTag()).format(t);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final code = widget.entry.exitCode;
    final failed = code != null && code != 0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        padding: const EdgeInsets.only(left: 6, top: 2, bottom: 2),
        decoration: BoxDecoration(
          color: _hover ? ZestColors.surfaceRaisedAlt : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: l10n.inspectorHistoryPutAtPrompt,
                child: MouseRegion(
                  cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: RedactedText(
                        Redactable.command(widget.entry.command),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'JetBrainsMono',
                          color: ZestColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              failed ? l10n.termToolsExitCode(code) : _when(context),
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: failed ? ZestColors.statusError : ZestColors.textTertiary,
              ),
            ),
            const SizedBox(width: 4),
            _RowIcon(
              key: ValueKey('inspector-history-copy-${widget.entry.id}'),
              icon: LucideIcons.copy,
              tooltip: l10n.copy,
              onTap: widget.onCopy,
            ),
            _RowIcon(
              key: ValueKey('inspector-history-run-${widget.entry.id}'),
              icon: LucideIcons.rotateCw,
              tooltip: l10n.termToolsRunAgain,
              onTap: widget.onRunAgain,
            ),
          ],
        ),
      ),
    );
  }
}

/// A small icon action of a row: muted, the text colour under the pointer.
class _RowIcon extends StatefulWidget {
  const _RowIcon({super.key, required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_RowIcon> createState() => _RowIconState();
}

class _RowIconState extends State<_RowIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover && on ? ZestColors.surfaceChip : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 13,
              color: !on
                  ? ZestColors.textDisabled
                  : _hover
                      ? ZestColors.textPrimary
                      : ZestColors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: ZestColors.textTertiary),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 8),
            _TextLink(label: action!, onTap: onAction, bold: true),
          ],
        ],
      ),
    );
  }
}

/// A snippet card's Run: a play icon in the muted ink, the accent under the
/// pointer, its name as its tooltip.
class _RunIcon extends StatefulWidget {
  const _RunIcon({required this.tooltip, this.onTap});

  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_RunIcon> createState() => _RunIconState();
}

class _RunIconState extends State<_RunIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover && on ? ZestColors.surfaceRaisedAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              LucideIcons.play,
              size: 14,
              color: !on
                  ? ZestColors.textDisabled
                  : _hover
                      ? ZestColors.accentInk
                      : ZestColors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

class _TextLink extends StatefulWidget {
  const _TextLink({required this.label, this.onTap, this.bold = false});

  final String label;
  final VoidCallback? onTap;
  final bool bold;

  @override
  State<_TextLink> createState() => _TextLinkState();
}

class _TextLinkState extends State<_TextLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: widget.bold ? FontWeight.w600 : FontWeight.w500,
            color: !enabled
                ? ZestColors.textDisabled
                : _hover
                    ? ZestColors.accentHover
                    : ZestColors.accentInk,
            decoration: _hover && enabled ? TextDecoration.underline : null,
            decorationColor: ZestColors.accentHover,
          ),
        ),
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final InspectorTab value;
  final Map<InspectorTab, String> labels;
  final ValueChanged<InspectorTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Row(
        children: [
          for (final t in InspectorTab.values)
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: ValueKey('inspector-tab-${t.name}'),
                  onTap: () => onChanged(t),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t == value ? ZestColors.bgSurface : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      labels[t]!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            t == value ? FontWeight.w600 : FontWeight.w400,
                        color: t == value
                            ? ZestColors.textPrimary
                            : ZestColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IconAction extends StatefulWidget {
  const _IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? ZestColors.surfaceRaisedAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon,
                size: 15,
                color: _hover ? ZestColors.textPrimary : ZestColors.textTertiary),
          ),
        ),
      ),
    );
  }
}
