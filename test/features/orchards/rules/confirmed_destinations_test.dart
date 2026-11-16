import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/rules/confirmed_destinations.dart';

/// A password from a Crate that asks again (3.0): the person is
/// asked once for each address the password goes to, on this device; the
/// same key to the same address is not asked about again, a new address
/// is, and a "no" is not remembered.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true));
  tearDown(() => db.close());

  test('a destination is the key and the address, whatever the case of the host', () {
    final a = destinationOf(identityId: 'k1', host: 'DB1.Example.com ', port: 22);
    expect(destinationOf(identityId: 'k1', host: 'db1.example.com', port: 22), a);
    expect(destinationOf(identityId: 'k1', host: 'db1.example.com', port: 2222), isNot(a));
    expect(destinationOf(identityId: 'k2', host: 'db1.example.com', port: 22), isNot(a));
    expect(destinationOf(identityId: 'k1', host: 'db2.example.com', port: 22), isNot(a));
    expect(a, isNot(contains('example')), reason: 'kept as a hash');
  });

  test('asked once per destination; a no is not remembered', () async {
    final asked = <String>[];
    var answer = true;
    Future<bool> go(String host, int port, {String key = 'k1'}) => confirmPasswordDestination(db,
        identityId: key, host: host, port: port, ask: (d) async {
          asked.add(d);
          return answer;
        });

    expect(await go('db1.example.com', 22), isTrue);
    expect(asked, ['db1.example.com:22']);
    expect(await go('DB1.example.com', 22), isTrue);
    expect(asked, ['db1.example.com:22'], reason: 'the same address: not asked again');

    // The host pointed somewhere else asks again, and so does another key.
    expect(await go('db1.example.com', 2222), isTrue);
    expect(await go('db1.example.com', 22, key: 'k2'), isTrue);
    expect(asked, ['db1.example.com:22', 'db1.example.com:2222', 'db1.example.com:22']);

    answer = false;
    expect(await go('evil.example', 22), isFalse);
    expect(await go('evil.example', 22), isFalse);
    expect(asked.where((d) => d == 'evil.example:22').length, 2, reason: 'a no is asked again next time');
    expect(await destinationConfirmedIn(db, destinationOf(identityId: 'k1', host: 'evil.example', port: 22)), isFalse);
  });

  // Found in a security review: a remote screen's address is as its
  // carrier sees it, so the carrier is part of where the password goes.
  test("a remote screen's destination is its address through its carrier: another carrier asks again", () async {
    final plain = destinationOf(identityId: 'k1', host: 'localhost', port: 5900);
    final viaA = destinationOf(identityId: 'k1', host: 'localhost', port: 5900, via: 'bastion.example.com:22');
    expect(viaA, isNot(plain));
    expect(destinationOf(identityId: 'k1', host: 'localhost', port: 5900, via: 'Bastion.example.com:22 '), viaA);
    expect(destinationOf(identityId: 'k1', host: 'localhost', port: 5900, via: 'other.example.com:22'), isNot(viaA));

    final asked = <String>[];
    Future<bool> go(String via) => confirmPasswordDestination(db,
        identityId: 'k1', host: 'localhost', port: 5900, via: via, ask: (d) async {
          asked.add(d);
          return true;
        });
    expect(await go('bastion.example.com:22'), isTrue);
    expect(await go('bastion.example.com:22'), isTrue);
    expect(asked, ['bastion.example.com:22 \u2192 localhost:5900'], reason: 'the same route: not asked again');
    expect(await go('evil.example.com:22'), isTrue);
    expect(asked, hasLength(2), reason: 'the screen moved to another carrier, or its carrier re-pointed: asked again');
  });

  test('the newest destinations are kept, up to the limit', () async {
    for (var i = 0; i <= kMaxConfirmedDestinations; i++) {
      await rememberDestinationIn(db, 'd$i');
    }
    expect(await destinationConfirmedIn(db, 'd0'), isFalse, reason: 'the oldest went');
    expect(await destinationConfirmedIn(db, 'd1'), isTrue);
    expect(await destinationConfirmedIn(db, 'd$kMaxConfirmedDestinations'), isTrue);
    // Confirming one again moves it to the newest.
    await rememberDestinationIn(db, 'd1');
    await rememberDestinationIn(db, 'd-new');
    expect(await destinationConfirmedIn(db, 'd1'), isTrue);
    expect(await destinationConfirmedIn(db, 'd2'), isFalse);
  });
}
