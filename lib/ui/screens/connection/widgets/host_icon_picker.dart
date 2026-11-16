import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/models/os_descriptor.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/connection/widgets/host_icon_color_field.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/l10n/host_icon_names.dart';

/// The host-card icon a user chose: a built-in catalog [iconId], an uploaded
/// [customIcon] (base64 PNG), or neither (auto OS icon); and what colours it
/// ([iconColor], as the host stores it: see [HostIconColor]).
typedef HostIconChoice = ({String? iconId, String? customIcon, int? iconColor});

/// Longest side an uploaded custom icon is downscaled to before it is stored
/// and synced, so a photo never bloats the encrypted blob.
const int _kCustomIconMaxSide = 128;

/// Hard cap on the encoded PNG (matches the sync restore cap). A downscaled
/// 128px icon is far under this; anything larger is refused.
const int _kCustomIconMaxBytes = 96 * 1024;

/// Open the icon picker. Resolves with the new choice, or null if cancelled.
///
/// Every icon is shown in the colour the card will draw it in: its own by
/// default, or what [currentIconColor] says and the person picks here.
/// [labelColor] is the colour of the host's label (its own, else its
/// group's), for an icon that follows it; [labelSource] and [groupName] say
/// where that colour comes from.
Future<HostIconChoice?> showHostIconPicker(
  BuildContext context, {
  required String? currentIconId,
  required String? currentCustomIcon,
  int? currentIconColor,
  Color? labelColor,
  HostLabelColorSource labelSource = HostLabelColorSource.none,
  String? groupName,
  String? detectedOs,
  String? autoIconId,
}) {
  return showZestModal<HostIconChoice>(
    context: context,
    size: ZestModalSize.standard,
    child: _HostIconPickerDialog(
      detectedOs: detectedOs,
      autoIconId: autoIconId,
      currentIconId: currentIconId,
      currentCustomIcon: currentCustomIcon,
      currentIconColor: currentIconColor,
      labelColor: labelColor,
      labelSource: labelSource,
      groupName: groupName,
    ),
  );
}

/// Downscale image [input] to a small square-ish PNG and base64-encode it, or
/// null if it cannot be decoded or stays over the byte cap. Uses Flutter's own
/// image codec (no extra dependency): the decode does the resize.
Future<String?> downscaleIconToBase64(Uint8List input) async {
  try {
    final codec = await ui.instantiateImageCodec(
      input,
      targetWidth: _kCustomIconMaxSide,
      targetHeight: _kCustomIconMaxSide,
    );
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) return null;
    final png = data.buffer.asUint8List();
    if (png.length > _kCustomIconMaxBytes) return null;
    return base64Encode(png);
  } catch (_) {
    return null;
  }
}

/// The picker's section label for a catalog category.
String hostIconCategoryLabel(AppLocalizations l10n, HostIconCategory c) =>
    switch (c) {
      HostIconCategory.os => l10n.hostIconCatOs,
      HostIconCategory.hardware => l10n.hostIconCatHardware,
      HostIconCategory.network => l10n.hostIconCatNetwork,
      HostIconCategory.cloud => l10n.hostIconCatCloud,
      HostIconCategory.services => l10n.hostIconCatServices,
      HostIconCategory.security => l10n.hostIconCatSecurity,
      HostIconCategory.places => l10n.hostIconCatPlaces,
      HostIconCategory.tags => l10n.hostIconCatTags,
    };

class _HostIconPickerDialog extends StatefulWidget {
  const _HostIconPickerDialog({
    required this.currentIconId,
    required this.currentCustomIcon,
    required this.currentIconColor,
    required this.labelColor,
    required this.labelSource,
    required this.groupName,
    this.detectedOs,
    this.autoIconId,
  });

  /// The built-in icon Auto shows for this kind of host whatever runs on it
  /// (a remote screen's), named by [detectedOs]; null where Auto follows the
  /// system seen.
  final String? autoIconId;

  /// The name of the system the host was seen to run (Debian), or null
  /// before it has been connected to.
  final String? detectedOs;

  final String? currentIconId;
  final String? currentCustomIcon;
  final int? currentIconColor;
  final Color? labelColor;
  final HostLabelColorSource labelSource;
  final String? groupName;

  @override
  State<_HostIconPickerDialog> createState() => _HostIconPickerDialogState();
}

class _HostIconPickerDialogState extends State<_HostIconPickerDialog> {
  late String? _iconId = widget.currentIconId;
  late String? _customIcon = widget.currentCustomIcon;
  late int? _iconColor = widget.currentIconColor;
  final _searchController = TextEditingController();
  String _query = '';
  bool _uploading = false;

