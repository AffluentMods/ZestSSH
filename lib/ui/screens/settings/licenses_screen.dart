import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;

/// Searchable, grouped open-source-license browser.
///
/// Replaces Flutter's built-in [showLicensePage] with a desktop-feeling
/// layout: a scrollable list of packages on the left (search + count
/// header up top), full license text on the right when one is
/// selected. Renders all licenses surfaced via [LicenseRegistry].
class LicensesScreen extends StatefulWidget {
  const LicensesScreen({super.key, required this.version});
  final String version;

  @override
  State<LicensesScreen> createState() => _LicensesScreenState();
}

class _LicensesScreenState extends State<LicensesScreen> {
  /// Map of package name → list of license entries. The same package
  /// can show up multiple times (e.g. Apache + BSD); each row in
  /// the value list represents one such block.
  Map<String, List<LicenseEntry>> _entries = {};

  /// Filter query (case-insensitive substring match on package name).
  String _query = '';

  /// Currently-selected package name, or null on the empty state.
  String? _selected;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = <String, List<LicenseEntry>>{};
    await for (final entry in LicenseRegistry.licenses) {
      // Each entry has a list of packages it applies to. We split
      // them out so a single license that covers 5 packages shows
      // up under each.
      for (final pkg in entry.packages) {
        result.putIfAbsent(pkg, () => <LicenseEntry>[]).add(entry);
      }
    }
    if (!mounted) return;
    setState(() {
      _entries = result;
      _loading = false;
    });
  }

  List<String> get _filteredPackages {
    final all = _entries.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (_query.trim().isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((p) => p.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.licensesTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (context, box) {
              // Narrower than the two side by side (on a phone the license had 39
              // of the page's 360 pixels): the list, and a package's license in
              // its place, back to the list by the back button.
              if (box.maxWidth < _kTwoPanesWidth) {
                if (_selected case final selected?) {
                  return PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, _) {
                      if (!didPop) setState(() => _selected = null);
                    },
                    child: _LicenseDetail(packageName: selected, entries: _entries[selected]!),
                  );
                }
                return _PackageList(
                  packages: _filteredPackages,
                  selected: _selected,
                  totalCount: _entries.length,
                  width: box.maxWidth,
                  onQuery: (q) => setState(() => _query = q),
                  onSelect: (p) => setState(() => _selected = p),
                );
              }
              return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PackageList(
                  packages: _filteredPackages,
                  selected: _selected,
                  totalCount: _entries.length,
                  onQuery: (q) => setState(() => _query = q),
                  onSelect: (p) => setState(() => _selected = p),
                ),
                VerticalDivider(
                    width: 1, color: AppColors.divider),
                Expanded(
                  child: _selected == null
                      ? const _EmptyDetail()
                      : _LicenseDetail(
                          packageName: _selected!,
                          entries: _entries[_selected]!,
                        ),
                ),
              ],
            );
            }),
    );
  }
}

/// The least width that holds the list (320) and a license beside it.
const double _kTwoPanesWidth = 700;

class _PackageList extends StatelessWidget {
  const _PackageList({
    required this.packages,
    required this.selected,
    required this.totalCount,
    this.width = 320,
    required this.onQuery,
    required this.onSelect,
  });

  final List<String> packages;
  final String? selected;
  final int totalCount;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSelect;

  /// 320 beside the license; the page's width where the list stands alone.
  final double width;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: width,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.licensesCountShown(packages.length, totalCount),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  onChanged: onQuery,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.surface,
                    prefixIcon: Icon(LucideIcons.search,
                        size: 16, color: AppColors.onSurfaceVariant),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 36),
                    hintText: l10n.licensesFilterHint,
                    hintStyle: const TextStyle(fontSize: 12),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 10),
                    // A mouse's 32 high at least, a finger's 48 (the
                    // compact theme drew it 30).
                    constraints: BoxConstraints(minHeight: minTapTarget(context)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          BorderSide(color: AppColors.divider),
                    ),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            child: packages.isEmpty
                ? const _NoMatches()
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: packages.length,
                    itemBuilder: (_, i) {
                      final p = packages[i];
                      final isSel = selected == p;
                      return _PackageRow(
                        name: p,
                        isSelected: isSel,
                        onTap: () => onSelect(p),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _PackageRow extends StatefulWidget {
  const _PackageRow({
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  final String name;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_PackageRow> createState() => _PackageRowState();
}

class _PackageRowState extends State<_PackageRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          color: widget.isSelected
              ? AppColors.brandOrange.withValues(alpha: 0.10)
              : (_hover
                  ? AppColors.surface
                  : Colors.transparent),
          child: Row(
            children: [
              Icon(
                LucideIcons.package,
                size: 13,
                color: widget.isSelected
                    ? AppColors.accentInk
                    : AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.name,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'JetBrainsMono',
                    color: widget.isSelected
                        ? AppColors.accentInk
                        : AppColors.onSurface,
                    fontWeight: widget.isSelected
                        ? FontWeight.w600
                        : FontWeight.w400,
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

class _NoMatches extends StatelessWidget {
  const _NoMatches();
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n.licensesNoMatches,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12, color: AppColors.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.scale,
              size: 36, color: AppColors.onSurfaceDim),
          const SizedBox(height: 12),
          Text(
            l10n.licensesEmptyDetail,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LicenseDetail extends StatelessWidget {
  const _LicenseDetail({
    required this.packageName,
    required this.entries,
  });

  final String packageName;
  final List<LicenseEntry> entries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.package,
                  size: 18, color: AppColors.accentInk),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  packageName,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onBackground,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.licensesLicensesAttached(entries.length),
            style: TextStyle(
                fontSize: 11, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          for (final entry in entries) ...[
            _LicenseBlock(entry: entry),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _LicenseBlock extends StatelessWidget {
  const _LicenseBlock({required this.entry});
  final LicenseEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final body = entry.paragraphs
        .map((p) => p.text)
        .where((t) => t.trim().isNotEmpty)
        .join('\n\n');
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        body.isEmpty ? l10n.licensesNoLicenseBody : body,
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'JetBrainsMono',
          height: 1.55,
          color: AppColors.onSurface,
        ),
      ),
    );
  }
}
