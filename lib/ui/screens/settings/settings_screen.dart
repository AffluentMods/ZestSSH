import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart' show puttyImportHere;
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';
import 'package:zestssh/providers/backup_destination_providers.dart';
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/services/backup/google_drive_destination.dart';
import 'package:zestssh/services/backup/webdav_destination.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/settings/clear_all_data_dialog.dart';
import 'package:zestssh/services/auto_sync_service.dart' show AutoSyncService;
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show AccountPlanName;
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes;
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart' show InitialImportedKey;
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/language_picker.dart';
import 'package:zestssh/ui/screens/settings/phone_settings_search.dart';
import 'package:zestssh/ui/screens/settings/reachability_checks_setting.dart';
import 'package:zestssh/ui/screens/settings/widgets/font_picker.dart';
import 'package:zestssh/ui/screens/settings/widgets/theme_picker.dart';
import 'package:zestssh/ui/screens/settings/ssh_config_export.dart';
import 'package:zestssh/ui/screens/sync/sync_now.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/cloud_import/ui/cloud_accounts_view.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardSummariesProvider;
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/ink_layer.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Confirm + reset every setting to its default (data is untouched). Reuses
/// [SettingsService.resetAllToDefaults] - the same reset the desktop settings
/// surface offers. A phone's is on the Backups and data page (4.0; it was at
/// the end of the Settings root).
Future<void> confirmResetAllSettings(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.settingsInlineResetAllSettingsTitle,
    body: l10n.settingsInlineResetAllSettingsBody,
    confirmLabel: l10n.settingsInlineReset,
  );
  if (confirmed == true) {
    await ref.read(settingsServiceProvider).resetAllToDefaults();
    if (context.mounted) {
      showTopSnackBar(context, l10n.settingsInlineSettingsResetRestart);
    }
  }
}

/// A phone's Plan row: the plans and what this account owns (the Upgrade
/// page), or, for a team's member, who is never shown the plans' names,
/// what the seat gives.
Future<void> openPhonePlan(BuildContext context, WidgetRef ref) async {
  final inTeam = (ref.read(orchardSummariesProvider).valueOrNull ?? const []).isNotEmpty;
  if (!inTeam) {
    await context.push(Routes.upgrade);
    return;
  }
  final l10n = AppLocalizations.of(context)!;
  await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.info,
    icon: LucideIcons.crown,
    title: l10n.settingsPagePlan,
    body: l10n.settingsPlanTeamSeat,
    showCancel: false,
    confirmLabel: l10n.settingsMobGotIt,
  );
}

/// App settings screen (desktop uses this with ResponsiveScaffold wrapper).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // A phone's and a tablet's: in the one centred column a phone page takes
    // on a tablet, as Hosts and Networks have (ResponsiveScaffold centres a
    // computer's only, and a tablet's ran the full width: found after a
    // design audit).
    if (isTouchLayout) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: const PhonePageColumn(child: SettingsBody()),
      );
    }
    return ResponsiveScaffold(
      title: l10n.settingsTitle,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: const SettingsBody(),
    );
  }
}

/// Shared settings body used by both [SettingsScreen] (desktop) and
/// the mobile home-screen settings tab.
class SettingsBody extends ConsumerStatefulWidget {
  const SettingsBody({super.key, this.bottomPadding = 0});

  /// Extra bottom padding (for mobile bottom-nav safe area).
  final double bottomPadding;

