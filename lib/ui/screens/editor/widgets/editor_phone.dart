import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// A phone's actions, at the bottom in thumb reach (3.4): Save,
/// Find, Undo, Redo, More. Save is orange only when there is something to
/// save.
class EditorPhoneBar extends StatelessWidget {
  const EditorPhoneBar({
    super.key,
    required this.onSave,
    required this.canSave,
    required this.onFind,
    required this.onUndo,
    required this.onRedo,
    required this.onMore,
    this.saving = false,
  });

  final VoidCallback? onSave;
  final bool canSave;
  final bool saving;
  final VoidCallback onFind;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget item(Key key, IconData icon, String label, VoidCallback? onTap, {bool primary = false}) {
      final color = onTap == null
          ? AppColors.v3TextDisabled
          : primary
              ? AppColors.onBrand(AppColors.v3AccentPrimary)
              : AppColors.v3TextSecondary;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Material(
            color: primary && onTap != null ? AppColors.v3AccentPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              key: key,
              onTap: onTap,
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 48,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (primary && saving)
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                    else
                      Icon(icon, size: 18, color: color),
                    const SizedBox(height: 3),
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: color)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      key: const ValueKey('editor-phone-bar'),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.v3ChromeBg,
        border: Border(top: BorderSide(color: AppColors.v3ChromeDivider)),
      ),
      child: Row(
        children: [
          item(const ValueKey('editor-phone-save'), LucideIcons.save, l10n.save, canSave && !saving ? onSave : null, primary: true),
          item(const ValueKey('editor-phone-find'), LucideIcons.search, l10n.editorKeyFind, onFind),
          item(const ValueKey('editor-phone-undo'), LucideIcons.undo2, l10n.editorKeyUndo, onUndo),
          item(const ValueKey('editor-phone-redo'), LucideIcons.redo2, l10n.editorKeyRedo, onRedo),
          item(const ValueKey('editor-phone-more'), LucideIcons.moreHorizontal, l10n.editorMore, onMore),
        ],
      ),
    );
  }
}

/// What a key of the keys row does.
enum EditorRowKey { tab, esc, undo, redo, left, up, down, right }

/// The keys row above a phone's keyboard (3.4), in a fixed order:
/// Tab, Esc, Undo, Redo, the brackets, then
/// the arrows; it slides sideways for the symbols configs need.
class EditorKeysRow extends StatelessWidget {
  const EditorKeysRow({super.key, required this.onKey, required this.onText});

  final void Function(EditorRowKey key) onKey;
  final void Function(String text) onText;

  static const List<String> brackets = ['{', '}', '[', ']', '(', ')'];
  static const List<String> symbols = ['|', '/', r'\', '~', '`', r'$', '#', '"', "'", ':', ';', '=', '-', '_', '<', '>', '&', '*', '!', '%', '@', '^'];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget key(Key k, Widget face, VoidCallback onTap, {double width = 44, String? tip}) {
      final button = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: AppColors.v3Elevated,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            key: k,
            onTap: onTap,
            borderRadius: BorderRadius.circular(7),
            child: SizedBox(width: width, height: 38, child: Center(child: face)),
          ),
        ),
      );
      return tip == null ? button : Tooltip(message: tip, child: button);
    }

    final faceStyle = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14, color: AppColors.v3TextPrimary);
    Widget icon(IconData i) => Icon(i, size: 16, color: AppColors.v3TextPrimary);
    return Container(
      key: const ValueKey('editor-keys-row'),
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.v3ChromeBg,
        border: Border(top: BorderSide(color: AppColors.v3ChromeDivider)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        children: [
          key(const ValueKey('editor-key-tab'), Text('Tab', style: faceStyle.copyWith(fontSize: 12.5)), () => onKey(EditorRowKey.tab), width: 52),
          key(const ValueKey('editor-key-esc'), Text('Esc', style: faceStyle.copyWith(fontSize: 12.5)), () => onKey(EditorRowKey.esc), width: 52),
          key(const ValueKey('editor-key-undo'), icon(LucideIcons.undo2), () => onKey(EditorRowKey.undo), tip: l10n.editorKeyUndo),
          key(const ValueKey('editor-key-redo'), icon(LucideIcons.redo2), () => onKey(EditorRowKey.redo), tip: l10n.editorKeyRedo),
          for (final b in brackets) key(ValueKey('editor-key-$b'), Text(b, style: faceStyle), () => onText(b), width: 36),
          key(const ValueKey('editor-key-left'), icon(LucideIcons.arrowLeft), () => onKey(EditorRowKey.left)),
          key(const ValueKey('editor-key-up'), icon(LucideIcons.arrowUp), () => onKey(EditorRowKey.up)),
          key(const ValueKey('editor-key-down'), icon(LucideIcons.arrowDown), () => onKey(EditorRowKey.down)),
          key(const ValueKey('editor-key-right'), icon(LucideIcons.arrowRight), () => onKey(EditorRowKey.right)),
          for (final s in symbols) key(ValueKey('editor-key-$s'), Text(s, style: faceStyle), () => onText(s), width: 36),
        ],
      ),
    );
  }
}

/// One row of the More sheet: an icon, what it is, what it is now, and a
/// tap.
class EditorSheetRow extends StatelessWidget {
  const EditorSheetRow({
    super.key,
    required this.icon,
    required this.title,
    this.value,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? value;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.v3Error : AppColors.v3TextPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: danger ? AppColors.v3Error : AppColors.v3TextSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14.5, color: color)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
                  ],
                ],
              ),
            ),
            if (value != null)
              Text(value!, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: AppColors.v3TextSecondary)),
            ?trailing,
            if (onTap != null && trailing == null) ...[
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronRight, size: 15, color: AppColors.v3TextTertiary),
            ],
          ],
        ),
      ),
    );
  }
}
