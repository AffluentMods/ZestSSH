import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardServiceProvider;
import 'package:zestssh/features/orchards/orchard_service.dart' show OrchardDevices;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/account_deletion_flow.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/services/desktop_auth_server.dart' show BrowserSignInCancelled;
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

/// Signing in again, for the few actions that need a sign-in from the last
/// few minutes: deleting the account, replacing its keys, changing where it
/// is signed in, and suspending or removing someone from an Orchard. The
/// provider's own sign-in or the password on phones (and a Mac signed in
/// through Firebase), the browser on desktop, with the second step when the
/// account has one.

/// Signs in again. Null when the person backs out; a [FreshSignIn] with an
/// empty uid when they picked another account. [sso]: the browser opens at
/// "Sign in with SSO" (a desktop session that came through a company
/// sign-in; phones sign in again the way they signed in).
Future<FreshSignIn?> signInAgain(BuildContext context, {bool sso = false, BrowserConfirm? confirm}) =>
    AwayForSignIn.during(() => _signInAgain(context, sso: sso, confirm: confirm));

Future<FreshSignIn?> _signInAgain(BuildContext context, {bool sso = false, BrowserConfirm? confirm}) async {
  if (AuthService.currentUser == null) {
    try {
      final result = await DesktopBrowserSignIn.run(sso: sso, confirm: confirm);
      return FreshSignIn(token: result.token, uid: result.uid, email: result.email);
    } on BrowserSignInCancelled {
      // Cancelled while it waited: backed out.
      return null;
    }
  }
  try {
    final token = await AuthService.signInAgain(
      askPassword: (email) => _askAccountPassword(context, email),
      secondStep: SecondStepAsker(context).call,
    );
    if (token == null) return null;
    final user = AuthService.currentUser!;
    return FreshSignIn(token: token, uid: user.uid, email: user.email ?? '');
  } on FirebaseAuthException catch (e) {
    // They picked a different account than the one signed in here.
    if (e.code == 'user-mismatch') {
      return const FreshSignIn(token: '', uid: '');
    }
    rethrow;
  }
}

/// Whether [fresh] is [account] signed in again. A desktop session saved
/// before account ids were is matched by its address.
bool isSameAccount(UserProfile account, FreshSignIn fresh) {
  if (fresh.uid.isEmpty) return false;
  if (account.uid == 'desktop-session') {
    final email = account.email?.trim().toLowerCase() ?? '';
    return email.isNotEmpty && email == fresh.email.trim().toLowerCase();
  }
  return fresh.uid == account.uid;
}

/// Signs the person in again so this device's sign-in is recent. On desktop
/// the browser brings a new session: this device switches to it and signs
/// the old one out, so it stays one entry in the list. False when it did
/// not happen (they backed out, picked another account, or it failed); they
/// have been told. [wrongAccount] is what they are told when they picked
/// another account. [sso]: on desktop the browser opens at "Sign in with
/// SSO" (it does anyway when this session came through a company sign-in).
Future<bool> refreshSignIn(BuildContext context, WidgetRef ref, {String? wrongAccount, bool sso = false}) async {
  final l10n = AppLocalizations.of(context)!;
  final account = ref.read(currentUserProvider);
  if (account == null) return false;
  final session =
      AuthService.currentUser == null ? await AccountSecret.sessionToken.read(ref.read(secureStorageProvider)) : null;
  final throughSso = AuthService.currentUser == null && (sso || sessionSsoProvider(session) != null);
  if (!context.mounted) return false;
  // The browser's page says what it is for, and fills the address in (security
  // review).
  final address = account.email?.trim() ?? '';
  final confirm = address.isEmpty ? null : BrowserConfirm(address, way: sessionSignInWay(session));
  final FreshSignIn? fresh;
  try {
    fresh = await signInAgain(context, sso: throughSso, confirm: confirm);
  } on TwoStepTurnedOff {
    // A recovery code turned two-step sign-in off mid-confirmation.
    if (context.mounted) {
      await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.info,
        title: l10n.accountTwoStep,
        body: l10n.twoStepTurnedOffSignInAgain,
        showCancel: false,
        // What it is, not OK (the dialog rules, 3.4).
        confirmLabel: l10n.desktopGotIt,
      );
    }
    return false;
  } on NoWayHere {
    // The account's only way in is Apple's own, away from Apple's devices.
    if (context.mounted) {
      await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.info,
        title: l10n.devicesSignInFailed,
        body: l10n.signInAgainNoWayHere,
        showCancel: false,
        confirmLabel: l10n.desktopGotIt,
      );
    }
    return false;
  } catch (e) {
    AppLogger.warning('Signing in again failed: $e');
    if (context.mounted) {
      showTopSnackBar(context, l10n.devicesSignInFailed, isError: true, details: '$e');
    }
    return false;
  }
  if (fresh == null || !context.mounted) return false;
  final browser = AuthService.currentUser == null;
  if (!isSameAccount(account, fresh)) {
    showTopSnackBar(context, wrongAccount ?? l10n.devicesWrongAccount, isError: true);
    // A browser sign-in to another account left a session behind.
    if (browser && fresh.token.isNotEmpty) {
      unawaited(() async {
        try {
          final other = DeviceSessionsApi(bearer: () async => fresh!.token);
          final id = await other.current();
          if (id != null) await other.signOut(id);
        } catch (_) {
          // It expires on its own.
        }
      }());
    }
    return false;
  }
  if (browser) {
    final devices = ref.read(deviceSessionServiceProvider);
    String? oldId;
    try {
      oldId = await devices.api.current();
    } catch (_) {
      oldId = null;
    }
    await AccountSecret.sessionToken.write(ref.read(secureStorageProvider), fresh.token);
    if (oldId != null) {
      try {
        await devices.api.signOut(oldId);
      } catch (e) {
        AppLogger.warning('Signing out the previous session failed: $e');
      }
    }
    unawaited(devices.ensure());
  }
  // An Orchard that lets in approved devices only knows a sign-in by the
  // device it said it is (3.0): a new one says so before whatever
  // the person signed in again for is tried.
  await ref.read(orchardServiceProvider).signedInAgain();
  return true;
}

/// The password for [email], to confirm it is them: a question in plain
/// colours with words of its own (it borrowed account deletion's red,
/// found in a security review).
Future<String?> _askAccountPassword(BuildContext context, String email) {
  final l10n = AppLocalizations.of(context)!;
  return showZestInputDialog(
    context: context,
    title: l10n.stepUpTitle,
    subtitle: l10n.signInAgainPasswordFor(email),
    icon: LucideIcons.lock,
    tone: ZestDialogTone.neutral,
    fieldLabel: l10n.identityPassword,
    obscureText: true,
    confirmLabel: l10n.profileContinue,
  );
}