  @override
  ConsumerState<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends ConsumerState<SettingsBody> {
  // The phone's search (3.0 UI): its field, and what is typed in it.
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Opens a page of the phone's Settings, as its row there does.
  void _openPhonePage(BuildContext context, PhoneSettingsPage page) {
    switch (page) {
      case PhoneSettingsPage.account:
        context.push(Routes.profile);
      case PhoneSettingsPage.plan:
        openPhonePlan(context, ref);
      case PhoneSettingsPage.security:
        SecuritySettingsScreen.show(context);
      case PhoneSettingsPage.backups:
        showPhoneAutoBackupConfig(context, ref);
      case PhoneSettingsPage.language:
        showLanguagePickerDialog(context, ref);
      case PhoneSettingsPage.appearance:
        context.push(Routes.appearance);
      case PhoneSettingsPage.terminal:
        context.push(Routes.terminalSettings);
      case PhoneSettingsPage.keyboardRow:
        context.push(Routes.keyboardRow);
      case PhoneSettingsPage.notifications:
        context.push(Routes.notificationSettings);
      case PhoneSettingsPage.sftp:
        context.push(Routes.sftpSettings);
      case PhoneSettingsPage.screens:
        context.push(Routes.screenSettings);
      case PhoneSettingsPage.automation:
        context.push(Routes.automationSettings);
      case PhoneSettingsPage.data:
        context.push(Routes.dataSettings);
      case PhoneSettingsPage.about:
        context.push(Routes.about);
      case PhoneSettingsPage.reset:
        confirmResetAllSettings(context, ref);
    }
  }

  /// What the phone's search finds: each setting, with the page it is on
  /// under it (or, for a page itself, what it holds); a tap opens the page.
  List<Widget> _searchResults(BuildContext context, AppLocalizations l10n) {
    final found = searchPhoneSettings(_query, l10n);
    if (found.isEmpty) {
      return [
        Padding(
          key: const ValueKey('settings-search-none'),
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
          child: Text(
            l10n.settingsSearchNoResults,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ),
      ];
    }
    return [
      PhoneListGroup(l10n.phoneUiSettingsSearchResults(found.length)),
      PhoneListCard(
        key: const ValueKey('settings-search-results'),
        children: [
          for (final s in found)
            PhoneListRow(
              icon: s.page.icon,
              title: Text(
                s.name(l10n),
                style: s.page == PhoneSettingsPage.reset
                    ? PhoneListRow.titleStyle.copyWith(color: AppColors.error)
                    : PhoneListRow.titleStyle,
              ),
              subtitle: s.name(l10n) == s.page.nameIn(l10n) ? s.about?.call(l10n) : s.page.nameIn(l10n),
              subtitleMaxLines: null,
              destructive: s.page == PhoneSettingsPage.reset,
              onTap: () => _openPhonePage(context, s.page),
            ),
        ],
      ),
    ];
  }

  /// Show a help tooltip dialog for a setting.
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

  /// A small (?) icon button that shows a help dialog.
  Widget _helpIcon(String title, String body) {
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      icon: Icon(LucideIcons.helpCircle, size: 18, color: AppColors.textSecondary.withValues(alpha: 0.6)),
      tooltip: l10n.settingsMobLearnMore,
      onPressed: () => _showHelp(context, title, body),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Desktop gets a multi-column card layout
    if (isDesktopPlatform && widget.bottomPadding == 0) {
      return _buildDesktopSettings(context, ref);
    }

    // ── Mobile layout: drill-down category list ─────────────────────
    // The root is a few groups of rows (the accent's icon tile, the name, a
    // live value or what the page holds, a chevron), drawn as the More tab
    // draws its own (lib/ui/widgets/phone_list.dart); each opens its page.
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);
    final isSignedIn = ref.watch(isSignedInProvider);
    final appLockOn = ref.watch(securityLockEnabledProvider);
    final appThemeName = ref.watch(appThemeProvider).name;
    // A team's member is not shown the plans' names:
    // the seat, said in words.
    final inTeam = (ref.watch(orchardSummariesProvider).valueOrNull ?? const []).isNotEmpty;
    // The plan as its chip says it (the Bundle for both); the Plan page
    // this row opens explains it.
    final accountPlan = ref.watch(accountPlanProvider);
    final plan = inTeam || accountPlan == AccountPlan.teamSeat ? l10n.settingsPlanTeamSeat : accountPlan.nameIn(l10n);
    Widget name(String text) => Text(text, style: PhoneListRow.titleStyle);

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, widget.bottomPadding + 24),
      children: [
        PhoneSearchField(
          key: const ValueKey('settings-search'),
          controller: _search,
          hintText: l10n.settingsSearchHint,
          onChanged: (v) => setState(() => _query = v.trim()),
        ),
        const SizedBox(height: 12),
        if (_query.isNotEmpty)
          ..._searchResults(context, l10n)
        else ...[
          // Fully entitled (Squeezed + Cloud Sync): no card - the account
          // already has everything, and manage/restore lives under Account.
          if (zestHasPlans && (!isPro || !isCloudSync)) ...[
            PhoneUpgradeCard(
              key: const ValueKey('settings-upgrade'),
              icon: !isPro ? LucideIcons.rocket : LucideIcons.cloud,
              title: !isPro && !isCloudSync
                  ? l10n.settingsUpgradeSqueezedOrJuiced
                  : isPro
                      ? l10n.settingsAddCloudSync
                      : l10n.settingsUpgradeToSqueezed,
              subtitle: !isPro && !isCloudSync
                  ? l10n.settingsUpgradeSqueezedOrJuicedDesc
                  : isPro
                      ? l10n.settingsAddCloudSyncDesc
                      : l10n.settingsUnlockConnectionsThemes,
              onTap: () => context.push(Routes.upgrade),
            ),
            const SizedBox(height: 2),
          ],

          // The groups a computer's Settings has (4.0):
          // Account, App, Connections, Security and data,
          // About; each row opens its page.
          PhoneListGroup(l10n.settingsGroupAccount),
          PhoneListCard(children: [
            PhoneListRow(
              key: const ValueKey('settings-account'),
              // (No "Sign in now" in a build with no account service: the page
              // is the keys', the sync's and the backups'.)
              icon: isSignedIn || !zestHasCloud ? LucideIcons.userCircle : LucideIcons.logIn,
              title: name(l10n.settingsAccount),
              subtitle: isSignedIn || !zestHasCloud ? l10n.settingsPageAccountDesc : l10n.settingsMobSignInNow,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.profile),
            ),
            if (zestHasPlans)
            PhoneListRow(
              key: const ValueKey('settings-plan'),
              icon: LucideIcons.crown,
              title: name(l10n.settingsPagePlan),
              subtitle: plan,
              subtitleMaxLines: null,
              onTap: () => openPhonePlan(context, ref),
            ),
          ]),

          PhoneListGroup(l10n.settingsGroupApp),
          PhoneListCard(children: [
            // General: a phone's is its language (the window and startup are
            // a computer's), so its row opens the language's choice at once.
            PhoneListRow(
              key: const ValueKey('settings-language'),
              icon: LucideIcons.settings,
              title: name(l10n.settingsInlineSectionGeneral),
              subtitle: '${l10n.settingsLanguage}: ${currentLanguageLabel(context, ref)}',
              subtitleMaxLines: null,
              onTap: () => showLanguagePickerDialog(context, ref),
            ),
            // A tablet (4.1.1): what its large screen shows, the computer
            // layout or these tabs however it is held.
            if (canBeLargeScreen(MediaQuery.sizeOf(context)))
              PhoneListRow(
                key: const ValueKey('settings-large-layout'),
                icon: LucideIcons.layoutDashboard,
                title: name(l10n.largeLayoutLabel),
                subtitle: ref.watch(largeScreenLayoutProvider) == LargeScreenLayout.tabs
                    ? l10n.largeLayoutTabs
                    : l10n.largeLayoutComputer,
                subtitleMaxLines: null,
                onTap: () async {
                  final picked = await showZestChoice<LargeScreenLayout>(
                    context,
                    title: l10n.largeLayoutLabel,
                    subtitle: l10n.largeLayoutDesc,
                    selected: ref.read(largeScreenLayoutProvider),
                    choices: [
                      ZestChoice(value: LargeScreenLayout.computer, label: l10n.largeLayoutComputer),
                      ZestChoice(value: LargeScreenLayout.tabs, label: l10n.largeLayoutTabs),
                    ],
                  );
                  if (picked != null) ref.read(largeScreenLayoutProvider.notifier).set(picked);
                },
              ),
            PhoneListRow(
              key: const ValueKey('settings-appearance'),
              icon: LucideIcons.palette,
              title: name(l10n.settingsMobAppearance),
              subtitle: appThemeName,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.appearance),
            ),
            PhoneListRow(
              key: const ValueKey('settings-keyboard'),
              icon: LucideIcons.keyboard,
              title: name(l10n.settingsPageKeyboardMouse),
              subtitle: l10n.settingsPageKeyboardMousePhoneDesc,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.keyboardRow),
            ),
            PhoneListRow(
              key: const ValueKey('settings-notifications'),
              icon: LucideIcons.bell,
              title: name(l10n.settingsNotifications),
              subtitle: l10n.settingsLinkNotificationsHelp,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.notificationSettings),
            ),
          ]),

          PhoneListGroup(l10n.settingsGroupConnections),
          PhoneListCard(children: [
            PhoneListRow(
              key: const ValueKey('settings-terminal'),
              icon: LucideIcons.terminal,
              title: name(l10n.settingsPageTerminalSsh),
              subtitle: l10n.settingsPageTerminalSshDesc,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.terminalSettings),
            ),
            PhoneListRow(
              key: const ValueKey('settings-sftp'),
              icon: LucideIcons.folderOpen,
              title: name(l10n.settingsPageFiles),
              subtitle: l10n.settingsMobSftpRowDesc,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.sftpSettings),
            ),
            PhoneListRow(
              key: const ValueKey('settings-screens'),
              icon: LucideIcons.monitor,
              title: name(l10n.settingsScreensSection),
              subtitle: l10n.settingsScreensRowDesc,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.screenSettings),
            ),
          ]),

          PhoneListGroup(l10n.settingsGroupSecurityData),
          PhoneListCard(children: [
            PhoneListRow(
              key: const ValueKey('settings-security'),
              icon: LucideIcons.shieldCheck,
              title: name(l10n.settingsPageSecurityPrivacy),
              subtitle: appLockOn ? l10n.settingsValAppLockOn : l10n.settingsValAppLockOff,
              subtitleMaxLines: null,
              onTap: () => SecuritySettingsScreen.show(context),
            ),
            PhoneListRow(
              key: const ValueKey('settings-data'),
              icon: LucideIcons.archive,
              title: name(l10n.settingsPageBackupsData),
              subtitle: l10n.settingsPageBackupsDataDesc,
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.dataSettings),
            ),
          ]),

          PhoneListGroup(l10n.settingsInlineSectionAbout),
          PhoneListCard(children: [
              PhoneListRow(
              key: const ValueKey('settings-about'),
              icon: LucideIcons.info,
              title: name(l10n.settingsAbout),
              subtitle: l10n.settingsVersion(ref.watch(appVersionProvider).valueOrNull ?? '…'),
              subtitleMaxLines: null,
              onTap: () => context.push(Routes.about),
            ),
          ]),
          // Automation is the More tab's (as a computer's is a screen of its
          // own), and Reset all settings the Backups and data page's (4.0).
        ],
      ],
    );
  }

  // ── Desktop multi-column card layout ──────────────────────────

  static Widget _desktopCard(String title, List<Widget> children) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
        ),
        child: InkLayer(
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
              child: Text(
                title,
                style: TextStyle(
                  color: AppColors.accentInk,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            ...children,
            const SizedBox(height: 4),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildDesktopSettings(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final themeId = ref.watch(shownTerminalThemeIdProvider);
    final fontFamily = ref.watch(terminalFontFamilyProvider);
    final fontSize = ref.watch(terminalFontSizeProvider);
    final scrollback = ref.watch(scrollbackLinesProvider);
    final hapticFeedback = ref.watch(hapticFeedbackProvider);
    final keepAwake = ref.watch(keepScreenAwakeProvider);
    final cursorBlink = ref.watch(cursorBlinkProvider);
    final settings = ref.watch(settingsServiceProvider);
    final updater = ref.watch(settingsUpdaterProvider);
    final isPro = ref.watch(isProProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);

    // ── Section tile builders ────────────────────────────────────

    final subscriptionTiles = <Widget>[
      if (!zestHasPlans)
        const SizedBox.shrink()
      else if (!isPro && !isCloudSync)
        ListTile(
          title: Text(l10n.settingsUpgradeSqueezedOrJuiced),
          subtitle: Text(l10n.settingsUpgradeSqueezedOrJuicedDesc),
          leading: Icon(LucideIcons.rocket,
              color: AppColors.accentInk),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => context.push(Routes.upgrade),
        )
      else if (isPro && !isCloudSync)
        ListTile(
          title: Text(l10n.settingsAddCloudSync),
          subtitle: Text(l10n.settingsAddCloudSyncDesc),
          leading: Icon(LucideIcons.cloudCog,
              color: AppColors.accentInk),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => context.push(Routes.upgrade),
        )
      else if (!isPro && isCloudSync)
        ListTile(
          title: Text(l10n.settingsUpgradeToSqueezed),
          subtitle: Text(l10n.settingsUnlockConnectionsThemes),
          leading: Icon(LucideIcons.rocket,
              color: AppColors.accentInk),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => context.push(Routes.upgrade),
        )
      ,
      // Fully entitled: no subscription tile - it is dead weight.
      ListTile(
        title: Text(l10n.settingsProfileCloudSync),
        subtitle: Text(l10n.settingsProfileCloudSyncDesc),
        leading: const Icon(LucideIcons.cloudCog, color: AppColors.cloudSync),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => ProfileScreen.showAdaptive(context),
      ),
    ];

    final terminalAppearanceTiles = <Widget>[
      ListTile(
        title: Text(l10n.settingsTerminalTheme),
        subtitle: Text(
            app_themes.TerminalThemes.names[themeId] ??
                l10n.settingsThemeUnknown),
        leading: const Icon(LucideIcons.palette),
        onTap: () => _showThemePicker(context, ref),
      ),
      ListTile(
        title: Text(l10n.settingsFont),
        subtitle: Text(fontFamily.nameIn(l10n)),
        leading: const Icon(LucideIcons.type),
        onTap: () => _showFontPicker(context, ref),
      ),
      ListTile(
        title: Text(l10n.settingsFontSize),
        subtitle: Text(l10n.settingsFontSizePx(fontSize.toInt())),
        leading: const Icon(LucideIcons.type),
        trailing: SizedBox(
          width: 200,
          child: SliderTheme(
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
      ),
      ListTile(
        title: Text(l10n.settingsScrollbackLines),
        subtitle: Text(scrollback <= 0 ? l10n.settingsMobUnlimitedScrollback : l10n.settingsScrollbackCount(scrollback)),
        leading: const Icon(LucideIcons.history),
        trailing: _helpIcon(l10n.settingsScrollbackLines,
            l10n.settingsMobScrollbackHelpBody),
        onTap: () => _showScrollbackDialog(context, ref, scrollback),
      ),
      SwitchListTile(
        title: Text(l10n.settingsCursorBlink),
        subtitle: Text(l10n.settingsCursorBlinkDesc),
        secondary: const Icon(LucideIcons.film),
        value: cursorBlink,
        onChanged: (v) => updater.setCursorBlink(v),
      ),
      ListTile(
        title: Text(l10n.settingsTerminalMargin),
        subtitle: Text(
          ref.watch(terminalMarginProvider) == 0
              ? l10n.none
              : l10n.settingsFontSizePx(ref.watch(terminalMarginProvider).round()),
        ),
        leading: const Icon(LucideIcons.squareDashedBottom),
        onTap: () => _showTerminalMarginDialog(context, ref),
      ),
    ];

    final terminalBehaviourTiles = <Widget>[
      SwitchListTile(
        title: Text(l10n.settingsHapticFeedback),
        subtitle: Text(l10n.settingsHapticFeedbackDesc),
        secondary: const Icon(LucideIcons.vibrate),
        value: hapticFeedback,
        onChanged: (v) => updater.setHapticFeedback(v),
      ),
      SwitchListTile(
        title: Text(l10n.settingsKeepAwake),
        subtitle: Text(l10n.settingsKeepAwakeDesc),
        secondary: const Icon(LucideIcons.sun),
        value: keepAwake,
        onChanged: (v) => updater.setKeepScreenAwake(v),
      ),
      SwitchListTile(
        title: Text(l10n.settingsAutoExecuteSnippets),
        subtitle: Text(l10n.settingsAutoExecuteSnippetsDesc),
        secondary: const Icon(LucideIcons.play),
        value: ref.watch(autoExecuteSnippetsProvider),
        onChanged: (v) => updater.setAutoExecuteSnippets(v),
      ),
      ListTile(
        title: Text(l10n.settingsKeepaliveInterval),
        subtitle: Text(_keepaliveLabel(ref.watch(keepaliveIntervalProvider), l10n)),
        leading: const Icon(LucideIcons.heart),
        trailing: _helpIcon(l10n.settingsKeepaliveInterval,
            l10n.settingsMobKeepaliveHelpBody),
        onTap: () => _showKeepaliveDialog(context, ref),
      ),
      ListTile(
        title: Text(l10n.settingsMobTriggers),
        subtitle: Text(l10n.settingsMobTriggersDesc),
        leading: const Icon(LucideIcons.bellRing),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => context.push(Routes.triggers),
      ),
      ListTile(
        title: Text(l10n.settingsMobCommandHistory),
        subtitle: Text(l10n.settingsMobCommandHistoryDesc),
        leading: const Icon(LucideIcons.history),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => context.push(Routes.commandHistory),
      ),
    ];

    final snippetsTiles = <Widget>[
      // The protection a computer's Settings has: the warning before a
      // dangerous command is pasted, run as a snippet or broadcast. (This was
      // a switch of its own that nothing read.)
      SwitchListTile(
        key: const ValueKey('settings-dangerous-commands'),
        title: Text(l10n.settingsInlineDangerousCommandProtection),
        subtitle: Text(l10n.settingsDangerousCommandDesc),
        secondary: const Icon(LucideIcons.alertTriangle),
        value: ref.watch(dangerousCommandProtectionProvider),
        onChanged: (v) => updater.setDangerousCommandProtection(v),
      ),
      ListTile(
        title: Text(l10n.settingsDefaultSnippetCategory),
        subtitle: Text(
            ref.watch(defaultSnippetCategoryProvider) ?? l10n.none),
        leading: const Icon(LucideIcons.shapes),
        onTap: () => _showDefaultSnippetCategoryDialog(context, ref),
      ),
    ];

    final notificationsTiles = <Widget>[
      SwitchListTile(
        title: Text(l10n.settingsConnectionLost),
        subtitle: Text(l10n.settingsConnectionLostDesc),
        secondary: const Icon(LucideIcons.wifiOff),
        value: ref.watch(notifyConnectionLostProvider),
        onChanged: (v) => updater.setNotifyConnectionLost(v),
      ),
      SwitchListTile(
        title: Text(l10n.settingsTransferComplete),
        subtitle: Text(l10n.settingsTransferCompleteDesc),
        secondary: const Icon(LucideIcons.cloud),
        value: ref.watch(notifyTransferCompleteProvider),
        onChanged: (v) => updater.setNotifyTransferComplete(v),
      ),
      SwitchListTile(
        key: const ValueKey('settings-reach-checks'),
        title: Text(l10n.settingsServerHealthChecks),
        subtitle: Text(l10n.settingsServerHealthChecksDesc),
        secondary: const Icon(LucideIcons.activity),
        value: ref.watch(healthChecksEnabledProvider),
        onChanged: (v) => setReachabilityChecks(context, ref, v),
      ),
      if (ref.watch(healthChecksEnabledProvider))
        ListTile(
          title: Text(l10n.settingsInlineCheckInterval),
          subtitle: Text(reachabilityCheckIntervalLabel(l10n, ref.watch(healthCheckIntervalProvider))),
          leading: const Icon(LucideIcons.timer),
          onTap: () => showReachabilityIntervalPicker(context, ref),
        ),
    ];

    final securityTiles = <Widget>[
      // ONE home for security controls: the dedicated Security screen (app
      // lock, PIN, encryption, hardware binding, host-key trust). The old
      // inline toggle here bypassed the current-PIN gate and the
      // PIN<->encryption coupling.
      ListTile(
        title: Text(l10n.settingsSecurity),
        subtitle: Text(l10n.settingsMobSecurityDesc),
        leading: Icon(LucideIcons.shieldCheck, color: AppColors.accentInk),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => SecuritySettingsScreen.show(context),
      ),
    ];

    // Sync is free on any storage, so "set up and on" (not the Juiced
    // purchase) is what gates the mode and interval rows. Setup lives on the
    // Profile screen for every backend, so the off-state tile goes there.
    final syncOn = ref.watch(syncIsActiveProvider).valueOrNull ?? false;
    final ownsJuiced = ref.watch(isCloudSyncProvider);
    final cloudSyncTiles = <Widget>[
      if (!syncOn)
        ListTile(
          title: Text(l10n.settingsCloudSync),
          subtitle: Text(ownsJuiced
              ? l10n.settingsMobCloudSignInHint
              : l10n.settingsMobCloudFreeHint),
          leading: Icon(LucideIcons.cloudOff,
              color: AppColors.textSecondary),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => context.push(Routes.profile),
        )
      else ...[
        ListTile(
          title: Text(l10n.settingsSyncMode),
          subtitle: Text(
              _syncModeLabel(ref.watch(syncModeProvider), l10n)),
          leading: Icon(LucideIcons.refreshCw, color: AppColors.accentInk),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => _showSyncModeDialog(context, ref),
        ),
        if (ref.watch(syncModeProvider) == 'auto')
          ListTile(
            title: Text(l10n.settingsSyncInterval),
            subtitle: Text(_syncIntervalLabel(
                ref.watch(syncIntervalProvider), l10n)),
            leading: Icon(LucideIcons.timer,
                color: AppColors.accentInk),
            trailing: const Icon(LucideIcons.chevronRight),
            onTap: () => _showSyncIntervalDialog(context, ref),
          ),
        ListTile(
          title: Text(l10n.settingsLastSynced),
          subtitle: Text(
              _formatLastSyncTime(settings.lastSyncTime, l10n)),
          leading: Icon(LucideIcons.clock,
              color: AppColors.textSecondary),
        ),
        ListTile(
          title: Text(l10n.settingsSyncNow),
          subtitle: Text(l10n.settingsSyncNowDesc),
          leading: Icon(LucideIcons.cloudCog,
              color: AppColors.accentInk),
          // Syncs (it only said "Syncing..." and synced nothing).
          onTap: () => runSyncNow(context, ref),
        ),
      ],
    ];

    final backupRestoreTiles = <Widget>[
      // ONE tile: schedule + location folded together (destinations live here
      // now, not in a separate dead info tile).
      ListTile(
        title: Text(l10n.settingsAutoBackup),
        subtitle: Text(phoneAutoBackupSummary(ref, l10n)),
        leading: Icon(LucideIcons.archive,
            color: AppColors.accentInk),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => showPhoneAutoBackupConfig(context, ref),
      ),
    ];

    final hostKeysTiles = <Widget>[
      ListTile(
        title: Text(l10n.settingsTrustedHostKeys),
        subtitle: Text(l10n.settingsTrustedHostKeysDesc),
        leading: const Icon(LucideIcons.keyRound),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => context.push(Routes.knownHosts),
      ),
      SwitchListTile(
        title: Row(
          children: [
            Expanded(child: Text(l10n.settingsAskBeforeTrusting)),
            _helpIcon(l10n.settingsMobHostKeyVerificationHelpTitle,
                l10n.settingsMobHostKeyVerificationHelpBody),
          ],
        ),
        subtitle: Text(l10n.settingsAskBeforeTrustingDesc),
        secondary: const Icon(LucideIcons.shield),
        value: ref.watch(askBeforeTrustingKeysProvider),
        onChanged: (v) => updater.setAskBeforeTrustingNewKeys(v),
      ),
      ListTile(
        title: Text(l10n.settingsClearTrustedKeys),
        subtitle: Text(l10n.settingsClearTrustedKeysDesc),
        leading: Icon(LucideIcons.trash,
            color: AppColors.error),
        onTap: () => _confirmClearKnownHosts(context, ref),
      ),
    ];

    final dataTiles = <Widget>[
      ListTile(
        title: Text(l10n.settingsMobImportData),
        subtitle: Text(l10n.settingsMobImportDataDesc),
        leading: Icon(LucideIcons.download, color: AppColors.accentInk),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => _showImportDataSheet(context, ref),
      ),
      ListTile(
        title: Text(l10n.settingsMobExportData),
        subtitle: Text(l10n.settingsMobExportDataDesc),
        leading: Icon(LucideIcons.upload, color: AppColors.accentInk),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => _showExportDataSheet(context, ref),
      ),
      // Cloud accounts kept in sync on this device (3.0).
      const CloudAccountsTiles(),
      ListTile(
        title: Text(l10n.settingsClearAllData),
        subtitle: Text(l10n.settingsClearAllDataDesc),
        leading: Icon(LucideIcons.trash2, color: AppColors.error),
        onTap: () => _confirmClearAllData(context, ref),
      ),
    ];

    final aboutTiles = <Widget>[
      // Server Monitor lives in the desktop shell's own monitor view, not here.
      ListTile(
        title: Text(l10n.appName),
        subtitle: Text(l10n.settingsVersion(
                ref.watch(appVersionProvider).valueOrNull ?? '…')),
        leading: const Icon(LucideIcons.info),
        onTap: () => context.push(Routes.about),
      ),
    ];

    // ── 2-column card layout ─────────────────────────────────────

    return LayoutBuilder(
      builder: (context, constraints) {
        // Responsive: single column for narrower desktop windows
        final useTwoColumns = constraints.maxWidth > 900;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: DesktopDimensions.settingsMaxWidth),
              child: useTwoColumns
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Left column
                        Expanded(
                          child: Column(
                            children: [
                              _desktopCard(l10n.settingsSubscription,
                                  subscriptionTiles),
                              _desktopCard(l10n.settingsTerminalAppearance,
                                  terminalAppearanceTiles),
                              _desktopCard(
                                  l10n.settingsSecurity, securityTiles),
                              _desktopCard(l10n.settingsBackupRestore,
                                  backupRestoreTiles),
                              _desktopCard(l10n.settingsData, dataTiles),
                            ],
                          ),
                        ),
                        const SizedBox(width: 24),
                        // Right column
                        Expanded(
                          child: Column(
                            children: [
                              _desktopCard(l10n.settingsTerminalBehaviour,
                                  terminalBehaviourTiles),
                              _desktopCard(l10n.settingsSnippetsAndNotifications, [
                                ...snippetsTiles,
                                Divider(
                                    height: 1, color: AppColors.divider),
                                ...notificationsTiles,
                              ]),
                              _desktopCard(
                                  l10n.settingsCloudSync, cloudSyncTiles),
                              _desktopCard(l10n.settingsHostKeys, hostKeysTiles),
                              _desktopCard(l10n.settingsAbout, aboutTiles),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        _desktopCard(l10n.settingsSubscription,
                            subscriptionTiles),
                        _desktopCard(l10n.settingsTerminalAppearance,
                            terminalAppearanceTiles),
                        _desktopCard(l10n.settingsSecurity, securityTiles),
                        _desktopCard(l10n.settingsBackupRestore,
                            backupRestoreTiles),
                        _desktopCard(l10n.settingsData, dataTiles),
                        _desktopCard(l10n.settingsTerminalBehaviour,
                            terminalBehaviourTiles),
                        _desktopCard(l10n.settingsSnippetsAndNotifications, [
                          ...snippetsTiles,
                          Divider(
                              height: 1, color: AppColors.divider),
                          ...notificationsTiles,
                        ]),
                        _desktopCard(
                            l10n.settingsCloudSync, cloudSyncTiles),
                        _desktopCard(l10n.settingsHostKeys, hostKeysTiles),
                        _desktopCard(l10n.settingsAbout, aboutTiles),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

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

  // ── Terminal margin dialog ─────────────────────────────────────

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
                // phone and a tablet (3.0).
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

  // ── Cloud Sync helpers ─────────────────────────────────────────

  static String _syncModeLabel(String mode, AppLocalizations l10n) {
    switch (mode) {
      case 'instant':
        return l10n.settingsSyncModeInstant;
      case 'auto':
        return l10n.settingsSyncModeAutomatic;
      case 'manual':
        return l10n.settingsSyncModeManual;
      case 'off':
        return l10n.settingsSyncModeOff;
      default:
        return mode;
    }
  }

  static String _syncIntervalLabel(int minutes, AppLocalizations l10n) => syncIntervalLabel(l10n, minutes);

  static String _formatLastSyncTime(DateTime? time, AppLocalizations l10n) {
    if (time == null) return l10n.settingsNeverSynced;
    // A line of its own: within a day the shared compact words, then the
    // date and the time.
    if (DateTime.now().difference(time).inHours < 24) return timeAgoWords(l10n, time);
    return DateFormat.yMd(l10n.localeName).add_jm().formatPlain(time);
  }

  Future<void> _showSyncModeDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(syncModeProvider);
    final v = await showZestChoice<String>(
      context,
      title: l10n.settingsSyncMode,
      icon: LucideIcons.refreshCw,
      selected: current,
      choices: [
        for (final entry in {
          'instant': l10n.settingsSyncModeInstant,
          'auto': l10n.settingsSyncModeAutomatic,
          'manual': l10n.settingsSyncModeManual,
          'off': l10n.settingsSyncModeOff,
        }.entries)
          ZestChoice(
            value: entry.key,
            label: entry.value,
            detail: entry.key == 'instant'
                ? l10n.syncInstantDescPull(AutoSyncService.instantPullEvery.inMinutes)
                : null,
          ),
      ],
    );
    // The one in use chosen again changes nothing (as its radio did).
    if (v == null || v == current) return;
    ref.read(settingsUpdaterProvider).setSyncMode(v);
    // Start/stop auto sync based on mode
    final autoSync = ref.read(autoSyncServiceProvider);
    if (v == 'auto' || v == 'instant') {
      autoSync.startAutoSync();
    } else {
      autoSync.stopAutoSync();
    }
  }

  Future<void> _showSyncIntervalDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(syncIntervalProvider);
    final v = await showZestChoice<int>(
      context,
      title: l10n.settingsSyncInterval,
      icon: LucideIcons.timer,
      selected: current,
      choices: [
        // The same as the Account page offers (3.0: every 2, 6 and 24
        // hours too).
        for (final minutes in [for (final (_, every) in kSyncSchedules) ?every])
          ZestChoice(value: minutes, label: _syncIntervalLabel(minutes, l10n)),
      ],
    );
    if (v == null || v == current) return;
    ref.read(settingsUpdaterProvider).setSyncInterval(v);
    // Restart auto sync with new interval
    final autoSync = ref.read(autoSyncServiceProvider);
    autoSync.startAutoSync();
  }

  // ── Backup Destinations tile ──────────────────────────────────

  // ── Auto Backup helpers ──────────────────────────────────────

  /// Prompt the user to set a password for auto-backups.
  // ── Keepalive helper ──────────────────────────────────────────

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

  // ── Snippet settings helpers ──────────────────────────────

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

  // ── Host Keys helpers ─────────────────────────────────────

  Future<void> _confirmClearKnownHosts(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.settingsClearTrustedKeysConfirmTitle,
      body: l10n.settingsClearTrustedKeysConfirmMsg,
      confirmLabel: l10n.settingsClearAll,
    );
    if (confirmed == true) {
      await ref.read(knownHostsDaoProvider).deleteAll();
      if (context.mounted) {
        showTopSnackBar(context, l10n.settingsTrustedKeysCleared);
      }
    }
  }

  // ── Data helpers ──────────────────────────────────────────

  /// Import chooser: every "bring data in" method in one sheet.
  void _showImportDataSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(l10n.settingsMobImportData,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              key: const ValueKey('import-data-file'),
              leading: const Icon(LucideIcons.fileUp),
              title: Text(l10n.importFileAction),
              subtitle: Text(l10n.importFileDesc),
              onTap: () {
                Navigator.pop(ctx);
                openImportHosts(context, chooseFile: true);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.rotateCcw),
              title: Text(l10n.settingsMobRestoreFromBackup),
              subtitle: Text(l10n.settingsMobRestoreFromBackupDesc),
              onTap: () {
                Navigator.pop(ctx);
                runBackupImport(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.fileText),
              title: Text(l10n.settingsMobSshConfigFile),
              subtitle: Text(l10n.settingsMobSshConfigFileDesc),
              onTap: () {
                Navigator.pop(ctx);
                context.push(Routes.sshConfigImport);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.downloadCloud),
              title: Text(l10n.cloudImpFromCloud),
              subtitle: Text(l10n.cloudImpFromCloudDesc),
              onTap: () {
                Navigator.pop(ctx);
                openImportHosts(context);
              },
            ),
            ListTile(
              key: const ValueKey('import-data-csv'),
              leading: const Icon(LucideIcons.table),
              title: Text(l10n.cloudImpCsv),
              subtitle: Text(l10n.cloudImpCsvDesc),
              onTap: () {
                Navigator.pop(ctx);
                openCsvImport(context);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.keyRound),
              title: Text(l10n.settingsMobPuttyPrivateKey),
              onTap: () {
                Navigator.pop(ctx);
                _importPuttyKey(context, ref);
              },
            ),
            // PuTTY keeps its saved sessions in Windows' registry: offered
            // on Windows alone (a phone listed it and opened a page saying so).
            if (puttyImportHere)
              ListTile(
                key: const ValueKey('import-data-putty'),
                leading: const Icon(LucideIcons.terminal),
                title: Text(l10n.settingsMobPuttySessions),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(Routes.puttyImport);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Export chooser: every "take data out" method in one sheet. All local -
  /// no sign-in required.
  void _showExportDataSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(l10n.settingsMobExportData,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(LucideIcons.archive),
              title: Text(l10n.settingsMobFullBackup),
              subtitle: Text(l10n.settingsMobFullBackupDesc),
              onTap: () {
                Navigator.pop(ctx);
                runBackupExport(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.fileUp),
              title: Text(l10n.settingsMobConnectionsAsSshConfig),
              subtitle: Text(l10n.settingsMobConnectionsAsSshConfigDesc),
              onTap: () {
                Navigator.pop(ctx);
                exportSshConfig(context, ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _importPuttyKey(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    // Read + convert the picked .ppk HERE, then hand the editor the finished
    // key. (The old code picked a file, threw it away, and opened a blank
    // identity screen - a dead end on every platform.)
    try {
      final file = result.files.first;
      final String content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        throw const FormatException('Could not read file');
      }

      final importService = KeyImportService();
      if (!importService.isPpkFormat(content)) {
        if (context.mounted) {
          showTopSnackBar(context,
              l10n.settingsMobNotPuttyKey, isError: true);
        }
        return;
      }
      // A key with a passphrase is imported where the passphrase is asked
      // for; here it is said so (it was refused as not supported).
      if (importService.isEncrypted(content)) {
        if (context.mounted) showTopSnackBar(context, l10n.keyImportHasPassphrase, isError: true);
        return;
      }
      final imported = importService.importPpkKey(content, null);
      if (context.mounted) {
        context.push(
          Routes.identityEdit,
          extra: InitialImportedKey(
            privatePem: imported.privatePem,
            fingerprint: imported.fingerprint,
            keyType: imported.keyType,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showTopSnackBar(
          context,
          KeyImportService.problemSaid(e, l10n),
          isError: true,
          details: '$e',
        );
      }
    }
  }

  Future<void> _confirmClearAllData(BuildContext context, WidgetRef ref) => confirmClearAllData(context, ref);

}

// ── Automatic backups (a phone's) ─────────────────────────────

/// One-line summary for the phone's Backups row: schedule + location (on the
/// Backups and data page, 4.0; it was a row of the Settings root).
String phoneAutoBackupSummary(WidgetRef ref, AppLocalizations l10n) {
  final interval = ref.watch(autoBackupIntervalProvider);
  final schedule = _autoBackupLabel(interval, l10n);
  if (interval == 'off') return schedule;
  final count = ref
          .watch(backupDestinationCountProvider)
          .whenOrNull(data: (c) => c) ??
      0;
  // Local storage is always active; extra destinations are additional copies.
  final location = count == 0
      ? l10n.settingsMobBackupThisDevice
      : l10n.settingsMobBackupThisDevicePlusMore(count);
  return '$schedule · $location';
}

/// The phone's automatic backups: schedule AND location in one sheet.
void showPhoneAutoBackupConfig(BuildContext context, WidgetRef ref) {
  showZestSheet<void>(
    context: context,
    child: ZestSheetFrame(
      child: _AutoBackupConfigSheet(
        onSetInterval: (v) => _applyAutoBackupInterval(context, ref, v),
      ),
    ),
  );
}

/// Apply an interval change: on, with no backup password kept, it asks for
/// one first (the way Profile does it too).
Future<void> _applyAutoBackupInterval(BuildContext context, WidgetRef ref, String v) =>
    setAutoBackupInterval(context, ref, v);

/// Configure a WebDAV / Nextcloud backup location.
Future<void> _showWebDavDestinationForm(
    BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final labelCtl = TextEditingController(text: 'Nextcloud');
  final urlCtl = TextEditingController();
  final userCtl = TextEditingController();
  final passCtl = TextEditingController();
  final pathCtl = TextEditingController(text: '/ZestSSH/backups/');
  final formKey = GlobalKey<FormState>();
  var obscured = true;

  // Shared by the real fields and their recording-mode stand-ins, so the
  // rules hold while the values are masked.
  String? validateUrl(String? v) {
    final t = v?.trim() ?? '';
    if (!t.startsWith('https://')) {
      return l10n.settingsMobUseHttpsUrl;
    }
    return null;
  }

  String? validateUser(String? v) =>
      (v == null || v.trim().isEmpty) ? l10n.settingsMobRequired : null;

  final saved = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    child: StatefulBuilder(
      builder: (ctx, setDialogState) {
        void submit() {
          if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
        }

        return ZestDialogShell(
          size: ZestModalSize.standard,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.cloud,
          title: l10n.settingsMobWebDavNextcloud,
          body: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: labelCtl,
                  decoration: InputDecoration(labelText: l10n.settingsMobLabel),
                ),
                // The server host and the username are identifiers: while
                // recording they render masked and read-only.
                RecordingMaskedFormField(
                  controller: urlCtl,
                  mask: maskEndpointUrl,
                  decoration: InputDecoration(
                    labelText: l10n.settingsMobServerUrl,
                    hintText: 'https://cloud.example.com/remote.php/dav',
                  ),
                  validate: () => validateUrl(urlCtl.text),
                  child: TextFormField(
                    controller: urlCtl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.settingsMobServerUrl,
                      hintText: 'https://cloud.example.com/remote.php/dav',
                    ),
                    validator: validateUrl,
                  ),
                ),
                RecordingMaskedFormField(
                  controller: userCtl,
                  mask: (v) => Redactable.username(v).display,
                  decoration: InputDecoration(labelText: l10n.settingsMobUsername),
                  validate: () => validateUser(userCtl.text),
                  child: TextFormField(
                    controller: userCtl,
                    autocorrect: false,
                    decoration:
                        InputDecoration(labelText: l10n.settingsMobUsername),
                    validator: validateUser,
                  ),
                ),
                TextFormField(
                  controller: passCtl,
                  obscureText: obscured,
                  decoration: InputDecoration(
                    labelText: l10n.settingsMobPasswordAppToken,
                    suffixIcon: IconButton(
                      icon: Icon(obscured
                          ? LucideIcons.eye
                          : LucideIcons.eyeOff),
                      tooltip: obscured ? l10n.settingsMobShow : l10n.settingsMobHide,
                      onPressed: () =>
                          setDialogState(() => obscured = !obscured),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? l10n.settingsMobRequired : null,
                ),
                TextFormField(
                  controller: pathCtl,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: l10n.settingsMobRemotePath),
                ),
              ],
            ),
          ),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(ctx, false)),
          primaryAction: (label: l10n.save, icon: null, onPressed: submit),
        );
      },
    ),
  );

  final password = passCtl.text;
  // The typed password leaves the form as the dialog closes: it stayed in a
  // controller nobody disposed until it was collected (found in a code
  // audit).
  passCtl.clear();
  if (saved != true) return;
  final destination = WebDavBackupDestination(
    serverUrl: urlCtl.text.trim(),
    username: userCtl.text.trim(),
    password: password,
    remotePath: pathCtl.text.trim(),
    label: labelCtl.text.trim().isEmpty ? 'WebDAV' : labelCtl.text.trim(),
  );
  await ref.read(backupDestinationNotifierProvider).add(destination);
  if (context.mounted) {
    showTopSnackBar(context, l10n.settingsMobBackupLocationAdded);
  }
}

String _autoBackupLabel(String interval, AppLocalizations l10n) {
  switch (interval) {
    case 'daily':
      return l10n.settingsAutoBackupDaily;
    case 'weekly':
      return l10n.settingsAutoBackupWeekly;
    case 'off':
      return l10n.settingsSyncModeOff;
    default:
      return interval;
  }
}

/// The folded Auto Backup config sheet: schedule (off/daily/weekly) AND the
/// backup places ([BackupPlaces]).
class _AutoBackupConfigSheet extends ConsumerWidget {
  const _AutoBackupConfigSheet({required this.onSetInterval});

  final void Function(String interval) onSetInterval;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final interval = ref.watch(autoBackupIntervalProvider);

    return SettingsSheetBody(
      title: l10n.settingsAutoBackup,
      subtitle: l10n.settingsMobAutoBackupSheetDesc,
      children: [
        ZestSectionHeader(label: l10n.settingsMobSchedule),
        // One of the three: the dot radios a pick-one choice has (a check
        // stood on the one picked: found on a Pixel 3a).
        RadioGroup<String>(
          groupValue: interval,
          onChanged: (value) {
            if (value != null) onSetInterval(value);
          },
          child: SettingsChoiceCard(
            children: [
              for (final e in {
                'off': l10n.settingsSyncModeOff,
                'daily': l10n.settingsAutoBackupDaily,
                'weekly': l10n.settingsAutoBackupWeekly,
              }.entries)
                SettingsRadioRow<String>(
                  key: ValueKey('backup-schedule-${e.key}'),
                  value: e.key,
                  label: e.value,
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ZestSectionHeader(label: l10n.settingsMobLocation),
        const BackupPlaces(),
      ],
    );
  }
}

/// Opens the backup places on a computer: the account page's Backup places
/// row. A computer had no way to add one: the WebDAV form was on a phone's
/// Settings alone (found in a code audit).
Future<void> showBackupPlacesDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.archive,
        title: l10n.accountBackupPlaces,
        subtitle: l10n.accountBackupPlacesDesc,
        body: const BackupPlaces(),
        primaryAction: (label: l10n.done, icon: null, onPressed: () => Navigator.pop(ctx)),
      ),
    ),
  );
}

/// The places automatic backups go: this device always, and each place added
/// (a WebDAV or Nextcloud server anywhere; Google Drive on a phone, where its
/// sign-in works), each with Remove; and the buttons that add them.
/// [offerGoogleDrive] and [connectGoogleDrive] are for tests.
class BackupPlaces extends ConsumerWidget {
  const BackupPlaces({super.key, this.offerGoogleDrive, this.connectGoogleDrive});

  /// Whether Google Drive can be added here: a phone (the backup's Google
  /// sign-in is the system's, which a computer does not have).
  final bool? offerGoogleDrive;

  /// Signs in to Google and gives the place; throws when it did not.
  final Future<BackupDestination> Function()? connectGoogleDrive;

  static Future<BackupDestination> _connectGoogleDrive() async {
    final drive = GoogleDriveBackupDestination();
    await drive.authenticate();
    return drive;
  }

  Future<void> _addGoogleDrive(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final drive = await (connectGoogleDrive ?? _connectGoogleDrive)();
      await ref.read(backupDestinationNotifierProvider).add(drive);
      if (context.mounted) showTopSnackBar(context, l10n.settingsMobBackupLocationAdded, isSuccess: true);
    } catch (e) {
      if (context.mounted) showTopSnackBar(context, l10n.backupGoogleDriveNotAdded, isError: true, details: '$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final destinations = ref.watch(backupDestinationsProvider);
    final hasDrive = destinations.maybeWhen(data: (list) => list.any((d) => d.name == 'google_drive'), orElse: () => true);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsChoiceCard(
          children: [
            SettingsChoiceRow(
              leading: Icon(LucideIcons.smartphone, size: 18, color: ZestTokens.textSecondary),
              label: l10n.settingsMobThisDevice,
              subtitle: l10n.settingsMobAlwaysOn,
            ),
            ...destinations.maybeWhen(
              data: (list) => [
                for (final d in list)
                  SettingsChoiceRow(
                    leading: Icon(LucideIcons.server, size: 18, color: ZestTokens.textSecondary),
                    // A destination label is user text and may name the
                    // server (recording mode).
                    labelWidget: RedactedText(
                      Redactable.freeText(d.displayName),
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
                    ),
                    label: '',
                    trailing: IconButton(
                      icon: Icon(LucideIcons.x, size: 18, color: ZestTokens.textTertiary),
                      tooltip: l10n.commonRemove,
                      onPressed: () => ref.read(backupDestinationNotifierProvider).remove(d.id),
                    ),
                  ),
              ],
              orElse: () => const <Widget>[],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('backup-add-webdav'),
              onPressed: () => _showWebDavDestinationForm(context, ref),
              icon: const Icon(LucideIcons.plus, size: 16),
              label: Text(l10n.settingsMobAddWebDavNextcloud),
            ),
            // One Google Drive place: it is one account's folder.
            if ((offerGoogleDrive ?? isMobilePlatform) && !hasDrive)
              OutlinedButton.icon(
                key: const ValueKey('backup-add-google-drive'),
                onPressed: () => _addGoogleDrive(context, ref),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: Text(l10n.backupAddGoogleDrive),
              ),
          ],
        ),
      ],
    );
  }
}

