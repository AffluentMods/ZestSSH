import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/idle_lock.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/redactor.dart' show RedactLevel;
import 'package:zestssh/ui/screens/security/security_actions.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// Security and privacy, so all the lock / encryption controls live in one
/// place instead of cluttering the main settings list. Layered by design: a
/// plain App Lock (PIN), then opt-in "Encrypt data at rest" for lost/stolen
/// devices, then opt-in hardware binding on top for the security-conscious.
/// Then host key trust, dangerous commands (4.0: they were the Terminal
/// page's) and recording mode (4.0: it was the Help page's alone, which keeps
/// it too), as a computer's Security and privacy page has them.
class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({super.key});

  static Future<void> show(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const SecuritySettingsScreen()),
    );
  }

  @override
  ConsumerState<SecuritySettingsScreen> createState() =>
      _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState
    extends ConsumerState<SecuritySettingsScreen> {
  SecurityActions get _actions => SecurityActions(context, ref);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsServiceProvider);
    final lockOn = settings.securityLockEnabled;
    final encryptOn = settings.encryptingLockEnabled;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsPageSecurityPrivacy)),
      // The 3.0 look of a phone's settings pages: each group in a card
      // (widgets/settings_section.dart), where orange capitals headed rows.
      // On a tablet in the one centred column Settings' list takes (it ran
      // the full width beside it on a test device).
      body: PhonePageColumn(
          child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          SettingsSection(
            title: l10n.secSetHeaderAppLock,
            child: Column(
              children: [
              SwitchListTile(
                // Why it cannot be turned off, while it cannot, stays in
                // sight; otherwise what it does is behind More (4.0).
                title: encryptOn
                    ? Text(l10n.secSetAppLock)
                    : FoldedHelpTitle(setting: l10n.secSetAppLock, help: l10n.secSetAppLockSubtitle),
                subtitle: encryptOn ? Text(l10n.secSetAppLockSubtitleEncrypted) : null,
                secondary: const PhoneIconTile(LucideIcons.lock),
                value: lockOn,
                // The app lock can't be removed while encryption is ON - the PIN is
                // what decrypts the data, so a lockless-but-encrypted vault would be
                // unopenable. The user must turn off encryption first (which prompts
                // for the PIN and decrypts).
                onChanged: encryptOn
                    ? null
                    : (v) async {
                        await _actions.setAppLock(v);
                        if (mounted) setState(() {});
                      },
              ),

              if (lockOn)
                ListTile(
                  leading: const PhoneIconTile(LucideIcons.pin),
                  title: FoldedHelpTitle(setting: l10n.secSetChangePin, help: l10n.secSetChangePinSubtitle),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () async {
                    await _actions.changePin();
                    if (mounted) setState(() {});
                  },
                ),

              // How long away before it locks, and whether it also locks while
              // in front (3.0).
              if (lockOn) _autoLockTile(l10n),
              if (lockOn) _idleLockTile(l10n),
              // The lock screen says how many sessions are still connected
              // behind it, never their names; off by default (4.0).
              if (lockOn)
                SwitchListTile(
                  key: const ValueKey('security-lock-sessions'),
                  title: FoldedHelpTitle(setting: l10n.secSetLockShowSessions, help: l10n.secSetLockShowSessionsDesc),
                  secondary: const PhoneIconTile(LucideIcons.terminalSquare),
                  value: ref.watch(lockShowSessionsProvider),
                  onChanged: (v) => ref.read(settingsUpdaterProvider).setLockShowSessions(v),
                ),
              ],
            ),
          ),
          SettingsSection(
            title: l10n.secSetHeaderDataAtRest,
            // Each setting with the line that says why it cannot be turned
            // on yet under its words (they stood at another indent), its
            // icon as faint as its words while it cannot, a hairline
            // between the two settings.
            child: Column(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      key: const ValueKey('security-encrypt'),
                      title: FoldedHelpTitle(setting: l10n.secSetEncryptAtRest, help: l10n.secSetEncryptAtRestSubtitle),
                      secondary: _tile(LucideIcons.lock, enabled: lockOn),
                      value: encryptOn,
                      onChanged: lockOn
                          ? (v) async {
                              if (v) {
                                await _actions.enableEncryption();
                              } else {
                                await _actions.disableEncryption();
                              }
                              if (mounted) setState(() {});
                            }
                          // Needs an app-lock PIN first (the encryption key rides on it).
                          : null,
                    ),
                    if (!lockOn) _helper(l10n.secSetEncryptNeedsLock),
                    // Honesty note on desktop: without full-disk encryption, an
                    // attacker who takes the raw drive can attempt the PIN
                    // offline with nothing to throttle them. Disk encryption is
                    // the real stolen-device defense on a computer; this
                    // encryption is a second layer on top. Said in a callout.
                    if (isDesktopPlatform)
                      Container(
                        key: const ValueKey('security-disk-note'),
                        // The card's width, so a long word (German's) keeps whole.
                        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
                        decoration: BoxDecoration(
                          color: ZestTokens.surfaceRaisedAlt,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: ZestTokens.borderSubtle),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Icon(LucideIcons.info, size: 15, color: ZestTokens.statusPending),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.secSetDesktopDiskNote(SecurityActions.diskEncryptionName()),
                                style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),

                // Hardware-backed encryption: opt-in extra layer that binds the key
                // to this device's secure hardware, so an extracted file is useless
                // off the device (offline brute-force must go through the hardware's
                // rate-limited/non-exportable key). Mobile = Keystore / Secure
                // Enclave; Windows = the TPM (CNG Platform Crypto Provider); a Mac =
                // its Secure Enclave (4.0). Linux stays hidden (the provider's
                // isAvailable is false there).
                if (isMobilePlatform || Platform.isWindows || Platform.isMacOS)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FutureBuilder<({bool available, bool bound})>(
                        future: _actions.hardwareState(),
                        builder: (context, snap) {
                          final available = snap.data?.available ?? false;
                          final bound = snap.data?.bound ?? false;
                          final texts = hardwareTexts(l10n);
                          final can = encryptOn && available && snap.hasData;
                          return SwitchListTile(
                            key: const ValueKey('security-hardware'),
                            // Why it is not here stays in sight; what it does
                            // is behind More (4.0).
                            title: !available
                                ? Text(l10n.secSetHwEncryption)
                                : FoldedHelpTitle(
                                    setting: l10n.secSetHwEncryption,
                                    help: texts.subtitle,
                                  ),
                            subtitle: !available
                                ? Text(texts.notAvailable)
                                : null,
                            secondary: _tile(LucideIcons.cpu, enabled: can),
                            value: bound,
                            onChanged: can
                                ? (v) async {
                                    await _actions.setHardwareBinding(v);
                                    if (mounted) setState(() {});
                                  }
                                : null,
                          );
                        },
                      ),
                      if (!encryptOn) _helper(l10n.secSetHwNeedsEncrypt),
                    ],
                  ),
              ],
            ),
          ),
          SettingsSection(
            title: l10n.secSetHeaderHostKeyTrust,
            child: Column(
              children: [
              ListTile(
                title: FoldedHelpTitle(setting: l10n.secSetTrustedHostKeys, help: l10n.secSetTrustedHostKeysSubtitle),
                leading: const PhoneIconTile(LucideIcons.keyRound),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => context.push(Routes.knownHosts),
              ),
              SwitchListTile(
                title: FoldedHelpTitle(setting: l10n.secSetAskBeforeTrusting, help: l10n.secSetAskBeforeTrustingSubtitle),
                secondary: const PhoneIconTile(LucideIcons.shield),
                value: ref.watch(askBeforeTrustingKeysProvider),
                onChanged: (v) => ref
                    .read(settingsUpdaterProvider)
                    .setAskBeforeTrustingNewKeys(v),
              ),
              // What removes, in the danger red, with the chevron every row
              // that opens something has.
              ListTile(
                key: const ValueKey('security-clear-keys'),
                title: Text(l10n.secSetClearAllKeys, style: TextStyle(color: AppColors.error)),
                subtitle: Text(l10n.secSetClearAllKeysSubtitle),
                leading: PhoneIconTile(LucideIcons.trash, color: AppColors.error),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => _actions.clearKnownHosts(),
              ),
              ],
            ),
          ),
          SettingsSection(
            title: l10n.settingsInlineSafetySection,
            child: SwitchListTile(
              key: const ValueKey('settings-dangerous-commands'),
              title: FoldedHelpTitle(setting: l10n.settingsInlineDangerousCommandProtection, help: l10n.settingsDangerousCommandDesc),
              secondary: const PhoneIconTile(LucideIcons.alertTriangle),
              value: ref.watch(dangerousCommandProtectionProvider),
              onChanged: (v) => ref.read(settingsUpdaterProvider).setDangerousCommandProtection(v),
            ),
          ),
          SettingsSection(
            title: l10n.settingsInlinePrivacySection,
            child: Column(
              children: [
                SwitchListTile(
                  key: const ValueKey('security-recording-mode'),
                  title: FoldedHelpTitle(setting: l10n.recModeName, help: l10n.recModeTooltipOff),
                  secondary: const PhoneIconTile(LucideIcons.video),
                  value: ref.watch(recordingModeProvider),
                  onChanged: (v) => ref.read(settingsUpdaterProvider).setRecordingMode(v),
                ),
                if (ref.watch(recordingModeProvider)) _recordingLevelTile(l10n),
              ],
            ),
          ),
        ],
      )),
    );
  }
}

