import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/hosts/local_terminal.dart' show localTerminalOnThisDevice;
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

/// Sentinel returned when the user picks "Local Files" - used by the SFTP
/// header dropdown to flip a remote pane back to a local browser. Stage 2's
/// placeholder picker hides the entry by passing `includeLocalFiles: false`.
class LocalFilesEntry {
  const LocalFilesEntry();
}

/// Result of [ConnectionPickerDialog.show]. Either [connection] is set
/// (the user picked a host), [localFiles] is true (user picked Local Files),
/// [localTerminal] is true (a terminal on this device was picked), or all are
/// null/false (user dismissed the dialog).
class ConnectionPickerResult {
  final ConnectionWithDetails? connection;
  final bool localFiles;
  final bool localTerminal;

  const ConnectionPickerResult.connection(this.connection)
      : localFiles = false,
        localTerminal = false;
  const ConnectionPickerResult.local()
      : connection = null,
        localFiles = true,
        localTerminal = false;
  const ConnectionPickerResult.localTerminal()
      : connection = null,
        localFiles = false,
        localTerminal = true;
  const ConnectionPickerResult.none()
      : connection = null,
        localFiles = false,
        localTerminal = false;
}

/// Picker dialog showing all saved connections with a live search: fills
/// placeholder panes, re-targets an SFTP pane, and picks the host for what is
/// run on one (Run snippet on…, Run on, a workflow's step).
///
/// Pass [includeLocalFiles] to add a pinned "Local Files" entry at the top
/// (intended for SFTP-side use; Stage 2 hides it because terminal panes
/// can't be backed by the local filesystem).
///
/// Its hosts are the one row of a host ([HostRow]), by group; with [place]'s
/// Active first on (on by itself where
/// something is run on the host) those with a session open stand first, the
/// last used first, and the rest under them.
class ConnectionPickerDialog extends ConsumerStatefulWidget {
  final String title;
  final bool includeLocalFiles;
  final String? excludeConnectionId;

  /// Picking a host for something that runs on it (a snippet, a step of a
  /// workflow, a forward): a host that is SFTP only is shown dimmed with
  /// why ([noTerminalReason]), and cannot be picked.
  final bool needsTerminal;

  /// Which picker this is: its own Active first.
  final HostListPlace place;

  /// A "Local terminal" choice first, above the hosts (a snippet's Run
  /// on...), where this device has a shell of its own
  /// ([localTerminalOnThisDevice]): picked, the result is
  /// [ConnectionPickerResult.localTerminal]. It is the person's own in any
  /// space, so a team's space offers it as well.
  final bool includeLocalTerminal;

  const ConnectionPickerDialog({
    super.key,
    required this.title,
    this.includeLocalFiles = false,
    this.excludeConnectionId,
    this.needsTerminal = false,
    this.place = HostListPlace.pickHost,
    this.includeLocalTerminal = false,
  });

  static Future<ConnectionPickerResult> show(
    BuildContext context, {
    String title = 'Pick a host',
    bool includeLocalFiles = false,
    String? excludeConnectionId,
    bool needsTerminal = false,
    HostListPlace place = HostListPlace.pickHost,
    bool includeLocalTerminal = false,
  }) async {
    // Chosen for a dialog (a key's host in Create API key, a forward's): in
    // that dialog's place, which comes back as it was (rule 4 of the dialog
    // rules, 3.4: no dialog over a dialog). Elsewhere, a dialog of its own.
    final result = await showZestInPlace<ConnectionPickerResult>(
      context: context,
      size: ZestModalSize.standard,
      builder: (_) => ConnectionPickerDialog(
        title: title,
        includeLocalFiles: includeLocalFiles,
        excludeConnectionId: excludeConnectionId,
        needsTerminal: needsTerminal,
        place: place,
        includeLocalTerminal: includeLocalTerminal,
      ),
    );
    return result ?? const ConnectionPickerResult.none();
  }

  @override
  ConsumerState<ConnectionPickerDialog> createState() =>
      _ConnectionPickerDialogState();
}

