import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart' show DatabaseNewerThanApp;
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/windows_keychain.dart';
import 'package:zestssh/services/vault_slot_service.dart';

/// What a start of the app reads settings through, and what it found of profiles.
@immutable
class ProfileBoot {
  const ProfileBoot(this.prefs, this.start);

  final SharedPreferences prefs;

  /// Null where this platform keeps no profiles: a phone.
  final ProfileStart? start;
}

/// The part of a start that is about profiles, before anything opens. On a phone
/// it does nothing at all, and what reads settings reads the system's store as
/// ever. On a computer a move goes as far as it can without the database, with
/// [sayMoving] on the screen first, and which profile opens is settled.
///
/// [manager] is a test's stand-in for the one made here.
Future<ProfileBoot> bootProfiles({
  required SharedPreferences rawPrefs,
  required Future<void> Function() sayMoving,
  ProfileManager Function(ProfilePreferences helper)? manager,
}) async {
  if (!profilesOnThisPlatform) return ProfileBoot(rawPrefs, null);
  final helper = ProfilePreferences(rawPrefs);
  ProfilePreferences.instance = helper;
  final made = manager?.call(helper) ??
      ProfileManager(
        base: await ProfilePaths.base(),
        device: deviceKeychain,
        prefs: helper,
        rawPrefs: rawPrefs,
        folders: await _personFolders(),
        firebaseUid: () => AuthService.currentUser?.uid,
        firebaseReported: AuthService.isFirebaseAvailable ? AuthService.firstReport : null,
      );
  ProfileManager.instance = made;
  if (await made.moveNeeded()) await sayMoving();
  return ProfileBoot(helper, await made.start());
}

/// Whether [error], which stopped a database opening, may well pass by itself: what
/// holds a file for a moment, a full disk, a keychain that does not answer now. Try
/// again is the answer to those, and setting data aside the wrong one, so it is not
/// offered. Anything else fails the same way the next time.
bool failureMayPass(Object error) {
  if (error is KeychainFileFailed ||
      error is FileSystemException ||
      error is PlatformException ||
      error is TimeoutException ||
      error is VaultLockedException) {
    return true;
  }
  const ofTheMoment = [
    'database is locked',
    'database table is locked',
    'disk i/o error',
    'database or disk is full',
    'unable to open database file',
    'readonly database',
    'locking protocol',
    'out of memory',
  ];
  final words = error.toString().toLowerCase();
  return ofTheMoment.any(words.contains);
}

/// Whether the data must stay exactly as it is after [error] stopped it opening: no
/// Set aside, no Reset, no copy put back. A failure that may pass by itself
/// ([failureMayPass]), and data from a newer ZestSSH ([DatabaseNewerThanApp]), where
/// updating the app is the answer (found in a code audit).
bool dataStaysAsItIs(Object error) => failureMayPass(error) || error is DatabaseNewerThanApp;

/// Whether Reset is offered on the database's error screen for [error]. Never where
/// the failure may pass by itself ([failureMayPass]: a keychain that did not answer
/// now, a file held a moment), for any keychain's or platform's exception, a key the
/// keychain did not hand over among them, nor while a move holds the only copy
/// ([moving]). Nor on a computer ([computer]): there Set aside is the way to start
/// fresh, which keeps everything, keys included, and Put it back undoes (3.3.3: Reset
/// deleted the database, its copies and its key, and on a Mac a key macOS had only not
/// let ZestSSH read was then made anew over the data). On a phone Reset sets the
/// files aside too (AppDatabase.setAsideAndRecreate).
bool resetOffered(Object error, {required bool moving, required bool computer}) {
  if (computer || moving || dataStaysAsItIs(error) || error is PlatformException) return false;
  return !error.toString().contains('Cannot read encryption key');
}

/// What the screen of a start that failed before any window offers besides Try
/// again, where anything: a keychain's file that does not open may stay under another
/// name, and a move that has moved its files may be set aside. A move that has moved
/// nothing has nothing to set aside (profile_move.dart), and another failure is not
/// helped by it. [retry] starts the app again.
Future<Future<void> Function()?> startWayOut(Object error, {required VoidCallback retry}) async {
  if (error is KeychainFileFailed && error.step == 'does-not-open') {
    return () async {
      await setKeychainFileAside();
      retry();
    };
  }
  final manager = ProfileManager.instance;
  if (error is ProfileMoveFailed && manager != null && await manager.moveCanBeSetAside()) {
    return () async {
      await manager.setAsideCurrent();
      retry();
    };
  }
  return null;
}

/// The folders of a person's files on this computer, asked for once.
Future<PersonFolders Function()> _personFolders() async {
  try {
    final folders = await PersonFolders.onThisDevice();
    return () => folders;
  } catch (e) {
    // A system with no such folders: what needs them says so where it does.
    return () => throw e;
  }
}
