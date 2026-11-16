import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/services/account/sign_in_ways.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/widgets/sign_in_again.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/account/sso_gate_refusal.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show sayProfileCannotOpen;

// "Sign in with SSO" where the app signs in with Firebase itself: phones,
// and a Mac signed in through Firebase (3.0). Desktop signs
// in on the website, which has the same button. The work address finds its
// company's sign-in (only its domain is sent), then the company's sign-in
// page opens in a browser tab. An address that already has an account
// signs in the usual way first, and the company sign-in is added to that
// account, so their Tree stays theirs and a company can never take an
// account over by its address alone.

/// ZestSSH Cloud's refusal of this device's company sign-in, or null when it
/// takes it: a sign-in through an Orchard's provider counts only while the
/// provider is on and only for the Orchard's proven domains.
Future<String?> ssoRefusal() async {
  final token = await AuthService.getIdToken();
  if (token == null) return null;
  try {
    final r = await PinnedHttpClient.client
        .get(Uri.parse('${OrchardsApi.defaultBase}/sessions'), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 403) return null;
    final body = jsonDecode(r.body);
    final code = body is Map ? body['code'] : null;
    return code is String && code.startsWith('sso-') ? code : null;
  } catch (e) {
    // Offline: the app finds out on its next call.
    AppLogger.warning('Company sign-in: could not be checked ($e)');
    return null;
  }
}

String _refusalText(String code, AppLocalizations l10n) => switch (code) {
      'sso-domain-mismatch' => l10n.ssoSignInOutside,
      // Its team was deleted, or an owner turned it off.
      'sso-removed' => l10n.devicesSignedOutSsoRemovedBody,
      _ => l10n.ssoSignInNotOn,
    };

/// What to tell the person when a company sign-in through Firebase failed
/// with [e]: the sign-in gate's refusal in its own words (3.0 backend
/// review, B1), anything else as a sign-in that did not complete.
String ssoSignInFailureText(FirebaseAuthException e, AppLocalizations l10n) => switch (ssoGateRefusalOf(e)) {
      SsoGateRefusal.outsideDomains => l10n.ssoSignInOutside,
      SsoGateRefusal.notChecked => l10n.ssoSignInGateUnreachable,
      null => l10n.ssoSignInFailed,
    };

/// After a sign-in on this device: ZestSSH Cloud takes no account whose
/// address belongs to another ZestSSH account (one account per email
/// address, 3.0). Then this device signs out again and says how to get into
/// the account the address has. True when it was refused. Not answered in a
/// few seconds (offline), it is let be: the app finds out on its next call.
Future<bool> refusedForAddress(
  BuildContext context,
  WidgetRef ref, {
  SignInWaysApi? api,
  String? email,
  Future<void> Function()? signOut,
}) async {
  final address = email ?? AuthService.currentUser?.email ?? '';
  try {
    await (api ?? SignInWaysApi(bearer: accountBearer)).load().timeout(const Duration(seconds: 8));
    return false;
  } on AddressHasAccount {
    await (signOut ?? () => signOutAccount(ref, lock: false))();
    if (context.mounted) await showAddressHasAccount(context, address);
    return true;
  } catch (e) {
    AppLogger.warning('Sign-in: the account could not be checked ($e)');
    return false;
  }
}

/// The end of a sign-in on a Mac, whose checks passed: the account's profile
/// opens only now, so a sign-in they refuse has made nothing on the device.
/// True where it could not open: Firebase signed out again, and the person was
/// told. (A later stage has the Mac trade Firebase for a session as the other
/// computers work.)
Future<bool> profileNotOpened(BuildContext context, WidgetRef ref) async {
  final failed = await ref.read(profileControllerProvider).afterFirebaseSignIn();
  if (failed == null) return false;
  if (context.mounted) await sayProfileCannotOpen(context, failed);
  return true;
}

/// Says that [email] already has an account that signs in another way.
Future<void> showAddressHasAccount(BuildContext context, String email) async {
  final l10n = AppLocalizations.of(context)!;
  await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.info,
    title: l10n.signInAddressHasAccountTitle,
    // The address masked in recording mode, as everywhere else (it was shown
    // as it is, on a recording of the screen too).
    body: l10n.signInAddressHasAccountBody(Redactable.account(email).display),
    showCancel: false,
    // What it is, not OK (the dialog rules, 3.4).
    confirmLabel: l10n.desktopGotIt,
  );
}

/// Signs in through the company sign-in the person's work address finds.
Future<void> signInWithSso(BuildContext context, WidgetRef ref) =>
    AwayForSignIn.during(() => _signInWithSso(context, ref));

