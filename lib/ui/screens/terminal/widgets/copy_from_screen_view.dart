import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_fonts.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Copy from screen: the terminal's text, scrollback and all, to select and
/// copy from. It opens at the bottom, the most recent output, which is what is
/// copied most (it used to open at the top of the
/// scrollback). Its scrollbar is a handle to drag through long text, and two
/// buttons go to the top and the bottom. It shows the last 100, 250, 500 or
/// 1,000 lines, or all of them, as picked (and kept on the device).
class CopyFromScreenView extends ConsumerStatefulWidget {
  const CopyFromScreenView({super.key, required this.text, required this.onCopy});

  final String text;

  /// Copies the selection, or all the lines shown with none ([hasRange]
  /// false).
  final void Function(String toCopy, bool hasRange) onCopy;

  /// The counts of last lines to pick from; 0 is all of them.
  static const lineCounts = [100, 250, 500, 1000, 0];

  @override
  ConsumerState<CopyFromScreenView> createState() => _CopyFromScreenViewState();
}

class _CopyFromScreenViewState extends ConsumerState<CopyFromScreenView> {
  final _scroll = ScrollController();
  TextSelection? _selection;
  bool _atTop = true;
  bool _atBottom = true;
  late List<String> _lines;
  late int _count;
  late String _shown;

