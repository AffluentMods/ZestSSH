/// The command palette (Ctrl+K): a host, an action or a snippet, found by
/// what is typed and done from the keyboard. It CONNECTS, RUNS, or NAVIGATES;
/// it never switches to an existing session.
///
/// The 4.0 redesign:
/// results grouped under Hosts, Actions and Snippets, each row an
/// icon, a name and a second line (a host's address, what an action does, a
/// snippet's command); what was typed marked in every match; a host's open
/// sessions said in words ("2 open", "Open"); the row in hand says what
/// Enter does and, for a host, Ctrl+Enter (Cmd+Enter on a Mac): Open in
/// split. Actions that name a host or a group come first where what is typed
/// finds one (Open web-01 in SFTP, Broadcast to the Web group). Snippets are
/// found by name, command and category.
///
/// With nothing typed: the hosts connected to last (Recent), then the
/// actions and the snippets; every host where none has been connected to
/// yet. Typing `@` lists every host.
///
/// Prefix filters restrict the search and are stripped from the query:
///   `>` → Actions only   `#` → Snippets only   `@` → Hosts only
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/hosts/open_selected_hosts.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_hints.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/command_palette_item.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/kbd.dart';
import 'package:zestssh/ui/widgets/match_marks.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/fuzzy_search.dart';

/// The most rows a section holds for what is typed, where all three are
/// listed: each of them is in sight (a long list of hosts pushed the actions
/// and the snippets out of it).
const _kSectionCap = 8;

/// The most rows for what is typed after a filter (`>`, `#`, `@`).
const _kFilteredCap = 30;

/// Most-recent hosts surfaced in the Recent section.
const _kRecentLimit = 5;

/// The least room a row's words keep beside what the row in hand says of its
/// keys; with less it says nothing of them (the footer says the keys).
const double _kRowWordsAtLeast = 160;

// ── Static show helper ──────────────────────────────────────────

/// Whether the palette is currently open. Guards against stacking: every
/// call site shares this flag, so a second shortcut press toggles the palette
/// closed instead of pushing another modal (each [showDialog] adds its own
/// black54 scrim, so repeated presses just darken the screen).
bool _paletteOpen = false;

/// Show the command palette as a modal dialog overlay.
///
/// [actions] lets the caller inject a fully-built action set (the desktop
/// shell passes its context-aware window / pane / layout / navigation
/// commands, each with what it does as its subtitle, which can't be built
/// inside the palette because they close over shell state). When provided,
/// these REPLACE the palette's built-in action list; the palette still lists
/// the hosts and the snippets beside them.
///
/// How a chosen host is opened is the caller's where it gives one:
/// [onConnect] (Enter), [onOpenInSplit] (Ctrl+Enter, Cmd+Enter on a Mac),
/// [onOpenSftp] (the action "Open web-01 in SFTP", offered only where it
/// is given) and [onBroadcast] ("Broadcast to the Web group", with the ids of
/// its hosts).
Future<void> showCommandPalette(
  BuildContext context,
  WidgetRef ref, {
  List<CommandPaletteItem>? actions,
  void Function(ConnectionWithDetails host)? onConnect,
  void Function(ConnectionWithDetails host)? onOpenInSplit,
  void Function(ConnectionWithDetails host)? onOpenSftp,
  void Function(Set<String> hostIds)? onBroadcast,
}) {
  // Toggle: if the palette is already up, the shortcut closes it.
  if (_paletteOpen) {
    Navigator.of(context, rootNavigator: true).maybePop();
    return Future<void>.value();
  }
  _paletteOpen = true;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => Align(
      alignment: const Alignment(0, -0.3),
      child: Material(
        color: Colors.transparent,
        child: _CommandPaletteDialog(
          injectedActions: actions,
          onConnect: onConnect,
          onOpenInSplit: onOpenInSplit,
          onOpenSftp: onOpenSftp,
          onBroadcast: onBroadcast,
        ),
      ),
    ),
  ).whenComplete(() => _paletteOpen = false);
}

/// The key that opens a host in a split from the palette, as the shortcut
/// formatter writes it: Ctrl+Enter, or Cmd+Enter on a Mac (⌘Enter).
String paletteSplitKeyLabel({TargetPlatform? platform}) {
  final mac = (platform ?? defaultTargetPlatform) == TargetPlatform.macOS;
  return formatShortcutKey(
    ShortcutKey(keyId: LogicalKeyboardKey.enter.keyId, ctrl: !mac, meta: mac),
    platform: platform,
  );
}

// ── Palette row model (palette-only) ────────────────────────────

/// What a row is: a host connected to lately (with nothing typed), a host, an
/// action or a snippet. Each has its section.
enum _RowKind { recent, host, action, snippet }

/// A single rendered palette row. Deliberately palette-local (not the shared
/// [CommandPaletteItem]) so a host's and a snippet's rows have somewhere to
/// live without touching the injected-action contract.
class _Row {
  _Row({
    required this.id,
    required this.kind,
    required this.title,
    required this.onSelect,
    this.subtitle,
    this.subtitleMono = false,
    this.icon,
    this.host,
    this.open = 0,
    this.time,
    this.shortcut,
    this.tag,
    this.onSplit,
    this.fuzzy = const [],
    this.whole = const [],
  });

  final String id;
  final _RowKind kind;

  /// The name as shown: an action's, a snippet's, a host's (masked while a
  /// screen is recorded, as its row shows it).
  final String title;

  /// The second line: a host's user@address, what an action does, a
  /// snippet's command (its first line).
  final String? subtitle;
  final bool subtitleMono;

  /// The icon of an action or a snippet. A host's row has its own ([host]).
  final IconData? icon;

  /// A host's row: drawn as a host is everywhere ([HostRow]: its own icon,
  /// its name, user@address, its open sessions in words),
  /// when it was last connected to after it. Null for action
  /// and snippet rows.
  final ConnectionWithDetails? host;

  /// How many sessions [host] has open.
  final int open;

  /// When [host] was last connected to ([timeAgoShort]).
  final String? time;

  /// Keyboard accelerator label of an action, as the shortcut formatter
  /// writes it.
  final String? shortcut;

  /// A snippet's category.
  final String? tag;

