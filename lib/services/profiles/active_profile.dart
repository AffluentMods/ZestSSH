import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/utils/type_name.dart';

// Accounts on one device (to-do 60). A profile is one set of a person's local
// data: a personal database with its team databases, the settings that are a
// person's, their keychain entries and their files. There is one for each
// account that has signed in on the computer, and one for data made with no
// account (guest data). Phones keep none yet: nothing here applies to them
// until [Profiles.turnOn] is called, which only a computer's start does.

/// Whether this platform keeps a person's data in profiles: computers first,
/// phones in the next release. On a phone nothing moves
/// and nothing changes.
bool get profilesOnThisPlatform => switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
      _ => false,
    };

/// The profile the app has open.
@immutable
class ActiveProfile {
  const ActiveProfile({required this.id, required this.dir, this.uid});

  /// Random: nothing outside a profile says who it belongs to.
  final String id;

  /// `profiles/<id>`: its database, its team databases.
  final Directory dir;

  /// The account it belongs to; null for guest data.
  final String? uid;

  bool get isGuest => uid == null;

  /// What every keychain entry of this profile begins with.
  String get prefix => KeychainPrefix.of(id);
}

/// What a profile's keychain entries begin with.
class KeychainPrefix {
  KeychainPrefix._();

  static String of(String id) => 'p.$id.';

  /// The profile an entry's whole [name] belongs to, or null where it belongs
  /// to none.
  static String? profileOf(String name) {
    if (!name.startsWith('p.')) return null;
    final end = name.indexOf('.', 2);
    return end < 0 ? null : name.substring(2, end);
  }
}

/// A profile's entries or files are asked for without one being open: the app is
/// locked, or between two profiles. Nothing of a person is ever written outside a
/// profile.
class NoProfileOpen implements Exception, HasTypeName {
  const NoProfileOpen();

  @override
  String toString() => 'NoProfileOpen';

  @override
  String get typeName => 'NoProfileOpen';
}

/// What a profile's id looks like ([newProfileId]). Nothing else ever reaches a
/// path: an id of `..`, or an empty one, would name somewhere else entirely.
final _profileId = RegExp(r'^[0-9a-f]{32}$');

bool isProfileId(String? id) => id != null && _profileId.hasMatch(id);

/// Which profile is open, for what has no provider to ask: the keychain, the
/// database's own folder, the files of a person.
class Profiles {
  Profiles._();

  static bool _on = false;
  static ActiveProfile? _current;

  /// Whether this run keeps data in profiles. Off on a phone and in a test
  /// that does not ask for it: every name and path is then what it always was.
  static bool get on => _on;

  /// The profile open now; null in between two (a switch, a sign-out) and
  /// before the first.
  static ActiveProfile? get current => _current;

  /// Teams with no owner yet that are used where they are, in the held folder,
  /// as ZestSSH Cloud has not said whose they are: for this profile only.
  static final provisionalTeams = <String>{};

  /// A computer's start says so, once, before anything reads a name or a path.
  static void turnOn() => _on = true;

  /// [profile] is the one open from now on.
  static void bind(ActiveProfile? profile) => _current = profile;

  @visibleForTesting
  static void debugReset() {
    _on = false;
    _current = null;
    provisionalTeams.clear();
  }
}

/// A new profile's id: 128 random bits, in hex.
String newProfileId() {
  final rng = Random.secure();
  return List<int>.generate(16, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Where a profile's files are.
class ProfilePaths {
  ProfilePaths._();

  /// A test's folder, in place of this computer's own. A test never reaches
  /// the real app data.
  @visibleForTesting
  static Directory? debugBase;

  /// The folder the personal database lived in before profiles, which holds
  /// `profiles/`.
  ///
  /// On Windows, `LOCALAPPDATA\com.affluentlabs.zestssh`, to avoid OneDrive
  /// sync (Documents) and roaming profile sync (AppData\Roaming). Elsewhere,
  /// [getApplicationSupportDirectory].
  static Future<Directory> base() async {
    final test = debugBase;
    if (test != null) return test;
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return Directory(p.join(localAppData, 'com.affluentlabs.zestssh'));
      }
    }
    return getApplicationSupportDirectory();
  }

  /// The folder of the database open now: the profile's on a computer, and
  /// where it always was on a phone. Throws on a computer while no profile is
  /// open: nothing of a person is ever made outside a profile.
  static Future<Directory> databaseDirectory() async {
    if (!Profiles.on) return base();
    final current = Profiles.current;
    if (current == null) throw StateError('No profile is open');
    return current.dir;
  }

  static Directory root(Directory base) => Directory(p.join(base.path, 'profiles'));

  static Directory ofProfile(Directory base, String id) {
    if (!isProfileId(id)) throw ArgumentError('Not the id of a profile');
    return Directory(p.join(root(base).path, id));
  }

  /// Where data that did not open waits ([ProfileManager.setAsideCurrent]).
  static Directory setAside(Directory base) => Directory(p.join(root(base).path, 'set_aside'));

  /// Teams that belong to no profile yet: an account that has not signed in
  /// here since the move, or one whose owner the server has yet to say. In a
  /// folder of their own so that an older version run after the move, which
  /// would read their keys as lost and delete them, never sees them.
  static Directory heldTeams(Directory base) => Directory(p.join(root(base).path, 'held', 'orchards'));

  /// [parent] for the files of the profile open now, a folder of its own
  /// inside it; [parent] as it is on a phone. Throws [NoProfileOpen] on a computer
  /// while none is open: [parent] is everyone's there, and nothing may take it for
  /// one person's, least of all to delete it.
  static Directory forCurrent(Directory parent) {
    if (!Profiles.on) return parent;
    final current = Profiles.current;
    if (current == null) throw const NoProfileOpen();
    return Directory(p.join(parent.path, current.id));
  }
}

/// The folders a person's files live in outside the database's own.
class PersonFolders {
  const PersonFolders({required this.documents, required this.support});

  /// The person's Documents folder.
  final Directory documents;

  /// The app's support folder.
  final Directory support;

  static Future<PersonFolders> onThisDevice() async => PersonFolders(
        documents: await getApplicationDocumentsDirectory(),
        support: await getApplicationSupportDirectory(),
      );
}
