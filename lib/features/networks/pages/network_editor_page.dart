import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/group_color.dart';
import '../data/network_icon_catalog.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/network_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../ui/widgets/recording_masked_field.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/top_snackbar.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../../../utils/platform_utils.dart';
import '../engine/cidr.dart';
import '../engine/network_state.dart' show wifiNamesReadHere;
import '../models/network.dart';
import '../models/network_trigger.dart';
import '../widgets/trigger_summary.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// Curated set of icons offered in the editor's icon picker.
///
/// Icon picker grid contents.  Sourced from the shared catalog so
/// the editor and the repository can't drift out of sync - the
/// repository looks up stored networks' icons by codePoint against
/// this same list.
const List<IconData> _kIconChoices = networkIconChoices;

/// User-pickable colors for a network. Excludes [GroupColor.gray] which is
/// reserved for the Default network - we don't want two networks visually
/// indistinguishable from the system fallback.
final List<GroupColor> _kColorChoices = GroupColor.values
    .where((c) => c != GroupColor.gray)
    .toList(growable: false);

/// Modal editor for creating or editing a [Network].
///
/// Use [NetworkEditorPage.show] from the Networks page; the result is
/// `true` when the user saved (or deleted), `false` on cancel.
class NetworkEditorPage extends ConsumerStatefulWidget {
  const NetworkEditorPage({super.key, this.network, this.onClose});

  /// Existing network to edit, or null for a brand-new one. The Default
  /// network is permitted but the editor locks the triggers section.
  final Network? network;

  /// When provided, the editor is EMBEDDED (in the A2 split view) rather than
  /// shown as a dialog: save / cancel / delete invoke this instead of popping
  /// a route. The live `allNetworksProvider` stream refreshes the list.
  final VoidCallback? onClose;

  /// Convenience launcher. Shows the editor as a centered dialog (matches
  /// the snippet editor's desktop pattern). Returns true when saved.
  static Future<bool> show(BuildContext context, [Network? network]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // unsaved-edits guard runs in PopScope
      builder: (_) => Dialog(
        backgroundColor: AppColors.v3Surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          // Two-column desktop layout: identity | behavior.
          constraints: const BoxConstraints(maxWidth: 860, maxHeight: 640),
          child: NetworkEditorPage(network: network),
        ),
      ),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<NetworkEditorPage> createState() => _NetworkEditorPageState();
}

class _NetworkEditorPageState extends ConsumerState<NetworkEditorPage> {
  // ── Field state ─────────────────────────────────────────────────
  late final TextEditingController _nameController;
  late GroupColor _color;
  late IconData _icon;
  late final List<_TriggerDraft> _triggers;
  // Kept as stored: its picker is gone, as nothing ever brought a VPN up
  // before, and a save leaves the value as it was.
  String? _bringUpVpn;
  bool _saving = false;

  // ── Validation state ────────────────────────────────────────────
  String? _nameError;
  String? _triggersError;

  // ── Form helpers ────────────────────────────────────────────────
  bool get _isEditing => widget.network != null;
  bool get _isDefault => widget.network?.isFallback ?? false;
  String get _initialName => widget.network?.name ?? '';

