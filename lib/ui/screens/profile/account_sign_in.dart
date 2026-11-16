import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart' show SsoLookup;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/services/entitlement_diagnostics.dart' show decodeJwtPayload;
import 'package:zestssh/services/sign_in_code.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/sso_sign_in.dart';
import 'package:zestssh/ui/screens/profile/widgets/lockout_recovery_dialog.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/services/profiles/windows_keychain.dart' show KeychainFileFailed;

// Signing in from anywhere in the app (a new install did not say where to
// sign up or sign in; a guest joining
// a team was told "Sign in first" with nothing to press). The welcome screen,
// Join a team, Create a team and a guest's row at the bottom left sign in
// here, the way the account page does: a computer without Firebase (Windows,
// Linux and the Mac, whose build bundles no Firebase configuration: the
// two-step contract, section 6.7) in the browser, on zestssh.com, which comes
// back to the app; a phone and a tablet with Google, Apple, email, Microsoft
// or company sign-in. Each says what went wrong where it went wrong. (The
// Mac's place in [signInWaysHere] is only for a Mac build that one day
// bundles Firebase; passkeys would then need a way of their own there, as
// [passkeyWayProvider] says.)

/// The ways this device signs in itself, without the browser: false on a
/// computer without Firebase, where zestssh.com signs in for it.
bool get signsInOnDevice => debugSignsInOnDevice ?? AuthService.isFirebaseAvailable;

/// A test's word on [signsInOnDevice] (a phone's welcome, drawn on a
/// computer); null asks Firebase.
@visibleForTesting
bool? debugSignsInOnDevice;

/// A way to sign in on a device that signs in itself ([signsInOnDevice]).
enum SignInWay { google, apple, email, microsoft, company }

/// The ways this device offers, in the order shown: Apple first where it is
/// Apple's, Google first elsewhere.
List<SignInWay> signInWaysHere() => [
      if (Platform.isIOS || Platform.isMacOS) ...[SignInWay.apple, SignInWay.google] else SignInWay.google,
      SignInWay.email,
      if (kMicrosoftSignIn) SignInWay.microsoft,
      if (kOrchardsEnabled) SignInWay.company,
    ];

/// Signs this device in, [createAccount] starting at Create an account: in
/// the browser on a computer without Firebase, otherwise with the way the
/// person picks from a sheet. True once signed in (also when it already was).
///
/// A build with no account service (a community build: [zestHasCloud]) signs
/// nobody in: this, [showSignInWays], [signInWith] and [signInInBrowser] do
/// nothing there, and what offers them is not drawn.
Future<bool> signInFromAnywhere(BuildContext context, WidgetRef ref, {bool createAccount = false}) async {
  if (ref.read(isSignedInProvider)) return true;
  if (!zestHasCloud) return false;
  if (!signsInOnDevice) return signInInBrowser(context, ref, createAccount: createAccount);
  final way = await showSignInWays(context, createAccount: createAccount);
  if (way == null || !context.mounted) return false;
  return signInWith(context, ref, way, createAccount: createAccount);
}

/// The ways to sign in (a phone, a tablet): the one picked, or null.
/// The app's dialog (3.4), a phone's sheet: the ways are its choices, the
/// account's recovery the footer's side link and Cancel beside it (a sheet of
/// its own before, its link a button under the ways).
Future<SignInWay?> showSignInWays(BuildContext context, {bool createAccount = false}) {
  if (!zestHasCloud) return Future<SignInWay?>.value();
  final l10n = AppLocalizations.of(context)!;
  return showZestModal<SignInWay>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        key: const ValueKey('sign-in-ways'),
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.logIn,
        title: createAccount ? l10n.welcomeCreateAccount : l10n.profileSignIn,
        subtitle: l10n.profileSignInDesc,
        body: SignInWayButtons(onPick: (way) => Navigator.of(ctx).pop(way)),
        // Lost every second step and every recovery code: the account's
        // recovery (3.3, the two-step contract, section 6.5).
        tertiaryKey: const ValueKey('sign-in-recover-account'),
        tertiaryAction: createAccount
            ? null
            : (
                label: l10n.lockoutLink,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  if (context.mounted) unawaited(showLockoutRecovery(context));
                },
              ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(ctx).pop()),
      ),
    ),
  );
}

