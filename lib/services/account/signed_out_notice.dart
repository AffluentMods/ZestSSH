import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/device_sessions.dart';

/// What the notice says when ZestSSH Cloud signed this device out, by the
/// [reason] it gave (from a security review; the two-step
/// contract, section 6.1): two-step sign-in was turned on, a way to pass it
/// was removed, it was turned off, a recovery code was used, the account was
/// recovered, its password or sign-in changed, or the company sign-in it
/// used is gone; else that another device did it.
({String title, String body}) signedOutNotice(AppLocalizations l10n, String? reason) => switch (reason) {
      kSignedOutForTwoStep => (title: l10n.devicesSignedOutTwoStepTitle, body: l10n.devicesSignedOutTwoStepBody),
      kSignedOutFactorRemoved => (title: l10n.signedOutFactorRemovedTitle, body: l10n.signedOutFactorRemovedBody),
      kSignedOutTwoStepOff => (title: l10n.signedOutTwoStepOffTitle, body: l10n.signedOutTwoStepOffBody),
      kSignedOutRecoveryCodeUsed => (title: l10n.signedOutRecoveryCodeTitle, body: l10n.signedOutRecoveryCodeBody),
      kSignedOutAccountRecovered => (title: l10n.signedOutRecoveredTitle, body: l10n.signedOutRecoveredBody),
      kSignedOutPasswordChanged => (title: l10n.signedOutPasswordChangedTitle, body: l10n.signedOutPasswordChangedBody),
      kSignedOutSsoRemoved => (title: l10n.devicesSignedOutSsoRemovedTitle, body: l10n.devicesSignedOutSsoRemovedBody),
      _ => (title: l10n.devicesSignedOutElsewhereTitle, body: l10n.devicesSignedOutElsewhereBody),
    };
