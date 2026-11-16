import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

/// A choice of one from a few, as Settings asks it (3.0 UI review): on a
/// phone the app's bottom sheet (its title, a line of what it sets, then
/// every choice in one grouped card, 52 high rows, the app's dot radio on
/// each, the one picked filled); on a computer the app's dialog with the same
/// card. It was a centred Material dialog of radio buttons, over the app bar
/// on a phone, then a check on the one picked (a pick-one choice is a dot;
/// found on the Language sheet on a
/// Pixel 3a).
///
/// The answer comes back in a record, so that a choice whose value is null
/// is a choice too; null where nothing was picked.
Future<(T,)?> showSettingsChoice<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData icon = LucideIcons.listChecks,
  required List<(T, String)> choices,
  required T current,
  Key Function(T value)? keyOf,
}) {
  Widget list(BuildContext inner) => RadioGroup<T>(
        groupValue: current,
        onChanged: (value) => Navigator.of(inner).pop((value as T,)),
        child: SettingsChoiceCard(
          children: [
            for (final (value, words) in choices)
              SettingsRadioRow<T>(key: keyOf?.call(value), value: value, label: words),
          ],
        ),
      );
  if (zestUsesSheets(context)) {
    return showZestSheet<(T,)>(
      context: context,
      child: Builder(
        builder: (inner) => ZestSheetFrame(
          child: SettingsSheetBody(title: title, subtitle: subtitle, children: [list(inner)]),
        ),
      ),
    );
  }
  return showZestModal<(T,)>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (inner) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: icon,
        title: title,
        subtitle: subtitle,
        body: list(inner),
      ),
    ),
  );
}

/// What a settings sheet holds on a phone: its title (12 under the handle,
/// 18 w600), a line of what it sets (15, the secondary text), then its
/// [children], on the page's 16 gutter, scrolling where it is long.
class SettingsSheetBody extends StatelessWidget {
  const SettingsSheetBody({super.key, required this.title, this.subtitle, required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.3, color: ZestTokens.textPrimary)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, style: TextStyle(fontSize: 15, height: 1.4, color: ZestTokens.textSecondary)),
          ],
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}

/// Choices in one card: one step lighter than the sheet or page under it,
/// with a hairline, divided by inset hairlines.
class SettingsChoiceCard extends StatelessWidget {
  const SettingsChoiceCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, thickness: 1, indent: 14, color: ZestTokens.borderSubtle),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One choice: its words (and a line under them where given), the check
/// in the accent's ink on the one picked; 52 high. [leading] and
/// [trailing] stand where a row needs them (a device's icon, a remove).
class SettingsChoiceRow extends StatelessWidget {
  const SettingsChoiceRow({
    super.key,
    required this.label,
    this.subtitle,
    this.selected = false,
    this.onTap,
    this.leading,
    this.trailing,
    this.labelWidget,
  });

  final String label;

  /// Stands for [label] where the words are drawn another way (masked
  /// while recording, say).
  final Widget? labelWidget;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: EdgeInsets.fromLTRB(14, 8, trailing == null ? 14 : 4, 8),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      labelWidget ?? Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          color: ZestTokens.textPrimary,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: TextStyle(fontSize: 13, height: 1.35, color: ZestTokens.textSecondary)),
                      ],
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 12),
                  Icon(LucideIcons.check, size: 18, color: ZestTokens.brandInk),
                ],
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One choice of a pick-one list, in the [RadioGroup] around the list: the
/// dot radio the dialogs have at its leading edge (20 square, 10 before the
/// words, as a team's access dialog draws it), its words as a
/// [SettingsChoiceRow] has them, the whole row a tap that picks it; 52 high.
/// A pick-one choice is a dot; a check is for where several can be picked
/// at once.
class SettingsRadioRow<T> extends StatelessWidget {
  const SettingsRadioRow({super.key, required this.value, required this.label, this.subtitle});

  /// What picking it sets.
  final T value;
  final String label;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final group = RadioGroup.maybeOf<T>(context);
    final selected = group != null && group.groupValue == value;
    // The row is the one control: a tap anywhere on it, or Enter or Space on
    // it, picks the choice, and the up and down arrows move between choices
    // without picking. The dot only shows which is picked: it took the taps on
    // it, and one on the dot of the choice already picked did nothing, so the
    // sheet stayed open; and with the dot focused, an arrow key picked the
    // next choice, which closes a sheet that closes on a pick (found in a UI
    // review). RadioGroup's own arrow keys act only
    // while a dot has the focus, which it now never has.
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
      },
      child: MergeSemantics(
        child: InkWell(
          onTap: () => group?.onChanged(value),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: ExcludeFocus(
                      child: IgnorePointer(
                        child: Radio<T>(
                          value: value,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.3,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            color: ZestTokens.textPrimary,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!, style: TextStyle(fontSize: 13, height: 1.35, color: ZestTokens.textSecondary)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
