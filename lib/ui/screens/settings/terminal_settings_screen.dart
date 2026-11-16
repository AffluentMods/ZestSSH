import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/list_names.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/enums.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../router/routes.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../theme/terminal_themes.dart' as app_themes;
import '../../../utils/platform_utils.dart';
import '../../widgets/responsive_scaffold.dart';
import '../../widgets/zest_dialog.dart';
import 'widgets/font_picker.dart';
import 'widgets/setting_control_tile.dart';
import 'widgets/theme_picker.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// Drill-down screen for terminal settings. Reached from the Appearance screen
/// (Terminal row), matching the desktop change where Terminal is a sub-group of
/// Appearance. Holds the former "Terminal Appearance" and "Terminal Behaviour"
/// sections as two [_Section] groups.
///
/// The picker/dialog helpers here are copies of the ones the desktop settings
/// card in settings_screen.dart still uses; the keyboard-row + customize-keys
/// helpers were mobile-only and moved here wholesale.
class TerminalSettingsScreen extends ConsumerStatefulWidget {
  const TerminalSettingsScreen({super.key});

  @override
  ConsumerState<TerminalSettingsScreen> createState() =>
      _TerminalSettingsScreenState();
}

class _TerminalSettingsScreenState
    extends ConsumerState<TerminalSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final themeId = ref.watch(shownTerminalThemeIdProvider);
    final fontFamily = ref.watch(terminalFontFamilyProvider);
    final fontSize = ref.watch(terminalFontSizeProvider);
    final scrollback = ref.watch(scrollbackLinesProvider);
    final hapticFeedback = ref.watch(hapticFeedbackProvider);
    final keepAwake = ref.watch(keepScreenAwakeProvider);
    final cursorBlink = ref.watch(cursorBlinkProvider);
    final updater = ref.watch(settingsUpdaterProvider);

    return ResponsiveScaffold(
      // Terminal and SSH (4.0): the terminal's look and behaviour, session
      // logs and the keepalive; the keyboard's and the mouse's rows are
      // Keyboard and mouse's, dangerous commands Security and privacy's.
      title: l10n.settingsPageTerminalSsh,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // ── Terminal Appearance ──────────────────────────────────
          _Section(
            title: l10n.settingsTerminalAppearance,
            child: Column(
              children: [
                ListTile(
                  title: Text(l10n.settingsTerminalTheme),
                  subtitle: Text(app_themes.TerminalThemes.names[themeId] ??
                      l10n.settingsThemeUnknown),
                  leading: const PhoneIconTile(LucideIcons.palette),
                  onTap: () => _showThemePicker(context, ref),
                ),
                ListTile(
                  title: Text(l10n.settingsFont),
                  subtitle: Text(fontFamily.nameIn(l10n)),
                  leading: const PhoneIconTile(LucideIcons.type),
                  onTap: () => _showFontPicker(context, ref),
                ),
                SettingControlTile(
                  title: Text(l10n.settingsFontSize),
                  subtitle: Text(l10n.settingsFontSizePx(fontSize.toInt())),
                  leading: const PhoneIconTile(LucideIcons.type),
                  controlWidth: 200,
                  control: (context, beside) => SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      showValueIndicator: ShowValueIndicator.never,
                    ),
                    child: Slider(
                      value: clampTerminalFontSize(fontSize),
                      min: kTerminalFontSizeMin,
                      max: kTerminalFontSizeMax,
                      divisions: (kTerminalFontSizeMax - kTerminalFontSizeMin).round(),
                      onChanged: (v) => updater.setTerminalFontSize(v),
                    ),
                  ),
                ),
                ListTile(
                  title: Text(l10n.settingsScrollbackLines),
                  subtitle: Text(scrollback <= 0
                      ? l10n.settingsMobUnlimitedScrollback
                      : l10n.settingsScrollbackCount(scrollback)),
                  leading: const PhoneIconTile(LucideIcons.history),
                  trailing: _helpIcon(l10n.settingsScrollbackLines,
                      l10n.settingsMobScrollbackHelpBody),
                  onTap: () => _showScrollbackDialog(context, ref, scrollback),
                ),
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsCursorBlink, help: l10n.settingsCursorBlinkDesc),
                  secondary: const PhoneIconTile(LucideIcons.film),
                  value: cursorBlink,
                  onChanged: (v) => updater.setCursorBlink(v),
                ),
                SettingControlTile(
                  title: Text(l10n.settingsMobCursorShape),
                  subtitle: Text(ref.watch(cursorStyleProvider).nameIn(l10n)),
                  leading: const PhoneIconTile(LucideIcons.pencil),
                  controlWidth: 160,
                  control: (context, beside) => SizedBox(
                    width: 160,
                    child: SegmentedButton<TerminalCursorShape>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: [
                        for (final shape in const [
                          TerminalCursorShape.block,
                          TerminalCursorShape.underline,
                          TerminalCursorShape.verticalBar,
                        ])
                          ButtonSegment(
                            value: shape,
                            tooltip: shape.nameIn(l10n),
                            label: _CursorGlyph(shape, key: ValueKey('cursor-shape-${shape.name}')),
                          ),
                      ],
                      selected: {ref.watch(cursorStyleProvider)},
                      onSelectionChanged: (s) =>
                          updater.setTerminalCursorShape(s.first),
                    ),
                  ),
                ),
                // When the cursor is drawn (4.0): hidden while output
                // arrives, for full-screen programs, or never.
                ListTile(
                  key: const ValueKey('cursor-visibility'),
                  title: FoldedHelpTitle(setting: l10n.settingsCursorVisibility, help: l10n.settingsCursorVisibilityDesc),
                  subtitle: Text(ref.watch(cursorVisibilityProvider).nameIn(l10n)),
                  leading: const PhoneIconTile(LucideIcons.textCursor),
                  onTap: () async {
                    final picked = await showZestChoice<TerminalCursorVisibility>(
                      context,
                      title: l10n.settingsCursorVisibility,
                      icon: LucideIcons.textCursor,
                      selected: ref.read(cursorVisibilityProvider),
                      choices: [
                        for (final v in TerminalCursorVisibility.values)
                          ZestChoice(
                            key: ValueKey('cursor-visibility-${v.name}'),
                            value: v,
                            label: v.nameIn(l10n),
                            detail: v.noteIn(l10n),
                          ),
                      ],
                    );
                    if (picked != null) await updater.setCursorVisibility(picked);
                  },
                ),
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsMobProgrammingLigatures, help: l10n.settingsMobProgrammingLigaturesDesc),
                  secondary: const PhoneIconTile(LucideIcons.type),
                  value: ref.watch(terminalLigaturesProvider),
                  onChanged: (v) => updater.setTerminalLigatures(v),
                ),
                ListTile(
                  title: Text(l10n.settingsTerminalMargin),
                  subtitle: Text(
                    ref.watch(terminalMarginProvider) == 0
                        ? l10n.none
                        : l10n.settingsFontSizePx(
                            ref.watch(terminalMarginProvider).round()),
                  ),
                  leading: const PhoneIconTile(LucideIcons.squareDashedBottom),
                  onTap: () => _showTerminalMarginDialog(context, ref),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Terminal Behaviour ───────────────────────────────────
          _Section(
            title: l10n.settingsTerminalBehaviour,
            child: Column(
              children: [
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsHapticFeedback, help: l10n.settingsHapticFeedbackDesc),
                  secondary: const PhoneIconTile(LucideIcons.vibrate),
                  value: hapticFeedback,
                  onChanged: (v) => updater.setHapticFeedback(v),
                ),
                SwitchListTile(
                  key: const ValueKey('settings-terminal-bell'),
                  title: Text(l10n.settingsInlineTerminalBell),
                  secondary: const PhoneIconTile(LucideIcons.bellRing),
                  value: ref.watch(bellEnabledProvider),
                  onChanged: (v) => updater.setBellEnabled(v),
                ),
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsKeepAwake, help: l10n.settingsKeepAwakeDesc),
                  secondary: const PhoneIconTile(LucideIcons.sun),
                  value: keepAwake,
                  onChanged: (v) => updater.setKeepScreenAwake(v),
                ),
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsAutoExecuteSnippets, help: l10n.settingsAutoExecuteSnippetsDesc),
                  secondary: const PhoneIconTile(LucideIcons.play),
                  value: ref.watch(autoExecuteSnippetsProvider),
                  onChanged: (v) => updater.setAutoExecuteSnippets(v),
                ),
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsTmuxAutoDetect, help: l10n.settingsTmuxAutoDetectDesc),
                  secondary: const PhoneIconTile(LucideIcons.layoutGrid),
                  value: ref.watch(tmuxAutoDetectProvider),
                  onChanged: (v) => updater.setTmuxAutoDetect(v),
                ),
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsOsc52Clipboard, help: l10n.settingsOsc52ClipboardDesc),
                  secondary: const PhoneIconTile(LucideIcons.clipboardPaste),
                  value: ref.watch(osc52ClipboardProvider),
                  onChanged: (v) => updater.setOsc52Clipboard(v),
                ),
                ListTile(
                  title: Text(l10n.settingsDefaultSnippetCategory),
                  subtitle:
                      Text(ref.watch(defaultSnippetCategoryProvider) ?? l10n.none),
                  leading: const PhoneIconTile(LucideIcons.shapes),
                  onTap: () => _showDefaultSnippetCategoryDialog(context, ref),
                ),
                // The recordings saved on this phone, to read (nothing in
                // the app opened one).
                ListTile(
                  key: const ValueKey('settings-saved-transcripts'),
                  title: FoldedHelpTitle(setting: l10n.transcriptsTitle, help: l10n.transcriptsSettingsDesc),
                  leading: const PhoneIconTile(LucideIcons.scrollText),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () => context.push(Routes.transcripts),
                ),
                ListTile(
                  title: Text(l10n.settingsKeepaliveInterval),
                  subtitle: Text(_keepaliveLabel(
                      ref.watch(keepaliveIntervalProvider), l10n)),
                  leading: const PhoneIconTile(LucideIcons.heart),
                  trailing: _helpIcon(l10n.settingsKeepaliveInterval,
                      l10n.settingsMobKeepaliveHelpBody),
                  onTap: () => _showKeepaliveDialog(context, ref),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // ── Session log ──────────────────────────────────────────
          // Logs land in the app's own documents folder on a phone, so the
          // "Session logs" row is the way to get them out (share) or clean up.
          _Section(
            title: l10n.settingsSessionLogSection,
            child: Column(
              children: [
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsSessionLogEnabled, help: l10n.settingsSessionLogEnabledDesc),
                  secondary: const PhoneIconTile(LucideIcons.scrollText),
                  value: ref.watch(sessionLogEnabledProvider),
                  onChanged: (v) => updater.setSessionLogEnabled(v),
                ),
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsSessionLogTimestamps, help: l10n.settingsSessionLogTimestampsDesc),
                  secondary: const PhoneIconTile(LucideIcons.clock),
                  value: ref.watch(sessionLogTimestampsProvider),
                  onChanged: (v) => updater.setSessionLogTimestamps(v),
                ),
                ListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsSessionLogBrowse, help: l10n.settingsSessionLogBrowseDesc),
                  leading: const PhoneIconTile(LucideIcons.folder),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () => context.push(Routes.sessionLogs),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Help tooltip (copied from settings_screen.dart) ─────────────

  void _showHelp(BuildContext context, String title, String body) {
    final l10n = AppLocalizations.of(context)!;
    // A help note in the shell: one button, which says what it does.
    ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      icon: LucideIcons.helpCircle,
      title: title,
      body: body,
      showCancel: false,
      confirmLabel: l10n.settingsMobGotIt,
    );
  }

  Widget _helpIcon(String title, String body) {
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      icon: Icon(LucideIcons.helpCircle,
          size: 18, color: AppColors.textSecondary.withValues(alpha: 0.6)),
      tooltip: l10n.settingsMobLearnMore,
      onPressed: () => _showHelp(context, title, body),
    );
  }

  // ── Theme / font pickers (copied from settings_screen.dart) ─────

  // The theme and font pickers: the app's dialog, a phone's sheet (3.4).
  void _showThemePicker(BuildContext context, WidgetRef ref) => showThemePicker(context, ref);

  void _showFontPicker(BuildContext context, WidgetRef ref) => showFontPicker(context);

  Future<void> _showScrollbackDialog(
      BuildContext context, WidgetRef ref, int current) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showZestInputDialog(
      context: context,
      title: l10n.settingsScrollbackLines,
      icon: LucideIcons.scrollText,
      fieldLabel: l10n.settingsScrollbackLines,
      hintText: l10n.settingsMobScrollbackDialogHint(
          l10n.settingsScrollbackHint, l10n.settingsScrollbackSuffix),
      initialValue: current.toString(),
      confirmLabel: l10n.save,
      cancelLabel: l10n.cancel,
      validator: (v) {
        final value = int.tryParse(v.trim());
        // 0 = unlimited scrollback; only reject blank/negative/non-numeric.
        if (value == null || value < 0) return l10n.settingsScrollbackError;
        return null;
      },
    );
    if (result == null) return;
    final value = int.tryParse(result.trim());
    if (value == null || value < 0) return;
    ref.read(settingsUpdaterProvider).setScrollbackLines(value);
  }

  // ── Terminal margin dialog (copied from settings_screen.dart) ───

  void _showTerminalMarginDialog(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(terminalMarginProvider);
    var value = current;

    void apply(BuildContext ctx) {
      ref.read(settingsUpdaterProvider).setTerminalMargin(value);
      Navigator.pop(ctx);
    }

    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: StatefulBuilder(
        builder: (ctx, setDialogState) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.squareDashedBottom,
          title: l10n.settingsTerminalMargin,
          subtitle: l10n.settingsTerminalMarginDesc,
          body: Row(
            children: [
              Text(
                l10n.settingsFontSizePx(value.round()),
                // A size, not a value to copy: the app's own type on a
                // phone and a tablet (3.0 quick wins).
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  fontFamily: isTouchLayout ? null : 'JetBrainsMono',
                ),
              ),
              Expanded(
                child: Slider(
                  value: value,
                  min: 0,
                  max: 64,
                  divisions: 16,
                  label: l10n.settingsFontSizePx(value.round()),
                  onChanged: (v) {
                    setDialogState(() => value = v);
                  },
                ),
              ),
            ],
          ),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(ctx)),
          primaryAction: (label: l10n.settingsApply, icon: null, onPressed: () => apply(ctx)),
        ),
      ),
    );
  }

  // ── Keepalive helper (copied from settings_screen.dart) ─────────

  static String _keepaliveLabel(int seconds, AppLocalizations l10n) {
    if (seconds <= 0) return l10n.settingsDisabled;
    return l10n.settingsTimeoutSeconds(seconds);
  }

  Future<void> _showKeepaliveDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(keepaliveIntervalProvider);
    final v = await showZestChoice<int>(
      context,
      title: l10n.settingsKeepaliveInterval,
      icon: LucideIcons.heartPulse,
      selected: current,
      choices: [
        for (final seconds in const [0, 15, 30, 60, 120])
          ZestChoice(value: seconds, label: seconds == 0 ? l10n.settingsDisabled : l10n.settingsTimeoutSeconds(seconds)),
      ],
    );
    if (v == null || v == current) return;
    ref.read(settingsUpdaterProvider).setKeepaliveInterval(v);
  }

  // ── Snippet settings helper (copied from settings_screen.dart) ──

  Future<void> _showDefaultSnippetCategoryDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(defaultSnippetCategoryProvider);
    final categories = await ref.read(snippetsDaoProvider).getCategories();
    if (!context.mounted) return;
    // In a record, so None (null) is a choice of its own and not "closed".
    final v = await showZestChoice<(String?,)>(
      context,
      title: l10n.settingsDefaultSnippetCategory,
      icon: LucideIcons.folder,
      selected: (current,),
      choices: [
        ZestChoice(value: (null,), label: l10n.none),
        for (final cat in categories) ZestChoice(value: (cat,), label: cat),
      ],
    );
    if (v == null || v.$1 == current) return;
    ref.read(settingsUpdaterProvider).setDefaultSnippetCategory(v.$1);
  }

}

