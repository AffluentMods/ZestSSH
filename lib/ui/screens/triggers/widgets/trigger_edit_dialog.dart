import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// Preset highlight colours (ARGB). `null` in the model means "feature default"
/// (brand amber), represented by the first swatch here.
const List<int> kTriggerHighlightPresets = [
  0xFFE8600A, // brand amber (default)
  0xFFEF4444, // red
  0xFFEAB308, // yellow
  0xFF22C55E, // green
  0xFF06B6D4, // cyan
  0xFF3B82F6, // blue
  0xFFA855F7, // purple
];

/// The values collected by [showTriggerEditDialog].
class TriggerEditResult {
  final String name;
  final String pattern;
  final bool caseSensitive;
  final bool notify;
  final bool highlight;
  final int? highlightColor;
  final bool playSound;
  final String? connectionId;
  final bool enabled;

  const TriggerEditResult({
    required this.name,
    required this.pattern,
    required this.caseSensitive,
    required this.notify,
    required this.highlight,
    required this.highlightColor,
    required this.playSound,
    required this.connectionId,
    required this.enabled,
  });
}

/// Create or edit a trigger rule. Returns null on cancel.
Future<TriggerEditResult?> showTriggerEditDialog({
  required BuildContext context,
  TerminalTrigger? trigger,
  required List<Connection> connections,
}) {
  return showZestModal<TriggerEditResult>(
    context: context,
    size: ZestModalSize.compact,
    child: _TriggerEditDialog(trigger: trigger, connections: connections),
  );
}

class _TriggerEditDialog extends ConsumerStatefulWidget {
  final TerminalTrigger? trigger;
  final List<Connection> connections;

  const _TriggerEditDialog({required this.trigger, required this.connections});

  @override
  ConsumerState<_TriggerEditDialog> createState() => _TriggerEditDialogState();
}

