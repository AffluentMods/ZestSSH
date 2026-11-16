import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/database/daos/connections_dao.dart'
    show ConnectionWithDetails;
import 'package:zestssh/features/hosts/data/folder_icon_catalog.dart';
import 'package:zestssh/features/hosts/state/host_sort_mode.dart';
import 'package:zestssh/features/hosts/host_health_summary.dart' show hostHealthSummariesProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/sftp/widgets/this_computer.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// The user's choice from [showSftpSourcePicker].
sealed class SftpSourceChoice {
  const SftpSourceChoice();
}

/// "This PC" - the local filesystem.
class SftpChooseLocal extends SftpSourceChoice {
  const SftpChooseLocal();
}

/// An already-connected SFTP session - switching to it is instant.
class SftpChooseSession extends SftpSourceChoice {
  const SftpChooseSession(this.entry);
  final SftpSessionEntry entry;
}

/// A saved host that isn't connected yet - switching to it opens a connection.
class SftpChooseConnect extends SftpSourceChoice {
  const SftpChooseConnect(this.connection);
  final ConnectionWithDetails connection;
}

/// A connected host for the picker: an SFTP session plus its optional latency
/// label (resolved by the caller from the health provider).
class SftpPickerConnected {
  const SftpPickerConnected({required this.entry, this.latencyLabel});
  final SftpSessionEntry entry;
  final String? latencyLabel;
}

/// A filterable source picker, shown as a popover anchored under a rail group
/// header (or a collapsed-rail icon). It shares the LEFT HOSTS PULL-OUT's design
/// so every host list in the app reads the same: "This PC" leads, then saved
/// hosts grouped by their folder (named groups first in stored order, Ungrouped
/// last), each row a server glyph + a status-coloured name + the group-colour
/// "calling-card" wash + a status dot. A host with a live SFTP session reads
/// green and switches instantly; an offline host connects on tap. A filter field
/// is pinned at the top and focused on open.
Future<SftpSourceChoice?> showSftpSourcePicker(
  BuildContext context, {
  required Offset anchor,
  required List<ConnectionWithDetails> saved,
  required List<ConnectionGroup> groups,
  required Map<String, SftpPickerConnected> sftpByConnId,
  String? currentSessionId,
  bool currentIsLocal = false,
}) {
  return showDialog<SftpSourceChoice>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (ctx) => _SourcePickerOverlay(
      anchor: anchor,
      saved: saved,
      groups: groups,
      sftpByConnId: sftpByConnId,
      currentSessionId: currentSessionId,
      currentIsLocal: currentIsLocal,
    ),
  );
}

class _SourcePickerOverlay extends ConsumerStatefulWidget {
  const _SourcePickerOverlay({
    required this.anchor,
    required this.saved,
    required this.groups,
    required this.sftpByConnId,
    this.currentSessionId,
    this.currentIsLocal = false,
  });

  final Offset anchor;
  final List<ConnectionWithDetails> saved;
  final List<ConnectionGroup> groups;
  final Map<String, SftpPickerConnected> sftpByConnId;
  final String? currentSessionId;
  final bool currentIsLocal;

  @override
  ConsumerState<_SourcePickerOverlay> createState() =>
      _SourcePickerOverlayState();
}

class _SourcePickerOverlayState extends ConsumerState<_SourcePickerOverlay> {
  final _filterController = TextEditingController();
  final _filterFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _filterController.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final q = _query.trim().toLowerCase();
    bool match(String s) => q.isEmpty || s.toLowerCase().contains(q);

    // The English names still match, and so does the name shown on the row.
    final showLocal = match('this pc') ||
        match('this mac') ||
        match('this computer') ||
        match('local files') ||
        match(thisComputerName(l10n));
    // Sort each group exactly like the Hosts page and the left rail, and let the
    // picker change that sort (writes the shared hostSortModeProvider).
    final sortMode = ref.watch(hostSortModeProvider);
    // Each host's health, for the Health sort (as the Hosts page orders by it).
    final health = sortMode == HostSortMode.health ? ref.watch(hostHealthSummariesProvider) : null;
    final sessions = ref.watch(activeSessionsProvider);