/// The buttons for [signInWaysHere], one under another; [onPick] is given the
/// one pressed. Null [onPick] shows them turned off (a sign-in running).
class SignInWayButtons extends StatelessWidget {
  const SignInWayButtons({super.key, required this.onPick, this.height = 48});

  final ValueChanged<SignInWay>? onPick;
  final double height;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ways = signInWaysHere();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, way) in ways.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          ButtonBox(
            height: height,
            child: OutlinedButton.icon(
              key: ValueKey('sign-in-way-${way.name}'),
              onPressed: onPick == null ? null : () => onPick!(way),
              icon: Icon(_icon(way), size: way == SignInWay.google ? 24 : 18),
              label: Text(signInWayLabel(way, l10n)),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: BorderSide(color: AppColors.divider),
              ),
            ),
          ),
        ],
      ],
    );
  }

  static IconData _icon(SignInWay way) => switch (way) {
        SignInWay.google => Icons.g_mobiledata,
        SignInWay.apple => Icons.apple,
        SignInWay.email => LucideIcons.atSign,
        SignInWay.microsoft => LucideIcons.building,
        SignInWay.company => LucideIcons.briefcase,
      };
}

/// What a way's button says.
String signInWayLabel(SignInWay way, AppLocalizations l10n) => switch (way) {
      SignInWay.google => l10n.profileContinueWithGoogle,
      SignInWay.apple => l10n.profileContinueWithApple,
      SignInWay.email => l10n.profileContinueWithEmail,
      SignInWay.microsoft => l10n.profileContinueWithMicrosoft,
      SignInWay.company => l10n.profileContinueWithSso,
    };

/// Signs in with [way] on this device: true once signed in. Email opens the
/// email screen ([createAccount]: at Create an account) and is signed in
/// when it closes with the device signed in.
Future<bool> signInWith(BuildContext context, WidgetRef ref, SignInWay way, {bool createAccount = false}) =>
    !zestHasCloud
        ? Future<bool>.value(false)
        : AwayForSignIn.during(() => _signInWith(context, ref, way, createAccount: createAccount));

Future<bool> _signInWith(BuildContext context, WidgetRef ref, SignInWay way, {bool createAccount = false}) async {
  if (!await _sessionsMayClose(context, ref) || !context.mounted) return false;
  switch (way) {
    case SignInWay.google:
      await _signInWithProvider(context, ref, kGoogleWay, (asker) => AuthService.signInWithGoogle(secondStep: asker.call));
    case SignInWay.apple:
      await _signInWithProvider(context, ref, kAppleWay, (asker) => AuthService.signInWithApple(secondStep: asker.call));
    case SignInWay.email:
      await context.push(Routes.emailAuth, extra: createAccount ? kEmailAuthCreate : null);
    case SignInWay.microsoft:
      await signInWithMicrosoft(context, ref);
    case SignInWay.company:
      await signInWithSso(context, ref);
  }
  return ref.read(isSignedInProvider);
}

/// On a computer a sign-in opens the account's own data, and what is open now
/// closes first: said, with how many, before anything is signed in.
Future<bool> _sessionsMayClose(BuildContext context, WidgetRef ref) async {
  final profiles = ref.read(profileControllerProvider);
  if (!profiles.on || profiles.openSessions == 0) return true;
  final l10n = AppLocalizations.of(context)!;
  // What closes, in its amber sentence (the whole dialog was yellow).
  final ok = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.profileSignIn,
    body: '',
    warning: l10n.signInSessionsClose(profiles.openSessions),
    confirmLabel: l10n.profileSignIn,
  );
  return ok == true;
}

/// What [Routes.emailAuth] is given to open at Create an account.
const kEmailAuthCreate = 'create';

