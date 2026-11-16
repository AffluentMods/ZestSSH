import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/byte_size.dart';

/// What a transfer does: picks the selection dialog's wording ("Upload N
/// items" / "Download N items" / "Copy N items") and its glyph.
enum TransferVerb { upload, download, copy }

/// One node in the pre-transfer selection tree. Built by the scan
/// (`_scanTransferTree` in the dual-pane screen) from the source side, before
/// any bytes move. A directory's [size]/[items] are RECURSIVE (its whole
/// subtree), so a folder row can state what pruning it saves. Children arrive
/// pre-sorted (folders first, largest first) so the heavy folder surfaces at
/// the top with no special casing.
class TransferNode {
  final String path;
  final String name;
  final bool isDir;
  final bool isHidden;
  final int size;
  final int items;
  final List<TransferNode> children;

  const TransferNode({
    required this.path,
    required this.name,
    required this.isDir,
    required this.isHidden,
    required this.size,
    required this.items,
    this.children = const [],
  });
}

enum _Tick { on, partial, off }

/// Pre-transfer selection dialog (v2). No chips: the tree is sorted largest
/// first so the heavy folder is already one click from the top, and a single
/// warning callout names it when one folder is most of the transfer. The count
/// in the button never lets someone confirm a transfer they believe they
/// trimmed and did not.
///
/// Resolves with the set of TOP-MOST excluded paths (each the root of a pruned
/// subtree) which the caller skips during the transfer. Resolves null on Cancel
/// / dismiss.
class TransferSelectionDialog extends StatefulWidget {
  const TransferSelectionDialog({
    super.key,
    required this.root,
    required this.destPath,
    required this.verb,
    required this.conflictCount,
    this.conflictCountIsFloor = false,
    required this.truncated,
  });

  /// Synthetic root whose children are the top-level rows. For a single dragged
  /// folder these are its contents; for a multi-drag they are the dragged items.
  final TransferNode root;
  final String destPath;
  final TransferVerb verb;
  final int conflictCount;

  /// True when [conflictCount] is a floor: the scan could not compare the
  /// whole tree with the destination, so more may turn up during the transfer.
  final bool conflictCountIsFloor;
  final bool truncated;

  static Future<Set<String>?> show(
    BuildContext context, {
    required TransferNode root,
    required String destPath,
    required TransferVerb verb,
    required int conflictCount,
    bool conflictCountIsFloor = false,
    required bool truncated,
  }) {
    return showZestModal<Set<String>?>(
      context: context,
      size: ZestModalSize.standard,
      barrierDismissible: false,
      child: TransferSelectionDialog(
        root: root,
        destPath: destPath,
        verb: verb,
        conflictCount: conflictCount,
        conflictCountIsFloor: conflictCountIsFloor,
        truncated: truncated,
      ),
    );
  }

  @override
  State<TransferSelectionDialog> createState() =>
      _TransferSelectionDialogState();
}

class _TransferSelectionDialogState extends State<TransferSelectionDialog> {
  /// Top-most excluded paths. Absent = included, so an untouched transfer
  /// carries no state and behaves exactly like today.
  final Set<String> _excluded = {};

  /// Folders collapsed in the tree. Everything below the root starts collapsed.
  final Set<String> _collapsed = {};

  bool _treeOpen = false;
  final ScrollController _scroll = ScrollController();

  static const double _rowHeight = 30;