Future<void> _signInWithSso(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  SsoLookup? found;
  final email = await showZestInputDialog(
    context: context,
    title: l10n.ssoSignInTitle,
    subtitle: l10n.ssoSignInBody,
    icon: LucideIcons.briefcase,
    fieldLabel: l10n.ssoSignInWorkEmail,
    hintText: 'name@company.com',
    confirmLabel: l10n.ssoSignInFind,
    validator: (v) => workAddressDomain(v) == null ? l10n.ssoSignInNotAddress : null,
    onConfirm: (v) async {
      final domain = workAddressDomain(v)!;
      try {
        found = await OrchardSsoApi.lookup(domain);
      } catch (e) {
        AppLogger.warning('Company sign-in: lookup failed ($e)');
        return cloudStopped(l10n, e) ?? l10n.ssoSignInLookupFailed;
      }
      return found == null ? l10n.ssoSignInNotFound(domain) : null;
    },
  );
  final company = found;
  if (email == null || company == null || !context.mounted) return;
  final asker = SecondStepAsker(context);
  try {
    final result = await AuthService.signInWithSso(company.providerId, email: email.trim(), secondStep: asker.call);
    if (result == null || !context.mounted) return;
    await _settle(context, ref, company);
  } on SsoAccountExists catch (pending) {
    if (context.mounted) await addSignInToAccount(context, ref, pending, company);
  } on TwoStepTurnedOff {
    if (context.mounted) showTopSnackBar(context, l10n.twoStepTurnedOffSignInAgain, duration: const Duration(seconds: 8));
  } on FirebaseAuthException catch (e) {
    AppLogger.warning('Company sign-in: ${e.code}');
    if (context.mounted) showTopSnackBar(context, ssoSignInFailureText(e, l10n), isError: true, details: '$e');
  }
}

/// Microsoft, Google and Apple as ways to add to an account, like a company
/// sign-in.
const _microsoft = SsoLookup(providerId: 'microsoft.com', displayName: 'Microsoft');
const kGoogleWay = SsoLookup(providerId: 'google.com', displayName: 'Google');
const kAppleWay = SsoLookup(providerId: 'apple.com', displayName: 'Apple');

/// Whether this build offers Sign in with Microsoft (3.0):
/// on once the Entra app registration is in Firebase.
const bool kMicrosoftSignIn = bool.fromEnvironment('ZEST_MICROSOFT');

/// Signs in with Microsoft; an address that already has an account adds
/// Microsoft to it after signing in the usual way.
Future<void> signInWithMicrosoft(BuildContext context, WidgetRef ref) =>
    AwayForSignIn.during(() => _signInWithMicrosoft(context, ref));

Future<void> _signInWithMicrosoft(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final asker = SecondStepAsker(context);
  try {
    final result = await AuthService.signInWithMicrosoft(secondStep: asker.call);
    if (result == null || !context.mounted) return;
    if (await refusedForAddress(context, ref) || !context.mounted) return;
    if (await profileNotOpened(context, ref) || !context.mounted) return;
    showTopSnackBar(context, l10n.ssoSignInDone(_microsoft.displayName), isSuccess: true);
  } on SsoAccountExists catch (pending) {
    if (context.mounted) await addSignInToAccount(context, ref, pending, _microsoft);
  } on TwoStepTurnedOff {
    if (context.mounted) showTopSnackBar(context, l10n.twoStepTurnedOffSignInAgain, duration: const Duration(seconds: 8));
  } on FirebaseAuthException catch (e) {
    AppLogger.warning('Microsoft sign-in: ${e.code}');
    if (!context.mounted) return;
    showTopSnackBar(context, e.code == 'operation-not-allowed' ? l10n.microsoftSignInOff : l10n.ssoSignInFailed,
        isError: true, details: '$e');
  }
}

/// After a company sign-in: ZestSSH Cloud must take it, or this device signs
/// out again and says why.
Future<void> _settle(BuildContext context, WidgetRef ref, SsoLookup company) async {
  final l10n = AppLocalizations.of(context)!;
  if (await refusedForAddress(context, ref) || !context.mounted) return;
  final refused = await ssoRefusal();
  if (!context.mounted) return;
  if (refused != null) {
    await signOutAccount(ref, lock: false);
    if (context.mounted) showTopSnackBar(context, _refusalText(refused, l10n), isError: true);
    return;
  }
  if (await profileNotOpened(context, ref) || !context.mounted) return;
  showTopSnackBar(context, l10n.ssoSignInDone(company.displayName), isSuccess: true);
}