/// Signs in with [way] (Google or Apple). An address that already has an
/// account that signs in another way gets [way] added to that account once
/// the person signed in to it (one account per email address); one ZestSSH
/// Cloud refuses for that reason signs out again and says so.
Future<void> _signInWithProvider(BuildContext context, WidgetRef ref, SsoLookup way,
    Future<Object?> Function(SecondStepAsker asker) signIn) async {
  final l10n = AppLocalizations.of(context)!;
  final asker = SecondStepAsker(context);
  try {
    final result = await signIn(asker);
    if (result == null || !context.mounted) return;
    if (await refusedForAddress(context, ref) || !context.mounted) return;
    if (await profileNotOpened(context, ref) || !context.mounted) return;
    if (asker.usedRecoveryCode && context.mounted) {
      showTopSnackBar(context, l10n.twoStepTurnedOffNotice, duration: const Duration(seconds: 8));
    }
  } on SsoAccountExists catch (pending) {
    if (context.mounted) await addSignInToAccount(context, ref, pending, way);
  } on TwoStepTurnedOff {
    if (context.mounted) {
      showTopSnackBar(context, l10n.twoStepTurnedOffSignInAgain, duration: const Duration(seconds: 8));
    }
  } catch (e) {
    if (context.mounted) {
      showTopSnackBar(context, l10n.profileSignInFailedWith(way.displayName), isError: true, details: '$e');
    }
  }
}

/// A test's stand-in for the browser.
@visibleForTesting
Future<BrowserSession> Function({bool create})? debugBrowserSession;

