import 'dart:convert';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/host_address.dart';

/// SharedPreferences key for the recent quick-connect entries.
const _recentKey = 'quick_connect_recent';

/// Maximum number of recent entries to keep.
const _maxRecent = 5;

/// Maximum fuzzy-match results to display.
const _maxMatches = 5;

/// Quick Connect v3 modal -- type user@host:port, pick a recent, or
/// fuzzy-match a saved connection and connect instantly.
///
/// This dialog is ephemeral: it does NOT save connections to the database.
/// After a successful connect the caller is responsible for showing a
/// "Save to connections?" toast if desired.
class QuickConnectV3 extends ConsumerStatefulWidget {
  final void Function(String sessionUri) onConnect;

  /// What is in the field as it opens (a quick connect link's host), else
  /// nothing.
  final String? typed;

  /// The New Tab page's other ways (3.2): an open tab found by its name goes
  /// to that tab, and a saved
  /// workspace opens. Null leaves the section out.
  final void Function(String tabId)? onSwitchTab;
  final void Function(String workspaceId)? onOpenWorkspace;

  const QuickConnectV3({
    super.key,
    required this.onConnect,
    this.typed,
    this.onSwitchTab,
    this.onOpenWorkspace,
  });

  /// Show as a centered dialog positioned 30 % from the top.
  static Future<void> show(
    BuildContext context, {
    required void Function(String) onConnect,
    String? typed,
    void Function(String tabId)? onSwitchTab,
    void Function(String workspaceId)? onOpenWorkspace,
  }) {
    return showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Align(
        alignment: const Alignment(0, -0.4),
        child: Material(
          color: Colors.transparent,
          child: QuickConnectV3(
            onConnect: onConnect,
            typed: typed,
            onSwitchTab: onSwitchTab,
            onOpenWorkspace: onOpenWorkspace,
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<QuickConnectV3> createState() => _QuickConnectV3State();
}

class _QuickConnectV3State extends ConsumerState<QuickConnectV3> {
  late final _controller = TextEditingController(text: widget.typed ?? '');
  final _focusNode = FocusNode();
  final _keyboardFocusNode = FocusNode();

  List<String> _recentEntries = [];
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    _focusNode.requestFocus();
    _loadRecent();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  // ── Recent list persistence ──────────────────────────────────────

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  void _loadRecent() {
    final raw = _prefs.getString(_recentKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        setState(() {
          _recentEntries = decoded
              .whereType<String>()
              .take(_maxRecent)
              .toList();
        });
      }
    } catch (_) {
      // Corrupted prefs -- ignore silently.
    }
  }

  Future<void> _pushRecent(String entry) async {
    _recentEntries.remove(entry);
    _recentEntries.insert(0, entry);
    if (_recentEntries.length > _maxRecent) {
      _recentEntries = _recentEntries.sublist(0, _maxRecent);
    }
    await _prefs.setString(_recentKey, jsonEncode(_recentEntries));
  }

  // ── Fuzzy matching ───────────────────────────────────────────────

  List<ConnectionWithDetails> _fuzzyMatch(
    String query,
    List<ConnectionWithDetails> connections,
  ) {
    if (query.isEmpty) return const [];
    final lower = query.toLowerCase();

    // Score each connection: label-start > host-start > label-contains > host-contains.
    final scored = <(ConnectionWithDetails, int)>[];
    for (final c in connections) {
      final label = c.connection.label.toLowerCase();
      final host = c.connection.host.toLowerCase();

      int score;
      if (label.startsWith(lower)) {
        score = 4;
      } else if (host.startsWith(lower)) {
        score = 3;
      } else if (label.contains(lower)) {
        score = 2;
      } else if (host.contains(lower)) {
        score = 1;
      } else {
        continue;
      }
      scored.add((c, score));
    }

    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(_maxMatches).map((e) => e.$1).toList();
  }

  // ── Connect action ──────────────────────────────────────────────

  void _submit([ConnectionWithDetails? matchedConnection]) {
    final input = _controller.text.trim();
    if (input.isEmpty) return;

    // If a specific saved connection was chosen, use its ID.
    if (matchedConnection != null) {
      _pushRecent(input);
      Navigator.of(context).pop();
      widget.onConnect(matchedConnection.connection.id);
      return;
    }

    // Try to fuzzy-match exactly one saved connection.
    final connectionsAsync = ref.read(connectionsWithDetailsProvider);
    final connections = connectionsAsync.valueOrNull ?? [];
    final matches = _fuzzyMatch(input, connections);

    if (matches.length == 1) {
      _pushRecent(input);
      Navigator.of(context).pop();
      widget.onConnect(matches.first.connection.id);
      return;
    }

    // Read as user@host:port (parseQuickTarget, as everywhere it is typed).
    final l10n = AppLocalizations.of(context)!;
    final target = parseQuickTarget(input);
    if (target == null) {
      setState(() => _errorText = l10n.quickConnectV3InvalidHostFormat);
      return;
    }

    if (target.user == null) {
      setState(() => _errorText = l10n.quickConnectV3SpecifyUserHost);
      return;
    }

    // Handed on as it would be typed again: an IPv6 address in brackets.
    final uri = target.typed;
    _pushRecent(uri);
    Navigator.of(context).pop();
    widget.onConnect(uri);
  }

  void _fillFromRecent(String entry) {
    _controller.text = entry;
    _controller.selection = TextSelection.collapsed(offset: entry.length);
    setState(() => _errorText = null);
    _focusNode.requestFocus();
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final input = _controller.text.trim();
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final connections = connectionsAsync.valueOrNull ?? [];
    final matches = _fuzzyMatch(input, connections);
    // The New Tab page (3.2): open tabs found by their names while typing;
    // with nothing typed, the hosts connected to last and the saved
    // workspaces.
    final openTabs = widget.onSwitchTab == null || input.isEmpty
        ? const <({String id, String title})>[]
        : newTabOpenTabs(ref.watch(workTabsProvider).tabs, ref.watch(activeSessionsProvider), input);
    final recentHosts = input.isEmpty ? newTabRecentHosts(connections) : const <ConnectionWithDetails>[];
    final workspaces = widget.onOpenWorkspace == null || input.isNotEmpty
        ? const []
        : ref.watch(workspacesProvider).take(_maxNewTabRows).toList();

    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
        }
      },
      child: Container(
        // Wider on desktop and a touch taller - the previous 500px
        // box made the input feel like an "oval inside a box" once
        // the rounded corners + accent border + outlined input
        // stacked. We give the dialog room to breathe and tighten
        // the input's own border so it visually merges with the
        // dialog instead of fighting it.
        width: 560,
        decoration: BoxDecoration(
          color: AppColors.v3Surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.v3BorderDefault,
            width: 0.6,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Title ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Text(
                l10n.quickConnectV3Title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.v3TextPrimary,
                ),
              ),
            ),

            const SizedBox(height: 14),

            // ── Input field ────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _InputField(
                controller: _controller,
                focusNode: _focusNode,
                errorText: _errorText,
                onChanged: (_) => setState(() => _errorText = null),
                onSubmitted: (_) => _submit(),
              ),
            ),