extension on _SecuritySettingsScreenState {
  static const _timeoutChoices = [0, 1, 5, 10, 15, 30, -1];

  String _timeoutLabel(AppLocalizations l10n, int minutes) => switch (minutes) {
        0 => l10n.settingsInlineImmediately,
        < 0 => l10n.settingsInlineNever,
        _ => l10n.settingsInlineMinutesOption(minutes),
      };

  String _idleLabel(AppLocalizations l10n, int minutes) =>
      minutes == 0 ? l10n.secSetIdleLockOff : l10n.settingsInlineMinutesOption(minutes);

  Widget _autoLockTile(AppLocalizations l10n) {
    final timeout = ref.watch(autoLockTimeoutProvider).valueOrNull;
    return ListTile(
      key: const ValueKey('security-auto-lock'),
      leading: const PhoneIconTile(LucideIcons.timer),
      // What it does behind More, what it is set to in sight (4.0).
      title: FoldedHelpTitle(setting: l10n.settingsInlineAutoLock, help: l10n.settingsInlineAutoLockDesc),
      subtitle: timeout == null ? null : Text(_timeoutLabel(l10n, timeout)),
      trailing: const Icon(LucideIcons.chevronRight),
      onTap: () async {
        final picked = await _pickMinutes(
          title: l10n.settingsInlineAutoLock,
          choices: _timeoutChoices,
          current: timeout,
          label: (m) => _timeoutLabel(l10n, m),
        );
        if (picked == null) return;
        await ref.read(securityLockServiceProvider).setAutoLockTimeout(picked);
        ref.invalidate(autoLockTimeoutProvider);
      },
    );
  }

