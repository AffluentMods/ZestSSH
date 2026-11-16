import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/account/passkey_step_up.dart';
import 'package:zestssh/services/account/recovery_proof.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart' show sessionAccountUid;
import 'package:zestssh/services/passkeys/passkey_platform.dart';

// Two-step sign-in and passkeys (3.3): ZestSSH Cloud's routes with this
// device's sign-in, the recovery proof, a waiting lock-out recovery, and how
// this device makes passkeys.

/// ZestSSH Cloud's two-step routes with this device's sign-in: a phone's
/// freshly refreshed Firebase ID token (a sign-in the person just confirmed
/// counts as recent, and ZestSSH Cloud asks Firebase with it), a computer's
/// session token.
final twoStepApiProvider = Provider<TwoStepApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return TwoStepApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: true) ?? await AccountSecret.sessionToken.read(storage),
  );
});

/// Confirming it is the person with a passkey (from a security review); null under
/// `flutter test`, where nothing can answer and the screens that ask are about
/// something else: a test of it puts its own.
final passkeyStepUpProvider = Provider<PasskeyStepUp?>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
  return PasskeyStepUp(
    api: () => ref.read(twoStepApiProvider),
    platform: ref.watch(passkeyPlatformProvider),
    remember: (at) => ref.read(settingsServiceProvider).setStepUpAt(at.millisecondsSinceEpoch ~/ 1000),
  );
});

/// Opens the account page, from the notice that a passkey makes "Confirm it's
/// you" one tap: the app has a screen to do it from.
final addPasskeyRequestProvider = StateProvider<int>((_) => 0);

/// The recovery this device waits for, and the accounts it registered a
/// recovery proof for.
final lockoutRecoveryStoreProvider =
    Provider<LockoutRecoveryStore>((ref) => LockoutRecoveryStore(ref.watch(secureStorageProvider)));

/// The signed-in account's Firebase id: the Firebase user's on a phone, the
/// one a computer's session names ([user] as currentUserProvider says it,
/// the session token in [storage]).
Future<String?> signedInAccountUid(UserProfile? user, FlutterSecureStorage storage) async {
  final firebase = AuthService.currentUser?.uid;
  if (firebase != null) return firebase;
  final kept = user?.uid;
  if (kept != null && kept.isNotEmpty && kept != 'desktop-session') return kept;
  return sessionAccountUid(await AccountSecret.sessionToken.read(storage));
}

/// Registers the account's recovery proof whenever this device holds a
/// verified sync key (lib/services/account/recovery_proof.dart).
final recoveryProofServiceProvider = Provider<RecoveryProofService>((ref) {
  return RecoveryProofService(
    api: () => ref.read(twoStepApiProvider),
    accountUid: () => signedInAccountUid(ref.read(currentUserProvider), ref.read(secureStorageProvider)),
    // (Known to be ZestSSH Cloud: not while the store could not be read, 3.4.2.)
    hosted: () => ref.read(syncStoreKnownHostedProvider),
    remember: (uid) async {
      final email = ref.read(currentUserProvider)?.email;
      if (email != null && email.isNotEmpty) await ref.read(lockoutRecoveryStoreProvider).rememberAccount(email, uid);
    },
  );
});

/// Setting the authenticator app up with Firebase on this device: the
/// signed-in Firebase user's (a phone, a tablet), or none (a computer, which
/// sets it up on zestssh.com). Tests put their own.
final authenticatorEnrollerProvider = Provider<AuthenticatorEnroller? Function()>((ref) {
  return () {
    final user = AuthService.currentUser;
    return user == null ? null : TwoStepAccount(user);
  };
});

/// Whether this device signs in with Firebase itself (a phone, a tablet),
/// and so changes two-step sign-in with its own sign-in; a computer signs in
/// through the browser.
final signsInWithFirebaseProvider = Provider<bool>((ref) {
  ref.watch(authStateProvider);
  return AuthService.currentUser != null;
});

/// How this device makes a passkey.
enum PasskeyWay {
  /// The system's own ceremony (Android, iOS 16+, Windows Hello).
  here,

  /// zestssh.com's security page in the browser: a computer whose system
  /// makes none for the app (Linux, the Mac, an older Windows).
  browser,

  /// None: a phone on an older system (Android 8, iOS 15).
  none,
}

/// How this device makes a passkey: its own ceremony where the system has
/// one, the browser on a computer, none on an older phone.
final passkeyWayProvider = FutureProvider<PasskeyWay>((ref) async {
  if (await passkeysHere(ref.watch(passkeyPlatformProvider))) return PasskeyWay.here;
  // A computer signs in through the browser (it has no Firebase of its
  // own, the Mac included: the contract, section 6.7, and the Mac target
  // bundles no GoogleService-Info.plist, held by
  // test/providers/passkey_way_test.dart); a phone does not. A device that
  // signs in with Firebase but has no ceremony adds none: its own sign-in
  // could not use the passkey (signInWithSecondStep: passkeyElsewhere), so
  // a passkey-only account would leave it only its backup codes.
  return AuthService.isFirebaseAvailable ? PasskeyWay.none : PasskeyWay.browser;
});
