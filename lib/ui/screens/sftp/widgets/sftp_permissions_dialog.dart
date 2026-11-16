import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A permissions (chmod) dialog: an rwx grid and an octal field that are two
/// representations of ONE value, each editable and each updating the other
/// Returns a record of the chosen octal mode (0-0777) and whether
/// the user asked to apply it recursively, or null on cancel.
///
/// When [isDirectory] is true the dialog offers an "Apply to enclosed items"
/// checkbox (default OFF) that drives a queued recursive chmod; [recursive] is
/// false whenever the box is absent or unchecked.
///
/// Apply stays disabled until something changes - the mode, or (for a
/// directory) the recursive checkbox, since re-applying the current top-level
/// mode to differing children is itself a real operation.
Future<({int mode, bool recursive})?> showSftpPermissionsDialog({
  required BuildContext context,
  required String pathLabel,
  required int initialMode,
  int itemCount = 1,
  bool isDirectory = false,
}) {
  return showZestModal<({int mode, bool recursive})>(
    context: context,
    size: ZestModalSize.compact,
    child: _SftpPermissionsDialog(
      pathLabel: pathLabel,
      initialMode: initialMode & 0x1FF, // keep only the 9 permission bits
      itemCount: itemCount,
      isDirectory: isDirectory,
    ),
  );
}

class _SftpPermissionsDialog extends StatefulWidget {
  const _SftpPermissionsDialog({
    required this.pathLabel,
    required this.initialMode,
    required this.itemCount,
    required this.isDirectory,
  });

  final String pathLabel;
  final int initialMode;
  final int itemCount;
  final bool isDirectory;

  @override
  State<_SftpPermissionsDialog> createState() => _SftpPermissionsDialogState();
}

class _SftpPermissionsDialogState extends State<_SftpPermissionsDialog> {
  late int _mode = widget.initialMode;
  bool _recursive = false;
  late final TextEditingController _octalCtrl =
      TextEditingController(text: _octalText(_mode));

  bool get _changed => _mode != widget.initialMode;

  /// Apply is enabled once the mode changes, or once the user opts into a
  /// recursive apply (which is meaningful even at the unchanged top-level mode,
  /// because enclosed items may differ).
  bool get _canApply => _changed || _recursive;

  static String _octalText(int mode) => mode.toRadixString(8).padLeft(3, '0');

  /// Bit for (row 0=owner/1=group/2=others, col 0=read/1=write/2=execute).
  int _bit(int row, int col) => 1 << ((2 - row) * 3 + (2 - col));

  bool _has(int row, int col) => (_mode & _bit(row, col)) != 0;

  void _toggle(int row, int col) {
    setState(() {
      _mode ^= _bit(row, col);
      final text = _octalText(_mode);
      if (_octalCtrl.text != text) {
        _octalCtrl.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    });
  }

  void _onOctalChanged(String v) {
    final t = v.trim();
    if (t.isEmpty) return;
    if (RegExp(r'^[0-7]{1,4}$').hasMatch(t)) {
      setState(() => _mode = int.parse(t, radix: 8) & 0x1FF);
    }
  }

  static String _symbolic(int mode) {
    const rwx = ['---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx'];
    return rwx[(mode >> 6) & 7] + rwx[(mode >> 3) & 7] + rwx[mode & 7];
  }

  @override
  void dispose() {
    _octalCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The shell (the dialog rules of 3.4): Cancel and Apply in its footer.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.lock,
      title: l10n.sftpPropertyPermissions,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.itemCount > 1
                ? l10n.sftpItemCount(widget.itemCount)
                : widget.pathLabel,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'JetBrainsMono',
              color: AppColors.textSecondary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          _buildGrid(l10n),
          const SizedBox(height: 16),
          _buildOctalRow(l10n),
          const SizedBox(height: 12),
          Text(
            _changed
                ? l10n.sftpPermNew(_symbolic(_mode), _octalText(_mode))
                : l10n.sftpPermWas(_symbolic(widget.initialMode),
                    _octalText(widget.initialMode)),
            style: TextStyle(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
          if (widget.isDirectory) ...[
            const SizedBox(height: 6),
            _buildRecursiveToggle(l10n),
          ],
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
      primaryAction: (
        label: l10n.sftpApply,
        icon: null,
        onPressed: _canApply
            ? () => Navigator.pop(
                  context,
                  (
                    mode: _mode,
                    recursive: widget.isDirectory && _recursive,
                  ),
                )
            : null,
      ),
    );
  }

  /// "Apply to enclosed items" - the recursive opt-in, shown only for a
  /// directory. Default OFF so a chmod never silently descends. A whole-row
  /// tap toggles it, matching the rwx cells above.
  Widget _buildRecursiveToggle(AppLocalizations l10n) {
    return InkWell(
      onTap: () => setState(() => _recursive = !_recursive),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Checkbox(
                value: _recursive,
                onChanged: (v) => setState(() => _recursive = v ?? false),
                activeColor: AppColors.onSurfaceVariant,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.sftpApplyToEnclosed,
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(AppLocalizations l10n) {
    final rows = [l10n.sftpPermOwner, l10n.sftpPermGroup, l10n.sftpPermOthers];
    final cols = [l10n.sftpPermRead, l10n.sftpPermWrite, l10n.sftpPermExecute];
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 72),
            for (final c in cols)
              Expanded(
                child: Center(
                  child: Text(
                    c,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (var r = 0; r < 3; r++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    rows[r],
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
                for (var c = 0; c < 3; c++)
                  Expanded(child: Center(child: _cell(r, c))),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cell(int row, int col) {
    final on = _has(row, col);
    const glyph = ['r', 'w', 'x'];
    return InkWell(
      onTap: () => _toggle(row, col),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 36,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? AppColors.v3TextPrimary.withValues(alpha: 0.10)
              : AppColors.surfaceDark,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: on
                ? AppColors.v3TextPrimary.withValues(alpha: 0.35)
                : AppColors.divider,
          ),
        ),
        child: Text(
          on ? glyph[col] : '',
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'JetBrainsMono',
            fontWeight: FontWeight.w600,
            color: on ? AppColors.v3TextPrimary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildOctalRow(AppLocalizations l10n) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            l10n.sftpOctal,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
        SizedBox(
          width: 90,
          child: TextField(
            controller: _octalCtrl,
            onChanged: _onOctalChanged,
            maxLength: 4,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-7]')),
            ],
            style: const TextStyle(fontSize: 13, fontFamily: 'JetBrainsMono'),
            decoration: const InputDecoration(
              isDense: true,
              counterText: '',
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}
