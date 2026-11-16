import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/keys/key_agent.dart' show systemAgentProvider, takeBackAgentKeys;
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/profiles/profile_manager.dart' show ProfileCannotOpen;
import 'package:zestssh/services/task_scheduler_service.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Whatever reads the providers: a page's `ref.read`, or a test's container.
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Delete all local data, once the person has said what is to go: sync goes off so
/// the wipe is never uploaded, and the account is signed out. ZestSSH Cloud's secret
/// for this profile goes while the session can still ask. The profile stays open to
/// be wiped: signing out with a lock would lock it, and wipe whatever opened next.
///
/// The keys given to the system's SSH agent are taken back first, and where the agent
/// does not take them all back [whenKeysStay] asks the person whether to go on: false,
/// and nothing has gone (found in a code review). False where
/// nothing went.
Future<bool> deleteAllLocalData(ProviderRead read,
    {bool everything = false, WipeTargets? targets, Future<bool> Function()? whenKeysStay}) async {
  _refuseWhereSomeoneElses(read, everything);
  if (!await _agentKeysTakenBack(read, everything) && whenKeysStay != null && !await whenKeysStay()) return false;
  await read(autoSyncServiceProvider).suspend();
  if (read(isSignedInProvider)) {
    await read(profileControllerProvider).deleteLockedCopy(bearer: await accountBearer(storage: read(secureStorageProvider)));
    await signOutAccountWith(read, lock: false);
  }
  await wipeThisDevice(read, everything: everything, targets: targets);
  return true;
}

/// The keys this profile gave the system's agent go back, with Everything every
/// profile's, and with them what the computer's list says is owed; true where none is
/// left. What an agent does not take back stays on that list, outside every profile, so
/// that no wipe deletes the record of it, and goes back at the next opening.
Future<bool> _agentKeysTakenBack(ProviderRead read, bool everything) async {
  if (everything) await read(profileControllerProvider).oweAgentKeysOfEveryProfile();
  return takeBackAgentKeys(read(systemAgentProvider), read(databaseSessionProvider),
      keychain: read(secureStorageProvider));
}

/// Everything ZestSSH keeps on this device, with sync off first so the wipe is
/// never uploaded. [everything]: on a computer, every profile here as well, and not
/// only the one on screen. [targets] is a test's stand-in for this device's folders.
Future<void> wipeThisDevice(ProviderRead read, {bool everything = false, WipeTargets? targets}) async {
  _refuseWhereSomeoneElses(read, everything);
  await read(autoSyncServiceProvider).suspend();
  // The keys this profile gave the system's agent go first: the note of which
  // they are lives in the database the wipe deletes, so taken back after it
  // nothing was found, and the next person on this computer's login signed in
  // with them through `ssh` (found in a security review).
  // Every profile's, with Everything, and what the computer's list says is owed, whose
  // fingerprints stay listed until an agent takes them back.
  await _agentKeysTakenBack(read, everything);
  // Scheduled tasks go with their rows: WorkManager's jobs kept their command text, and
  // came up for a task no screen showed any more (Android).
  await _cancelScheduledTasks();
  // Orchards leave this device too: their databases and keys.
  await read(orchardDatabasesProvider.notifier).forgetAll();
  final session = read(databaseSessionProvider.notifier);
  // Asked before the wipe: the entry that says so goes with it.
  final hardwareBound = session.lockedKeyHex != null && await read(vaultSlotServiceProvider).isHardwareBound();
  final wiper = LocalDataWiper(
    database: read(treeDatabaseProvider),
    secureStorage: read(secureStorageProvider),
    preferences: read(sharedPreferencesProvider),
    targets: targets ?? await WipeTargets.onThisDevice(everything: everything),
    // A phone or tablet with Encrypt data at rest on: the wipe turns the lock
    // off with the key the database was opened by.
    lockedKeyHex: session.lockedKeyHex,
  );
  await wiper.wipe();
  if (wiper.turnedLockOff) {
    session.lockTurnedOff();
    // The lock's key in the device's hardware goes with it, where there was
    // one: nothing is wrapped by it any more. Never in the way of the wipe.
    if (hardwareBound) {
      try {
        await read(hardwareVaultServiceProvider).delete();
      } catch (e) {
        AppLogger.warning('Wipe: the hardware key of the lock was left (${errorKind(e)})');
      }
    }
  }
  // On a computer what is wiped is the profile, while it was still open: now it
  // goes, and guest data opens.
  final profiles = read(profileControllerProvider);
  if (profiles.on) {
    await (everything ? profiles.wipeEverything() : profiles.removeAfterWipe());
  }
}

/// Every scheduled task's job, as its rows go. Never in the way of the wipe: a job left
/// is cancelled at the next start, as no row names it.
Future<void> _cancelScheduledTasks() async {
  try {
    await TaskSchedulerService.cancelAll();
  } catch (e) {
    AppLogger.warning('Scheduled tasks were left for the next start (${errorKind(e)})');
  }
}

/// Everything on a computer that holds someone else's account is refused before anything
/// goes: theirs goes only with their own sign-in (ProfileController.mayDeleteEverything,
/// found in a code review). Throws [ProfileCannotOpen].
void _refuseWhereSomeoneElses(ProviderRead read, bool everything) {
  if (!everything) return;
  final profiles = read(profileControllerProvider);
  if (profiles.on && !profiles.mayDeleteEverything) throw const ProfileCannotOpen('profile-signed-in-long-ago');
}

/// The account [uid] was deleted at ZestSSH Cloud: what opened it here goes. Its
/// profile stays open until the last chance is answered: wiped while open, or kept.
/// No secret will ever open it again, so it is never locked.
Future<void> forgetDeletedAccount(ProviderRead read, String uid) async {
  await read(autoSyncServiceProvider).clearSyncCredentials();
  // The deleted account's keys are useless now; its sync keys too.
  await AccountKeyStore(read(secureStorageProvider), tree: () => read(databaseSessionProvider)).delete(uid);
  await signOutAccountWith(read, lock: false);
  await read(profileControllerProvider).accountGone();
}
