import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/features/shortcuts/shortcut_words.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_hints.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/features/terminal/terminal_dictation.dart' show voiceInputSupportedProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/theme/app_colors.dart';

/// The "Keyboard Shortcuts" panel inside Settings → Keyboard.
///
/// Lists every [ShortcutAction] grouped by category, shows the
/// effective binding (override → default), and lets the user:
///   • Click the binding chip to capture a new binding
///   • Click the undo glyph to restore the default
///   • Click the clear glyph to unbind an action entirely
///   • Click "Reset all" (top-right) to wipe every override
///
/// Conflict handling: if the user picks a combo that's already used
/// by another action we present a confirmation dialog. Confirming
/// auto-unbinds the conflicting action so the new binding wins
/// outright - that avoids the "two actions silently fight each
/// other" foot-gun.
class KeyboardShortcutsPanel extends ConsumerStatefulWidget {
  const KeyboardShortcutsPanel({super.key});

  @override
  ConsumerState<KeyboardShortcutsPanel> createState() =>
      _KeyboardShortcutsPanelState();
}

class _KeyboardShortcutsPanelState
    extends ConsumerState<KeyboardShortcutsPanel> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'shortcut search');
  final Map<ShortcutAction, GlobalKey> _rowKeys = {
    for (final a in ShortcutAction.values) a: GlobalKey(),
  };
  Set<ShortcutAction> _matches = const {};
  ShortcutAction? _scrolledTo;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Search matches label, description and the current key combo, so
  /// "split" finds both splits and "ctrl+shift+d" finds whatever owns it.
  void _onQuery(String q, ShortcutBindings bindings) {
    final query = q.trim().toLowerCase();
    final l10n = AppLocalizations.of(context)!;
    final matches = <ShortcutAction>{};
    if (query.isNotEmpty) {
      for (final a in shortcutActionsOffered(voice: ref.read(voiceInputSupportedProvider))) {
        final combo =
            bindings.bindingFor(a)?.displayLabel.toLowerCase() ?? '';
        if (shortcutName(l10n, a).toLowerCase().contains(query) ||
            shortcutHelp(l10n, a).toLowerCase().contains(query) ||
            combo.contains(query)) {
          matches.add(a);
        }
      }
    }
    setState(() => _matches = matches);
    // Jump to the first match (in display order) once the highlight has
    // painted; every match stays highlighted.
    final first = ShortcutAction.values.where(matches.contains).firstOrNull;
    if (first != null && first != _scrolledTo) {
      _scrolledTo = first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _rowKeys[first]?.currentContext;
        if (ctx != null && mounted) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.15,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        }
      });
    } else if (first == null) {
      _scrolledTo = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bindings = ref.watch(shortcutBindingsProvider);
    final notifier = ref.read(shortcutBindingsProvider.notifier);
    final l10n = AppLocalizations.of(context)!;

    // Group actions by category once so we can render section headers.
    final byCategory = <ShortcutCategory, List<ShortcutAction>>{};
    for (final action in shortcutActionsOffered(voice: ref.watch(voiceInputSupportedProvider))) {
      byCategory.putIfAbsent(action.category, () => []).add(action);
    }
    final searching = _search.text.trim().isNotEmpty;

    // Flat list, no nested card: the section already carries its "Keyboard
    // Shortcuts" header, so this sits directly on the settings surface with
    // the search box and a single Reset all action above category groups.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: _SearchField(
                    controller: _search,
                    focusNode: _searchFocus,
                    hint: l10n.keyboardShortcutsSearchHint,
                    onChanged: (q) => _onQuery(q, bindings),
                    onClear: () {
                      _search.clear();
                      _onQuery('', bindings);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: () async {
                final ok = await _confirmResetAll(context);
                if (ok == true) {
                  await notifier.resetAll();
                }
              },
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: Text(l10n.keyboardShortcutsResetAll),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.v3TextSecondary,
                textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12),
              ),
            ),
          ],
        ),
        if (searching && _matches.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              l10n.keyboardShortcutsNoMatch,
              style: TextStyle(color: AppColors.v3TextTertiary, fontSize: 12),
            ),
          ),
        for (final category in ShortcutCategory.values)
          if (byCategory[category] != null) ...[
            _CategoryHeader(label: shortcutCategoryName(l10n, category)),
            for (final action in byCategory[category]!)
              _ShortcutRow(
                key: _rowKeys[action],
                action: action,
                binding: bindings.bindingFor(action),
                isCustomised: bindings.isCustomised(action),
                highlighted: _matches.contains(action),
                dimmed: searching && !_matches.contains(action),
                onRebind: () =>
                    _captureNewBinding(context, ref, action, bindings),
                onReset: () => notifier.resetBinding(action),
                onUnbind: () => notifier.unbind(action),
              ),
          ],
        // Keys that are not rebindable (ranges the registry cannot express)
        // are documented here, since the read-only cheat-sheet is gone and
        // the palette lists only rebindable actions (spec 7a, 9).
        _CategoryHeader(label: l10n.helpFixedKeysTitle),
        Text(
          l10n.helpFixedKeysDesc,
          style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 11),
        ),
        const SizedBox(height: 4),
        _FixedKeyRow(
          combo: formatComboString('Ctrl+1-9'),
          label: l10n.helpFixedJumpToTab,
        ),
        _FixedKeyRow(
          combo: formatComboString('Alt+←↑→↓'),
          label: l10n.helpFixedNavigatePanes,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ── Capture flow ───────────────────────────────────────────────

  Future<void> _captureNewBinding(
    BuildContext context,
    WidgetRef ref,
    ShortcutAction action,
    ShortcutBindings currentBindings,
  ) async {
    // No onSubmit: Enter is a key that may be recorded. The capture field
    // takes every key first, Escape too (it cancels there), so the modal's
    // own Escape only closes it where the keyboard is on a button.
    final captured = await showZestModal<ShortcutKey>(
      context: context,
      size: ZestModalSize.compact,
      child: _CaptureDialog(action: action),
    );
    if (captured == null) return;

    // Detect conflicts BEFORE writing.
    final conflicts =
        currentBindings.conflicts(captured, excluding: action);
    if (conflicts.isNotEmpty) {
      if (!context.mounted) return;
      final overwrite = await _confirmOverwrite(
        context,
        newBinding: captured,
        conflicts: conflicts,
      );
      if (overwrite != true) return;
      // User opted in - unbind the loser(s) so the new combo is
      // unambiguous.
      final notifier = ref.read(shortcutBindingsProvider.notifier);
      for (final c in conflicts) {
        await notifier.unbind(c);
      }
    }

    await ref
        .read(shortcutBindingsProvider.notifier)
        .setBinding(action, captured);
  }

  Future<bool?> _confirmResetAll(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestConfirmDialog.show(
      context,
      // What is lost, in its amber sentence (3.4).
      tone: ZestDialogTone.warning,
      title: l10n.keyboardShortcutsResetAllTitle,
      body: '',
      warning: l10n.keyboardShortcutsResetAllBody,
      confirmLabel: l10n.keyboardShortcutsResetAll,
    );
  }

  /// Asks before a key that other shortcuts have is given to this one: it
  /// names them, and says that they lose it.
  Future<bool?> _confirmOverwrite(
    BuildContext context, {
    required ShortcutKey newBinding,
    required List<ShortcutAction> conflicts,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return ZestConfirmDialog.show(
      context,
      // Which shortcuts have it, then what they lose, in its amber sentence
      // (3.4).
      tone: ZestDialogTone.warning,
      title: l10n.keyboardShortcutsConflictTitle(newBinding.displayLabel),
      body: l10n.keyboardShortcutsConflictBoundTo,
      bullets: [for (final c in conflicts) shortcutName(l10n, c)],
      warning: l10n.keyboardShortcutsConflictWarning,
      confirmLabel: l10n.keyboardShortcutsUseAnyway,
    );
  }
}

// ── Internal widgets ───────────────────────────────────────────────

/// A read-only row for a key that is not rebindable: the chord is documented
/// here because the palette lists only rebindable actions.
class _FixedKeyRow extends StatelessWidget {
  const _FixedKeyRow({required this.combo, required this.label});
  final String combo;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.v3TextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          _BindingChip(label: combo),
        ],
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: AppColors.v3TextSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    super.key,
    required this.action,
    required this.binding,
    required this.isCustomised,
    required this.onRebind,
    required this.onReset,
    required this.onUnbind,
    this.highlighted = false,
    this.dimmed = false,
  });

  final ShortcutAction action;
  final ShortcutKey? binding;
  final bool isCustomised;
  final VoidCallback onRebind;
  final VoidCallback onReset;
  final VoidCallback onUnbind;

  /// A search match: lifted with a brand wash so every hit reads at once.
  final bool highlighted;

  /// Not a match while a search is active.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isUnbound = binding == null;

    // Whole-row tap removed: the chip is the record trigger (click-chip-to-
    // record) and inline glyphs replace the old 3-dot menu. No horizontal
    // padding: the panel is now flat (no card), so rows align with the
    // section's _SettingRows instead of being inset like card content.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding:
          EdgeInsets.symmetric(vertical: 6, horizontal: highlighted ? 10 : 0),
      decoration: BoxDecoration(
        color: highlighted
            ? AppColors.v3AccentPrimary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlighted
              ? AppColors.v3AccentPrimary.withValues(alpha: 0.35)
              : Colors.transparent,
        ),
      ),
      child: Opacity(
        opacity: dimmed ? 0.45 : 1,
        child: Row(
        children: [
          // Label + description column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Wraps beside its badge where the row is narrower than
                    // it (it ran out of the row in Russian and German).
                    Flexible(
                      child: Text(
                        shortcutName(l10n, action),
                        style: TextStyle(
                          color: AppColors.v3TextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (isCustomised) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.orange.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          l10n.keyboardShortcutsCustomBadge,
                          style: TextStyle(
                            color: AppColors.accentInk,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  shortcutHelp(l10n, action),
                  style: TextStyle(
                    color: AppColors.v3TextSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Binding chip - click to record a new binding.
          _BindingChip(
            label: isUnbound ? l10n.keyboardShortcutsUnbound : binding!.displayLabel,
            dimmed: isUnbound,
            onTap: onRebind,
          ),
          const SizedBox(width: 4),

          // Undo glyph: reset this action to its default binding.
          if (isCustomised)
            _GlyphButton(
              icon: LucideIcons.undo2,
              tooltip: l10n.keyboardShortcutsResetToDefault,
              onTap: onReset,
            ),
          // Clear glyph: unbind this action entirely.
          if (!isUnbound)
            _GlyphButton(
              icon: LucideIcons.x,
              tooltip: l10n.keyboardShortcutsUnbind,
              onTap: onUnbind,
            ),
        ],
        ),
      ),
    );
  }
}

/// Compact search box for the panel: filters as you type, Escape clears.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onClear,
      },
      child: SizedBox(
        height: 32,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary),
          cursorColor: AppColors.v3AccentPrimary,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle:
                TextStyle(fontSize: 12.5, color: AppColors.v3TextTertiary),
            prefixIcon:
                Icon(LucideIcons.search, size: 16, color: AppColors.v3TextTertiary),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 34, minHeight: 32),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: AppLocalizations.of(context)!.emptyClearSearch,
                    icon: Icon(LucideIcons.x,
                        size: 14, color: AppColors.v3TextTertiary),
                    onPressed: onClear,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 30, minHeight: 30),
                  ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            filled: true,
            fillColor: AppColors.v3Elevated,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppColors.v3BorderSubtle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                  color: AppColors.v3AccentPrimary.withValues(alpha: 0.6)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The binding chip. When [onTap] is given it is the record trigger: clicking