  @override
  void initState() {
    super.initState();
    final n = widget.network;

    _nameController = TextEditingController(text: _initialName);
    _color = n?.color ?? GroupColor.blue;
    _icon = n?.icon ?? LucideIcons.network;
    _bringUpVpn = n?.bringUpVpn;

    // Seed the trigger drafts. Default's [AlwaysTrigger] becomes a single
    // read-only row that can't be edited or removed.
    _triggers = (n?.triggers ?? const <NetworkTrigger>[])
        .map((t) => _TriggerDraft.fromTrigger(t))
        .toList();
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final t in _triggers) {
      t.dispose();
    }
    super.dispose();
  }

  // ── Trigger list mutation ───────────────────────────────────────

  void _addTrigger(_NewTriggerKind kind) {
    setState(() {
      _triggers.add(_TriggerDraft.empty(kind));
      _triggersError = null;
    });
  }

  void _removeTrigger(_TriggerDraft draft) {
    setState(() {
      _triggers.remove(draft);
      draft.dispose();
    });
  }

  void _setConnectivityKind(_TriggerDraft draft, ConnectivityKind kind) {
    setState(() {
      draft.trigger = ConnectivityTrigger(kind);
    });
  }

  // ── Save / delete ───────────────────────────────────────────────

  /// Close the editor: embedded (A2 split) → invoke onClose; dialog → pop.
  void _close({required bool saved}) {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop(saved);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context)!;

    // ── Validation ───────────────────────────────────────────────
    final name = _nameController.text.trim();
    String? nameErr;
    if (name.isEmpty) {
      nameErr = l10n.networkEditorNameRequired;
    } else if (name.length > 32) {
      // Defensive guardrail - UI maxLength keeps user from getting here
      // but a paste could otherwise sneak past.
      nameErr = l10n.networkEditorNameRequired;
    }

    String? triggersErr;
    if (!_isDefault) {
      if (_triggers.isEmpty) {
        triggersErr = l10n.networkEditorAtLeastOneTrigger;
      } else {
        for (final draft in _triggers) {
          final fieldErr = draft.computeFieldError(l10n);
          if (fieldErr != null) {
            // Field-level error already surfaces inline; treat as blocker.
            triggersErr = fieldErr;
            break;
          }
        }
      }
    }

    if (nameErr != null || triggersErr != null) {
      setState(() {
        _nameError = nameErr;
        _triggersError = triggersErr;
      });
      return;
    }

    setState(() {
      _saving = true;
      _nameError = null;
      _triggersError = null;
    });

    // ── Build the model ──────────────────────────────────────────
    final repo = ref.read(networkRepositoryProvider);
    final triggers = _isDefault
        ? const <NetworkTrigger>[AlwaysTrigger()]
        : _triggers.map((d) => d.bake()).toList(growable: false);

    final network = Network(
      id: widget.network?.id ?? const Uuid().v4(),
      name: name,
      color: _isDefault ? GroupColor.gray : _color,
      icon: _icon,
      triggers: triggers,
      isFallback: _isDefault,
      bringUpVpn: _bringUpVpn,
    );

    try {
      if (_isEditing) {
        await repo.update(network);
      } else {
        await repo.create(network);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // In the app's language, with what was thrown to copy (it was English
      // with the raw error glued on).
      showTopSnackBar(context, l10n.networkNotSaved, isError: true, details: '$e');
      return;
    }

    if (!mounted) return;
    _close(saved: true);
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final n = widget.network!;
    // Built outside build: the display form is a snapshot (recording mode).
    final shownName = Redactable.network(n.name).display;
    // The app's own question (it was a plain dialog), with the same words.
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: shownName,
      body: l10n.networksDeleteConfirm(shownName),
      confirmLabel: l10n.networksDelete,
      cancelLabel: l10n.networkEditorCancel,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(networkRepositoryProvider).delete(n.id);
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context, l10n.networkNotDeleted, isError: true, details: '$e');
      return;
    }
    if (!mounted) return;
    _close(saved: true);
  }

  // ── Column content (shared by the two-column desktop layout and the
  //    single-column mobile layout) ─────────────────────────────────

  /// Identity fields: name, color, icon.
  Widget _identityColumn(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _NameField(
          controller: _nameController,
          errorText: _nameError,
          label: l10n.networkEditorName,
          onChanged: (_) {
            if (_nameError != null) {
              setState(() => _nameError = null);
            }
          },
        ),
        const SizedBox(height: 20),
        if (!_isDefault) ...[
          _SectionLabel(label: l10n.networkEditorColor),
          const SizedBox(height: 8),
          _ColorPicker(
            selected: _color,
            onChanged: (c) => setState(() => _color = c),
          ),
          const SizedBox(height: 20),
        ],
        _SectionLabel(label: l10n.networkEditorIcon),
        const SizedBox(height: 10),
        _IconPicker(
          selected: _icon,
          tint: _isDefault ? GroupColor.gray : _color,
          onChanged: (i) => setState(() => _icon = i),
        ),
      ],
    );
  }

  /// Behavior fields: triggers + auto-connect VPN.
  Widget _behaviorColumn(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(
          label: l10n.networkEditorTriggers,
          helper: _isDefault
              ? l10n.networkEditorTriggersLockedDefault
              : l10n.networkEditorTriggersHelp,
        ),
        const SizedBox(height: 8),
        _TriggersSection(
          triggers: _triggers,
          isDefault: _isDefault,
          errorText: _triggersError,
          onAdd: _addTrigger,
          onRemove: _removeTrigger,
          onConnectivityChanged: _setConnectivityKind,
          onTriggerEdited: () {
            if (_triggersError != null) {
              setState(() => _triggersError = null);
            }
          },
        ),
      ],
    );
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(
          // The title names the network: painted in its display form.
          title: _isEditing
              ? l10n.networkEditorTitleEdit(
                  Redactable.network(widget.network!.name).displayIn(ref))
              : l10n.networkEditorTitleNew,
          onClose: () => _close(saved: false),
        ),
        Divider(height: 1, color: AppColors.v3BorderSubtle),

        // Desktop keeps the two-column identity | behavior layout; mobile
        // (the full-route editor) stacks them into a single scroll column so
        // the fields aren't crushed at phone width.
        Expanded(
          child: isDesktopPlatform
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
                        child: _identityColumn(l10n),
                      ),
                    ),
                    VerticalDivider(
                        width: 1, color: AppColors.v3BorderSubtle),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 20, 24, 20),
                        child: _behaviorColumn(l10n),
                      ),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _identityColumn(l10n),
                      const SizedBox(height: 20),
                      Divider(height: 1, color: AppColors.v3BorderSubtle),
                      const SizedBox(height: 20),
                      _behaviorColumn(l10n),
                    ],
                  ),
                ),
        ),

        Divider(height: 1, color: AppColors.v3BorderSubtle),
        _Footer(
          showDelete: _isEditing && !_isDefault,
          saving: _saving,
          onDelete: _confirmDelete,
          onCancel: () => _close(saved: false),
          onSave: _save,
          saveLabel: l10n.networkEditorSave,
          cancelLabel: l10n.networkEditorCancel,
          deleteLabel: l10n.networkEditorDelete,
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Trigger draft - mutable view of a NetworkTrigger inside the editor
// ══════════════════════════════════════════════════════════════════

/// Wraps a [NetworkTrigger] so the editor can mutate it (text fields,
/// dropdown changes) without having to reconstruct the immutable
/// trigger on every keystroke. [bake] turns the draft back into a
/// concrete [NetworkTrigger] at save time.
class _TriggerDraft {
  _TriggerDraft._({
    required this.key,
    required this.trigger,
    this.textController,
  });

  factory _TriggerDraft.fromTrigger(NetworkTrigger trigger) {
    final key = const Uuid().v4();
    return switch (trigger) {
      SubnetTrigger(:final cidr) => _TriggerDraft._(
          key: key,
          trigger: trigger,
          textController: TextEditingController(text: cidr),
        ),
      SsidTrigger(:final ssid) => _TriggerDraft._(
          key: key,
          trigger: trigger,
          textController: TextEditingController(text: ssid),
        ),
      _ => _TriggerDraft._(key: key, trigger: trigger),
    };
  }

  factory _TriggerDraft.empty(_NewTriggerKind kind) {
    final key = const Uuid().v4();
    return switch (kind) {
      _NewTriggerKind.subnet => _TriggerDraft._(
          key: key,
          trigger: const SubnetTrigger(''),
          textController: TextEditingController(),
        ),
      _NewTriggerKind.ssid => _TriggerDraft._(
          key: key,
          trigger: const SsidTrigger(''),
          textController: TextEditingController(),
        ),
      _NewTriggerKind.cellular => _TriggerDraft._(
          key: key,
          trigger: const CellularTrigger(),
        ),
      _NewTriggerKind.connectivity => _TriggerDraft._(
          key: key,
          trigger: const ConnectivityTrigger(ConnectivityKind.wifi),
        ),
    };
  }

  /// Stable identity for use in keyed widgets (especially if reorder
  /// support is added later - the editor doesn't reorder today).
  final String key;

  /// The current shape of this draft. Mutated in-place when the user
  /// switches a connectivity kind, etc.
  NetworkTrigger trigger;

  /// Lives only for triggers that take free-form text (subnet, ssid).
  final TextEditingController? textController;

  /// Convert back to an immutable [NetworkTrigger] using the latest
  /// controller text where applicable. Trims whitespace.
  NetworkTrigger bake() {
    return switch (trigger) {
      SubnetTrigger() => SubnetTrigger(textController?.text.trim() ?? ''),
      SsidTrigger() => SsidTrigger(textController?.text.trim() ?? ''),
      CellularTrigger() => const CellularTrigger(),
      ConnectivityTrigger(:final kind) => ConnectivityTrigger(kind),
      // Should not happen for a draft (the editor doesn't expose these)
      // but if it does, falling through to AlwaysTrigger is benign.
      _ => const AlwaysTrigger(),
    };
  }

  /// Validate this draft's editable field. Returns null if OK, else a
  /// localized error message. Used to gate save and to drive inline
  /// `errorText` decoration on the row.
  String? computeFieldError(AppLocalizations l10n) {
    return switch (trigger) {
      SubnetTrigger() => () {
          final raw = textController?.text.trim() ?? '';
          if (raw.isEmpty || Cidr.tryParse(raw) == null) {
            return l10n.networkEditorCidrInvalid;
          }
          return null;
        }(),
      SsidTrigger() => () {
          final raw = textController?.text.trim() ?? '';
          if (raw.isEmpty) return l10n.networkEditorSsidEmpty;
          return null;
        }(),
      _ => null,
    };
  }

  void dispose() {
    textController?.dispose();
  }
}

/// The kinds of trigger the user can add via the "+ Add trigger" menu.
/// (Internal to the editor - `NetworkTrigger` itself doesn't model this
/// because [AlwaysTrigger] and [_UnknownTrigger] aren't user-addable.)
enum _NewTriggerKind { subnet, ssid, cellular, connectivity }

// ══════════════════════════════════════════════════════════════════
// Subwidgets
// ══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.v3TextPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: onClose,
            iconSize: 16,
            splashRadius: 18,
            icon: Icon(
              LucideIcons.x,
              color: AppColors.v3TextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.showDelete,
    required this.saving,
    required this.onDelete,
    required this.onCancel,
    required this.onSave,
    required this.saveLabel,
    required this.cancelLabel,
    required this.deleteLabel,
  });

  final bool showDelete;
  final bool saving;
  final VoidCallback onDelete;
  final VoidCallback onCancel;
  final VoidCallback onSave;
  final String saveLabel;
  final String cancelLabel;
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          if (showDelete)
            TextButton.icon(
              onPressed: saving ? null : onDelete,
              icon: const Icon(LucideIcons.trash2, size: 14),
              label: Text(deleteLabel),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.v3Error,
                textStyle: const TextStyle(
                  fontFamily: 'GeistSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          const Spacer(),
          TextButton(
            onPressed: saving ? null : onCancel,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.v3TextSecondary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              textStyle: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            child: Text(cancelLabel),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: saving ? null : onSave,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.v3AccentPrimary,
              foregroundColor: AppColors.onBrand(AppColors.v3AccentPrimary),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              textStyle: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: ButtonSpinner(),
                  )
                : Text(saveLabel),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.helper});

  final String label;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: AppColors.v3TextSecondary,
          ),
        ),
        if (helper != null) ...[
          const SizedBox(height: 2),
          Text(
            helper!,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.v3TextTertiary,
            ),
          ),
        ],
      ],
    );
  }
}