            // ── Error text ─────────────────────────────────────
            if (_errorText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text(
                  _errorText!,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.v3Error,
                  ),
                ),
              ),

            // ── Fuzzy matches ──────────────────────────────────
            if (matches.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  l10n.quickConnectV3MatchesLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              ...matches.map((c) {
                return _MatchRow(
                  label: c.connection.label.isNotEmpty
                      ? Redactable.host(c.connection.label)
                      : Redactable.address(c.connection.host),
                  hostPort: Redactable.address(
                      hostWithPort(c.connection.host, c.connection.port)),
                  host: c,
                  isExact: matches.length == 1,
                  onTap: () => _submit(c),
                );
              }),
            ],

            // ── Open tabs (New Tab page) ───────────────────────
            if (openTabs.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionLabel(l10n.homeSessionsTab),
              const SizedBox(height: 4),
              for (final tab in openTabs)
                _ItemRow(
                  key: ValueKey('new-tab-open-${tab.id}'),
                  icon: LucideIcons.terminalSquare,
                  label: Redactable.host(tab.title),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onSwitchTab!(tab.id);
                  },
                ),
            ],

            // ── Recent connections (New Tab page) ──────────────
            if (recentHosts.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionLabel(l10n.desktopHomeRecentConnections),
              const SizedBox(height: 4),
              for (final c in recentHosts)
                _MatchRow(
                  key: ValueKey('new-tab-recent-${c.connection.id}'),
                  label: c.connection.label.isNotEmpty
                      ? Redactable.host(c.connection.label)
                      : Redactable.address(c.connection.host),
                  hostPort: Redactable.address(hostWithPort(c.connection.host, c.connection.port)),
                  host: c,
                  isExact: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onConnect(c.connection.id);
                  },
                ),
            ],

            // ── Workspaces (New Tab page) ──────────────────────
            if (workspaces.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionLabel(l10n.workspacesSectionTitle),
              const SizedBox(height: 4),
              for (final w in workspaces)
                _ItemRow(
                  key: ValueKey('new-tab-workspace-${w.id}'),
                  icon: LucideIcons.layoutGrid,
                  label: Redactable.freeText(w.name),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onOpenWorkspace!(w.id);
                  },
                ),
            ],

            // ── Recent list ────────────────────────────────────
            if (input.isEmpty && _recentEntries.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  l10n.quickConnectV3RecentLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              ..._recentEntries.map(
                (entry) => _RecentRow(
                  entry: entry,
                  onTap: () => _fillFromRecent(entry),
                ),
              ),
            ],

            const SizedBox(height: 12),

            // ── Bottom hint ────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.v3BorderSubtle, width: 0.5),
                ),
              ),
              child: Text(
                l10n.quickConnectV3BottomHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.v3TextSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Input field ────────────────────────────────────────────────────

class _InputField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? errorText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _InputField({
    required this.controller,
    required this.focusNode,
    required this.errorText,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  State<_InputField> createState() => _InputFieldState();
}

class _InputFieldState extends State<_InputField> {
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    _hasFocus = widget.focusNode.hasFocus;
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    setState(() => _hasFocus = widget.focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final borderColor = widget.errorText != null
        ? AppColors.v3Error
        : _hasFocus
            ? AppColors.v3AccentPrimary
            : AppColors.v3BorderSubtle;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        // Same radius as the surrounding dialog so the input lines
        // up visually with the chrome rather than nesting like an
        // oval-in-a-box.
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: borderColor,
          width: _hasFocus ? 1.2 : 0.6,
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(
            LucideIcons.search,
            size: 16,
            color: _hasFocus
                ? AppColors.v3AccentInk
                : AppColors.v3TextTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              style: TextStyle(
                fontSize: 14,
                fontFamily: 'JetBrainsMono',
                color: AppColors.v3TextPrimary,
              ),
              decoration: InputDecoration(
                hintText: l10n.quickConnectV3InputHint,
                hintStyle: TextStyle(
                  color: AppColors.v3TextTertiary,
                  fontFamily: 'JetBrainsMono',
                  fontSize: 14,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Match row (fuzzy-matched saved connection) ─────────────────────

class _MatchRow extends StatefulWidget {
  /// Painted host name (or address when the connection has no label).
  final Redactable label;

  /// Painted `host:port`.
  final Redactable hostPort;
  final ConnectionWithDetails host;
  final bool isExact;
  final VoidCallback onTap;

  const _MatchRow({
    super.key,
    required this.label,
    required this.hostPort,
    required this.host,
    required this.isExact,
    required this.onTap,
  });

  @override
  State<_MatchRow> createState() => _MatchRowState();
}

class _MatchRowState extends State<_MatchRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final highlightColor = widget.isExact
        ? AppColors.v3AccentPrimary.withValues(alpha: 0.08)
        : _hovered
            ? AppColors.v3Surface.withValues(alpha: 0.4)
            : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          color: highlightColor,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: HostGlyph(host: widget.host.connection, group: widget.host.group, size: 18),
              ),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: RedactedText(
                        widget.label,
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.v3TextPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    RedactedText(
                      widget.hostPort,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                        color: AppColors.v3TextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.isExact)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.v3AccentPrimary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l10n.quickConnectV3MatchBadge,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3AccentInk,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── New Tab page rows ──────────────────────────────────────────────

/// How many rows each New Tab section shows at most.
const _maxNewTabRows = 4;

/// The open tabs whose names hold [query], as a tab's own name or the names
/// of the hosts in it, for the New Tab page (3.2).
List<({String id, String title})> newTabOpenTabs(
  List<WorkTab> tabs,
  Map<String, SessionState> sessions,
  String query,
) {
  final lower = query.trim().toLowerCase();
  if (lower.isEmpty) return const [];
  final found = <({String id, String title})>[];
  for (final tab in tabs) {
    final names = [for (final id in tab.sessionIds) ?sessions[id]?.connectionLabel].where((l) => l.isNotEmpty).toList();
    final title = tab.customName?.trim().isNotEmpty == true ? tab.customName!.trim() : names.toSet().join(', ');
    if (title.isEmpty) continue;
    if (title.toLowerCase().contains(lower) || names.any((n) => n.toLowerCase().contains(lower))) {
      found.add((id: tab.id, title: title));
    }
    if (found.length == _maxNewTabRows) break;
  }
  return found;
}

/// The saved hosts connected to last, newest first, for the New Tab page.
List<ConnectionWithDetails> newTabRecentHosts(List<ConnectionWithDetails> hosts) {
  final seen = [
    for (final h in hosts)
      if (h.connection.lastConnected != null) h,
  ]..sort((a, b) => b.connection.lastConnected!.compareTo(a.connection.lastConnected!));
  return seen.take(_maxNewTabRows).toList();
}

Widget _sectionLabel(String text) => Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: AppColors.v3TextSecondary),
        ),
      ),
    );

/// A row of the New Tab page: an icon and a name.
class _ItemRow extends StatefulWidget {
  const _ItemRow({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final Redactable label;
  final VoidCallback onTap;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          color: _hovered ? AppColors.v3Surface.withValues(alpha: 0.4) : Colors.transparent,
          child: Row(
            children: [
              Icon(widget.icon, size: 15, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: RedactedText(
                  widget.label,
                  style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Recent row ─────────────────────────────────────────────────────

class _RecentRow extends StatefulWidget {
  final String entry;
  final VoidCallback onTap;

  const _RecentRow({
    required this.entry,
    required this.onTap,
  });

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          color: _hovered
              ? AppColors.v3Surface.withValues(alpha: 0.4)
              : Colors.transparent,
          child: Row(
            children: [
              Text(
                '\u21b3 ',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.v3TextSecondary,
                ),
              ),
              Expanded(
                // A recent entry is `user@host:port` or a typed nickname; the
                // free-text rule masks either. The raw entry still refills
                // the field on tap.
                child: RedactedText(
                  Redactable.freeText(widget.entry),
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'JetBrainsMono',
                    color: AppColors.v3TextPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