/// A computer's sign-in: zestssh.com's sign-in page in the default browser
/// ([createAccount]: at Create an account), which comes back to a server on
/// 127.0.0.1 with a one-time code this app trades for the session (see
/// [DesktopBrowserSignIn.session]). True once signed in; what went wrong is
/// said ([context] still mounted). With [confirm] the page says it is that account's
/// to confirm, and with [onlyFor] a sign-in that comes back as anyone else changes
/// nothing: picking one account never opens another. [said] is what an "Add account"
/// was told of this sign-in, and it goes with this one.
Future<bool> signInInBrowser(
  BuildContext context,
  WidgetRef ref, {
  bool createAccount = false,
  BrowserConfirm? confirm,
  String? onlyFor,
  String? onlyForName,
  SignInSaid said = SignInSaid.nothing,
}) async {
  if (!zestHasCloud) return false;
  final l10n = AppLocalizations.of(context)!;
  if (!await _sessionsMayClose(context, ref)) return false;
  if (!context.mounted) return false;
  try {
    final test = debugBrowserSession;
    final session = await (test != null
        ? test(create: createAccount)
        : DesktopBrowserSignIn.session(create: createAccount, confirm: confirm));
    final profiles = ref.read(profileControllerProvider);
    if (onlyFor != null) {
      final came = (session.uid != null && session.uid!.isNotEmpty) ? session.uid : sessionAccountUid(session.token);
      if (came != onlyFor) {
        // Not the account that was picked: that session is of no use here.
        unawaited(profiles.endSessionOf(session.token));
        if (context.mounted) {
          showTopSnackBar(
            context,
            ErrorCodes.withCode(l10n.accountSwitchWrongAccount(onlyForName ?? ''), ErrorCodes.accountSwitchFailed),
            isError: true,
            duration: const Duration(seconds: 8),
          );
        }
        return false;
      }
    }
    // A profile that could not open says so and stays where it is: Try again is
    // this same sign-in, for ZestSSH Cloud's secret wants one from the last ten
    // minutes, and nothing else happens until it works or the person leaves it.
    while (true) {
      try {
        await storeDesktopSession(ref, session, said: said);
        break;
      } on ProfileCannotOpen catch (e) {
        AppLogger.warning('Desktop sign-in: ${e.code} (${e.cause == null ? 'no cause' : errorKind(e.cause!)})');
        // One more account than a computer keeps: no Try again changes that, and the
        // session made for it goes.
        final full = e.code == 'profile-too-many-accounts';
        if (full) unawaited(profiles.endSessionOf(session.token));
        if (!context.mounted || !await sayProfileCannotOpen(context, e, canRetry: !full)) return false;
      }
    }
    if (context.mounted) {
      // Masked in recording mode: a second account's sign-in comes with sessions and
      // screens in the way as often as the first's.
      showTopSnackBar(context, l10n.profileSignedInAs(Redactable.account(session.email ?? 'user').displayIn(ref)), isSuccess: true);
    }
    return true;
  } on BrowserSignInCancelled {
    // Cancelled while it waited: nothing to say.
    return false;
  } on TimeoutException {
    if (context.mounted) {
      showTopSnackBar(context, l10n.profileSignInTimedOut, duration: const Duration(seconds: 6));
    }
  } on SignInCodeRefused catch (e) {
    // The code ran out (two minutes), was used, or was not this app's.
    AppLogger.warning('Desktop sign-in: $e');
    if (context.mounted) {
      showTopSnackBar(context, l10n.profileSignInTimedOut, isError: true, duration: const Duration(seconds: 8), details: '$e');
    }
  } on AuthCallbackError catch (e) {
    // The browser came back with a bad payload (no token, a state that does
    // not match): said as it is, so it is not taken for the app's fault.
    AppLogger.warning('Desktop sign-in: ${e.kind.name}');
    if (context.mounted) {
      showTopSnackBar(context, e.userMessage, isError: true, duration: const Duration(seconds: 8), details: '$e');
    }
  } on NoSignInPort catch (e) {
    if (context.mounted) {
      showTopSnackBar(context, ErrorCodes.withCode(l10n.signInNoPort, ErrorCodes.signInNoPort), isError: true, details: '$e');
    }
    return false;
  } on SessionNotStored catch (e) {
    AppLogger.error('Failed to store session token', e.cause);
    if (context.mounted) {
      showTopSnackBar(
        context,
        e.cause is KeychainFileFailed
            ? ErrorCodes.withCode(l10n.keychainFileFailed, ErrorCodes.keychainFile)
            : l10n.profileSignInFailed(''),
        isError: true,
        details: e.cause is KeychainFileFailed ? '${e.cause}' : null,
      );
    }
  } catch (e) {
    AppLogger.error('Desktop sign-in failed', e);
    if (context.mounted) {
      showTopSnackBar(context, l10n.profileCouldNotOpenBrowser, isError: true, details: '$e');
    }
  }
  return false;
}

/// A sign-in whose account's profile could not open: said with its code and
/// what to do, and the app stays where it is. Try again is the same sign-in
/// again: a secret ZestSSH Cloud holds wants a sign-in from the last ten
/// minutes, so nothing short of that would do once they have passed.
Future<bool> sayProfileCannotOpen(BuildContext context, ProfileCannotOpen e, {bool canRetry = false}) async {
  final l10n = AppLocalizations.of(context)!;
  // What went wrong, said: a notice (it was yellow), closed by Close (it
  // said OK).
  final again = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.info,
    title: e.code == 'profile-too-many-accounts' ? l10n.accountsFullTitle : l10n.profileCannotOpenTitle,
    body: profileCannotOpenWords(l10n, e),
    confirmLabel: canRetry ? l10n.retry : l10n.close,
    showCancel: canRetry,
  );
  return canRetry && again == true;
}

/// The session could not be kept on this device ([cause]).
class SessionNotStored implements Exception, HasTypeName {
  const SessionNotStored(this.cause);
  final Object cause;
  @override
  String get typeName => 'SessionNotStored';
  @override
  String toString() => 'SessionNotStored($cause)';
}

