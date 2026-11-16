import 'dart:io' show Process;

import 'package:flutter/services.dart' show PlatformException;
import 'package:zestssh/services/profiles/mac_keychain.dart' show KeychainAccessDenied;

/// What stopped the app reading its keys from a Linux system's keyring (the
/// Secret Service, usually GNOME Keyring), which it reads before its window can
/// open. On a kiosk, a computer that signs in by itself
/// leaves the login keyring locked, and "ZestSSH could not start" came up behind
/// GNOME's box asking for its password.
enum KeyringProblem {
  /// It is there and locked: the person unlocks it in the system's own box, or
  /// closed that box.
  locked,

  /// Nothing answers for it on this system.
  missing,

  /// On a Mac (3.3.2): macOS asked whether ZestSSH may read its own saved keys, and
  /// the answer was not yes ([KeychainAccessDenied]). Try again asks again.
  macDenied,
}

/// What the system says of its keyring when asked ([linuxKeyringState]).
enum KeyringState {
  /// It is there, and open.
  unlocked,

  /// It is there, and locked.
  locked,

  /// Nothing answers for it on this system.
  absent,

  /// It could not be told (no gdbus, no answer in time).
  unknown,
}

/// Whether [error] is a failure of the system's keyring. The plugin answers
/// every failure with one code, and a read warms the keyring up first, so that
/// what comes of nearly anything is one fixed text, "Failed to unlock the
/// keyring": a computer with no Secret Service, or one where the store itself
/// fails, as much as one with a locked keyring. So the words say that it is the
/// keyring, not what is wrong with it: [keyringProblemOf] asks the system.
bool isKeyringFailure(Object error) => error is PlatformException && error.code == 'Libsecret error';

/// The [KeyringProblem] that [error] is: what the system says of its keyring
/// ([state]), once. Null where it is no keyring failure, or where the keyring
/// is open or the system cannot tell: there a claim of a locked keyring could
/// hide the real error, and the person gets that error, with its details to
/// copy.
Future<KeyringProblem?> keyringProblemOf(Object error, {Future<KeyringState> Function() state = linuxKeyringState}) async {
  // A Mac's says what it is itself, and nothing is asked.
  if (error is KeychainAccessDenied) return KeyringProblem.macDenied;
  if (!isKeyringFailure(error)) return null;
  return switch (await state()) {
    KeyringState.locked => KeyringProblem.locked,
    KeyringState.absent => KeyringProblem.missing,
    KeyringState.unlocked || KeyringState.unknown => null,
  };
}

/// Whether the default keyring is unlocked now. Null where it cannot be told.
Future<bool?> linuxKeyringUnlocked() async => switch (await linuxKeyringState()) {
      KeyringState.unlocked => true,
      KeyringState.locked => false,
      KeyringState.absent || KeyringState.unknown => null,
    };

/// What the system says of its keyring, asked without ever bringing up a box (a
/// read of a key does, each time: asking by that would keep opening one in front
/// of someone who just closed it).
Future<KeyringState> linuxKeyringState() async {
  try {
    final result = await Process.run('gdbus', const [
      'call',
      '--session',
      '--timeout',
      '5',
      '--dest',
      'org.freedesktop.secrets',
      '--object-path',
      '/org/freedesktop/secrets/aliases/default',
      '--method',
      'org.freedesktop.DBus.Properties.Get',
      'org.freedesktop.Secret.Collection',
      'Locked',
    ]);
    return keyringStateFromGdbus(result.exitCode, '${result.stdout}', '${result.stderr}');
  } catch (_) {
    // (No gdbus here: the person says when, by Try again.)
    return KeyringState.unknown;
  }
}

/// What gdbus's answer about the collection's Locked property says: `(<true>,)`
/// when it was answered, and otherwise why it could not be. A session bus with
/// nobody owning the Secret Service's name, and no session bus at all, are
/// nothing there to answer.
KeyringState keyringStateFromGdbus(int exitCode, String out, String error) {
  if (exitCode == 0) {
    if (out.contains('false')) return KeyringState.unlocked;
    if (out.contains('true')) return KeyringState.locked;
    return KeyringState.unknown;
  }
  final said = error.toLowerCase();
  const nothingThere = [
    'serviceunknown',
    'namehasnoowner',
    'not provided by any',
    'cannot autolaunch',
    'could not connect',
    'error connecting',
  ];
  return nothingThere.any(said.contains) ? KeyringState.absent : KeyringState.unknown;
}