  /// Recording mode's level, Layout or Strict, as the Help page offers them.
  Widget _recordingLevelTile(AppLocalizations l10n) {
    final level = ref.watch(recordingRedactLevelProvider);
    String name(RedactLevel l) => l == RedactLevel.strict ? l10n.recModeLevelStrict : l10n.recModeLevelLayout;
    return ListTile(
      key: const ValueKey('security-recording-level'),
      leading: const PhoneIconTile(LucideIcons.eyeOff),
      // The level in sight, what it does behind More (4.0).
      title: FoldedHelpTitle(
        setting: l10n.recModeLevelLabel,
        help: level == RedactLevel.strict ? l10n.recModeLevelStrictDesc : l10n.recModeLevelLayoutDesc,
      ),
      subtitle: Text(name(level)),
      trailing: const Icon(LucideIcons.chevronRight),
      onTap: () async {
        final picked = await showSettingsChoice<RedactLevel>(
          context,
          title: l10n.recModeLevelLabel,
          icon: LucideIcons.eyeOff,
          current: level,
          choices: [for (final l in RedactLevel.values) (l, name(l))],
        );
        if (picked == null) return;
        await ref.read(settingsUpdaterProvider).setRecordingRedactLevel(picked.$1);
      },
    );
  }

  Widget _idleLockTile(AppLocalizations l10n) {
    final own = ref.watch(idleLockSettingProvider).valueOrNull ?? 0;
    final team = ref.watch(teamIdleLockMinutesProvider);
    // What it does behind More; what it is set to, and a team's rule, in
    // sight (4.0).
    final value = team == null ? _idleLabel(l10n, own) : '${_idleLabel(l10n, own)}\n${l10n.secSetIdleLockTeam(team)}';
    return ListTile(
      key: const ValueKey('security-idle-lock'),
      leading: const PhoneIconTile(LucideIcons.hourglass),
      title: FoldedHelpTitle(setting: l10n.secSetIdleLock, help: l10n.secSetIdleLockDesc),
      subtitle: Text(value),
      isThreeLine: team != null,
      trailing: const Icon(LucideIcons.chevronRight),
      onTap: () async {
        final picked = await _pickMinutes(
          title: l10n.secSetIdleLock,
          choices: kIdleLockChoices,
          current: own,
          label: (m) => _idleLabel(l10n, m),
        );
        if (picked == null) return;
        await ref.read(securityLockServiceProvider).setIdleLockMinutes(picked);
        ref.invalidate(idleLockSettingProvider);
      },
    );
  }

  /// A setting's icon tile, as faint as its words while it cannot be turned
  /// on (it stayed in the full accent beside grey words).
  Widget _tile(IconData icon, {required bool enabled}) =>
      Opacity(opacity: enabled ? 1 : 0.4, child: PhoneIconTile(icon));

  /// Why a setting cannot be turned on yet, under its words, at their
  /// indent (the card's padding, the tile and its gap).
  Widget _helper(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(60, 0, 12, 12),
        child: Text(text, style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4)),
      );

  /// A short list to choose from, in the app's sheet (its dialog on a
  /// computer), the one set checked.
  Future<int?> _pickMinutes({
    required String title,
    required List<int> choices,
    required int? current,
    required String Function(int minutes) label,
  }) async {
    final picked = await showSettingsChoice<int?>(
      context,
      title: title,
      icon: LucideIcons.timer,
      current: current,
      choices: [for (final c in choices) (c, label(c))],
    );
    return picked?.$1;
  }
}