/// Keeps a computer's [session] and signs the app in with it: the token in
/// secure storage with the account's email, name, id and picture (restored at
/// the next start, app.dart), then the account's purchases read again. Throws
/// [SessionNotStored] when secure storage refuses.
Future<void> storeDesktopSession(WidgetRef ref, BrowserSession session, {SignInSaid? said}) async {
  final token = session.token;
  // The callback's id, else the token's own (an older website sent none).
  final uid = (session.uid != null && session.uid!.isNotEmpty) ? session.uid : sessionAccountUid(token);
  // On a computer the account's profile opens first, or a new one is made, and
  // the session is written into it only at the end. ZestSSH Cloud took this
  // sign-in or there would be no session here. An account with no id is never
  // the old "unknown account" again: nothing is made for it.
  final controller = ref.read(profileControllerProvider);
  if (controller.on) {
    if (uid == null || uid.isEmpty) throw const SessionNotStored('The session did not say its account');
    await controller.openForAccount(uid: uid, label: session.email, bearer: token, said: said);
  }
  final String? photoUrl;
  String? replaced;
  try {
    // The app-wide provider, for the same platform options everywhere
    // (EncryptedSharedPreferences on Android, and so on).
    final storage = ref.read(secureStorageProvider);
    // An account signed in here already has a session in its profile, and this new one
    // takes its place (asked of someone else's at a switch).
    if (controller.on) replaced = await AccountSecret.sessionToken.read(storage);
    await AccountSecret.sessionToken.write(storage, token);
    if (session.email != null) await storage.write(key: 'session_email', value: session.email);
    if (session.name != null) await storage.write(key: 'session_name', value: session.name);
    // The Firebase UID (= RevenueCat app user id), shown as the Account ID.
    if (uid != null && uid.isNotEmpty) await storage.write(key: 'session_uid', value: uid);
    // The picture: the callback's, else a picture claim in the session JWT.
    final picture = session.picture;
    photoUrl = (picture != null && picture.isNotEmpty) ? picture : avatarUrlFromToken(token);
    if (photoUrl != null) {
      await storage.write(key: 'session_photo', value: photoUrl);
    } else {
      await storage.delete(key: 'session_photo');
    }
  } catch (e) {
    await controller.sessionNotKept().catchError((Object _) {});
    throw SessionNotStored(e);
  }
  AppLogger.info('Desktop sign-in completed');
  ref.read(desktopSessionProvider.notifier).state = UserProfile(
    uid: (uid != null && uid.isNotEmpty) ? uid : 'desktop-session',
    email: session.email,
    displayName: session.name,
    photoUrl: photoUrl,
  );
  // The locked copy is told to ZestSSH Cloud in here, once the session is written,
  // and it is waited for: nothing else writes to the keychain meanwhile.
  await controller.sessionKept();
  // Each sign-in is a session of its own at ZestSSH Cloud: the one replaced would stay
  // on the account's device list for nothing.
  if (replaced != null && sessionTokenId(replaced) != null && sessionTokenId(replaced) != sessionTokenId(token)) {
    unawaited(controller.endSessionOf(replaced));
  }
  // The purchases, read at the start when there was no token yet: without
  // this the app would show Free until the next start.
  unawaited(ref.read(isProProvider.notifier).refresh());
  unawaited(ref.read(isCloudSyncProvider.notifier).refresh());
}

/// The session a session token is at ZestSSH Cloud (its `sid` claim), or null.
String? sessionTokenId(String token) {
  try {
    final sid = decodeJwtPayload(token)?['sid'];
    return sid is String && sid.isNotEmpty ? sid : null;
  } catch (_) {
    return null;
  }
}

/// A picture's address from a `picture`/`photo`/`avatar` claim in the session
/// JWT, if ZestSSH Cloud puts one there; null on anything else.
String? avatarUrlFromToken(String token) {
  try {
    final claims = decodeJwtPayload(token);
    if (claims == null) return null;
    for (final key in const ['picture', 'photo', 'photoURL', 'avatar', 'avatar_url']) {
      final v = claims[key];
      if (v is String && v.startsWith('http')) return v;
    }
  } catch (_) {
    // A malformed token: no picture.
  }
  return null;
}
