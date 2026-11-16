import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/utils/type_name.dart';

/// How a profile stands on this computer.
enum ProfileState {
  /// Its key is here: guest data, or an account signed in.
  open,

  /// Signed out: the only copy of its key is wrapped with a secret ZestSSH
  /// Cloud keeps, and it opens only after that account signs in again.
  locked,

  /// Signed out before the secret reached ZestSSH Cloud: hidden as guest data
  /// is, and said so. The next sign-in online locks it properly.
  hidden,

  /// Its account was deleted a moment ago, and whether its data stays is still
  /// to be answered.
  gone,

  /// Its secret is gone from ZestSSH Cloud: it can never be opened again. Its
  /// folder is left, and nothing makes use of it.
  lost,

  /// Guest data set aside when the data of a deleted account became the guest
  /// data. Nothing is lost; the switcher reaches it.
  kept,

  /// Being deleted: a removal that stopped is finished at the next start.
  removing,

  /// It did not open, and the person set it aside: its folder is in
  /// `profiles/set_aside`, nothing of it is deleted, and nothing opens it. It is
  /// said at each start until it is deleted.
  setAside,
}

/// One profile on this computer.
@immutable
class ProfileEntry {
  const ProfileEntry({required this.id, this.uid, this.label, this.state = ProfileState.open, this.made = 0, this.person});

  /// Throws where it is not one: an id that is not a profile's would name another
  /// folder, and such a list is no list.
  factory ProfileEntry.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    if (!isProfileId(id)) throw const FormatException('Not the id of a profile');
    return ProfileEntry(
      id: id,
      uid: j['uid'] as String?,
      label: j['label'] as String?,
      state: ProfileState.values.asNameMap()[j['state']] ?? ProfileState.open,
      made: j['made'] as int? ?? 0,
      person: j['person'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (uid != null) 'uid': uid,
        if (label != null) 'label': label,
        'state': state.name,
        'made': made,
        if (person != null) 'person': person,
      };

  final String id;

  /// The account it belongs to; null for guest data.
  final String? uid;

  /// What the account was called at its last sign-in (its address), to say
  /// whose it is where it is not open.
  final String? label;
  final ProfileState state;
  final int made;

  /// Whose account this is among the people who use this computer:
  /// accounts of one person carry the same random mark, said when one was added.
  /// Null where nobody was asked: such an account is nobody else's to open.
  final String? person;

  /// Whether [other] is an account of the same person as this one, so that a switch
  /// between them asks for nothing.
  bool sameOwnerAs(ProfileEntry other) => person != null && person == other.person;

  ProfileEntry copyWith({String? uid, String? label, ProfileState? state, String? person, bool noAccount = false}) => ProfileEntry(
        id: id,
        uid: noAccount ? null : uid ?? this.uid,
        label: noAccount ? null : label ?? this.label,
        state: state ?? this.state,
        made: made,
        person: noAccount ? null : person ?? this.person,
      );
}

/// A list that cannot be read: the app stops and says so, and never takes it
/// for a device with no profiles.
class ProfileListUnreadable implements Exception, HasTypeName {
  const ProfileListUnreadable();

  @override
  String toString() => 'ProfileListUnreadable';

  @override
  String get typeName => 'ProfileListUnreadable';
}

/// The list of profiles on this computer, and the map from account to profile:
/// one device entry in the keychain. It is the only thing that says which
/// account a profile is, so no folder or other name has to.
///
/// A second copy is written first, for a keychain that keeps each entry on its own
/// (a Mac): an app stopped in between still finds the list. On Windows both are in
/// one file, which is replaced whole or not at all (SafeKeychainFile), so there the
/// file's own last-good copy is what stands behind it.
class ProfileList {
  ProfileList({List<ProfileEntry>? entries, this.current, bool shared = false})
      : entries = List.of(entries ?? const []),
        _shared = shared {
    _noteShared();
  }

  final List<ProfileEntry> entries;

  /// The profile on screen when the app last closed.
  String? current;

  static const name = 'profiles_v1';
  static const copyName = 'profiles_v1_copy';

  /// The most accounts a computer keeps. Guest data does not count.
  static const maxAccounts = 5;

  /// The accounts that count toward [maxAccounts]: each still holds its data here, in
  /// reach of a sign-in. One that can never open again holds nobody's place.
  List<ProfileEntry> get accounts => [
        for (final e in entries)
          if (e.uid != null && (e.state == ProfileState.open || e.state == ProfileState.locked || e.state == ProfileState.hidden)) e,
      ];