  @override
  void initState() {
    super.initState();
    _lines = widget.text.split('\n');
    final saved = ref.read(settingsServiceProvider).copyScreenLines;
    // A count of its own (Custom) is kept too.
    _count = saved >= 0 ? saved : 100;
    _shown = _textOf(_count);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(animate: false));
  }

  /// The last [count] lines, or all of them for 0.
  String _textOf(int count) =>
      count == 0 || _lines.length <= count ? widget.text : _lines.sublist(_lines.length - count).join('\n');

  void _pick(int count) {
    ref.read(settingsServiceProvider).setCopyScreenLines(count);
    setState(() {
      _count = count;
      _shown = _textOf(count);
      _selection = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(animate: false));
  }

  /// Custom: as many of the last lines as are typed.
  Future<void> _pickCustom() async {
    final picked = await showZestModal<int>(
      context: context,
      size: ZestModalSize.compact,
      child: _CustomLines(initial: CopyFromScreenView.lineCounts.contains(_count) ? null : _count),
    );
    if (picked != null) _pick(picked);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final top = p.pixels <= p.minScrollExtent + 8;
    final bottom = p.pixels >= p.maxScrollExtent - 8;
    if (top != _atTop || bottom != _atBottom) {
      setState(() {
        _atTop = top;
        _atBottom = bottom;
      });
    }
  }

  void _toBottom({bool animate = true}) {
    if (!mounted || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(end, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(end);
      _onScroll();
    }
  }

  void _toTop() =>
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Dialog.fullscreen(
      backgroundColor: AppColors.surfaceDark,
      child: Column(
        children: [
          AppBar(
            backgroundColor: AppColors.surfaceDark,
            title: Text(l10n.terminalMakeSelection),
            leading: IconButton(
              tooltip: l10n.close,
              icon: const Icon(LucideIcons.x),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              TextButton.icon(
                key: const ValueKey('copy-screen-copy'),
                onPressed: () {
                  final s = _selection;
                  final hasRange = s != null && s.isValid && s.start != s.end;
                  widget.onCopy(hasRange ? _shown.substring(s.start, s.end) : _shown, hasRange);
                },
                icon: const Icon(LucideIcons.copy),
                label: Text(l10n.copy),
              ),
            ],
          ),
          // How many of the last lines: a choice kept on the device.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                for (final count in CopyFromScreenView.lineCounts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('copy-screen-lines-$count'),
                      label: Text(count == 0
                          ? l10n.copyScreenAll
                          : l10n.copyScreenLast(NumberFormat.decimalPattern(Localizations.localeOf(context).toString()).format(count))),
                      selected: _count == count,
                      onSelected: (_) => _pick(count),
                    ),
                  ),
                // Custom: a count of its own, shown on the chip once picked.
                ChoiceChip(
                  key: const ValueKey('copy-screen-lines-custom'),
                  label: Text(CopyFromScreenView.lineCounts.contains(_count)
                      ? l10n.copyScreenCustom
                      : l10n.copyScreenLast(NumberFormat.decimalPattern(Localizations.localeOf(context).toString()).format(_count))),
                  selected: !CopyFromScreenView.lineCounts.contains(_count),
                  onSelected: (_) => _pickCustom(),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                // A thick handle a finger can take, to drag through long text.
                Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 10,
                  radius: const Radius.circular(5),
                  child: SingleChildScrollView(
                    key: const ValueKey('copy-screen-scroll'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 24, 88),
                    child: SelectableText(
                      _shown,
                      key: ValueKey('copy-screen-text-$_count'),
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        // A prompt's powerline signs and icons, as the
                        // terminal draws them (4.0).
                        fontFamilyFallback: const [kNerdFontSymbolsFamily],
                        fontSize: 13,
                        color: AppColors.onSurface,
                        height: 1.5,
                      ),
                      selectionControls: materialTextSelectionControls,
                      onSelectionChanged: (selection, cause) => _selection = selection,
                    ),
                  ),
                ),
                Positioned(
                  right: 24,
                  bottom: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_atTop)
                        FloatingActionButton.small(
                          key: const ValueKey('copy-screen-top'),
                          heroTag: null,
                          elevation: 0,
                          highlightElevation: 0,
                          shape: CircleBorder(side: BorderSide(color: AppColors.v3BorderSubtle)),
                          tooltip: l10n.copyScreenToTop,
                          backgroundColor: AppColors.surfaceLight,
                          foregroundColor: AppColors.onSurface,
                          onPressed: _toTop,
                          child: const Icon(LucideIcons.arrowUpToLine),
                        ),
                      if (!_atTop && !_atBottom) const SizedBox(height: 8),
                      if (!_atBottom)
                        FloatingActionButton.small(
                          key: const ValueKey('copy-screen-bottom'),
                          heroTag: null,
                          elevation: 0,
                          highlightElevation: 0,
                          shape: CircleBorder(side: BorderSide(color: AppColors.v3BorderSubtle)),
                          tooltip: l10n.copyScreenToBottom,
                          backgroundColor: AppColors.surfaceLight,
                          foregroundColor: AppColors.onSurface,
                          onPressed: _toBottom,
                          child: const Icon(LucideIcons.arrowDownToLine),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom's dialog: how many of the last lines to show. Its own widget, so its
/// field lives until the dialog has gone (freed as the dialog was closing, it
/// was used after it was freed).
class _CustomLines extends StatefulWidget {
  const _CustomLines({this.initial});

  final int? initial;

  @override
  State<_CustomLines> createState() => _CustomLinesState();
}

class _CustomLinesState extends State<_CustomLines> {
  late final _field = TextEditingController(text: widget.initial?.toString() ?? '');
  String? _error;
  bool _closing = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done() {
    if (_closing) return;
    final n = int.tryParse(_field.text.trim());
    if (n == null || n <= 0) {
      // Said under the field (it did nothing).
      setState(() => _error = AppLocalizations.of(context)!.settingsScrollbackError);
      return;
    }
    _closing = true;
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The app's dialog (the dialog rules, 3.4): its button says what it does
    // (it said OK).
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.listOrdered,
      title: l10n.copyScreenCustomTitle,
      body: ZestTextField(
        key: const ValueKey('copy-screen-custom-field'),
        controller: _field,
        hintText: l10n.copyScreenCustomHint,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
        errorText: _error,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmit: _done,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
      primaryKey: const ValueKey('copy-screen-custom-ok'),
      primaryAction: (label: l10n.settingsApply, icon: null, onPressed: _done),
    );
  }
}