class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.errorText,
    required this.label,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String? errorText;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 14, color: AppColors.v3TextPrimary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label: label),
        const SizedBox(height: 8),
        // The name identifies the user's environment: masked + read-only while
        // recording mode is on (a tap runs the reveal gate); the controller's
        // real text is never touched.
        RecordingMaskedFormField(
          controller: controller,
          mask: (v) => Redactable.network(v).display,
          style: style,
          decoration: _editorInputDecoration(
            hint: gl10n.networkIconHome,
            errorText: errorText,
            counter: const SizedBox.shrink(),
          ),
          child: TextField(
            controller: controller,
            // Desktop: focus the name field on open so the user can type the
            // network name right away. Mobile: do NOT autofocus - the soft
            // keyboard would spring up on entry and cover the form before the
            // user has decided to type, wasting the space.
            autofocus: !isMobilePlatform,
            maxLength: 32,
            inputFormatters: [LengthLimitingTextInputFormatter(32)],
            onChanged: onChanged,
            style: style,
            decoration: _editorInputDecoration(
              hint: gl10n.networkIconHome,
              errorText: errorText,
              counter: const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.selected, required this.onChanged});

  final GroupColor selected;
  final ValueChanged<GroupColor> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _kColorChoices.map((c) {
        final isSelected = c == selected;
        return GestureDetector(
          onTap: () => onChanged(c),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: c.value,
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: c.value.withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: isSelected
                ? const Icon(LucideIcons.check, size: 14, color: Colors.white)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

class _IconPicker extends StatelessWidget {
  const _IconPicker({
    required this.selected,
    required this.tint,
    required this.onChanged,
  });

  final IconData selected;
  final GroupColor tint;
  final ValueChanged<IconData> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _kIconChoices.map((icon) {
        final isSelected = icon.codePoint == selected.codePoint;
        final label = _networkIconLabel(l10n, icon);
        return GestureDetector(
          onTap: () => onChanged(icon),
          child: Tooltip(
            message: label,
            waitDuration: const Duration(milliseconds: 400),
            child: Container(
              width: 64,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? tint.value.withValues(alpha: 0.18)
                    : AppColors.v3Background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? tint.value : AppColors.v3BorderSubtle,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color:
                        isSelected ? tint.value : AppColors.v3TextSecondary,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.1,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected
                          ? tint.value
                          : AppColors.v3TextTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Localised label for a network icon in the picker grid. Keyed by the
/// icon's codePoint so it stays in sync with [networkIconChoices]. Labels
/// are literal descriptions of the glyph so the choice is never ambiguous.
String _networkIconLabel(AppLocalizations l10n, IconData icon) {
  final cp = icon.codePoint;
  if (cp == LucideIcons.home.codePoint) return l10n.networkIconHome;
  if (cp == LucideIcons.briefcase.codePoint) return l10n.networkIconWork;
  if (cp == LucideIcons.building.codePoint) return l10n.networkIconBuilding;
  if (cp == LucideIcons.coffee.codePoint) return l10n.networkIconCafe;
  if (cp == LucideIcons.wifi.codePoint) return l10n.networkIconWifi;
  if (cp == LucideIcons.signal.codePoint) return l10n.networkIconSignal;
  if (cp == LucideIcons.cloud.codePoint) return l10n.networkIconCloud;
  if (cp == LucideIcons.globe.codePoint) return l10n.networkIconGlobe;
  if (cp == LucideIcons.shield.codePoint) return l10n.networkIconShield;
  if (cp == LucideIcons.lock.codePoint) return l10n.networkIconLock;
  if (cp == LucideIcons.airplay.codePoint) return l10n.networkIconAirplay;
  return l10n.networkIconNetwork;
}

// ══════════════════════════════════════════════════════════════════
// Triggers section
// ══════════════════════════════════════════════════════════════════

class _TriggersSection extends StatelessWidget {
  const _TriggersSection({
    required this.triggers,
    required this.isDefault,
    required this.errorText,
    required this.onAdd,
    required this.onRemove,
    required this.onConnectivityChanged,
    required this.onTriggerEdited,
  });

  final List<_TriggerDraft> triggers;
  final bool isDefault;
  final String? errorText;
  final ValueChanged<_NewTriggerKind> onAdd;
  final ValueChanged<_TriggerDraft> onRemove;
  final void Function(_TriggerDraft, ConnectivityKind) onConnectivityChanged;
  final VoidCallback onTriggerEdited;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (isDefault) {
      // Single read-only "Always" pill - the Default network's triggers
      // are pinned by design.
      return _LockedAlwaysRow(label: l10n.networksTriggerSummaryAlways);
    }

    final hasSsid = triggers.any((d) => d.trigger is SsidTrigger);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errorText != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              errorText!,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.v3Error,
              ),
            ),
          ),
        ],
        for (final draft in triggers)
          Padding(
            key: ValueKey(draft.key),
            padding: const EdgeInsets.only(bottom: 8),
            child: _TriggerRow(
              draft: draft,
              onRemove: () => onRemove(draft),
              onConnectivityChanged: (k) => onConnectivityChanged(draft, k),
              onTextChanged: onTriggerEdited,
            ),
          ),
        const SizedBox(height: 2),
        // Distinct add control per trigger type - the type is discoverable
        // without opening a generic menu first (§4).
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _AddTriggerButton(
              icon: LucideIcons.network,
              label: l10n.networkEditorTriggerSubnet,
              onTap: () => onAdd(_NewTriggerKind.subnet),
            ),
            // Only where the Wi-Fi's name is read: never on a phone.
            if (wifiNamesReadHere)
              _AddTriggerButton(
                icon: LucideIcons.wifi,
                label: l10n.networkEditorTriggerSsid,
                onTap: () => onAdd(_NewTriggerKind.ssid),
              ),
            _AddTriggerButton(
              icon: LucideIcons.signal,
              label: l10n.networkEditorTriggerCellular,
              onTap: () => onAdd(_NewTriggerKind.cellular),
            ),
            _AddTriggerButton(
              icon: LucideIcons.router,
              label: l10n.networkEditorTriggerConnectivity,
              onTap: () => onAdd(_NewTriggerKind.connectivity),
            ),
          ],
        ),
        // Surfaced only once a Wi-Fi trigger exists: the spoofing caveat
        // (security), then what reading the name takes (muted). A phone
        // reads no Wi-Fi name (wifiNamesReadHere), and says so, with what
        // tells its networks apart instead.
        if (!wifiNamesReadHere) ...[
          const SizedBox(height: 12),
          _SsidWarningBanner(
            key: const ValueKey('network-wifi-names-not-read'),
            // A Mac reads none either (macOS asks for Location Services),
            // and is told so in its own words.
            text: defaultTargetPlatform == TargetPlatform.macOS ? l10n.netWifiNamesNotOnMac : l10n.netWifiNamesNotOnPhones,
            muted: true,
          ),
        ] else if (hasSsid) ...[
          const SizedBox(height: 12),
          _SsidWarningBanner(text: l10n.networkEditorSsidSpoofWarning),
          const SizedBox(height: 8),
          _SsidWarningBanner(
            text: l10n.netWifiNameComputerNote,
            muted: true,
          ),
        ],
      ],
    );
  }
}

class _LockedAlwaysRow extends StatelessWidget {
  const _LockedAlwaysRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.v3BorderSubtle,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.globe,
            size: 14,
            color: AppColors.v3TextTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.v3TextSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          Icon(
            LucideIcons.lock,
            size: 12,
            color: AppColors.v3TextTertiary,
          ),
        ],
      ),
    );
  }
}