class _TriggerEditDialogState extends ConsumerState<_TriggerEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late bool _caseSensitive;
  late bool _notify;
  late bool _highlight;
  late bool _playSound;
  late bool _enabled;
  late int? _highlightColor;
  late String? _connectionId;
  String? _patternError;

  @override
  void initState() {
    super.initState();
    final t = widget.trigger;
    _name = TextEditingController(text: t?.name ?? '');
    _pattern = TextEditingController(text: t?.pattern ?? '');
    _caseSensitive = t?.caseSensitive ?? false;
    _notify = t?.notify ?? true;
    _highlight = t?.highlight ?? false;
    _playSound = t?.playSound ?? false;
    _enabled = t?.enabled ?? true;
    _highlightColor = t?.highlightColor;
    // A scope pointing at a now-deleted host falls back to "All hosts".
    final scope = t?.connectionId;
    _connectionId = widget.connections.any((c) => c.id == scope) ? scope : null;
    _name.addListener(_revalidate);
    _pattern.addListener(_revalidate);
  }

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    super.dispose();
  }

  void _revalidate() {
    final l10n = AppLocalizations.of(context)!;
    final p = _pattern.text;
    // As the engine takes it: a leading (?i) is a flag, not an error.
    final message = triggerPatternError(p);
    final String? err = triggerPatternRefused(p, caseSensitive: _caseSensitive)
        ? l10n.trgPatternRefused
        : message == null
            ? null
            : (message.isEmpty ? l10n.trgInvalidRegex : message);
    setState(() => _patternError = err);
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _pattern.text.trim().isNotEmpty &&
      _patternError == null &&
      (_notify || _highlight);

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop(TriggerEditResult(
      name: _name.text.trim(),
      pattern: _pattern.text,
      caseSensitive: _caseSensitive,
      notify: _notify,
      highlight: _highlight,
      highlightColor: _highlight ? _highlightColor : null,
      playSound: _notify && _playSound,
      connectionId: _connectionId,
      enabled: _enabled,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isEdit = widget.trigger != null;
    // The app's dialog (3.4): its title the header's, Cancel and Save (or
    // Create) in the footer.
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.zap,
      title: isEdit ? l10n.trgEditTrigger : l10n.trgNewTrigger,
      maxWidth: 480,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
        _label(l10n.trgName),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          decoration: _fieldDecoration(l10n.trgNameHint),
        ),
        const SizedBox(height: 16),
        _label(l10n.trgPatternLabel),
        TextField(
          controller: _pattern,
          style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 13),
          minLines: 1,
          maxLines: 3,
          decoration: _fieldDecoration(r'e.g. (?i)\berror\b').copyWith(
            errorText: _patternError,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.trgPatternHelp,
          style: TextStyle(
              fontSize: 11.5, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        _switchRow(
          l10n.trgCaseSensitive,
          _caseSensitive,
          (v) {
            _caseSensitive = v;
            _revalidate();
          },
        ),
        const Divider(height: 20),
        // ── Actions ──
        _switchRow(
          l10n.trgNotifyMe,
          _notify,
          (v) => setState(() => _notify = v),
          subtitle: l10n.trgNotifySubtitle,
        ),
        if (_notify)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: _switchRow(
              l10n.trgPlaySound,
              _playSound,
              (v) => setState(() => _playSound = v),
              // How a phone plays it, which needs its
              // notifications allowed.
              subtitle: triggerSoundIsComputers ? null : l10n.trgPlaySoundPhoneHint,
            ),
          ),
        _switchRow(
          l10n.trgHighlight,
          _highlight,
          (v) => setState(() => _highlight = v),
          subtitle: l10n.trgHighlightSubtitle,
        ),
        if (_highlight) ...[
          const SizedBox(height: 8),
          _colorPicker(),
        ],
        if (!_notify && !_highlight)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              l10n.trgPickAction,
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
        const Divider(height: 20),
        _label(l10n.trgAppliesTo),
        _scopeDropdown(),
        const SizedBox(height: 16),
        _switchRow(
          l10n.commonEnabled,
          _enabled,
          (v) => setState(() => _enabled = v),
        ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      primaryKey: const ValueKey('trigger-edit-save'),
      primaryAction: (label: isEdit ? l10n.save : l10n.create, icon: null, onPressed: _canSave ? _save : null),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
      );

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: AppColors.surfaceLight,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );

  Widget _switchRow(String title, bool value, ValueChanged<bool> onChanged,
      {String? subtitle}) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 14, color: AppColors.onSurface)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle,
                      style: TextStyle(
                          fontSize: 11.5, color: AppColors.textSecondary)),
                ),
            ],
          ),
        ),
        ZestSwitch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _colorPicker() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < kTriggerHighlightPresets.length; i++)
          _swatch(kTriggerHighlightPresets[i], isDefault: i == 0),
      ],
    );
  }

  Widget _swatch(int argb, {required bool isDefault}) {
    // The first preset represents "default" (stored as null).
    final selected =
        isDefault ? _highlightColor == null : _highlightColor == argb;
    return GestureDetector(
      onTap: () =>
          setState(() => _highlightColor = isDefault ? null : argb),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Color(argb),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.onSurface : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: selected
            ? const Icon(LucideIcons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }

  Widget _scopeDropdown() {
    final l10n = AppLocalizations.of(context)!;
    // The app's select (it was a Material dropdown in a box of its
    // own).
    return ZestSelect<String?>(
      value: _connectionId,
      items: [
        ZestSelectItem(null, l10n.commonAllHosts),
        // Masked in recording mode, as everywhere a host is named; the value
        // stays the id.
        for (final c in widget.connections)
          ZestSelectItem(
            c.id,
            c.label.isNotEmpty ? Redactable.host(c.label).displayIn(ref) : Redactable.address(c.host).displayIn(ref),
            leading: HostGlyph(host: c, size: 16),
          ),
      ],
      onChanged: (v) => setState(() => _connectionId = v),
    );
  }
}
