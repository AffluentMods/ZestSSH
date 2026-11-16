import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/database/database.dart' show Snippet, SnippetCategory;
import 'package:zestssh/features/snippets/snippet_category_color.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Filterable snippet quick-picker (UX audit §10). Replaces the old flat
/// `showMenu` of every snippet with: an autofocus filter (matches label AND
/// command), category groups, keyboard nav (↑/↓ move a highlight, Enter
/// inserts, Esc closes), and a "N of M" footer. Resolves with the chosen
/// [Snippet], or null if dismissed.
Future<Snippet?> showSnippetQuickPicker(
  BuildContext context,
  List<Snippet> snippets, {
  Map<String, SnippetCategory> categoryMeta = const {},
}) {
  return showDialog<Snippet>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) =>
        _SnippetPicker(snippets: snippets, categoryMeta: categoryMeta),
  );
}

class _SnippetPicker extends StatefulWidget {
  const _SnippetPicker({required this.snippets, this.categoryMeta = const {}});
  final List<Snippet> snippets;

  /// Category name -> persisted metadata (colour), so groups match the mobile
  /// list's accent colours. Empty = fall back to name-derived colours.
  final Map<String, SnippetCategory> categoryMeta;

  @override
  State<_SnippetPicker> createState() => _SnippetPickerState();
}

class _SnippetPickerState extends State<_SnippetPicker> {
  final _controller = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Flat, filtered, order-preserving list - the target of keyboard nav.
  List<Snippet> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.snippets;
    return widget.snippets
        .where((s) =>
            s.label.toLowerCase().contains(q) ||
            s.command.toLowerCase().contains(q))
        .toList();
  }

  void _move(int delta) {
    final list = _filtered;
    if (list.isEmpty) return;
    setState(() => _highlight = (_highlight + delta) % list.length);
    if (_highlight < 0) _highlight += list.length;
  }

  void _accept() {
    final list = _filtered;
    if (list.isEmpty) return;
    final i = _highlight.clamp(0, list.length - 1);
    Navigator.of(context).pop(list[i]);
  }

  /// Accent colour for a category group, matching the mobile snippet list (a
  /// user-picked colour wins, else a name-derived default). Null category (an
  /// uncategorised snippet) falls back to the app accent.
  Color _colorFor(String? category) {
    if (category == null) return AppColors.v3AccentPrimary;
    return snippetCategoryColor(category, widget.categoryMeta[category]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final list = _filtered;
    if (_highlight >= list.length) _highlight = list.isEmpty ? 0 : list.length - 1;

    // Group the filtered list by category, preserving order.
    final grouped = <String?, List<Snippet>>{};
    for (final s in list) {
      grouped.putIfAbsent(s.category, () => []).add(s);
    }
    var flatIndex = 0;

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): _MoveIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowUp): _MoveIntent(-1),
        SingleActivator(LogicalKeyboardKey.enter): _AcceptIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _AcceptIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MoveIntent: CallbackAction<_MoveIntent>(
            onInvoke: (i) => _move(i.delta),
          ),
          _AcceptIntent: CallbackAction<_AcceptIntent>(
            onInvoke: (_) {
              _accept();
              return null;
            },
          ),
        },
        child: Dialog(
          backgroundColor: AppColors.v3Elevated,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Filter field + esc chip.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _searchFocus,
                          onChanged: (v) =>
                              setState(() { _query = v; _highlight = 0; }),
                          onSubmitted: (_) => _accept(),
                          style: TextStyle(
                              color: AppColors.v3TextPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: l10n.snippetQuickPickerFilterHint,
                            hintStyle: TextStyle(
                                color: AppColors.v3TextTertiary, fontSize: 13),
                            prefixIcon: Icon(LucideIcons.search,
                                size: 16, color: AppColors.v3TextTertiary),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  BorderSide(color: AppColors.v3BorderSubtle),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  BorderSide(color: AppColors.v3BorderSubtle),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  BorderSide(color: AppColors.v3AccentPrimary),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _EscChip(onTap: () => Navigator.of(context).pop()),
                    ],
                  ),
                ),
                Divider(height: 1, color: AppColors.v3BorderSubtle),
                Flexible(
                  child: list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(l10n.snippetQuickPickerNoMatch(_query),
                              style: TextStyle(
                                  color: AppColors.v3TextSecondary,
                                  fontSize: 13)),
                        )
                      : ListView(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          children: [
                            for (final entry in grouped.entries) ...[
                              if (entry.key != null)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 10, 16, 4),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 7,
                                        height: 7,
                                        decoration: BoxDecoration(
                                          color: _colorFor(entry.key),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                      Text(
                                        entry.key!.toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 1.2,
                                          color: _colorFor(entry.key),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              for (final s in entry.value)
                                _row(s, flatIndex++),
                            ],
                          ],
                        ),
                ),
                Divider(height: 1, color: AppColors.v3BorderSubtle),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        l10n.snippetQuickPickerNavHint,
                        style: TextStyle(
                            fontSize: 11, color: AppColors.v3TextTertiary),
                      ),
                      const Spacer(),
                      Text(
                        l10n.snippetQuickPickerCountOf(
                            list.length, widget.snippets.length),
                        style: TextStyle(
                            fontSize: 11, color: AppColors.v3TextTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(Snippet s, int index) {
    final highlighted = index == _highlight;
    final color = _colorFor(s.category);
    return InkWell(
      onTap: () => Navigator.of(context).pop(s),
      child: Container(
        decoration: BoxDecoration(
          color:
              highlighted ? color.withValues(alpha: 0.16) : Colors.transparent,
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(13, 7, 16, 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                s.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.v3TextPrimary,
                  fontWeight: highlighted ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                s.command,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'JetBrainsMono',
                  color: AppColors.v3TextSecondary,
                ),
              ),
            ),
            if (highlighted) ...[
              const SizedBox(width: 8),
              Icon(LucideIcons.cornerDownLeft, size: 13, color: color),
            ],
          ],
        ),
      ),
    );
  }
}

class _EscChip extends StatelessWidget {
  const _EscChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: AppColors.v3BorderDefault),
        ),
        child: Text('esc',
            style: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: AppColors.v3TextTertiary)),
      ),
    );
  }
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.delta);
  final int delta;
}

class _AcceptIntent extends Intent {
  const _AcceptIntent();
}