/// it captures a new binding, and it brightens with an accent border on hover
/// so it reads as clickable.
class _BindingChip extends StatefulWidget {
  const _BindingChip({required this.label, this.dimmed = false, this.onTap});
  final String label;
  final bool dimmed;
  final VoidCallback? onTap;

  @override
  State<_BindingChip> createState() => _BindingChipState();
}

class _BindingChipState extends State<_BindingChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final interactive = widget.onTap != null;
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _hovered ? AppColors.v3Hover : AppColors.v3Elevated,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: _hovered
              ? AppColors.v3AccentPrimary.withValues(alpha: 0.5)
              : AppColors.v3BorderSubtle,
        ),
      ),
      child: Text(
        widget.label,
        style: TextStyle(
          color: widget.dimmed
              ? AppColors.v3TextSecondary
              : AppColors.v3TextPrimary,
          fontSize: 12,
          fontFamily: 'JetBrainsMono',
          fontStyle: widget.dimmed ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
    if (!interactive) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(message: l10n.keyboardShortcutsClickToChange, child: chip),
      ),
    );
  }
}

/// A small square icon button used for the per-row reset (undo) and unbind
/// actions, replacing the old 3-dot menu.
class _GlyphButton extends StatefulWidget {
  const _GlyphButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<_GlyphButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _hovered ? AppColors.v3Hover : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: _hovered
                  ? AppColors.v3TextPrimary
                  : AppColors.v3TextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Capture dialog ────────────────────────────────────────────────

/// Modal dialog that listens for the next non-modifier key press and
/// returns a [ShortcutKey].  Esc cancels.
class _CaptureDialog extends StatefulWidget {
  const _CaptureDialog({required this.action});
  final ShortcutAction action;

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  ShortcutKey? _previewing;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Capture focus immediately so the user doesn't have to click
    // inside the dialog before pressing the combo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Esc cancels (only if no modifiers are held - Ctrl+Esc etc. is
    // a valid binding and we want to allow it).
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      final keys = HardwareKeyboard.instance;
      if (!keys.isControlPressed &&
          !keys.isShiftPressed &&
          !keys.isAltPressed &&
          !keys.isMetaPressed) {
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      }
    }

