import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

// Nothing ever suggested the app lock, and it is off by default on phones that
// hold SSH keys (found in a security review): asked once, after the
// first private key or saved password. It stays the person's choice. Computers
// are asked too (4.0, platform parity gap 10), at the same moment and once,
// in the computer's dialog, naming Windows Hello or Touch ID as the lock
// screen does.

/// Whether the question may be asked at all: on every device the app runs on,
/// but not under `flutter test`, where the editors save with nothing to answer
/// it; a test of the question turns it on.
final appLockOfferEnabledProvider = Provider<bool>((ref) => !Platform.environment.containsKey('FLUTTER_TEST'));

/// After a private key or a password was saved: asks, once ever on this
/// device, to turn the app lock on, and goes on to choosing its PIN. "Not
/// now" is the answer for good: it is not asked again.
Future<void> maybeOfferAppLock(BuildContext context, WidgetRef ref) async {
  if (!ref.read(appLockOfferEnabledProvider)) return;
  final settings = ref.read(settingsServiceProvider);
  if (settings.appLockOffered) return;
  await settings.setAppLockOffered();
  if (settings.securityLockEnabled || !context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final words = appLockOfferWords(l10n);
  final yes = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.info,
    icon: LucideIcons.lock,
    title: words.title,
    body: words.body,
    confirmLabel: l10n.appLockOfferTurnOn,
    cancelLabel: l10n.notNow,
  );
  if (yes == true && context.mounted) await PinSetupScreen.showAdaptive(context);
}

/// The question's title and body on [platform] (the one the app runs on
/// unless told): a phone's, or a computer's, which names what the lock takes
/// besides its PIN there (Windows Hello, Touch ID; on Linux the PIN alone).
({String title, String body}) appLockOfferWords(AppLocalizations l10n, [TargetPlatform? platform]) =>
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.windows => (
          title: l10n.appLockOfferTitleComputer,
          body: l10n.appLockOfferBodyComputer(l10n.pinSetupBiometricFactorWindowsHello),
        ),
      TargetPlatform.macOS => (
          title: l10n.appLockOfferTitleComputer,
          body: l10n.appLockOfferBodyComputer(l10n.pinSetupBiometricFactorTouchId),
        ),
      TargetPlatform.linux => (title: l10n.appLockOfferTitleComputer, body: l10n.appLockOfferBodyComputerPin),
      _ => (title: l10n.appLockOfferTitle, body: l10n.appLockOfferBody),
    };