/// Section header matching the app's settings sub-screens (orange bar + label).
class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  // The 3.0 look every phone settings page shares (widgets/settings_section.dart).
  @override
  Widget build(BuildContext context) => SettingsSection(title: title, child: child);
}

// ════════════════════════════════════════════════════════════════════
// Customize keys sheet - manages [softKeyboardDisabledKeysProvider]
// (moved from settings_screen.dart - mobile only)
// ════════════════════════════════════════════════════════════════════

/// Bottom-sheet picker that lets the user hide individual keys from the
/// scrollable soft-keyboard row. Shows the entire soft-key catalog as
/// toggleable chips; arrow keys are collapsed into a single "Arrow keys"
/// toggle so the inverted-T cluster on the keyboard stays visually intact.

/// A cursor shape drawn as the terminal draws it, in the segment's own
/// colour: a block, a line under, a bar. Drawn, as no interface font holds
/// every one of their characters.
class _CursorGlyph extends StatelessWidget {
  const _CursorGlyph(this.shape, {super.key});

  final TerminalCursorShape shape;

  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color ?? IconTheme.of(context).color;
    final (double w, double h) = switch (shape) {
      TerminalCursorShape.block => (9, 16),
      TerminalCursorShape.underline => (10, 2.5),
      TerminalCursorShape.verticalBar => (2.5, 16),
    };
    return SizedBox(
      width: 12,
      height: 18,
      child: Align(
        alignment: shape == TerminalCursorShape.underline ? Alignment.bottomCenter : Alignment.center,
        child: Container(width: w, height: h, color: color),
      ),
    );
  }
}