    final key = ShortcutKey.fromKeyEvent(event);
    if (key == null) {
      // Just a modifier - show a "waiting…" state but stay open.
      return KeyEventResult.handled;
    }
    setState(() => _previewing = key);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final defaultBinding = defaultShortcutBindings[widget.action];

    // The app's own dialog shell, shown with showZestModal and no onSubmit:
    // every key here is one that may be recorded, and the capture field takes
    // them first.
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyboard,
      maxWidth: 440,
      title: l10n.keyboardShortcutsRebindTitle(shortcutName(l10n, widget.action)),
      subtitle: l10n.keyboardShortcutsPressCombo,
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
      // Nothing to save until a key was pressed.
      primaryAction: (
        label: l10n.save,
        icon: null,
        onPressed: _previewing == null ? null : () => Navigator.pop(context, _previewing),
      ),
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                key: const ValueKey('shortcut-capture-key'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 18),
                decoration: BoxDecoration(
                  color: AppColors.v3Elevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _previewing != null
                        ? AppColors.orange
                        : AppColors.v3BorderSubtle,
                    width: _previewing != null ? 1.5 : 1,
                  ),
                ),
                child: Center(
                  child: Text(
                    _previewing?.displayLabel ??
                        l10n.keyboardShortcutsWaitingForInput,
                    style: TextStyle(
                      color: _previewing != null
                          ? AppColors.v3TextPrimary
                          : AppColors.v3TextSecondary,
                      fontSize: 16,
                      fontFamily: 'JetBrainsMono',
                      fontStyle: _previewing != null
                          ? FontStyle.normal
                          : FontStyle.italic,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(LucideIcons.info,
                      size: 14, color: AppColors.v3TextSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      defaultBinding != null
                          ? l10n.keyboardShortcutsDefaultBinding(
                              defaultBinding.displayLabel)
                          : l10n.keyboardShortcutsNoDefault,
                      style: TextStyle(
                          color: AppColors.v3TextSecondary,
                          fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                l10n.keyboardShortcutsPressToCancel(shortcutEscLabel()),
                style: TextStyle(
                    color: AppColors.v3TextSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