class _ConnectionPickerDialogState
    extends ConsumerState<ConnectionPickerDialog> {
  final _queryController = TextEditingController();
  final _focusNode = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _queryController.addListener(() => setState(() {}));
    // Focus the search box on next frame so users can start typing immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final all = connectionsAsync.valueOrNull ?? const <ConnectionWithDetails>[];
    final groups = ref.watch(connectionGroupsProvider).valueOrNull ??
        const <ConnectionGroup>[];

    // Index live SSH sessions by connectionId so the row can say the host is
    // open already, where a session would be reused.
    final sessions = ref.watch(activeSessionsProvider);
    final connectedConnectionIds = <String>{
      for (final s in sessions.values)
        if (s.connectionId != null &&
            s.status == SessionStatus.connected &&
            (s.session?.shell.isEncryptedSsh ?? false) &&
            !s.isHidden)
          s.connectionId!,
    };

    final query = _queryController.text.trim().toLowerCase();
    // This device's own terminal, first, where it has a shell to open and
    // what is typed in the search is the start of a word of its name (a
    // host's name typed, "dev-01", is not taken for the "device" of its
    // line, and Enter goes to that host).
    final localName = l10n.hostsToolbarTerminal.toLowerCase();
    final localTerminal = widget.includeLocalTerminal &&
        localTerminalOnThisDevice &&
        (query.isEmpty || localName.startsWith(query) || localName.contains(' $query'));
    void pickLocalTerminal() => zestDialogPop(context, const ConnectionPickerResult.localTerminal());
    final filtered = all.where((c) {
      if (c.connection.id == widget.excludeConnectionId) return false;
      if (query.isEmpty) return true;
      final label = c.connection.label.toLowerCase();
      final host = c.connection.host.toLowerCase();
      return label.contains(query) || host.contains(query);
    }).toList();

    // By group, named groups first (in their stored order), the ungrouped
    // ones last, and where the place has it, Active first. A flat,
    // in-display-order list drives "Enter opens the top match" and the
    // empty-state check.
    final layout = layOutHosts(
      filtered,
      groups: groups,
      activeFirst: ref.watch(activeFirstProvider(widget.place)),
      open: connectedConnectionIds,
      lastUsed: ref.watch(hostUseProvider),
    );
    final displayOrder = layout.inOrder;

    // Why a host cannot be picked here: one that is SFTP only, for
    // something that runs on it. Null for every host it can be.
    String? unavailable(ConnectionWithDetails c) =>
        widget.needsTerminal ? noTerminalReason(c.connection, l10n) : null;

    // A single host row, pre-wired to pop the picker with its connection.
    Widget rowFor(ConnectionWithDetails c) => HostRow(
          key: ValueKey('host-picker-${c.connection.id}'),
          host: c.connection,
          user: c.identity?.username,
          group: c.group,
          open: connectedConnectionIds.contains(c.connection.id),
          openLabel: l10n.connectionPickerAlreadyOpen,
          showOpenLabel: true,
          unavailableReason: unavailable(c),
          unavailableKey: ValueKey('host-picker-unavailable-${c.connection.id}'),
          onTap: () => zestDialogPop(
            context,
            ConnectionPickerResult.connection(c),
          ),
        );

    // A group's heading says how many of its hosts are open, then its rows.
    Iterable<Widget> blockOf(HostBlock b) sync* {
      final open = b.hosts
          .where((h) => connectedConnectionIds.contains(h.connection.id))
          .length;
      yield HostGroupHeading(
        group: b.group,
        count: l10n.hostPanelOpenCount(open, b.hosts.length),
      );
      yield* b.hosts.map(rowFor);
    }

    int countIn(List<HostBlock> blocks) => blocks.fold(0, (n, b) => n + b.hosts.length);

    final none = Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        l10n.connectionPickerNoMatches,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary),
      ),
    );
    final hosts = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (localTerminal) _LocalTerminalTile(onTap: pickLocalTerminal),
        if (widget.includeLocalFiles)
          _LocalFilesTile(
            onTap: () {
              zestDialogPop(
                context,
                const ConnectionPickerResult.local(),
              );
            },
          ),
        if (layout.split) ...[
          HostSectionHeading(active: true, count: countIn(layout.active)),
          for (final b in layout.active) ...blockOf(b),
          if (layout.rest.isNotEmpty)
            HostSectionHeading(active: false, count: countIn(layout.rest)),
        ],
        for (final b in layout.rest) ...blockOf(b),
      ],
    );
    final nothing = displayOrder.isEmpty && !widget.includeLocalFiles && !localTerminal;
    // A phone's sheet scrolls as one, its keyboard up or on its side: a list of
    // its own was a slit under the search, or overflowed.
    final sheet = ZestSheetScope.of(context);

    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.server,
      title: widget.title,
      bodyScrolls: sheet,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Search box - Enter opens the top match so the whole flow is
          // keyboard-only (type to filter, Enter to connect).
          Row(
            children: [
              Expanded(
                child: ZestListSearchField(
                  controller: _queryController,
                  focusNode: _focusNode,
                  hintText: l10n.connectionPickerSearchHint,
                  onChanged: (_) {},
                  onSubmitted: (_) {
                    // The top match that can be picked: this device's own
                    // terminal where it is shown, as it is the first row.
                    if (localTerminal) {
                      pickLocalTerminal();
                      return;
                    }
                    final top = displayOrder.where((c) => unavailable(c) == null).firstOrNull;
                    if (top != null) {
                      zestDialogPop(
                        context,
                        ConnectionPickerResult.connection(top),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 14),
              ActiveFirstToggle(place: widget.place),
            ],
          ),
          const SizedBox(height: 8),
          if (sheet)
            if (nothing) none else hosts
          else
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 200),
                child: nothing
                    ? none
                    : Scrollbar(
                        controller: _scroll,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          child: Padding(
                            padding: const EdgeInsetsDirectional.only(end: 10),
                            child: hosts,
                          ),
                        ),
                      ),
              ),
            ),
        ],
      ),
      secondaryAction: (
        label: l10n.cancel,
        onPressed: () => zestDialogPop(
            context, const ConnectionPickerResult.none()),
      ),
    );
  }
}