  /// The entries of an account whose data is still here, whatever state it is in:
  /// signed in or out, hidden, deleted at ZestSSH Cloud and not yet answered, or set
  /// aside. Not one that can never open again, nor one being removed.
  List<ProfileEntry> get ofSomeone => [
        for (final e in entries)
          if (e.uid != null && e.state != ProfileState.lost && e.state != ProfileState.removing) e,
      ];

  /// How many people's accounts this computer holds now ([ofSomeone]): two entries are
  /// one person's where they are of one account, or carry one mark ([ProfileEntry.person]).
  /// An account nobody said is anyone's is its own person's.
  int get peopleHere {
    final here = ofSomeone;
    final group = [for (var i = 0; i < here.length; i++) i];
    int root(int i) {
      while (group[i] != i) {
        i = group[i] = group[group[i]];
      }
      return i;
    }

    for (var i = 0; i < here.length; i++) {
      for (var j = 0; j < i; j++) {
        final a = here[i], b = here[j];
        if (a.uid == b.uid || a.sameOwnerAs(b)) group[root(i)] = root(j);
      }
    }
    return {for (var i = 0; i < here.length; i++) root(i)}.length;
  }

  /// Whether more than one person has had accounts on this computer (found in
  /// security reviews). Once so, it stays so, in
  /// the list, until everything here is deleted ([forgetPeople]): one person removing
  /// their own account, or leaving it set aside, never makes the computer one person's
  /// again, so guest data never opens the other's accounts with no sign-in.
  bool get shared => _shared || peopleHere > 1;
  bool _shared;

  void _noteShared() {
    if (!_shared && peopleHere > 1) _shared = true;
  }

  /// Everything on this computer is being deleted: nobody's accounts are here any more.
  void forgetPeople() => _shared = false;

  /// The guest data set aside when a deleted account's data became the guest data.
  List<ProfileEntry> get keptGuestData => [
        for (final e in entries)
          if (e.uid == null && e.state == ProfileState.kept) e,
      ];

  static Future<ProfileList?> read(FlutterSecureStorage device) async {
    final main = await device.read(key: name);
    if (main != null) {
      final list = _parse(main);
      if (list != null) return list;
    }
    final copy = await device.read(key: copyName);
    if (copy != null) {
      final list = _parse(copy);
      if (list != null) return list;
    }
    if (main != null || copy != null) throw const ProfileListUnreadable();
    return null;
  }

  static ProfileList? _parse(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return ProfileList(
        entries: [for (final e in j['profiles'] as List) ProfileEntry.fromJson(Map<String, dynamic>.from(e as Map))],
        current: j['current'] as String?,
        shared: j['shared'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(FlutterSecureStorage device) async {
    _noteShared();
    final raw = jsonEncode({
      'v': 1,
      'current': current,
      'profiles': [for (final e in entries) e.toJson()],
      if (_shared) 'shared': true,
    });
    await device.write(key: copyName, value: raw);
    await device.write(key: name, value: raw);
  }

  ProfileEntry? byId(String? id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// The profile of the account [uid] that can still be used; never a lost one,
  /// nor one set aside.
  ProfileEntry? byUid(String uid) {
    for (final e in entries) {
      if (e.uid == uid && e.state != ProfileState.lost && e.state != ProfileState.setAside) return e;
    }
    return null;
  }

  /// The profile whose copy of [uid] was lost, if any.
  ProfileEntry? lostOf(String uid) {
    for (final e in entries) {
      if (e.uid == uid && e.state == ProfileState.lost) return e;
    }
    return null;
  }

  /// The guest profile: data made with no account.
  ProfileEntry? get guest {
    for (final e in entries) {
      if (e.uid == null && e.state == ProfileState.open) return e;
    }
    return null;
  }

  /// [entry] in place of the one of its id, or added. Who was here before and after is
  /// noted ([shared]): a removal that follows lowers nothing.
  void put(ProfileEntry entry) {
    _noteShared();
    final at = entries.indexWhere((e) => e.id == entry.id);
    if (at >= 0) {
      entries[at] = entry;
    } else {
      entries.add(entry);
    }
    _noteShared();
  }

  void remove(String id) {
    _noteShared();
    entries.removeWhere((e) => e.id == id);
  }

  /// The ids of the profiles whose key is on this device, plain or wrapped by
  /// the vault: those the lock has to do with.
  Iterable<String> get withKeyHere =>
      entries
          .where((e) =>
              e.state == ProfileState.open ||
              e.state == ProfileState.hidden ||
              e.state == ProfileState.gone ||
              e.state == ProfileState.kept ||
              e.state == ProfileState.setAside)
          .map((e) => e.id);
}