/// A single `+ type` pill that adds one trigger of a specific kind, so the
/// available trigger types are visible without opening a menu first (§4).
class _AddTriggerButton extends StatelessWidget {
  const _AddTriggerButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.v3BorderDefault, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.plus,
                  size: 11, color: AppColors.v3TextSecondary),
              const SizedBox(width: 4),
              Icon(icon, size: 12, color: AppColors.v3AccentInk),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.v3TextPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SsidWarningBanner extends StatelessWidget {
  const _SsidWarningBanner({super.key, required this.text, this.muted = false});

  final String text;

  /// Muted = the secondary permission-cost note (subtle grey); non-muted =
  /// the primary spoofing caveat (amber, security-relevant).
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final accent = muted ? AppColors.v3TextTertiary : AppColors.v3Warning;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: muted
            ? Colors.transparent
            : AppColors.v3Warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: muted
              ? AppColors.v3BorderSubtle
              : AppColors.v3Warning.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              muted ? LucideIcons.info : LucideIcons.alertTriangle,
              size: 12,
              color: accent,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: AppColors.v3TextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Trigger row
// ══════════════════════════════════════════════════════════════════

/// Single editable row inside the triggers list. Internally rebuilds
/// itself on every keystroke so the live CIDR validation can flip the
/// row's `errorText` decoration without triggering a parent rebuild.
class _TriggerRow extends StatefulWidget {
  const _TriggerRow({
    required this.draft,
    required this.onRemove,
    required this.onConnectivityChanged,
    required this.onTextChanged,
  });

  final _TriggerDraft draft;
  final VoidCallback onRemove;
  final ValueChanged<ConnectivityKind> onConnectivityChanged;
  final VoidCallback onTextChanged;

  @override
  State<_TriggerRow> createState() => _TriggerRowState();
}

class _TriggerRowState extends State<_TriggerRow> {
  String? _liveError;

  @override
  void initState() {
    super.initState();
    widget.draft.textController?.addListener(_revalidate);
  }

  @override
  void dispose() {
    // Don't dispose the controller here - the editor state owns it via
    // _TriggerDraft.dispose.
    widget.draft.textController?.removeListener(_revalidate);
    super.dispose();
  }

  void _revalidate() {
    final l10n = AppLocalizations.of(context)!;
    final err = widget.draft.computeFieldError(l10n);
    if (err != _liveError) {
      setState(() => _liveError = err);
    }
    widget.onTextChanged();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final draft = widget.draft;

    final (icon, content) = switch (draft.trigger) {
      SubnetTrigger() => (
          LucideIcons.network,
          _SubnetField(
            controller: draft.textController!,
            errorText: _liveError,
            placeholder: l10n.networkEditorCidrPlaceholder,
          )
        ),
      SsidTrigger() => (
          LucideIcons.wifi,
          _SsidField(
            controller: draft.textController!,
            errorText: _liveError,
            placeholder: l10n.networkEditorSsidPlaceholder,
          )
        ),
      CellularTrigger() => (
          LucideIcons.signal,
          _CellularLabel(label: l10n.networkEditorTriggerCellular),
        ),
      ConnectivityTrigger(:final kind) => (
          LucideIcons.router,
          _ConnectivityDropdown(
            selected: kind,
            onChanged: widget.onConnectivityChanged,
          )
        ),
      _ => (LucideIcons.helpCircle, const SizedBox.shrink()),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.v3BorderSubtle,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 14,
            color: AppColors.v3TextSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(child: content),
          IconButton(
            tooltip: l10n.networkEditorRemoveTrigger,
            iconSize: 14,
            onPressed: widget.onRemove,
            splashRadius: 16,
            icon: Icon(
              LucideIcons.x,
              color: AppColors.v3TextTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubnetField extends StatelessWidget {
  const _SubnetField({
    required this.controller,
    required this.errorText,
    required this.placeholder,
  });

  final TextEditingController controller;
  final String? errorText;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      fontFamily: 'JetBrainsMono',
      color: AppColors.v3TextPrimary,
    );
    // A subnet is an address: masked + read-only while recording mode is on.
    return RecordingMaskedFormField(
      controller: controller,
      mask: maskedCidr,
      style: style,
      decoration: _editorInputDecoration(hint: placeholder, dense: true),
      child: TextField(
        controller: controller,
        style: style,
        decoration: _editorInputDecoration(
          hint: placeholder,
          errorText: errorText,
          dense: true,
        ),
      ),
    );
  }
}

class _SsidField extends StatelessWidget {
  const _SsidField({
    required this.controller,
    required this.errorText,
    required this.placeholder,
  });

  final TextEditingController controller;
  final String? errorText;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 13, color: AppColors.v3TextPrimary);
    // An SSID names the environment: masked + read-only while recording mode
    // is on (name rule), mirroring the subnet field.
    return RecordingMaskedFormField(
      controller: controller,
      mask: (v) => Redactable.network(v).display,
      style: style,
      decoration: _editorInputDecoration(hint: placeholder, dense: true),
      child: TextField(
        controller: controller,
        style: style,
        decoration: _editorInputDecoration(
          hint: placeholder,
          errorText: errorText,
          dense: true,
        ),
      ),
    );
  }
}

class _CellularLabel extends StatelessWidget {
  const _CellularLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 13,
        color: AppColors.v3TextPrimary,
      ),
    );
  }
}