/// "Local Files" entry - visually distinct from a host's row so it doesn't
/// pretend to be a saved connection. Used only when
/// [ConnectionPickerDialog.includeLocalFiles] is true.
class _LocalFilesTile extends StatefulWidget {
  const _LocalFilesTile({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_LocalFilesTile> createState() => _LocalFilesTileState();
}

class _LocalFilesTileState extends State<_LocalFilesTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: _hovering ? ZestTokens.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Icon(LucideIcons.folder, size: 16, color: ZestTokens.textSecondary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.connectionPickerLocalFiles,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                    ),
                    Text(
                      l10n.connectionPickerLocalFilesDesc,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                LucideIcons.chevronRight,
                size: 14,
                color: _hovering ? ZestTokens.brandInk : ZestTokens.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Local terminal": the first choice of a snippet's Run on..., a new
/// terminal on this device. Reached with Tab, picked with Enter or Space,
/// said to a screen reader as a button with its name and line
/// ([ZestPressable]), with the icon of the Hosts page's own Local terminal.
class _LocalTerminalTile extends StatefulWidget {
  const _LocalTerminalTile({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_LocalTerminalTile> createState() => _LocalTerminalTileState();
}

class _LocalTerminalTileState extends State<_LocalTerminalTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ZestPressable(
        key: const ValueKey('host-picker-local-terminal'),
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hovering = h),
        semanticLabel: '${l10n.hostsToolbarTerminal}, ${l10n.connectionPickerLocalTerminalDesc}',
        excludeChildSemantics: true,
        borderRadius: 6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: _hovering ? ZestTokens.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Icon(LucideIcons.terminalSquare, size: 16, color: ZestTokens.brandInk),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.hostsToolbarTerminal,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                    ),
                    Text(
                      l10n.connectionPickerLocalTerminalDesc,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                LucideIcons.chevronRight,
                size: 14,
                color: _hovering ? ZestTokens.brandInk : ZestTokens.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