  /// Enter.
  final VoidCallback onSelect;

  /// Ctrl+Enter (Cmd+Enter on a Mac): a host's, Open in split.
  final VoidCallback? onSplit;

  /// What a fuzzy search matches: names, addresses, commands, categories.
  final List<String?> fuzzy;

  /// What matches only where it holds what was typed whole: what an action
  /// does (a fuzzy search found scattered letters in every sentence).
  final List<String?> whole;

  /// Score for the current query (set during filtering).
  double score = 0.0;

  bool get isHost => kind == _RowKind.host || kind == _RowKind.recent;
}

// ── Dialog widget (used inside showDialog) ──────────────────────

class _CommandPaletteDialog extends ConsumerStatefulWidget {
  const _CommandPaletteDialog({
    this.injectedActions,
    this.onConnect,
    this.onOpenInSplit,
    this.onOpenSftp,
    this.onBroadcast,
  });

  /// Caller-supplied actions that replace the built-in action list.
  final List<CommandPaletteItem>? injectedActions;

  /// How a host chosen here is connected to: the caller's own way, as from
  /// its Hosts page (a computer's: the Telnet warning, the free plan's limit
  /// said, a tab of its own in front). A bare session where none is given.
  final void Function(ConnectionWithDetails host)? onConnect;

  /// How a host is opened in a split (Ctrl+Enter): the caller's, else
  /// [openHostInSplit].
  final void Function(ConnectionWithDetails host)? onOpenInSplit;

  /// How a host's files are opened ("Open web-01 in SFTP"): offered only
  /// where given.
  final void Function(ConnectionWithDetails host)? onOpenSftp;

  /// How a group's hosts are broadcast to: the caller's, else Broadcast to
  /// hosts with them ticked.
  final void Function(Set<String> hostIds)? onBroadcast;