    // Filter saved hosts by label OR host, then bucket by group.
    final filtered = widget.saved
        .where((c) => match(c.connection.label) || match(c.connection.host))
        .toList();
    final byGroup = <String?, List<ConnectionWithDetails>>{};
    for (final c in filtered) {
      byGroup.putIfAbsent(c.connection.groupId, () => []).add(c);
    }

    final rows = <Widget>[];

    if (showLocal) {
      rows.add(
        _PickerRow(
          icon: LucideIcons.hardDrive,
          label: thisComputerName(l10n),
          statusColor: AppColors.v3TextPrimary,
          groupColor: null,
          connected: false,
          showDot: false,
          selected: widget.currentIsLocal,
          onTap: () => Navigator.of(context).pop(const SftpChooseLocal()),
        ),
      );
    }

    void addGroup(
      String name,
      IconData? icon,
      Color? color,
      List<ConnectionWithDetails> rawHosts,
    ) {
      if (rawHosts.isEmpty) return;
      final hosts = sortConnections(
        conns: rawHosts,
        mode: sortMode,
        sessions: sessions,
        health: health ?? const {},
      );
      final open = hosts
          .where((h) => widget.sftpByConnId.containsKey(h.connection.id))
          .length;
      rows.add(
        _GroupHeader(
          name: name,
          icon: icon,
          color: color,
          countLabel: '$open/${hosts.length}',
        ),
      );
      for (final h in hosts) {
        final sess = widget.sftpByConnId[h.connection.id];
        final connected = sess != null;
        rows.add(
          _PickerRow(
            icon: LucideIcons.server,
            leading: HostGlyph(host: h.connection, group: h.group, size: 16),
            // Painted only; the filter above matches the real label.
            label: Redactable.host(h.connection.label).displayIn(ref),
            statusColor: connected
                ? AppColors.v3Success
                : AppColors.v3TextPrimary,
            groupColor: color,
            connected: connected,
            trailing: sess?.latencyLabel,
            selected:
                connected && sess.entry.sessionId == widget.currentSessionId,
            // A live host switches instantly (SftpChooseSession); an offline one
            // opens a fresh connection (SftpChooseConnect).
            onTap: () => Navigator.of(context).pop(
              connected ? SftpChooseSession(sess.entry) : SftpChooseConnect(h),
            ),
          ),
        );
      }
    }

    // Named groups first (stored order), Ungrouped last - the same order and
    // colour resolution as the left pull-out and the Hosts grid.
    for (final g in widget.groups) {
      addGroup(
        // The header paints this; the colour below still hashes the real name.
        Redactable.group(g.name).displayIn(ref),
        folderIconFor(g.iconCodePoint),
        resolveGroupColor(
          colorValue: g.colorValue,
          colorIndex: g.colorIndex,
          name: g.name,
        ),
        byGroup[g.id] ?? const [],
      );
    }
    addGroup(l10n.hostPanelUngrouped, null, null, byGroup[null] ?? const []);

