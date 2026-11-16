import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';

/// A keychain whose reads fail while [failing] is set, as a Mac's does where macOS
/// was not let in (3.3.2): what was read and written is kept.
class _Keychain implements FlutterSecureStorage {
  final kept = <String, String>{};
  final writes = <String>[];
  bool failing = false;

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        if (failing) return Future<String?>.error(KeychainAccessDenied(-128));
        return Future<String?>.value(kept[key]);
      case #write:
        writes.add(key!);
        kept[key] = i.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        kept.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(i);
  }
}

/// Three stores read a list from the keychain, change it, and write it whole. A read
/// that failed was taken for an empty list, and the next write put that, with one
/// change, over everything they kept (on a Mac,
/// each read could be one macOS was not let in to). Now none writes over what it did
/// not read (3.3.2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Keychain keychain;

  setUp(() => keychain = _Keychain());

  group('automation API keys', () {
    const name = 'automation_api_keys';
    final old = AutomationApiKey.fromSecret(
        id: 'k-old', label: 'old phone', secret: 'a made-up secret of the old phone', createdAt: DateTime(2026, 9, 1));

    List<String> keptIds() => [for (final k in AutomationApiKey.decodeList(keychain.kept[name]!)) k.id];

    test('a key made while they could not be read is not written over them, and goes beside them once they can',
        () async {
      keychain.kept[name] = AutomationApiKey.encodeList([old]);
      keychain.failing = true;
      final keys = AutomationKeysNotifier(keychain);
      await keys.ready;
      expect(keys.state, isEmpty, reason: 'nothing could be read');

      final first = keys.createKey('made while macOS said no');
      await pumpEventQueue();
      expect(keychain.writes.where((w) => w == name), isEmpty);
      expect(keptIds(), ['k-old']);

      // macOS lets ZestSSH in now (Try again, Always Allow).
      keychain.failing = false;
      final second = keys.createKey('made after');
      await pumpEventQueue();
      expect(keptIds(), ['k-old', first.key.id, second.key.id]);
      expect(keys.state.map((k) => k.id), ['k-old', first.key.id, second.key.id]);
    });

    test('read as they are, they are written as ever', () async {
      keychain.kept[name] = AutomationApiKey.encodeList([old]);
      final keys = AutomationKeysNotifier(keychain);
      await keys.ready;
      keys.deleteKey('k-old');
      await pumpEventQueue();
      expect(keptIds(), isEmpty);
    });
  });

  group('the accounts a recovery proof was registered for', () {
    test('a note that cannot read what is kept throws, and writes nothing over it', () async {
      final kept = jsonEncode({'a@example.com': 'uid-a', 'b@example.com': 'uid-b'});
      keychain.kept[LockoutRecoveryStore.accountsKey] = kept;
      keychain.failing = true;
      final store = LockoutRecoveryStore(keychain);
      await expectLater(store.rememberAccount('c@example.com', 'uid-c'), throwsA(isA<PlatformException>()));
      expect(keychain.kept[LockoutRecoveryStore.accountsKey], kept);
      // Asking which account is read leniently, as before: nothing is written by it.
      expect(await store.accountFor('a@example.com'), isNull);

      keychain.failing = false;
      await store.rememberAccount('c@example.com', 'uid-c');
      expect(jsonDecode(keychain.kept[LockoutRecoveryStore.accountsKey]!),
          {'a@example.com': 'uid-a', 'b@example.com': 'uid-b', 'c@example.com': 'uid-c'});
    });
  });

  group('the owners of teams on a phone', () {
    test('a read that fails throws, and neither a new owner nor a removal is written over the rest', () async {
      final kept = jsonEncode({'orchard-a': 'uid-a', 'orchard-b': 'uid-b'});
      keychain.kept[OrchardOwners.storageKey] = kept;
      keychain.failing = true;
      final owners = OrchardOwners(keychain);
      await expectLater(owners.read(), throwsA(isA<PlatformException>()));
      await expectLater(owners.set('orchard-c', 'uid-c'), throwsA(isA<PlatformException>()));
      await expectLater(owners.remove('orchard-a'), throwsA(isA<PlatformException>()));
      expect(keychain.kept[OrchardOwners.storageKey], kept);

      keychain.failing = false;
      await owners.set('orchard-c', 'uid-c');
      expect(await owners.read(), {'orchard-a': 'uid-a', 'orchard-b': 'uid-b', 'orchard-c': 'uid-c'});
    });

    test('nothing kept, or what is kept no map, is still none', () async {
      final owners = OrchardOwners(keychain);
      expect(await owners.read(), isEmpty);
      keychain.kept[OrchardOwners.storageKey] = 'not json';
      expect(await owners.read(), isEmpty);
    });
  });
}
