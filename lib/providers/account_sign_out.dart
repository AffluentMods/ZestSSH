import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/spaces.dart' show TreeSpace;
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart' show signedInAccountUid;
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/profiles/profile_manager.dart' show LockedCopyAtCloud;

/// Sign the ZestSSH account out of this device, the one sign-out every
/// "Sign out" button uses (Profile, the Tree menu, Manage Tree).
///
/// Firebase sign-out alone is not enough: on desktop Firebase is not used at
/// all, and the account lives in a browser-issued session token that
/// `_restoreDesktopSession()` would bring back on the next launch. So this
/// also deletes that token, clears the in-memory desktop session, resets the
/// cached entitlements to Free, drops the sync status and locks any cached
/// sync key; ZestSSH Cloud's sync, the account's, is forgotten on this device,
/// so a new sign-in sets it up or joins it from scratch. Local SSH data stays
/// on the device. [signedOutElsewhere] is a sign-out nobody asked for here:
/// what syncs this device is set aside for the account (KeptSync), and comes
/// back when that account signs in again; any other account finds nothing.
///
/// On a computer the profile on screen then locks and guest data opens
/// ([lock]); a deleted account's stays open until the person says what becomes
/// of it, and a wipe wipes it while it is still open (to-do 60).
///
/// It does not ask for confirmation; callers do that first.
///
/// This device leaves the account's device list too: it signs its session
/// out on ZestSSH Cloud first, while it still can. [signedOutElsewhere] means
/// the server already did (another device signed this one out), so it only
/// forgets the registration.
Future<void> signOutAccount(WidgetRef ref, {bool signedOutElsewhere = false, bool lock = true}) =>
    signOutAccountWith(ref.read, signedOutElsewhere: signedOutElsewhere, lock: lock);

/// [signOutAccount], with whatever reads the providers (the deleting flows, a
/// test's container).
Future<void> signOutAccountWith(T Function<T>(ProviderListenable<T> provider) read,
    {bool signedOutElsewhere = false, bool lock = true}) async {
  // Read while it is still known: the sign-out below ends it.
  final keepFor =
      signedOutElsewhere ? await signedInAccountUid(read(currentUserProvider), read(secureStorageProvider)) : null;
  // On a computer, whether ZestSSH Cloud still holds the locked copy the lock
  // below leaves as the only way into this account's data: asked while the
  // session works. Where it does not, or cannot say, the profile is only hidden
  // and its key stays (found in a data review). Signed out from
  // elsewhere, nothing is left to ask with.
  final cloud = lock && !signedOutElsewhere ? await read(profileControllerProvider).lockedCopyBeforeSignOut() : null;
  final devices = read(deviceSessionServiceProvider);
  if (signedOutElsewhere) {
    await devices.forget();
  } else {
    await devices.signOutHere();
  }

  // The teams on this device close, and the Tree is on screen: a team is
  // the account's that joined it, and the next one signed in here sees
  // only its own (OrchardOwners). Nothing of them is
  // deleted: they open again when their account signs back in.
  read(activeSpaceProvider.notifier).state = const TreeSpace();
  await read(orchardDatabasesProvider.notifier).closeAll();

  // What unlocked a password manager for this person is forgotten
  // (3.0).
  read(passwordManagersProvider)?.lock();

  // 1) Firebase sign-out (no-op on desktop where Firebase isn't configured). On a Mac
  // Firebase saying nobody is no sign-out by itself (a keychain macOS did not let it
  // read says the same): this one is said first, so one that stops before its lock is
  // finished at the next start.
  if (lock) await read(profileControllerProvider).signOutBegins();
  await AuthService.signOut();

  // 2) The desktop browser-based session, which Firebase sign-out does not
  //    touch. Without this, "sign out" appears to do nothing on Windows: the
  //    token in secure storage is restored on the next launch and the
  //    in-memory session keeps the UI signed in.
  try {
    final storage = read(secureStorageProvider);
    await AccountSecret.sessionToken.delete(storage);
    await storage.delete(key: 'session_email');
    await storage.delete(key: 'session_name');
    await storage.delete(key: 'session_photo');
    await storage.delete(key: 'session_uid');
  } catch (e) {
    AppLogger.warning('Failed to clear desktop session token: $e');
  }
  read(desktopSessionProvider.notifier).state = null;

  // Reset entitlements back to Free: the Pro / Cloud notifiers cache the last
  // seen state and do not flip on their own when the user signs out.
  // On a computer the refresh has no account to ask, and the last tier
  // stayed, also for whoever opened the app next and after a restart (29
  // October 2026): Free at once, and the saved copy forgotten.
  await PurchaseService.forgetDesktopEntitlements();
  read(isProProvider.notifier).signedOut();
  read(isCloudSyncProvider.notifier).signedOut();
  unawaited(read(isProProvider.notifier).refresh());
  unawaited(read(isCloudSyncProvider.notifier).refresh());

  read(syncStatusProvider.notifier).clear();
  // Drop any cached sync MEK: a signed-out session must hold no vault.
  read(vaultSessionProvider.notifier).lock();
  // ZestSSH Cloud's sync is the account's: this device forgets its keys and
  // starts its setup over, so whoever signs in here next sets up or joins
  // their own. The keys stayed (only the setup's state was reset), and sync
  // ran on with them for the next account signed in here: into an empty store
  // of that account went this device's vault, under the key of the account
  // before and with what a guess at its password needs (found 16 October
  // 2026 in the client's security review). A store of one's own (WebDAV, S3,
  // Google Drive, a server of one's own) needs no account, and its sync goes
  // on: its setup's state was reset too, and the app said sync was off while
  // it ran.
  final store = read(syncProviderConfigProvider.notifier);
  await store.ensureLoaded();
  await read(settingsServiceProvider).setSyncTurnOnAsked(false);
  await read(settingsServiceProvider).setStepUpAt(null);
  if (store.unknown) {
    // Which store this is could not be read (3.4.2: a Mac's keychain macOS
    // did not let ZestSSH read; the hosted default stood for it, and a store
    // of one's own lost its keys here). Nothing of sync's is deleted now; it
    // is owed, and done once the store is read (SyncProviderConfigNotifier),
    // before anything can sync with it.
    await read(settingsServiceProvider).setSyncDisconnectOwed(keepFor ?? '');
    AppLogger.warning('Sign-out: the sync store is not known, so its keys stay until it is read');
  } else if (read(syncProviderConfigProvider).kind.isHosted) {
    await forgetHostedSyncHere(read, keepFor: keepFor);
  }
  // Only now: all of the above is the profile's, and is done with it open.
  // A sign-out from elsewhere is said by its caller, and the person's own by its
  // question.
  if (lock) await read(profileControllerProvider).lockAfterSignOut(cloud: cloud ?? LockedCopyAtCloud.held, told: true);
}