class _ConnectivityDropdown extends StatelessWidget {
  const _ConnectivityDropdown({
    required this.selected,
    required this.onChanged,
  });

  final ConnectivityKind selected;
  final ValueChanged<ConnectivityKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The app's select, boxed as the row's text fields are (a bare Material
    // dropdown).
    return ZestSelect<ConnectivityKind>(
      value: selected,
      items: [for (final kind in ConnectivityKind.values) ZestSelectItem(kind, _connectivityLabel(l10n, kind))],
      onChanged: onChanged,
    );
  }

  static String _connectivityLabel(AppLocalizations l10n, ConnectivityKind kind) {
    return switch (kind) {
      ConnectivityKind.wifi => l10n.networkConnectivityWifi,
      ConnectivityKind.ethernet => l10n.networkConnectivityEthernet,
      ConnectivityKind.cellular => l10n.networkConnectivityCellular,
      ConnectivityKind.vpn => l10n.networkConnectivityVpn,
      ConnectivityKind.none => l10n.networkConnectivityNone,
    };
  }
}

// ══════════════════════════════════════════════════════════════════
// Shared input decoration
// ══════════════════════════════════════════════════════════════════

InputDecoration _editorInputDecoration({
  String? hint,
  String? errorText,
  Widget? counter,
  bool dense = false,
}) {
  const radius = 6.0;
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: AppColors.v3TextTertiary, fontSize: 13),
    errorText: errorText,
    errorStyle: TextStyle(fontSize: 11, color: AppColors.v3Error),
    filled: true,
    fillColor: AppColors.v3Background,
    contentPadding: dense
        ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    isDense: dense,
    counter: counter,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: AppColors.v3BorderSubtle),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: AppColors.v3BorderSubtle),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(
        color: AppColors.v3AccentPrimary,
        width: 1.5,
      ),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: AppColors.v3Error),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: AppColors.v3Error, width: 1.5),
    ),
  );
}
