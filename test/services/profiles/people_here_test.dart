import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/profile_list.dart';

/// Who has had accounts on this computer (found in security
/// reviews): every account whose data is here counts,
/// whatever its state, and once two people's have been here the list says so until
/// everything here is deleted.
void main() {
  ProfileEntry account(String uid, {ProfileState state = ProfileState.open, String? person}) =>
      ProfileEntry(id: newProfileId(), uid: uid, label: '$uid@example.com', state: state, person: person);

  group('people here', () {
    test('every account whose data is here counts, signed out, hidden, deleted and set aside too', () {
      for (final state in [ProfileState.open, ProfileState.locked, ProfileState.hidden, ProfileState.gone, ProfileState.setAside]) {
        final list = ProfileList(entries: [account('alex'), account('sam', state: state)]);
        expect(list.peopleHere, 2, reason: state.name);
      }
    });

    test('one that can never open again, one being removed and guest data are nobody', () {
      final list = ProfileList(entries: [
        account('alex'),
        account('sam', state: ProfileState.lost),
        account('kim', state: ProfileState.removing),
        ProfileEntry(id: newProfileId()),
        ProfileEntry(id: newProfileId(), state: ProfileState.kept),
        ProfileEntry(id: newProfileId(), state: ProfileState.setAside),
      ]);
      expect(list.peopleHere, 1);
      expect(list.shared, isFalse);
    });

    test('one account is one person, set aside and signed in again; one mark is one person; no mark is its own', () {
      // Alex's data set aside, and Alex's new profile: one account, one person.
      expect(ProfileList(entries: [account('alex', state: ProfileState.setAside, person: 'm1'), account('alex')]).peopleHere, 1);
      // Two accounts said to be one person's, joined through a third with no mark of its own.
      expect(
        ProfileList(entries: [
          account('alex', person: 'm1'),
          account('alex-work', person: 'm1'),
          account('alex', state: ProfileState.setAside),
        ]).peopleHere,
        1,
      );
      expect(ProfileList(entries: [account('alex'), account('sam')]).peopleHere, 2, reason: 'nobody said they are one person');
      expect(ProfileList(entries: [account('alex', person: 'm1'), account('sam', person: 'm2')]).peopleHere, 2);
    });
  });

  group('two people once', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('stays so when the second removes their own account, and across a start', () async {
      const device = FlutterSecureStorage();
      final sam = account('sam');
      final list = ProfileList(entries: [account('alex')]);
      expect(list.shared, isFalse);
      list.put(sam);
      expect(list.shared, isTrue);
      await list.write(device);

      // Sam's account goes, as removeAccount does: marked, then taken off the list.
      list.put(sam.copyWith(state: ProfileState.removing));
      list.entries.removeWhere((e) => e.id == sam.id);
      expect(list.peopleHere, 1);
      expect(list.shared, isTrue, reason: 'one person removing their own does not make it one person\'s');
      await list.write(device);

      final read = (await ProfileList.read(device))!;
      expect(read.peopleHere, 1);
      expect(read.shared, isTrue);
    });

    test('a list written before this was kept reads as two people where it holds two', () async {
      const device = FlutterSecureStorage();
      await device.write(
        key: ProfileList.name,
        value: jsonEncode({
          'v': 1,
          'current': null,
          'profiles': [account('alex').toJson(), account('sam', state: ProfileState.locked).toJson()],
        }),
      );
      final read = (await ProfileList.read(device))!;
      expect(read.shared, isTrue);
      read.remove(read.byUid('sam')!.id);
      expect(read.shared, isTrue);
    });

    test('only everything going forgets it', () async {
      const device = FlutterSecureStorage();
      final list = ProfileList(entries: [account('alex'), account('sam')]);
      for (final e in List.of(list.entries)) {
        list.put(e.copyWith(state: ProfileState.removing, noAccount: true));
      }
      expect(list.shared, isTrue);
      list.forgetPeople();
      expect(list.shared, isFalse);
      await list.write(device);
      expect((await ProfileList.read(device))!.shared, isFalse);
    });

    test("one person's accounts are never two people's", () async {
      final list = ProfileList(entries: [account('alex', person: 'm1')]);
      list.put(account('alex-work', person: 'm1'));
      list.put(list.byUid('alex')!.copyWith(state: ProfileState.locked));
      expect(list.shared, isFalse);
    });
  });
}