  bool get _isAuto => _iconId == null && _customIcon == null;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _uploading = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final bytes = picked?.files.firstOrNull?.bytes;
      if (bytes == null) {
        if (mounted) setState(() => _uploading = false);
        return;
      }
      final encoded = await downscaleIconToBase64(bytes);
      if (!mounted) return;
      if (encoded == null) {
        setState(() => _uploading = false);
        showTopSnackBar(context, l10n.hostIconUploadFailed, isError: true);
        return;
      }
      setState(() {
        _customIcon = encoded;
        _iconId = null; // a custom image supersedes a chosen built-in
        _uploading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        showTopSnackBar(context, l10n.hostIconUploadFailed, isError: true, details: '$e');
      }
    }
  }

  void _choose(String id) => setState(() {
        _iconId = id;
        _customIcon = null;
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The colour every icon is shown in here; null is each icon's own.
    final tint = HostIconColor.tint(_iconColor, labelColor: widget.labelColor);
    // Found by its name in the person's language too, as it is shown.
    final matches = OsCatalog.search(_query, nameOf: (d) => hostIconName(d, l10n));
    // One section per category, in catalog order, empty ones dropped so a
    // search collapses to just the sections that still have hits.
    final sections = [
      for (final c in HostIconCategory.values)
        (
          category: c,
          icons: matches.where((d) => d.category == c).toList(growable: false),
        ),
    ].where((s) => s.icons.isNotEmpty).toList(growable: false);

    // The shell (the dialog rules of 3.4): the icon chosen and how it is
    // coloured above the catalog, Upload a link at the left of the footer,
    // Cancel and Apply at its right; no lines.
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.image,
      title: l10n.hostIconPickerTitle,
      bodyScrolls: false,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A live preview of the current choice, and Auto.
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                HostIcon(
                  iconId: _iconId ?? widget.autoIconId,
                  customIcon: _customIcon,
                  size: 40,
                  iconColor: _iconColor,
                  labelColor: widget.labelColor,
                ),
                const SizedBox(width: 14),
                // Auto in use says what it shows (the system seen, or that
                // none is yet); a chosen icon offers to go back to it (it
                // was a greyed-out "Use auto").
                Flexible(
                  child: _ActionChip(
                    key: const ValueKey('host-icon-auto'),
                    icon: _isAuto ? LucideIcons.sparkles : LucideIcons.rotateCcw,
                    label: !_isAuto
                        ? l10n.hostIconResetAuto
                        : widget.detectedOs == null
                            ? l10n.hostIconAutoNotYet
                            : l10n.hostIconAutoDetected(widget.detectedOs!),
                    selected: _isAuto,
                    onTap: _isAuto
                        ? null
                        : () => setState(() {
                              _iconId = null;
                              _customIcon = null;
                            }),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: HostIconColorField(
              value: _iconColor,
              source: widget.labelSource,
              groupName: widget.groupName,
              shownNow: tint ?? OsIcon.ownColor(OsCatalog.get(_iconId)),
              picture: _customIcon?.isNotEmpty ?? false,
              onChanged: (v) => setState(() => _iconColor = v),
            ),
          ),
          ZestListSearchField(
            controller: _searchController,
            hintText: l10n.hostIconSearchHint,
            onChanged: (v) => setState(() => _query = v),
          ),
          Flexible(
            child: sections.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Text(
                      l10n.hostIconNoMatches,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.v3TextSecondary),
                    ),
                  )
                : CustomScrollView(
                    shrinkWrap: true,
                    slivers: [
                      for (final s in sections) ...[
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
                          sliver: SliverToBoxAdapter(
                            child: Text(
                              hostIconCategoryLabel(l10n, s.category)
                                  .toUpperCase(),
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.8,
                                color: AppColors.v3TextSecondary,
                              ),
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.only(bottom: 8),
                          sliver: SliverGrid(
                            gridDelegate:
                                // Taller than wide to seat a name label
                                // under each icon.
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 82,
                              childAspectRatio: 0.80,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 10,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, i) {
                                final d = s.icons[i];
                                return _IconTile(
                                  osId: d.id,
                                  label: hostIconName(d, l10n),
                                  tint: tint,
                                  selected: _customIcon == null &&
                                      _iconId == d.id,
                                  onTap: () => _choose(d.id),
                                );
                              },
                              childCount: s.icons.length,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
      // A picture of one's own: the system's file picker opens.
      tertiaryKey: const ValueKey('host-icon-upload'),
      tertiaryAction: (label: l10n.hostIconUpload, onPressed: _uploading ? null : _upload),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      primaryAction: (
        label: l10n.hostIconApply,
        icon: null,
        onPressed: () => Navigator.of(context).pop(
            (iconId: _iconId, customIcon: _customIcon, iconColor: _iconColor)),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.osId,
    required this.label,
    required this.tint,
    required this.selected,
    required this.onTap,
  });

  final String osId;
  final String label;
  final Color? tint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.v3TextPrimary.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? AppColors.v3TextPrimary.withValues(alpha: 0.55)
                          : AppColors.v3BorderSubtle,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: OsIcon(osId: osId, size: 32, color: tint),
                ),
              ),
              const SizedBox(height: 5),
              // The name under every icon (many are ambiguous monograms), so
              // the label is not hidden behind a hover tooltip.
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.05,
                  color: selected
                      ? AppColors.v3TextPrimary
                      : AppColors.v3TextSecondary,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// The state in use (Auto): shown as chosen, not as turned off.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null || selected;
    return Material(
      // Chosen: a quiet fill and line, no colour of its own (in a dialog,
      // colour is for what it means).
      color: selected ? AppColors.v3TextPrimary.withValues(alpha: 0.06) : AppColors.v3Background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? AppColors.v3TextPrimary.withValues(alpha: 0.30) : AppColors.v3BorderSubtle),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 15,
                  color: selected
                      ? AppColors.v3TextPrimary
                      : enabled
                          ? AppColors.v3TextSecondary
                          : AppColors.v3TextDisabled),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: enabled
                      ? AppColors.v3TextPrimary
                      : AppColors.v3TextDisabled,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
