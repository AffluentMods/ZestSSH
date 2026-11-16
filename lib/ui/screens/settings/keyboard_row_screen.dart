import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// Keyboard and mouse on a phone or a tablet (4.0, the groups a computer's
/// Settings has): the row of keys above the keyboard (3.0 UI: the row as the
/// terminal draws it, whether it shows and where, its layout, and which keys
/// it holds in which order), then a hardware keyboard's and a mouse's
/// settings (they were the Terminal page's). Settings' root opens it, and so
/// does the terminal's own sheet (a long press on the terminal). Before, its
/// four settings sat in a long page, and its keys in a sheet.
class KeyboardRowScreen extends ConsumerWidget {
  const KeyboardRowScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);
    final position = ref.watch(extraKeyboardPositionProvider);
    // Off where its switch is off, or where its position is Disabled (as the
    // terminal reads them).
    final on =
        ref.watch(showExtraKeyboardRowProvider) && position != 'disabled';
    final scrollable = ref.watch(softKeyboardScrollableModeProvider);
    final style = ref.watch(softKeyboardStyleProvider);
    final size = ref.watch(softKeyboardKeySizeProvider);
    final hardware = ref.watch(keysRowHardwareProvider) ??
        HardwareKeysRow.defaultFor(tablet: MediaQuery.sizeOf(context).shortestSide >= 600);

    // One choice of a group: its radio says which, the words keep their
    // colours. One of a few is picked, so a dot radio, the one the dialogs
    // have, in the RadioGroup around the choices; a check is for where
    // several can be picked (these were
    // a check in a circle).
    Widget choice<T>(String key, String name, String? about, T value, bool selected, VoidCallback onTap) => ListTile(
          key: ValueKey(key),
          title: Text(name, style: TextStyle(color: ZestColors.textPrimary)),
          subtitle: about == null ? null : Text(about, style: TextStyle(color: AppColors.textSecondary)),
          trailing: Radio<T>(key: ValueKey('$key-radio'), value: value),
          selected: selected,
          onTap: onTap,
        );

    return ResponsiveScaffold(
      title: l10n.settingsPageKeyboardMouse,
      maxWidth: 680,
      body: ListView(
        key: const ValueKey('keys-row-page'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          PhoneListGroup(l10n.zestHostSectionPreview),
          _Preview(on: on),
          const SizedBox(height: 12),
          _Card(
            children: [
              SwitchListTile(
                key: const ValueKey('keys-row-on'),
                title: FoldedHelpTitle(
                  setting: l10n.settingsExtraKeyboardRow,
                  help: l10n.settingsExtraKeyboardRowDesc,
                  title: _titleWithHelp(
                  context,
                  l10n.settingsExtraKeyboardRow,
                  l10n.settingsExtraKeyboardRow,
                  l10n.settingsMobExtraKeyboardRowHelpBody,
                ),
                ),
                secondary: const PhoneIconTile(LucideIcons.keyboard),
                value: on,
                onChanged: (v) {
                  updater.setShowExtraKeyboardRow(v);
                  // Turned on where its position was Disabled: above the keyboard.
                  if (v && position == 'disabled') {
                    updater.setExtraKeyboardPosition('aboveKeyboard');
                  }
                },
              ),
            ],
          ),
          if (on) ...[
            // With a hardware keyboard: the row hides itself while one is
            // typed on (Automatic), stays (Always), or keeps only the keys
            // it lacks (3.2.1, a tablet's default). Its switch off above is
            // Never.
            PhoneListGroup(l10n.hwKeysRowWhen),
            RadioGroup<HardwareKeysRow>(
              groupValue: hardware,
              onChanged: (mode) {
                if (mode != null) updater.setKeysRowHardware(mode);
              },
              child: _Card(
                children: [
                  for (final (mode, id, name, about) in [
                    (HardwareKeysRow.hide, 'auto', l10n.hwKeysRowAuto, l10n.hwKeysRowAutoDesc),
                    (HardwareKeysRow.always, 'always', l10n.hwKeysRowAlways, l10n.hwKeysRowAlwaysDesc),
                    (HardwareKeysRow.missingOnly, 'missing', l10n.hwKeysRowMissing, l10n.hwKeysRowMissingDesc),
                  ])
                    choice('keys-row-hardware-$id', name, about, mode, hardware == mode,
                        () => updater.setKeysRowHardware(mode)),
                ],
              ),
            ),
            PhoneListGroup(l10n.settingsKeyboardRowPosition),
            RadioGroup<String>(
              groupValue: position,
              onChanged: (value) {
                if (value != null) updater.setExtraKeyboardPosition(value);
              },
              child: _Card(
                children: [
                  for (final (value, name, about) in [
                    (
                      'aboveKeyboard',
                      l10n.settingsAboveKeyboard,
                      l10n.settingsAboveKeyboardDesc,
                    ),
                    (
                      'aboveTerminal',
                      l10n.settingsAboveTerminal,
                      l10n.settingsAboveTerminalDesc,
                    ),
                  ])
                    choice('keys-row-$value', name, about, value, position == value,
                        () => updater.setExtraKeyboardPosition(value)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              children: [
                SwitchListTile(
                  key: const ValueKey('keys-row-scrollable'),
                  title: FoldedHelpTitle(
                    setting: l10n.settingsMobScrollableKeyRow,
                    help: l10n.settingsMobScrollableKeyRowDesc,
                    title: _titleWithHelp(
                    context,
                    l10n.settingsMobScrollableKeyRow,
                    l10n.settingsMobScrollableKeyRowHelpTitle,
                    l10n.settingsMobScrollableKeyRowHelpBody,
                  ),
                  ),
                  secondary: const PhoneIconTile(LucideIcons.moveHorizontal),
                  value: scrollable,
                  onChanged: (v) => updater.setSoftKeyboardScrollableMode(v),
                ),
              ],
            ),
            // How big the keys are and how they look, in either layout
            // (3.2.1: the size was the two rows' Compact style).
            PhoneListGroup(l10n.keysRowSize),
            RadioGroup<SoftKeySize>(
              groupValue: size,
              onChanged: (value) {
                if (value != null) updater.setSoftKeyboardKeySize(value);
              },
              child: _Card(
                children: [
                  for (final (value, name) in [
                    (SoftKeySize.small, l10n.keysRowSizeSmall),
                    (SoftKeySize.medium, l10n.keysRowSizeMedium),
                    (SoftKeySize.large, l10n.keysRowSizeLarge),
                  ])
                    choice('keys-row-size-${value.name}', name, null, value, size == value,
                        () => updater.setSoftKeyboardKeySize(value)),
                ],
              ),
            ),
            PhoneListGroup(l10n.keysRowStyle),
            RadioGroup<SoftKeyRowStyle>(
              groupValue: style,
              onChanged: (value) {
                if (value != null) updater.setSoftKeyboardStyle(value);
              },
              child: _Card(
                children: [
                  for (final (value, name, about) in [
                    (SoftKeyRowStyle.grouped, l10n.keysRowStyleGrouped, l10n.keysRowStyleGroupedDesc),
                    (SoftKeyRowStyle.flat, l10n.keysRowStyleFlat, l10n.keysRowStyleFlatDesc),
                  ])
                    choice('keys-row-style-${value.name}', name, about, value, style == value,
                        () => updater.setSoftKeyboardStyle(value)),
                ],
              ),
            ),
            // Which keys, in which order, in either layout (3.2.1; before,
            // only the scrollable row's).
            PhoneListGroup(l10n.settingsMobCustomizeKeys),
            if (!scrollable)
              Padding(
                key: const ValueKey('keys-row-fn-page-note'),
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  l10n.keysRowFnPageNote,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            const _KeysEditor(),
          ],
          ..._keyboardAndMouse(context, ref),
        ],
      ),
    );
  }

  /// A hardware keyboard's settings (on Android and on an iPad or an
  /// iPhone, each its own) and a mouse's, as a computer's Keyboard and mouse
  /// page has them.
  List<Widget> _keyboardAndMouse(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);
    final platform = Theme.of(context).platform;
    final keyboard = <Widget>[
      if (platform == TargetPlatform.android)
        SwitchListTile(
          title: FoldedHelpTitle(setting: l10n.settingsVolumeKeyShortcuts, help: l10n.settingsVolumeKeyShortcutsDesc),
          secondary: const PhoneIconTile(LucideIcons.volume2),
          value: ref.watch(volumeKeysEnabledProvider),
          onChanged: (v) => updater.setVolumeKeysEnabled(v),
        ),
      // Whether the keyboard is asked not to learn from the terminal. Some
      // keyboards answer that with a mode of their own that is hard to type
      // on.
      if (platform == TargetPlatform.android)
        SwitchListTile(
          key: const ValueKey('settings-keyboard-incognito'),
          title: FoldedHelpTitle(
            setting: l10n.settingsKeyboardIncognito,
            help: l10n.settingsKeyboardIncognitoDesc,
            title: _titleWithHelp(
              context, l10n.settingsKeyboardIncognito, l10n.settingsKeyboardIncognito, l10n.settingsKeyboardIncognitoHelp),
          ),
          secondary: const PhoneIconTile(LucideIcons.eyeOff),
          value: ref.watch(keyboardIncognitoProvider),
          onChanged: (v) => updater.setKeyboardIncognito(v),
        ),
      // The keyboard without suggestions, as for a password typed in the
      // open: on many keyboards a smaller row above the keys, so more of the
      // terminal fits.
      if (platform == TargetPlatform.android)
        SwitchListTile(
          key: const ValueKey('settings-compact-keyboard'),
          title: FoldedHelpTitle(
            setting: l10n.settingsCompactKeyboard,
            help: l10n.settingsCompactKeyboardDesc,
            title: _titleWithHelp(
              context, l10n.settingsCompactKeyboard, l10n.settingsCompactKeyboard, l10n.settingsCompactKeyboardHelp),
          ),
          secondary: const PhoneIconTile(LucideIcons.keyboard),
          value: ref.watch(compactKeyboardProvider),
          onChanged: (v) => updater.setCompactKeyboard(v),
        ),
      // Option as Meta for a keyboard on an iPad or an iPhone: on until
      // turned off (it sent an uppercase letter
      // after Esc, and there was no way to turn it off for the layout's own
      // characters).
      if (platform == TargetPlatform.iOS)
        SwitchListTile(
          key: const ValueKey('settings-option-meta'),
          title: FoldedHelpTitle(setting: l10n.hwKeysOptionMeta, help: l10n.hwKeysOptionMetaDesc),
          secondary: const PhoneIconTile(LucideIcons.option),
          value: ref.watch(optionAsMetaProvider),
          onChanged: (v) => updater.setOptionAsMeta(v),
        ),
    ];
    return [
      if (keyboard.isNotEmpty) ...[
        PhoneListGroup(l10n.settingsDesktopSectionKeyboard),
        _Card(children: keyboard),
      ],
      // A mouse on a tablet or a phone: what its right and middle buttons do
      // in the terminal, as a computer's Settings has them (the same two
      // settings; a phone's had no switch for them).
      PhoneListGroup(l10n.settingsInlineMouseSection),
      _Card(
        children: [
          SwitchListTile(
            key: const ValueKey('settings-right-click-paste'),
            title: FoldedHelpTitle(setting: l10n.settingsInlineRightClickPaste, help: l10n.hwKeysRightClickDesc),
            secondary: const PhoneIconTile(LucideIcons.mouse),
            value: ref.watch(desktopRightClickPasteProvider),
            onChanged: (v) => ref.read(desktopSettingsUpdaterProvider).setRightClickPaste(v),
          ),
          SwitchListTile(
            key: const ValueKey('settings-middle-click-paste'),
            title: FoldedHelpTitle(setting: l10n.settingsInlineMiddleClickPaste, help: l10n.hwKeysMiddleClickDesc),
            secondary: const PhoneIconTile(LucideIcons.mousePointerClick),
            value: ref.watch(desktopMiddleClickPasteProvider),
            onChanged: (v) => ref.read(desktopSettingsUpdaterProvider).setMiddleClickPaste(v),
          ),
        ],
      ),
    ];
  }

  /// A setting's name with its (?) after its last word, as the Terminal page
  /// has them.
  static Widget _titleWithHelp(
    BuildContext context,
    String title,
    String helpTitle,
    String helpBody,
  ) {
    final l10n = AppLocalizations.of(context)!;
    return Text.rich(
      TextSpan(
        text: '$title ',
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: IconButton(
              icon: Icon(
                LucideIcons.helpCircle,
                size: 18,
                color: AppColors.textSecondary.withValues(alpha: 0.6),
              ),
              tooltip: l10n.settingsMobLearnMore,
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(32, 32),
                padding: EdgeInsets.zero,
              ),
              // A help note in the shell: one button, which says what it does.
              onPressed: () => ZestConfirmDialog.show(
                context,
                tone: ZestDialogTone.info,
                icon: LucideIcons.helpCircle,
                title: helpTitle,
                body: helpBody,
                showCancel: false,
                confirmLabel: l10n.settingsMobGotIt,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings of one kind together, on the surface with a subtle edge.
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      // The one settings row of the phone (settings_section.dart).
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          data: Theme.of(context).copyWith(listTileTheme: SettingsSection.rowTheme(context)),
          child: ListTileTheme(
            data: SettingsSection.rowTheme(context),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

/// The row as the terminal draws it, under a line of a made-up session; its
/// keys type nowhere.
class _Preview extends StatelessWidget {
  const _Preview({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('keys-row-preview'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'deploy@web-01',
                    style: TextStyle(color: AppColors.accentInk),
                  ),
                  TextSpan(
                    text: ':~\$ ',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  TextSpan(
                    text: 'tail -f /var/log/app.log',
                    style: TextStyle(color: ZestColors.textPrimary),
                  ),
                ],
              ),
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
          if (on)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 0, 12),
              child: ShaderMask(
                key: const ValueKey('keys-row-preview-fade'),
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [Colors.white, Colors.white, Colors.transparent],
                  stops: [0, 0.88, 1],
                ).createShader(bounds),
                child: TerminalSoftKeyboard(onKey: (_) {}),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Text(
                l10n.settingsValOff,
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// Which keys the row holds, in which order, in its two rows: drag
/// a key by its handle, move it to the other row, or switch it off. Ctrl, Alt
/// and the microphone stay.
class _KeysEditor extends ConsumerWidget {
  const _KeysEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final disabled = ref.watch(softKeyboardDisabledKeysProvider);
    final row1 = ref.watch(softKeyboardRow1OrderProvider);
    final row2 = ref.watch(softKeyboardRow2OrderProvider);
    final updater = ref.read(settingsUpdaterProvider);

    void reorder(List<String> row, int oldIndex, int newIndex, bool isRow1) {
      final list = [...row];
      list.insert(newIndex, list.removeAt(oldIndex));
      haptic(ref, Haptic.selection);
      updater.setSoftKeyboardRowOrders(
        isRow1 ? list : row1,
        isRow1 ? row2 : list,
      );
    }

    void moveToOtherRow(String id, bool fromRow1) {
      haptic(ref, Haptic.selection);
      final r1 = [...row1], r2 = [...row2];
      if (fromRow1) {
        r1.remove(id);
        r2.add(id);
      } else {
        r2.remove(id);
        r1.add(id);
      }
      updater.setSoftKeyboardRowOrders(r1, r2);
    }

    void toggle(String id) {
      haptic(ref, Haptic.selection);
      final next = Set<String>.from(disabled);
      next.contains(id) ? next.remove(id) : next.add(id);
      updater.setSoftKeyboardDisabledKeys(next);
    }

    Widget tile(String id, int index, bool isRow1) {
      final key = findSoftKey(id);
      if (key == null) return SizedBox(key: ValueKey('missing_$id'));
      final pinned = pinnedSoftKeyIds.contains(id);
      final legacyArrowHide =
          disabled.contains('arrows') &&
          const ['up', 'down', 'left', 'right'].contains(id);
      return _KeyTile(
        key: ValueKey('${isRow1 ? 'r1' : 'r2'}_$id'),
        id: id,
        index: index,
        label: key.label,
        pinned: pinned,
        shown: !(disabled.contains(id) || legacyArrowHide),
        onToggle: pinned ? null : () => toggle(id),
        onMove: () => moveToOtherRow(id, isRow1),
      );
    }

    // One card a row, its keys one under the other.
    Widget row(List<String> ids, bool isRow1) => _Card(
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (o, n) => reorder(ids, o, n, isRow1),
          proxyDecorator: (child, _, _) => Material(
            color: AppColors.surfaceLight,
            elevation: 4,
            child: child,
          ),
          children: [
            for (var i = 0; i < ids.length; i++) tile(ids[i], i, isRow1),
          ],
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          // The arrows the words name (⇅) drawn as the row's own icon: the
          // character is in no font of the app, and showed as a box.
          child: Text(
            l10n.phoneUiKeysEditorHelp,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        PhoneListGroup(l10n.settingsMobRow1Top),
        row(row1, true),
        PhoneListGroup(l10n.settingsMobRow2Bottom),
        row(row2, false),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            key: const ValueKey('keys-row-reset'),
            icon: const Icon(LucideIcons.rotateCcw, size: 16),
            label: Text(l10n.settingsMobResetToDefaults),
            onPressed: () {
              updater.resetSoftKeyboardRowOrders();
              updater.setSoftKeyboardDisabledKeys(const <String>{});
            },
          ),
        ),
      ],
    );
  }
}

/// One key of the editor: the key as the row draws it, whether it shows (an
/// eye, a lock for Ctrl, Alt and the microphone), and the one handle to drag
/// it by; a long press offers to move it to the other row. (It had a switch
/// in the accent and two ways to reorder on every row: about twenty orange
/// switches down the page.)
class _KeyTile extends StatelessWidget {
  const _KeyTile({
    super.key,
    required this.id,
    required this.index,
    required this.label,
    required this.pinned,
    required this.shown,
    required this.onMove,
    this.onToggle,
  });

  final String id;
  final int index;
  final String label;
  final bool pinned;
  final bool shown;
  final VoidCallback onMove;
  final VoidCallback? onToggle;

  Future<void> _menu(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final move = await showZestSheet<bool>(
      context: context,
      child: Builder(
        builder: (sheet) => ZestSheetFrame(
          child: SettingsSheetBody(
            title: label,
            children: [
              SettingsChoiceCard(children: [
                SettingsChoiceRow(
                  key: const ValueKey('keys-row-move'),
                  leading: Icon(LucideIcons.arrowUpDown, size: 18, color: ZestColors.textSecondary),
                  label: l10n.settingsMobMoveToOtherRow,
                  onTap: () => Navigator.of(sheet).pop(true),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
    if (move == true) onMove();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onLongPress: () => _menu(context),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
          ),
          child: Row(
            children: [
              Opacity(
                opacity: shown ? 1 : 0.4,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.v3BorderSubtle),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ZestColors.textPrimary,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (pinned)
                SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(LucideIcons.lock, size: 18, color: ZestColors.textTertiary),
                )
              else
                IconButton(
                  key: ValueKey('keys-row-visible-$id'),
                  onPressed: onToggle,
                  icon: Icon(shown ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
                  color: shown ? AppColors.textSecondary : ZestColors.textTertiary,
                  tooltip: shown ? l10n.phoneUiKeyHide : l10n.phoneUiKeyShow,
                ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 12, 8, 12),
                  child: Icon(
                    LucideIcons.gripVertical,
                    size: 20,
                    color: ZestColors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