  @override
  ConsumerState<_CommandPaletteDialog> createState() =>
      _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends ConsumerState<_CommandPaletteDialog>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  // Stable focus node for the key handler (owned + disposed here - no
  // per-keystroke FocusNode leak).
  final _keyFocusNode = FocusNode();
  final _scrollController = ScrollController();
  // Attached to the currently-selected tile so we can scroll it into view via
  // Scrollable.ensureVisible instead of guessing a fixed row height.
  final _selectedTileKey = GlobalKey();
  // Whatever held focus when the palette opened - restored on dismiss so the
  // shell / terminal regains focus.
  FocusNode? _previousFocus;
  int _selectedIndex = 0;
  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    // Capture the outgoing focus BEFORE we steal it, so it can be restored.
    _previousFocus = FocusManager.instance.primaryFocus;
    _focusNode.requestFocus();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    // Where the palette still has the keyboard as it goes, it goes back to
    // whatever had it when the palette opened. A choice that gave it to
    // something else keeps it there: Quick connect's field, Find in
    // terminal's (it was given back to the terminal behind them).
    final now = FocusManager.instance.primaryFocus;
    final stillHere = now == null || now == _focusNode || now == _keyFocusNode;
    // Gone, however it went: a palette taken down with its navigator (never
    // popped) left the flag up, and the next shortcut closed nothing instead
    // of opening one.
    _paletteOpen = false;
    _controller.dispose();
    _focusNode.dispose();
    _keyFocusNode.dispose();
    _scrollController.dispose();
    _animController.dispose();
    if (stillHere && _previousFocus?.context != null) {
      _previousFocus!.requestFocus();
    }
    super.dispose();
  }

  // ── Pool builders ───────────────────────────────────────────────

  String _userHost(ConnectionWithDetails c) {
    final u = c.identity?.username;
    final h = c.connection.host;
    return (u != null && u.isNotEmpty) ? '$u@$h' : h;
  }

  /// A host's name to sort by: its label, else its address.
  String _sortName(Connection c) => (c.label.isNotEmpty ? c.label : c.host).toLowerCase();

  _Row _hostRow(ConnectionWithDetails c, _RowKind kind, Map<String, int> open, AppLocalizations l10n) {
    final conn = c.connection;
    return _Row(
      id: '${kind.name}_${conn.id}',
      kind: kind,
      host: c,
      open: open[conn.id] ?? 0,
      title: hostRowName(conn, ref),
      subtitle: hostRowEndpoint(conn, c.identity?.username, ref),
      subtitleMono: true,
      time: conn.lastConnected == null ? null : timeAgoShort(l10n, conn.lastConnected!),
      fuzzy: [conn.label, conn.host, _userHost(c)],
      onSelect: () => _connect(c),
      onSplit: () => _openInSplit(c),
    );
  }

  /// The ≤5 most-recently-connected hosts, deduped to ONE row per host.
  List<_Row> _buildRecent(List<ConnectionWithDetails> cwds, Map<String, int> open, AppLocalizations l10n) {
    final timed = cwds
        .where((c) => c.connection.lastConnected != null)
        .toList()
      ..sort((a, b) => b.connection.lastConnected!
          .compareTo(a.connection.lastConnected!));

    final rows = <_Row>[];
    final seenHosts = <String>{};
    for (final c in timed) {
      if (!seenHosts.add(c.connection.host)) continue; // dedup on host
      rows.add(_hostRow(c, _RowKind.recent, open, l10n));
      if (rows.length >= _kRecentLimit) break;
    }
    return rows;
  }

  /// Every host, by name.
  List<_Row> _buildHosts(List<ConnectionWithDetails> cwds, Map<String, int> open, AppLocalizations l10n) {
    final sorted = [...cwds]..sort((a, b) => _sortName(a.connection).compareTo(_sortName(b.connection)));
    return [for (final c in sorted) _hostRow(c, _RowKind.host, open, l10n)];
  }

  /// [host], chosen: connected to as the caller connects to a host.
  void _connect(ConnectionWithDetails host) {
    final connect = widget.onConnect;
    if (connect != null) {
      connect(host);
    } else {
      ref.read(activeSessionsProvider.notifier).startSession(host.connection);
    }
  }

  /// [host] as a pane beside the panes of the tab in front (Ctrl+Enter).
  void _openInSplit(ConnectionWithDetails host) {
    final split = widget.onOpenInSplit;
    if (split != null) {
      split(host);
      return;
    }
    // The palette is already popped: the app's navigator asks what it asks.
    unawaited(openHostInSplit(Navigator.of(context, rootNavigator: true).context, ref, host.connection));
  }

  /// The hosts of a group, broadcast to (Broadcast to hosts, with them
  /// ticked: the person sees them before anything opens).
  void _broadcast(Set<String> ids) {
    final broadcast = widget.onBroadcast;
    if (broadcast != null) {
      broadcast(ids);
      return;
    }
    unawaited(broadcastToHostsFlow(Navigator.of(context, rootNavigator: true).context, ref, preselected: ids));
  }

  List<_Row> _buildSnippets(List<Snippet> snippets) {
    return [
      for (final s in snippets)
        _Row(
          id: 'snippet_${s.id}',
          kind: _RowKind.snippet,
          icon: LucideIcons.braces,
          title: s.label,
          subtitle: _firstLine(s.command),
          subtitleMono: true,
          tag: (s.category ?? '').trim().isEmpty ? null : s.category!.trim(),
          fuzzy: [s.label, s.command, s.category],
          onSelect: () => _runSnippet(s),
        ),
    ];
  }

  List<_Row> _buildActions() {
    // The desktop shell injects its context-aware action set, which REPLACES
    // the built-in list. Map them straight through: each keeps its
    // accelerator and what it does.
    final injected = widget.injectedActions;
    if (injected != null) {
      return [
        for (final it in injected)
          _Row(
            id: it.id,
            kind: _RowKind.action,
            icon: it.icon,
            title: it.title,
            subtitle: it.subtitle,
            shortcut: it.shortcut,
            fuzzy: [it.title],
            whole: [it.subtitle],
            onSelect: it.onSelect,
          ),
      ];
    }
    return _builtInActions();
  }

  /// The actions that name what was typed: "Open web-01 in SFTP" for the
  /// host that matches best, and "Broadcast to the Web group" for each group
  /// whose name holds it and has two hosts or more to type to. Each is the
  /// app's own way of doing it (the Hosts page's SFTP, Broadcast to hosts).
  List<_Row> _namedActions(List<_Row> rankedHosts, List<ConnectionWithDetails> cwds, String query, AppLocalizations l10n) {
    final out = <_Row>[];
    final sftp = widget.onOpenSftp;
    final top = rankedHosts.firstOrNull?.host;
    if (sftp != null && top != null) {
      final protocol = top.connection.protocol.toLowerCase();
      if (protocol == 'ssh' || protocol == 'sftp') {
        out.add(_Row(
          id: 'sftp_${top.connection.id}',
          kind: _RowKind.action,
          icon: LucideIcons.folderOpen,
          title: l10n.paletteOpenInSftp(hostRowName(top.connection, ref)),
          subtitle: l10n.paletteOpenInSftpDesc,
          onSelect: () => sftp(top),
        ));
      }
    }
    final groups = <String, (ConnectionGroup, List<ConnectionWithDetails>)>{};
    for (final c in cwds) {
      final g = c.group;
      if (g == null) continue;
      groups.putIfAbsent(g.id, () => (g, <ConnectionWithDetails>[])).$2.add(c);
    }
    for (final (group, members) in groups.values) {
      if (wholeMatches(group.name, query).isEmpty) continue;
      final typing = [for (final c in members) if (noTerminalReason(c.connection, l10n) == null) c];
      if (typing.length < kBroadcastFewestHosts) continue;
      final ids = {for (final c in typing) c.connection.id};
      out.add(_Row(
        id: 'broadcast_${group.id}',
        kind: _RowKind.action,
        icon: LucideIcons.radioTower,
        title: l10n.paletteBroadcastGroup(Redactable.group(group.name).displayIn(ref)),
        subtitle: typing.length == 2
            ? l10n.paletteBroadcastTwo(hostRowName(typing[0].connection, ref), hostRowName(typing[1].connection, ref))
            : l10n.paletteBroadcastMany(typing.length),
        onSelect: () => _broadcast(ids),
      ));
    }
    return out;
  }

  /// Fallback action set used when no caller-injected actions are supplied.
  /// Every entry connects, runs, or navigates - nothing switches sessions.
  List<_Row> _builtInActions() {
    final l10n = AppLocalizations.of(context)!;
    final router = GoRouter.of(context);
    // Live accelerator labels - pulled from the user's CURRENT bindings so the
    // keycaps shown here always match what actually fires.
    final binds = ref.read(shortcutBindingsProvider);
    String? accel(ShortcutAction a) => binds.bindingFor(a)?.displayLabel;

    _Row action(String id, IconData icon, String title, String desc, VoidCallback onSelect, {String? shortcut}) => _Row(
          id: id,
          kind: _RowKind.action,
          icon: icon,
          title: title,
          subtitle: desc,
          shortcut: shortcut,
          fuzzy: [title],
          whole: [desc],
          onSelect: onSelect,
        );

    return [
      action('action_new_connection', LucideIcons.plusCircle, l10n.hostsNewHost, l10n.paletteDescNewHost,
          () => router.push(Routes.connectionEdit),
          shortcut: accel(ShortcutAction.newConnection)),
      action('action_open_sftp', LucideIcons.folderInput, l10n.zestPaletteActionSftp, l10n.paletteDescSftpActive,
          _openSftpForActiveSession),
      action('action_split', LucideIcons.rows, l10n.zestPaletteActionSplit, l10n.paletteDescSplitRight,
          _splitActiveSessions),
      // ── Screen navigation ──
      action('action_server_monitor', LucideIcons.activity, l10n.commandPaletteSectionActionMonitor,
          l10n.paletteDescGoMonitor, () => router.push(Routes.monitor)),
      action('action_snippets', LucideIcons.code, l10n.snippetsTitle, l10n.paletteDescGoSnippets,
          () => router.push(Routes.snippets)),
      action('action_identities', LucideIcons.keyRound, l10n.commandPaletteSectionActionIdentities,
          l10n.paletteDescGoKeys, () => router.push(Routes.identityList)),
      action('action_keygen', LucideIcons.keyRound, l10n.commandPaletteSectionActionKeygen, l10n.paletteDescGenerateKey,
          () => router.push(Routes.keyGeneration)),
      // The palette's own context closes with it: the app's navigator opens
      // the dialog.
      action('action_import_hosts', LucideIcons.downloadCloud, l10n.cloudImpTitle, l10n.paletteDescImportHosts, () {
        final opener = router.routerDelegate.navigatorKey.currentContext;
        if (opener != null) openImportHosts(opener);
      }),
      action('action_import_ssh', LucideIcons.download, l10n.commandPaletteSectionActionImportSsh,
          l10n.cloudImpSshConfigDesc, () => router.push(Routes.sshConfigImport)),
      action('action_import_putty', LucideIcons.download, l10n.commandPaletteSectionActionImportPutty,
          l10n.cloudImpPuttyDesc, () => router.push(Routes.puttyImport)),
      // ── Settings panes ──
      action('action_settings', LucideIcons.settings, l10n.settingsTitle, l10n.paletteDescSettings,
          () => router.push(Routes.settings),
          shortcut: accel(ShortcutAction.settings)),
      action('action_about', LucideIcons.info, l10n.commandPaletteSectionActionAbout, l10n.paletteDescAbout,
          () => router.push(Routes.about)),
      if (zestHasPlans)
        action('action_upgrade', LucideIcons.star, l10n.commandPaletteSectionActionUpgrade, l10n.paletteDescUpgrade,
            () => router.push(Routes.upgrade)),
    ];
  }

  // ── Action handlers that need shell state ───────────────────────

  void _openSftpForActiveSession() {
    final sessions = ref.read(activeSessionsProvider);
    final ids = sessions.keys.toList();
    final tab = ref.read(desktopSelectedTabProvider);
    if (tab < 0 || tab >= ids.length) return;
    // The legacy classic-layout split state is the only GLOBAL split/SFTP
    // entry point; the modern paneTree API needs a shell-owned leaf id. On
    // desktop these come from the injected action set anyway.
    // ignore: deprecated_member_use_from_same_package
    ref.read(splitPaneProvider.notifier).openSftp(ids[tab]);
  }

  void _splitActiveSessions() {
    final sessions = ref.read(activeSessionsProvider);
    final ids = sessions.keys.toList();
    if (ids.length < 2) return;
    final tab = ref.read(desktopSelectedTabProvider);
    final primary = (tab >= 0 && tab < ids.length) ? ids[tab] : ids.first;
    final secondary = ids.firstWhere((id) => id != primary, orElse: () => primary);
    if (secondary == primary) return;
    // ignore: deprecated_member_use_from_same_package
    ref.read(splitPaneProvider.notifier).splitRight(secondary);
  }

  // ── Snippet execution ───────────────────────────────────────────

  Future<void> _runSnippet(Snippet snippet) async {
    // The session the person is looking at: the focused one, else the
    // selected tab's.
    final sessions = ref.read(activeSessionsProvider);
    final focused = ref.read(v3ActiveSessionTabProvider);
    var session = focused == null ? null : sessions[focused];
    if (session?.session?.terminal == null) {
      final tabIndex = ref.read(desktopSelectedTabProvider);
      final sessionIds = sessions.keys.toList();
      session = (tabIndex >= 0 && tabIndex < sessionIds.length) ? sessions[sessionIds[tabIndex]] : null;
    }
    final terminal = session?.session?.terminal;
    if (terminal == null) return;
    // A remote screen (4.0) has no shell to type the snippet into.
    if (session?.session?.shell is ScreenShellService) {
      final root = Navigator.of(context, rootNavigator: true).context;
      showTopSnackBar(root, AppLocalizations.of(root)!.hostScreenNoTerminal, isWarning: true);
      return;
    }
    // The palette is already popped: the shared path takes the root
    // navigator's context for its dialogs. A list of the host's own is read
    // on the session it types into.
    await runSnippetIn(Navigator.of(context, rootNavigator: true).context, ref, snippet, terminal,
        listOptions: listOptionsFrom(session));
  }

  // ── Filtering ───────────────────────────────────────────────────

  /// Split a `>` / `#` / `@` prefix off the raw text. Returns the restricted
  /// kind (null = all sections) and the trimmed query remainder.
  (_RowKind?, String) _parsePrefix(String raw) {
    if (raw.startsWith('>')) return (_RowKind.action, raw.substring(1).trim());
    if (raw.startsWith('#')) return (_RowKind.snippet, raw.substring(1).trim());
    if (raw.startsWith('@')) return (_RowKind.host, raw.substring(1).trim());
    return (null, raw.trim());
  }

  /// Turn the raw search text into the ordered, section-grouped result list.
  List<_Row> _computeRows(String rawText, AppLocalizations l10n) {
    final (mode, query) = _parsePrefix(rawText);

    final cwds = ref.read(connectionsWithDetailsProvider).valueOrNull ??
        const <ConnectionWithDetails>[];
    final snippets =
        ref.read(snippetsProvider).valueOrNull ?? const <Snippet>[];
    final open = openSessionCountsOf(ref.read(activeSessionsProvider));

    if (query.isEmpty) {
      switch (mode) {
        case null:
          // The hosts connected to last, where there are any: all of them
          // pushed the actions and the snippets out of sight.
          final recent = _buildRecent(cwds, open, l10n);
          return [
            ...(recent.isNotEmpty ? recent : _buildHosts(cwds, open, l10n)),
            ..._buildActions(),
            ..._buildSnippets(snippets),
          ];
        case _RowKind.host || _RowKind.recent:
          return _buildHosts(cwds, open, l10n);
        case _RowKind.action:
          return _buildActions();
        case _RowKind.snippet:
          return _buildSnippets(snippets);
      }
    }

    final cap = mode == null ? _kSectionCap : _kFilteredCap;
    final hosts = _rank(_buildHosts(cwds, open, l10n), query);
    return [
      if (mode == null || mode == _RowKind.host) ...hosts.take(cap),
      if (mode == null || mode == _RowKind.action)
        ...[..._namedActions(hosts, cwds, query, l10n), ..._rank(_buildActions(), query)].take(cap),
      if (mode == null || mode == _RowKind.snippet) ..._rank(_buildSnippets(snippets), query).take(cap),
    ];
  }

  List<_Row> _rank(List<_Row> pool, String query) {
    final lower = query.toLowerCase();
    final scored = <_Row>[];
    for (final r in pool) {
      var s = bestFuzzyScore(query, r.fuzzy);
      // What an action does counts where it holds the words whole, below a
      // name that holds them.
      if (s < 0.6 && r.whole.any((w) => w != null && w.toLowerCase().contains(lower))) s = 0.6;
      if (s > 0) {
        r.score = s;
        scored.add(r);
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored;
  }

  // ── Keyboard ────────────────────────────────────────────────────

  /// Whether the key that opens a host in a split is held: Ctrl, or Cmd on
  /// a Mac (where Control is taken as well).
  bool get _splitHeld {
    final keys = HardwareKeyboard.instance;
    return defaultTargetPlatform == TargetPlatform.macOS
        ? keys.isMetaPressed || keys.isControlPressed
        : keys.isControlPressed;
  }

  /// Central key handler. Returns [KeyEventResult.handled] for keys we own so
  /// they don't leak to the TextField (arrows/enter) or the shell (Tab).
  KeyEventResult _handleKey(KeyEvent event, List<_Row> filtered) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    void move(int delta) {
      if (filtered.isEmpty) return;
      setState(() {
        _selectedIndex = (_selectedIndex + delta) % filtered.length;
        if (_selectedIndex < 0) _selectedIndex += filtered.length;
      });
      _ensureSelectedVisible();
      _announce(filtered[_selectedIndex]);
    }

    void jumpTo(int index) {
      if (filtered.isEmpty) return;
      setState(() => _selectedIndex = index.clamp(0, filtered.length - 1));
      _ensureSelectedVisible();
      _announce(filtered[_selectedIndex]);
    }

    if (key == LogicalKeyboardKey.escape) {
      _handleEscape();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        (ctrl && key == LogicalKeyboardKey.keyN)) {
      move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        (ctrl && key == LogicalKeyboardKey.keyP)) {
      move(-1);
      return KeyEventResult.handled;
    }
    // Tab / Shift+Tab cycle results instead of escaping the palette's scope.
    if (key == LogicalKeyboardKey.tab) {
      move(shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      jumpTo(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      jumpTo(filtered.length - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      jumpTo(_selectedIndex + 8);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      jumpTo(_selectedIndex - 8);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (filtered.isNotEmpty && _selectedIndex < filtered.length) {
        final row = filtered[_selectedIndex];
        if (!_splitHeld) {
          _select(row);
        } else if (row.onSplit != null) {
          // Ctrl+Enter: a host in a split. (Nothing else has one: the
          // footer offers it only for a host.)
          _split(row);
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Escape clears an active `>` / `#` / `@` prefix filter first; a second
  /// press (with no prefix left) closes the palette.
  void _handleEscape() {
    final text = _controller.text;
    if (text.startsWith('>') || text.startsWith('#') || text.startsWith('@')) {
      final rest = text.substring(1);
      _controller.value = TextEditingValue(
        text: rest,
        selection: TextSelection.collapsed(offset: rest.length),
      );
      setState(() => _selectedIndex = 0);
      return;
    }
    _dismiss();
  }

  void _dismiss() => Navigator.of(context).pop();

  void _select(_Row row) {
    _dismiss();
    row.onSelect();
  }

  void _split(_Row row) {
    final split = row.onSplit;
    if (split == null) return;
    _dismiss();
    split();
  }

  /// What a screen reader says of [row] as the keys reach it: its words, and
  /// for a host the key that opens it in a split.
  String _spoken(_Row row) {
    final l10n = AppLocalizations.of(context)!;
    return [
      row.title,
      if (row.open > 0) _openWords(l10n, row.open),
      ?row.subtitle,
      ?row.time,
      ?row.tag,
      ?row.shortcut,
      if (row.onSplit != null) '${l10n.hpanelOpenInSplit} ${paletteSplitKeyLabel()}',
    ].join(', ');
  }

  void _announce(_Row row) {
    unawaited(SemanticsService.sendAnnouncement(View.of(context), _spoken(row), Directionality.of(context)));
  }

  void _ensureSelectedVisible() {
    // Scroll the actual selected tile into view (measured via its GlobalKey,
    // not a guessed row height). Deferred to post-frame because the newly
    // selected tile may not be laid out yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedTileKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Watch providers so the list updates reactively.
    ref.watch(activeSessionsProvider);
    ref.watch(connectionsWithDetailsProvider);
    ref.watch(snippetsProvider);

    final l10n = AppLocalizations.of(context)!;
    final rawText = _controller.text;
    final filtered = _computeRows(rawText, l10n);
    if (_selectedIndex >= filtered.length) {
      _selectedIndex = filtered.isEmpty ? 0 : filtered.length - 1;
    }
    final selected = filtered.isEmpty ? null : filtered[_selectedIndex];

    // The count / no-results copy reflect what the user has TYPED.
    final (_, strippedQuery) = _parsePrefix(rawText);
    final queryActive = rawText.isNotEmpty;

    return FadeTransition(
      opacity: _fadeAnim,
      // Focus (not KeyboardListener) so we can RETURN handled and stop Tab from
      // escaping the palette into the shell's focus traversal.
      child: Focus(
        focusNode: _keyFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) => _handleKey(event, filtered),
        child: Container(
          // Autosize relative to the host window: 60% of the width, capped at
          // 760 (ultra-wides) and floored at 360 (split-screen).
          width: math.max(
            360,
            math.min(760, MediaQuery.of(context).size.width * 0.6),
          ),
          // 60% of the window, clamped to 400-720, and the user's own drag
          // resize is remembered per window size (spec 9).
          constraints: BoxConstraints(maxHeight: _paletteHeight(context)),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ZestTokens.surfaceElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ZestTokens.borderStrong),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Search field ─────────────────────────────────
              Container(
                constraints: const BoxConstraints(minHeight: 56),
                padding: const EdgeInsetsDirectional.fromSTEB(18, 6, 16, 6),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZestTokens.borderSubtle))),
                child: Row(
                  children: [
                    Icon(LucideIcons.search, size: 18, color: ZestTokens.textFaint),
                    const SizedBox(width: 12),
                    Expanded(
                      // Named for a screen reader while it holds words too
                      // (its hint, all it had, goes once something is typed).
                      child: Semantics(
                        label: l10n.zestPaletteHint,
                        child: TextField(
                        key: const ValueKey('palette-query'),
                        controller: _controller,
                        focusNode: _focusNode,
                        cursorColor: ZestTokens.brand,
                        onChanged: (_) => setState(() => _selectedIndex = 0),
                        decoration: InputDecoration(
                          hintText: l10n.zestPaletteHint,
                          hintStyle: TextStyle(fontSize: 16, color: ZestTokens.textTertiary),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        style: TextStyle(fontSize: 16, color: ZestTokens.textPrimary),
                      ),
                      ),
                    ),
                    if (queryActive) ...[
                      const SizedBox(width: 12),
                      // Said again as it changes, to a screen reader too (a
                      // node of its own: it took the footer's words with it).
                      Semantics(
                        container: true,
                        liveRegion: true,
                        child: Text(
                          l10n.zestPaletteResults(filtered.length),
                          key: const ValueKey('palette-count'),
                          style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // ── Results ──────────────────────────────────────
              if (filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 18),
                  child: Text(
                    queryActive
                        ? l10n.zestPaletteNoResults(strippedQuery)
                        : l10n.commandPaletteNoResults,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ZestTokens.textTertiary,
                      fontSize: 14,
                    ),
                  ),
                )
              else
                Flexible(child: _buildGroupedList(filtered, strippedQuery)),

              // ── Footer: the keys ─────────────────────────────
              _Footer(hostInHand: selected?.isHost ?? false),
              // Resize handle: drag to change the palette height; the size is
              // remembered for this window size.
              MouseRegion(
                cursor: SystemMouseCursors.resizeUpDown,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => setState(() {
                    _userHeight =
                        (_userHeight ?? _paletteHeight(context)) + d.delta.dy;
                  }),
                  onVerticalDragEnd: (_) => _persistHeight(),
                  child: Container(
                    color: ZestTokens.surfacePanel,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ZestTokens.borderStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Height (spec 9) ────────────────────────────────────────────────

  double? _userHeight;
  bool _heightLoaded = false;

  static const double _kMinHeight = 400;
  static const double _kMaxHeight = 720;

  String _heightKey(double windowHeight) =>
      'palette_height_${(windowHeight / 100).round()}';

  double _heightCap(double windowHeight) =>
      math.min(_kMaxHeight, math.max(_kMinHeight, windowHeight - 80));

  double _paletteHeight(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    if (!_heightLoaded) {
      _heightLoaded = true;
      try {
        _userHeight = ref.read(sharedPreferencesProvider).getDouble(_heightKey(h));
      } catch (_) {
        // No preferences in this scope (tests): fall back to the default.
      }
    }
    return (_userHeight ?? h * 0.6).clamp(_kMinHeight, _heightCap(h));
  }

  void _persistHeight() {
    final v = _userHeight;
    if (v == null) return;
    final h = MediaQuery.sizeOf(context).height;
    final clamped = v.clamp(_kMinHeight, _heightCap(h));
    _userHeight = clamped;
    try {
      // ignore: discarded_futures
      ref.read(sharedPreferencesProvider).setDouble(_heightKey(h), clamped);
    } catch (_) {}
  }

  /// Build the flat result list, inserting a section header whenever the
  /// section changes. Selection indexes only the real rows, so Up/Down move
  /// across section boundaries and skip headings.
  Widget _buildGroupedList(List<_Row> rows, String query) {
    final l10n = AppLocalizations.of(context)!;
    final widgets = <Widget>[];
    String? lastHeader;
    final timeSlot = _timeSlotWidth(context, rows);

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final header = _headerFor(row, l10n);
      if (header != lastHeader) {
        lastHeader = header;
        widgets.add(_SectionHeader(label: header));
      }

      final isSelected = i == _selectedIndex;
      widgets.add(_PaletteResultTile(
        key: isSelected ? _selectedTileKey : null,
        row: row,
        isSelected: isSelected,
        query: query,
        timeSlotWidth: timeSlot,
        onTap: () {
          // Ctrl+click (Cmd+click on a Mac) on a host: in a split, as the keys.
          if (_splitHeld && row.onSplit != null) {
            _split(row);
          } else {
            _select(row);
          }
        },
        onSplit: row.onSplit == null ? null : () => _split(row),
        onHover: () {
          if (_selectedIndex != i) {
            setState(() => _selectedIndex = i);
          }
        },
      ));
    }

    return ListView(
      controller: _scrollController,
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      children: widgets,
    );
  }

  String _headerFor(_Row row, AppLocalizations l10n) => switch (row.kind) {
        _RowKind.recent => l10n.zestPaletteRecent,
        _RowKind.host => l10n.zestPaletteConnections,
        _RowKind.snippet => l10n.zestPaletteSnippets,
        _RowKind.action => l10n.zestPaletteActions,
      };
}

/// A host's open sessions in words: "Open", or "2 open".
String _openWords(AppLocalizations l10n, int open) =>
    open > 1 ? l10n.paletteOpenCount(open) : l10n.broadcastToHostsIsOpen;

// ── Section header ──────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(18, 14, 18, 7),
        child: Text(
          label.toUpperCase(),
          // In its own case to a screen reader (some read capitals letter by
          // letter).
          semanticsLabel: label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: ZestTokens.textTertiary,
            letterSpacing: 1.3,
            height: 1,
          ),
        ),
      ),
    );
  }
}

// ── Result tile ─────────────────────────────────────────────────

class _PaletteResultTile extends StatelessWidget {
  final _Row row;
  final bool isSelected;

  /// What was typed (the filter's sign taken off): marked where it matches.
  final String query;

  /// How wide the time slot is, the same on every host's row
  /// ([_timeSlotWidth]).
  final double timeSlotWidth;
  final VoidCallback onTap;
  final VoidCallback? onSplit;
  final VoidCallback onHover;

  const _PaletteResultTile({
    super.key,
    required this.row,
    required this.isSelected,
    required this.query,
    required this.timeSlotWidth,
    required this.onTap,
    required this.onSplit,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, box) {
      // The row in hand says what Enter does (and for a host Ctrl+Enter),
      // where its words keep room beside it; the footer always does.
      final enter = row.isHost ? l10n.hostsHomeMenuOpen : l10n.paletteKeyRun;
      Widget? hints;
      if (isSelected) {
        final words = _RowHints.words();
        var wanted = _keyHintWidth(context, shortcutEnterLabel(), enter, words);
        if (row.onSplit != null) {
          wanted += _keyHintWidth(context, paletteSplitKeyLabel(), l10n.hpanelOpenInSplit, words) + _HintRule.width;
        }
        // Its edges, its icon, and what else stands at its end.
        var taken = 16.0 + 20 + 32 + 12 + 12;
        if (row.isHost && timeSlotWidth > 0) taken += timeSlotWidth + 12;
        if (row.shortcut != null) taken += _spanWidth(context, TextSpan(text: row.shortcut, style: _kKbdStyle)) + 13 + 10 + _HintRule.width;
        if (row.tag != null) taken += 160 + 10 + _HintRule.width;
        if (box.maxWidth - taken - wanted >= _kRowWordsAtLeast) {
          hints = _RowHints(
            split: row.onSplit == null ? null : (label: l10n.hpanelOpenInSplit, onTap: onSplit),
            enter: enter,
          );
        }
      }
      final host = row.host;
      final Widget content;
      if (host != null) {
        final trailing = <Widget>[
          ?hints,
          if (timeSlotWidth > 0) ...[
            if (hints != null) const SizedBox(width: 12),
            SizedBox(
              width: timeSlotWidth,
              child: Text(
                row.time ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: _kTimeSlotStyle.copyWith(color: ZestTokens.textTertiary),
              ),
            ),
          ],
        ];
        content = HostRow(
          host: host.connection,
          user: host.identity?.username,
          group: host.group,
          open: row.open > 0,
          openLabel: _openWords(l10n, row.open),
          showOpenLabel: true,
          under: true,
          iconSize: 32,
          highlight: query.isEmpty ? null : query,
          nameStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
          padding: EdgeInsets.zero,
          margin: EdgeInsets.zero,
          hovers: false,
          trailing: trailing.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: trailing),
        );
      } else {
        content = _ActionOrSnippet(row: row, query: query, hints: hints);
      }
      final shape = BorderRadius.circular(9);
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(),
        child: MergeSemantics(
          child: Semantics(
            button: true,
            selected: isSelected,
            onTap: onTap,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // (The Semantics above has the row's tap.)
              excludeFromSemantics: true,
              onTap: onTap,
              child: Container(
                key: ValueKey('palette-row-${row.id}'),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: isSelected ? ZestTokens.brandFill : Colors.transparent,
                  borderRadius: shape,
                  border: Border.all(color: isSelected ? ZestTokens.brandBorder : Colors.transparent),
                ),
                child: content,
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// An action's or a snippet's row: its icon in a tile, its name over what it
/// does (an action) or its command (a snippet), and at its end a snippet's
/// category, an action's shortcut, and in the row in hand what Enter does.
class _ActionOrSnippet extends StatelessWidget {
  const _ActionOrSnippet({required this.row, required this.query, required this.hints});

  final _Row row;
  final String query;
  final Widget? hints;

  @override
  Widget build(BuildContext context) {
    final subtitle = row.subtitle;
    final tag = row.tag;
    final marks = _marksOf(row, query);
    final trailing = <Widget>[
      if (tag != null) _TagChip(tag: tag, marks: marks[2]),
      if (row.shortcut != null) Kbd(row.shortcut!),
      if (hints != null) ...[
        if (tag != null || row.shortcut != null) const _HintRule(),
        hints!,
      ],
    ];
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ZestTokens.surfaceChip,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(row.icon, size: 16, color: ZestTokens.textSecondary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text.rich(
                markedText(row.title, marks[0]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary, height: 1.3),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text.rich(
                  markedText(subtitle, marks[1]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: row.subtitleMono
                      ? TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary, height: 1.35)
                      : TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary, height: 1.35),
                ),
              ],
            ],
          ),
        ),
        for (final w in trailing) ...[const SizedBox(width: 10), w],
      ],
    );
  }

  /// What is marked in the name, the second line and the category. What an
  /// action does is marked only where its name holds nothing of what was
  /// typed (it was found by it).
  static List<List<TextRange>> _marksOf(_Row row, String query) {
    if (query.isEmpty) return const [[], [], []];
    final snippet = row.kind == _RowKind.snippet;
    final marks = matchesIn([
      (text: row.title, fuzzy: true),
      (text: row.subtitle ?? '', fuzzy: snippet),
      (text: row.tag ?? '', fuzzy: snippet),
    ], query);
    if (!snippet && marks[0].isNotEmpty) return [marks[0], const [], marks[2]];
    return marks;
  }
}

/// A snippet's category, in a pill with a tag before it.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.marks});

  final String tag;
  final List<TextRange> marks;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(7, 2, 9, 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: ZestTokens.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.tag, size: 12, color: ZestTokens.textFaint),
            const SizedBox(width: 5),
            Flexible(
              child: Text.rich(
                markedText(tag, marks),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: ZestTokens.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the keys do on the row in hand: for a host Open in split (its key,
/// and a click does it too), then what Enter does.
class _RowHints extends StatelessWidget {
  const _RowHints({required this.split, required this.enter});

  final ({String label, VoidCallback? onTap})? split;
  final String enter;

  /// How its words are drawn.
  static TextStyle words() => TextStyle(fontSize: 12, color: ZestTokens.textFaint);

  @override
  Widget build(BuildContext context) {
    final style = words();
    final split = this.split;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (split != null) ...[
          GestureDetector(
            key: const ValueKey('palette-row-split'),
            behavior: HitTestBehavior.opaque,
            // A screen reader reads the words; the row's own action opens it,
            // and Ctrl+Enter is said with the row.
            excludeFromSemantics: true,
            onTap: split.onTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(split.label, style: style),
                const SizedBox(width: 6),
                Kbd(paletteSplitKeyLabel()),
              ],
            ),
          ),
          const _HintRule(),
        ],
        Text(enter, style: style.copyWith(color: ZestTokens.textSecondary)),
        const SizedBox(width: 6),
        Kbd(shortcutEnterLabel()),
      ],
    );
  }
}

/// The thin line between two hints.
class _HintRule extends StatelessWidget {
  const _HintRule();

  /// How wide it stands, with the room each side of it.
  static const double width = 25;

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 16,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        color: ZestTokens.border,
      );
}

/// The keys, at the palette's foot: move, what Enter does on the row in
/// hand, Ctrl+Enter for a host, Esc; then the filters (`>` actions,
/// `#` snippets, `@` hosts). What has no room in this language and text size
/// drops: the filters first, then Move, then Ctrl+Enter (the row in hand
/// says it too); Enter and Esc stay.
class _Footer extends StatelessWidget {
  const _Footer({required this.hostInHand});

  final bool hostInHand;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = TextStyle(fontSize: 12, color: ZestTokens.textFaint);
    final arrows = '${formatShortcutKey(ShortcutKey(keyId: LogicalKeyboardKey.arrowUp.keyId))}'
        '${formatShortcutKey(ShortcutKey(keyId: LogicalKeyboardKey.arrowDown.keyId))}';
    final move = (keys: arrows, label: l10n.paletteKeyMove, key: const ValueKey('palette-footer-move'));
    final enter = (
      keys: shortcutEnterLabel(),
      label: hostInHand ? l10n.hostsHomeMenuOpen : l10n.paletteKeyRun,
      key: const ValueKey('palette-footer-enter'),
    );
    final split = (keys: paletteSplitKeyLabel(), label: l10n.paletteKeySplit, key: const ValueKey('palette-footer-split'));
    final esc = (keys: shortcutEscLabel(), label: l10n.close, key: const ValueKey('palette-footer-esc'));
    final sign = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, fontWeight: FontWeight.w700, color: ZestTokens.textFaint);
    final filter = TextStyle(fontSize: 12, color: ZestTokens.textTertiary);
    final filters = TextSpan(children: [
      TextSpan(text: '>', style: sign),
      TextSpan(text: ' ${l10n.paletteFilterActions}   ', style: filter),
      TextSpan(text: '#', style: sign),
      TextSpan(text: ' ${l10n.paletteFilterSnippets}   ', style: filter),
      TextSpan(text: '@', style: sign),
      TextSpan(text: ' ${l10n.paletteFilterHosts}', style: filter),
    ]);
    // A node of its own for a screen reader: the keys, apart from the rows
    // and the count above them.
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('palette-footer'),
        constraints: const BoxConstraints(minHeight: 38),
        padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 16, 4),
        decoration: BoxDecoration(
          color: ZestTokens.surfacePanel,
          border: Border(top: BorderSide(color: ZestTokens.borderSubtle)),
        ),
        child: LayoutBuilder(builder: (context, box) {
          const gap = 16.0;
          double width(({String keys, String label, ValueKey<String> key}) k) =>
              _keyHintWidth(context, k.keys, k.label, words);
          // Kept in this order of need; shown in the order of the keys.
          var shown = {enter, esc};
          var used = width(enter) + gap + width(esc);
          for (final k in [if (hostInHand) split, move]) {
            if (used + gap + width(k) > box.maxWidth) continue;
            shown = {...shown, k};
            used += gap + width(k);
          }
          final keys = [for (final k in [move, enter, if (hostInHand) split, esc]) if (shown.contains(k)) k];
          final room = box.maxWidth - used - gap;
          final filtersFit = room >= _spanWidth(context, filters);
          return Row(
            children: [
              for (final (i, k) in keys.indexed) ...[
                if (i > 0) const SizedBox(width: gap),
                Row(
                  key: k.key,
                  mainAxisSize: MainAxisSize.min,
                  children: [Kbd(k.keys), const SizedBox(width: 6), Text(k.label, maxLines: 1, style: words)],
                ),
              ],
              if (filtersFit) ...[
                const SizedBox(width: gap),
                Expanded(
                  child: Text.rich(
                    filters,
                    key: const ValueKey('palette-footer-filters'),
                    maxLines: 1,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ],
          );
        }),
      ),
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────

/// How a key's chip ([Kbd]) draws its words.
const _kKbdStyle = TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono');

/// How wide [span] is drawn here: in this language, at the person's text
/// size.
double _spanWidth(BuildContext context, InlineSpan span) {
  final painter = TextPainter(
    text: TextSpan(style: DefaultTextStyle.of(context).style, children: [span]),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width.ceilToDouble();
  painter.dispose();
  return width;
}

/// How wide a key's chip with its word beside it is drawn ([Kbd]: its words,
/// 6 each side and its edge; 6 between).
double _keyHintWidth(BuildContext context, String keys, String label, TextStyle words) =>
    _spanWidth(context, TextSpan(text: keys, style: _kKbdStyle)) + 13 + 6 + _spanWidth(context, TextSpan(text: label, style: words));

/// How the time slot draws its words.
const _kTimeSlotStyle = TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono');

/// The time slot's width: the widest of [rows]' times as the slot draws them,
/// at the person's text size, and at least the 42 it had; none where no
/// host's row has a time. A time in German or French is longer than its
/// English ("23 Std.", "maintenant"), and English itself lost its end there
/// ("12m a...").
double _timeSlotWidth(BuildContext context, List<_Row> rows) {
  final times = {
    for (final row in rows)
      if (row.isHost && row.time != null) row.time!,
  };
  if (times.isEmpty) return 0;
  final style = DefaultTextStyle.of(context).style.merge(_kTimeSlotStyle);
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  var widest = 42.0;
  for (final time in times) {
    final painter = TextPainter(
      text: TextSpan(text: time, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    widest = math.max(widest, painter.width.ceilToDouble());
    painter.dispose();
  }
  return widest;
}

/// A command's first line, with … where it has more.
String _firstLine(String command) {
  final lines = command.trim().split('\n');
  final first = lines.first.trimRight();
  return lines.length > 1 ? '$first …' : first;
}