  @override
  void initState() {
    super.initState();
    // Root is expanded, everything below it collapsed (spec: Expansion).
    void seed(TransferNode n, int depth) {
      if (n.isDir && depth >= 1) _collapsed.add(n.path);
      for (final c in n.children) {
        seed(c, depth + 1);
      }
    }

    for (final c in widget.root.children) {
      seed(c, 1);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // ── Selection model ────────────────────────────────────────────────

  bool _ancestorExcluded(String path) {
    for (final ex in _excluded) {
      if (path == ex) continue;
      if (path.startsWith('$ex/') || path.startsWith('$ex\\')) return true;
    }
    return false;
  }

  bool _subtreeHasExclusion(TransferNode node) {
    for (final ex in _excluded) {
      if (ex == node.path) continue;
      if (ex.startsWith('${node.path}/') || ex.startsWith('${node.path}\\')) {
        return true;
      }
    }
    return false;
  }

  _Tick _tickOf(TransferNode node) {
    if (_excluded.contains(node.path) || _ancestorExcluded(node.path)) {
      return _Tick.off;
    }
    if (node.isDir && _subtreeHasExclusion(node)) return _Tick.partial;
    return _Tick.on;
  }

  void _toggle(TransferNode node) {
    setState(() {
      // Spec 3: clicking a partial box selects all; on -> clears all.
      if (_tickOf(node) == _Tick.on) {
        _excluded.removeWhere((ex) =>
            ex.startsWith('${node.path}/') || ex.startsWith('${node.path}\\'));
        _excluded.add(node.path);
      } else {
        if (!_excluded.remove(node.path)) {
          _excluded.removeWhere((ex) =>
              ex.startsWith('${node.path}/') ||
              ex.startsWith('${node.path}\\'));
          if (_ancestorExcluded(node.path)) _reinclude(node);
        }
      }
    });
  }

  /// Re-include [target] when a strict ancestor is the excluded one: drop the
  /// ancestor from [_excluded] and exclude every sibling along the path down to
  /// [target], so only this branch comes back.
  void _reinclude(TransferNode target) {
    final chain = _pathTo(target.path);
    if (chain.isEmpty) return;
    TransferNode? excludedAncestor;
    for (final n in chain) {
      if (_excluded.contains(n.path)) {
        excludedAncestor = n;
        break;
      }
    }
    if (excludedAncestor == null) return;
    _excluded.remove(excludedAncestor.path);
    final start = chain.indexOf(excludedAncestor);
    for (var i = start; i < chain.length - 1; i++) {
      for (final c in chain[i].children) {
        if (c.path != chain[i + 1].path) _excluded.add(c.path);
      }
    }
  }

  List<TransferNode> _pathTo(String path) {
    final out = <TransferNode>[];
    bool dive(TransferNode n) {
      out.add(n);
      if (n.path == path) return true;
      for (final c in n.children) {
        if (dive(c)) return true;
      }
      out.removeLast();
      return false;
    }

    for (final c in widget.root.children) {
      if (dive(c)) return out;
    }
    return const [];
  }

  Set<String> _topMostExcluded() => {
        for (final ex in _excluded)
          if (!_ancestorExcluded(ex)) ex,
      };

  // ── Totals ─────────────────────────────────────────────────────────

  ({int folders, int files, int bytes}) _selected() {
    var folders = 0, files = 0, bytes = 0;
    void walk(TransferNode n, bool ancestorOff) {
      final off = ancestorOff || _excluded.contains(n.path);
      if (!off) {
        if (n.isDir) {
          folders++;
        } else {
          files++;
          bytes += n.size;
        }
      }
      for (final c in n.children) {
        walk(c, off);
      }
    }

    for (final c in widget.root.children) {
      walk(c, false);
    }
    return (folders: folders, files: files, bytes: bytes);
  }

  int get _totalItems {
    var n = 0;
    void walk(TransferNode node) {
      n++;
      for (final c in node.children) {
        walk(c);
      }
    }

    for (final c in widget.root.children) {
      walk(c);
    }
    return n;
  }

  int? _fullBytesCache;
  int get _fullBytes {
    if (_fullBytesCache != null) return _fullBytesCache!;
    var b = 0;
    void walk(TransferNode n) {
      if (!n.isDir) b += n.size;
      for (final c in n.children) {
        walk(c);
      }
    }

    for (final c in widget.root.children) {
      walk(c);
    }
    return _fullBytesCache = b;
  }

  bool _isBig(TransferNode n) =>
      n.isDir && _fullBytes > 0 && n.size > _fullBytes * 0.5;

  // ── Flatten visible rows ───────────────────────────────────────────

  List<_Row> _visibleRows() {
    final rows = <_Row>[];
    void walk(TransferNode n, int depth) {
      rows.add(_Row(n, depth));
      if (n.isDir && !_collapsed.contains(n.path)) {
        for (final c in n.children) {
          walk(c, depth + 1);
        }
      }
    }

    for (final c in widget.root.children) {
      walk(c, 0);
    }
    return rows;
  }

  String _fmtSize(int b) => formatByteSize(b, digits: SizeDigits.oneThenTwo);

  IconData get _verbGlyph => switch (widget.verb) {
        TransferVerb.download => LucideIcons.download,
        TransferVerb.copy => LucideIcons.copy,
        TransferVerb.upload => LucideIcons.upload,
      };

  /// "Upload N items" / "Download N items" / "Copy N items". The count is
  /// grouped the locale's way ("1,234" in English).
  String _verbItems(AppLocalizations l10n, int count) => switch (widget.verb) {
        TransferVerb.upload => l10n.sftpUploadItems(count),
        TransferVerb.download => l10n.sftpDownloadItems(count),
        TransferVerb.copy => l10n.sftpCopyItems(count),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sel = _selected();
    final selCount = sel.folders + sel.files;
    final total = _totalItems;
    final pruned = _excluded.isNotEmpty;
    final nothing = sel.folders == 0 && sel.files == 0;

    // The shell (the dialog rules of 3.4): what goes in the title, Reset a
    // link at the left of the footer, Cancel and the verb at its right.
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: _verbGlyph,
      title: pruned ? l10n.sftpItemsSelectedOfTotal(_verbItems(l10n, selCount), total) : _verbItems(l10n, selCount),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _destRow(),
          const SizedBox(height: 11),
          _summaryLine(sel, pruned),
          if (widget.conflictCount > 0) ...[
            const SizedBox(height: 11),
            _conflictCallout(),
          ],
          if (_treeOpen) ...[
            const SizedBox(height: 11),
            _tree(),
          ],
        ],
      ),
      tertiaryKey: const ValueKey('transfer-selection-reset'),
      tertiaryAction: pruned
          ? (label: l10n.settingsInlineReset, onPressed: () => setState(_excluded.clear))
          : null,
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(null)),
      primaryKey: const ValueKey('transfer-selection-go'),
      primaryAction: (
        label: _verbItems(l10n, selCount),
        icon: null,
        onPressed: nothing ? null : () => Navigator.of(context).pop(_topMostExcluded()),
      ),
    );
  }

  Widget _destRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.folder, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          // At least the old 22px, and wider for a longer word than "To" so a
          // translation never wraps inside the label column.
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 22),
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(AppLocalizations.of(context)!.sftpDestTo,
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            child: Text(
              widget.destPath,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
                color: AppColors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryLine(
      ({int folders, int files, int bytes}) sel, bool pruned) {
    final l10n = AppLocalizations.of(context)!;
    final parts = <String>[];
    if (sel.folders > 0) parts.add(l10n.sftpSelFolders(sel.folders));
    if (sel.files > 0) parts.add(l10n.sftpSelFiles(sel.files));
    final text = parts.isEmpty
        ? l10n.sftpNothingSelected
        : (parts.length == 2
            ? l10n.sftpSelFoldersAndFiles(parts[0], parts[1])
            : parts.first);

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _treeOpen = !_treeOpen),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.v3BorderSubtle),
        ),
        child: Row(
          children: [
            AnimatedRotation(
              turns: _treeOpen ? 0.25 : 0,
              duration: const Duration(milliseconds: 120),
              child: Icon(LucideIcons.chevronRight,
                  size: 14, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.onSurface)),
            ),
            if (pruned && _fullBytes != sel.bytes)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  _fmtSize(_fullBytes),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'JetBrainsMono',
                    color: AppColors.onSurfaceDim,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: AppColors.onSurfaceDim,
                  ),
                ),
              ),
            Text(
              _fmtSize(sel.bytes),
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'JetBrainsMono',
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _conflictCallout() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(LucideIcons.info,
                size: 14, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.conflictCountIsFloor
                  ? l10n.sftpConflictsAtLeast(widget.conflictCount)
                  : l10n.sftpConflictsExact(widget.conflictCount),
              style: TextStyle(
                  fontSize: 12, color: AppColors.onSurface, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tree() {
    final rows = _visibleRows();
    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: rows.length,
          itemBuilder: (_, i) => _treeRow(rows[i]),
        ),
      ),
    );
  }

  Widget _treeRow(_Row row) {
    final l10n = AppLocalizations.of(context)!;
    final n = row.node;
    final tick = _tickOf(n);
    final off = tick == _Tick.off;
    final collapsed = _collapsed.contains(n.path);
    final canExpand = n.isDir && n.children.isNotEmpty;
    final dim = n.isHidden && !off;
    final big = _isBig(n) && !off;

    Color nameColor = off
        ? AppColors.onSurfaceDim
        : (n.isDir ? AppColors.onSurface : AppColors.onSurfaceVariant);
    if (dim) nameColor = nameColor.withValues(alpha: 0.55);

    Color metaColor = off
        ? AppColors.onSurfaceDim
        : big
            ? AppColors.onSurface
            : AppColors.onSurfaceDim;

    return InkWell(
      onTap: () => _toggle(n),
      child: Opacity(
        opacity: dim ? 0.7 : 1.0,
        child: Container(
          height: _rowHeight,
          padding: EdgeInsets.only(left: 11.0 + row.depth * 18, right: 11),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: canExpand
                    ? Tooltip(message: collapsed ? AppLocalizations.of(context)!.zestAutoStepExpand : AppLocalizations.of(context)!.zestAutoStepCollapse, child: InkWell(
                        onTap: () => setState(() {
                          collapsed
                              ? _collapsed.remove(n.path)
                              : _collapsed.add(n.path);
                        }),
                        child: AnimatedRotation(
                          turns: collapsed ? 0 : 0.25,
                          duration: const Duration(milliseconds: 100),
                          child: Icon(LucideIcons.chevronRight,
                              size: 12, color: AppColors.onSurfaceDim),
                        ),
                      ))
                    : null,
              ),
              const SizedBox(width: 3),
              _Checkbox(tick: tick),
              const SizedBox(width: 9),
              Icon(
                n.isDir ? LucideIcons.folder : LucideIcons.file,
                size: 14,
                color: off
                    ? AppColors.onSurfaceDim
                    : (n.isDir
                        ? AppColors.brandHi
                        : AppColors.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  n.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: nameColor,
                    decoration: off ? TextDecoration.lineThrough : null,
                    decorationColor: AppColors.onSurfaceDim,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                n.isDir
                    ? '${l10n.sftpTreeItems(n.items)}'
                        '${n.size > 0 ? ' · ${_fmtSize(n.size)}' : ''}'
                    : _fmtSize(n.size),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'JetBrainsMono',
                  color: metaColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A flattened visible tree row (node + its indent depth).
class _Row {
  final TransferNode node;
  final int depth;
  const _Row(this.node, this.depth);
}

/// Tri-state checkbox: on (check), partial (dash), off (empty).
class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.tick});
  final _Tick tick;

  @override
  Widget build(BuildContext context) {
    final on = tick == _Tick.on;
    final part = tick == _Tick.partial;
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: on ? AppColors.brandHi : AppColors.v3Background,
        border: Border.all(
          color: (on || part) ? AppColors.brandHi : AppColors.divider,
        ),
      ),
      child: on
          ? Icon(LucideIcons.check, size: 10, color: AppColors.v3Background)
          : part
              ? Center(
                  child: Container(
                    width: 7,
                    height: 2,
                    decoration: BoxDecoration(
                      color: AppColors.brandHi,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                )
              : null,
    );
  }
}