    if (rows.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            l10n.stepCardNoMatches,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;
    const width = 300.0;
    final left = widget.anchor.dx.clamp(
      8.0,
      (size.width - width - 8).clamp(8.0, size.width),
    );
    final top = widget.anchor.dy.clamp(
      8.0,
      (size.height - 140).clamp(8.0, size.height),
    );
    final maxHeight = (size.height - top - 16).clamp(120.0, 460.0);

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: AppColors.v3Elevated,
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: width,
                maxHeight: maxHeight,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Filter field + sort control, pinned at the top.
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _filterController,
                            focusNode: _filterFocus,
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              hintText: l10n.sftpFilterHosts,
                              hintStyle: const TextStyle(fontSize: 12),
                              prefixIcon: const Icon(
                                LucideIcons.search,
                                size: 14,
                              ),
                              prefixIconConstraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 30,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: BorderSide(
                                  color: AppColors.divider,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: BorderSide(
                                  color: AppColors.divider,
                                ),
                              ),
                            ),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ),
                        const SizedBox(width: 4),
                        PopupMenuButton<HostSortMode>(
                          tooltip: l10n.sftpSortHosts,
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          color: AppColors.v3Surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          icon: Icon(
                            LucideIcons.arrowDownUp,
                            size: 16,
                            color: AppColors.v3TextSecondary,
                          ),
                          onSelected: (m) =>
                              ref.read(hostSortModeProvider.notifier).state = m,
                          itemBuilder: (context) => [
                            for (final m in HostSortMode.values)
                              PopupMenuItem<HostSortMode>(
                                value: m,
                                height: 36,
                                child: Row(
                                  children: [
                                    Icon(
                                      m == sortMode
                                          ? LucideIcons.check
                                          : LucideIcons.arrowDownUp,
                                      size: 13,
                                      color: m == sortMode
                                          ? AppColors.v3AccentInk
                                          : AppColors.v3TextTertiary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      m.nameIn(l10n),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.v3TextPrimary,
                                        fontWeight: m == sortMode
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 6),
                      children: rows,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Group section header, matching the left pull-out's `_GroupHeader`: a folder
/// icon (named groups only) + the group name tinted by its colour + an
/// `open/total` count.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.name,
    required this.icon,
    required this.color,
    required this.countLabel,
  });

  final String name;
  final IconData? icon;
  final Color? color;
  final String countLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 13,
              color: color?.withValues(alpha: 0.85) ?? AppColors.v3TextTertiary,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              name.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color ?? AppColors.v3TextSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Text(
            countLabel,
            style: TextStyle(
              color: AppColors.v3TextTertiary,
              fontSize: 10,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ],
      ),
    );
  }
}

/// A host / This-PC row, matching the left pull-out's `_HostRow`: a server glyph,
/// a status-coloured name (green live, white resting), the group-colour
/// "calling-card" wash, and a status dot. Selected rows also take a check.
class _PickerRow extends StatefulWidget {
  const _PickerRow({
    required this.icon,
    this.leading,
    required this.label,
    required this.statusColor,
    required this.groupColor,
    required this.connected,
    required this.onTap,
    this.trailing,
    this.showDot = true,
    this.selected = false,
  });

  final IconData icon;

  /// What stands in place of [icon]: a host's own icon.
  final Widget? leading;
  final String label;
  final Color statusColor;
  final Color? groupColor;
  final bool connected;
  final VoidCallback onTap;
  final String? trailing;
  final bool showDot;
  final bool selected;

  @override
  State<_PickerRow> createState() => _PickerRowState();
}

class _PickerRowState extends State<_PickerRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final gc = widget.groupColor;
    // "Calling-card" wash: the group colour bleeds in from the left and fades
    // to transparent (identical to the left pull-out).
    final BoxDecoration decoration = gc == null
        ? BoxDecoration(color: _hover ? AppColors.v3Hover : Colors.transparent)
        : BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                gc.withValues(alpha: _hover ? 0.34 : 0.24),
                gc.withValues(alpha: _hover ? 0.07 : 0.03),
                Colors.transparent,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          );
    final dotColor = widget.connected
        ? AppColors.v3Success
        : AppColors.v3TextPrimary.withValues(alpha: 0.5);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.only(left: 14, right: 10),
          decoration: decoration,
          child: Row(
            children: [
              widget.leading ?? Icon(widget.icon, size: 14, color: AppColors.v3TextSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.statusColor,
                    fontSize: 12,
                    fontWeight: widget.connected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 6),
                Text(
                  widget.trailing!,
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'JetBrainsMono',
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              if (widget.showDot) ...[
                const SizedBox(width: 6),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              if (widget.selected) ...[
                const SizedBox(width: 6),
                Icon(LucideIcons.check, size: 14, color: AppColors.accentInk),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