/// The address has an account that signs in another way: the person signs
/// in to it that way, and the way they tried ([company]: a company sign-in,
/// Microsoft, Google or Apple) is added to it. One address is one account.
Future<void> addSignInToAccount(BuildContext context, WidgetRef ref, SsoAccountExists pending, SsoLookup company) async {
  final l10n = AppLocalizations.of(context)!;
  // The ways as a choice, rows that each sign in (they were buttons in the
  // body; the dialog rules, 3.4).
  final way = await showZestChoice<String>(
    context,
    icon: LucideIcons.userCheck,
    title: l10n.ssoSignInExistsTitle,
    subtitle: l10n.ssoSignInExistsBody(pending.email, company.displayName),
    choices: _usualWays(l10n, tried: company.providerId),
  );
  if (way == null || !context.mounted) return;
  final asker = SecondStepAsker(context);
  try {
    final Object? signedIn;
    if (way == 'google') {
      signedIn = await AuthService.signInWithGoogle(secondStep: asker.call);
    } else if (way == 'apple') {
      signedIn = await AuthService.signInWithApple(secondStep: asker.call);
    } else if (way == 'microsoft') {
      signedIn = await AuthService.signInWithMicrosoft(secondStep: asker.call);
    } else {
      signedIn = await _withPassword(context, pending.email, asker);
    }
    if (signedIn == null || !context.mounted) return;
    final added = await AuthService.addSsoToAccount(pending, company.providerId, secondStep: asker.call);
    if (!context.mounted) return;
    if (added == null || !isOrchardSsoProvider(company.providerId)) {
      // Added (a company sign-in: though this session is not through it
      // yet). Google, Apple and Microsoft are simply ways in from now on.
      showTopSnackBar(context, l10n.ssoSignInAdded(company.displayName), isSuccess: true);
      return;
    }
    await _settle(context, ref, company);
  } on FirebaseAuthException catch (e) {
    AppLogger.warning('Company sign-in: adding it failed (${e.code})');
    if (!context.mounted) return;
    if (e.code == 'user-mismatch') {
      await signOutAccount(ref, lock: false);
      if (context.mounted) showTopSnackBar(context, l10n.ssoSignInWrongAccount(pending.email), isError: true, details: '$e');
      return;
    }
    showTopSnackBar(context, ssoSignInFailureText(e, l10n), isError: true, details: '$e');
  } on TwoStepTurnedOff {
    if (context.mounted) showTopSnackBar(context, l10n.twoStepTurnedOffSignInAgain, duration: const Duration(seconds: 8));
  }
}

Future<Object?> _withPassword(BuildContext context, String email, SecondStepAsker asker) async {
  final l10n = AppLocalizations.of(context)!;
  final password = await showZestInputDialog(
    context: context,
    title: l10n.ssoSignInPasswordTitle,
    subtitle: email,
    icon: LucideIcons.keyRound,
    fieldLabel: l10n.ssoSignInPassword,
    obscureText: true,
    confirmLabel: l10n.profileSignIn,
  );
  if (password == null || password.isEmpty) return null;
  return AuthService.signInWithEmail(email, password, secondStep: asker.call);
}

/// The account's usual ways in, but the one that was [tried].
List<ZestChoice<String>> _usualWays(AppLocalizations l10n, {required String tried}) {
  ZestChoice<String> way(String value, IconData icon, String label) =>
      ZestChoice(value: value, icon: icon, label: label, key: ValueKey('sso-usual-$value'));
  return [
    if (tried != kGoogleWay.providerId) way('google', Icons.g_mobiledata, l10n.profileContinueWithGoogle),
    if ((Platform.isIOS || Platform.isMacOS) && tried != kAppleWay.providerId)
      way('apple', Icons.apple, l10n.profileContinueWithApple),
    if (kMicrosoftSignIn && tried != _microsoft.providerId)
      way('microsoft', LucideIcons.building, l10n.profileContinueWithMicrosoft),
    way('email', LucideIcons.atSign, l10n.profileContinueWithEmail),
  ];
}

/// For a member an Orchard's rule "Sign in with SSO" holds back: signs this
/// device in through the company sign-in their address finds. Phones add
/// it to the account when needed and sign in through it; desktop signs in
/// again on the website, at "Sign in with SSO". True when it happened.
Future<bool> signInThroughCompany(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  if (AuthService.currentUser == null) {
    return refreshSignIn(context, ref, wrongAccount: l10n.orchardSignInWrongAccount, sso: true);
  }
  final domain = workAddressDomain(AuthService.currentUser?.email ?? '');
  SsoLookup? company;
  try {
    company = domain == null ? null : await OrchardSsoApi.lookup(domain);
  } catch (e) {
    AppLogger.warning('Company sign-in: lookup failed ($e)');
    if (context.mounted) showTopSnackBar(context, cloudStopped(l10n, e) ?? l10n.ssoSignInLookupFailed, isError: true, details: '$e');
    return false;
  }
  if (!context.mounted) return false;
  if (company == null) {
    showTopSnackBar(context, l10n.ssoSignInNotFound(domain ?? '?'), isError: true);
    return false;
  }
  try {
    final done = await AuthService.switchToSso(company.providerId, secondStep: SecondStepAsker(context).call);
    if (!done) return false;
    await ref.read(orchardSyncSchedulerProvider).syncAll();
    return true;
  } on FirebaseAuthException catch (e) {
    AppLogger.warning('Company sign-in: switching failed (${e.code})');
    if (context.mounted) showTopSnackBar(context, ssoSignInFailureText(e, l10n), isError: true, details: '$e');
    return false;
  }
}
