import 'package:flutter/material.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';

/// Where the colour of a host's label comes from, for the choice that has the
/// icon follow it.
enum HostLabelColorSource {
  /// The host has a colour label of its own.
  label,

  /// The host has none and takes its group's colour.
  group,

  /// The host has no colour label and is in no group.
  none,
}

/// What colours a host's icon: its own colour (the default), the colour of
/// the host's label (its own, else its group's), or a custom one. Holds no
/// choice itself: [value] is what the host stores (see [HostIconColor]).
class HostIconColorField extends StatefulWidget {
  const HostIconColorField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.source,
    required this.shownNow,
    this.groupName,
    this.picture = false,
  });

  /// The choice, as the host stores it.
  final int? value;
  final ValueChanged<int?> onChanged;

  /// Where the label's colour comes from: names the middle choice and says
  /// what it does for this host.
  final HostLabelColorSource source;

  /// The group whose colour the label takes, when [source] is the group.
  final String? groupName;

  /// The colour the icon is drawn in now. "Custom" starts from it, so that
  /// choosing Custom changes nothing until a colour is picked.
  final Color shownNow;

  /// Whether the icon is an uploaded picture, which is never tinted: the
  /// choices are shown, off, with the reason.
  final bool picture;

  static const _own = 'own';
  static const _label = 'label';
  static const _custom = 'custom';

  @override
  State<HostIconColorField> createState() => _HostIconColorFieldState();
}

class _HostIconColorFieldState extends State<HostIconColorField> {
  /// The custom colour last held, so that going to another choice and back
  /// brings it back.
  Color? _lastCustom;

  @override
  void initState() {
    super.initState();
    _lastCustom = HostIconColor.customColor(widget.value);
  }

  @override
  void didUpdateWidget(covariant HostIconColorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lastCustom = HostIconColor.customColor(widget.value) ?? _lastCustom;
  }

  String get _selected => widget.value == null
      ? HostIconColorField._own
      : widget.value == HostIconColor.followsLabel
          ? HostIconColorField._label
          : HostIconColorField._custom;

  void _choose(String id) {
    switch (id) {
      case HostIconColorField._own:
        widget.onChanged(null);
      case HostIconColorField._label:
        widget.onChanged(HostIconColor.followsLabel);
      case HostIconColorField._custom:
        widget.onChanged(HostIconColor.custom(_lastCustom ?? widget.shownNow));
    }
  }

  String _hint(AppLocalizations l10n) {
    if (widget.picture) return l10n.hostIconColorPicture;
    if (widget.value == null) return l10n.hostIconColorOwnHint;
    return switch (widget.source) {
      HostLabelColorSource.label => l10n.hostIconColorFromLabel,
      HostLabelColorSource.group => l10n.zestColorUsingGroup(widget.groupName ?? ''),
      HostLabelColorSource.none => l10n.hostIconColorNoLabel,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final off = widget.picture;
    final custom = HostIconColor.customColor(widget.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l10n.hostIconColorLabel,
              style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary),
            ),
            ZestModeToggle(
              key: const ValueKey('host-icon-color'),
              selectedId: _selected,
              disabledReason: l10n.hostIconColorPicture,
              onChanged: _choose,
              segments: [
                ZestModeSegment(id: HostIconColorField._own, label: l10n.hostIconColorOwn, enabled: !off),
                ZestModeSegment(
                  id: HostIconColorField._label,
                  label: widget.source == HostLabelColorSource.label
                      ? l10n.hostIconColorLabelColor
                      : l10n.hostIconColorGroup,
                  enabled: !off,
                ),
                ZestModeSegment(id: HostIconColorField._custom, label: l10n.zestColorPickerCustom, enabled: !off),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (custom != null && !off)
          ZestColorPicker(
            key: const ValueKey('host-icon-color-swatches'),
            presets: AppColors.labelPalette,
            selected: custom,
            onChanged: (c) => widget.onChanged(HostIconColor.custom(c)),
          )
        else
          // As tall as the swatches at least, so the dialog does not jump
          // between a choice with colours to pick and one without.
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _hint(l10n),
                key: const ValueKey('host-icon-color-hint'),
                style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.v3TextSecondary),
              ),
            ),
          ),
      ],
    );
  }
}
