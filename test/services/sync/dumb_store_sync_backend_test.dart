// Real Argon2id key derivation (the weakest accepted profile); allow for a
// machine busy compiling and running the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';

/// A shared in-memory object store two "devices" (backends) can point at.
/// [supportsEtag] toggles CAS-capable (WebDAV/S3) vs no-CAS (Drive) behaviour.
/// [beforeWrite] simulates another device committing in the read→write gap.
class FakeStore {
  Uint8List? bytes;
  String? etag;
  int counter = 0;
  final bool supportsEtag;

  /// Whether a write that asks for "only if nothing is there" is refused
  /// when something is. Not every store does (some S3-compatible ones take
  /// the write).
  final bool honoursIfAbsent;
  void Function()? beforeWrite;
  FakeStore({this.supportsEtag = true, this.honoursIfAbsent = true});
}

class FakeStoreBackend extends DumbStoreSyncBackend {
  final FakeStore store;
  FakeStoreBackend(this.store);

  @override
  SyncBackendKind get kind => SyncBackendKind.webdav;

  @override
  String get displayName => 'Fake';

  @override
  Future<void> checkConnection() async {}

  @override
  Future<RawObject?> readObject() async {
    if (store.bytes == null) return null;
    return RawObject(store.bytes!, store.supportsEtag ? store.etag : null);
  }

  @override
  Future<String?> writeObject(
    Uint8List bytes, {
    String? ifMatchEtag,
    bool ifAbsent = false,
  }) async {
    // Simulate a racing write from another device, then clear the hook.
    store.beforeWrite?.call();
    store.beforeWrite = null;

    if (ifAbsent && store.honoursIfAbsent && store.bytes != null) {
      throw const SyncConflictException(serverVersion: -1, expectedVersion: -1);
    }
    if (ifMatchEtag != null &&
        store.supportsEtag &&
        ifMatchEtag != store.etag) {
      throw const SyncConflictException(serverVersion: -1, expectedVersion: -1);
    }
    store.bytes = Uint8List.fromList(bytes);
    store.counter++;
    store.etag = 'etag-${store.counter}';
    return store.etag;
  }

  @override
  Future<void> deleteObject() async {
    store.bytes = null;
    store.etag = null;
  }
}

void main() {
  // Weakest params `deriveKey` accepts: the v1 legacy profile. The floor was
  // raised from the generic OWASP minimum (19456/2/1) to this, because the
  // parameters travel WITH the pulled blob - accepting anything weaker than
  // the app has ever written let a hostile store force a cheap-to-crack
  // derivation. Tests must derive with a set the app would really accept.
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};

  late SecretKey dek;
  late Uint8List salt;
  late SecretKey mek;
  late SecretKey wrongMek;
  late Uint8List verHash;
  late Uint8List wrappedPw;
  final data = {
    'connections': [
      {'id': 'c1', 'host': 'example.com', 'port': 22}
    ],
    'identities': const <dynamic>[],
  };

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    wrongMek = await SyncService.deriveKey('wrong-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
    wrappedPw = await SyncService.wrapDek(dek, mek);
  });

  Future<({int version, int blobSize, DateTime? updatedAt})> create(FakeStoreBackend b) => b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: wrappedPw,
        createOnly: true,
      );

  group('create + status + pull', () {
    test('first push creates v1 and round-trips the data', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);

      expect((await b.getStatus()).hasData, isFalse);

      final res = await create(b);
      expect(res.version, 1);

      final status = await b.getStatus();
      expect(status.hasData, isTrue);
      expect(status.version, 1);

      final pull = await b.pull();
      final decrypted = await SyncService.decrypt(pull.encryptedData, dek);
      expect((decrypted['connections'] as List).first['id'], 'c1');
      expect(pull.wrappedDekPassword, wrappedPw);
      expect(pull.salt, salt);
    });
  });

  group('create-race (the headline data-loss fix)', () {
    test('second device creating on a now-occupied store gets a conflict',
        () async {
      final store = FakeStore();
      final a = FakeStoreBackend(store);
      final b = FakeStoreBackend(store);

      await create(a); // A wins → v1
      // B also believed the store was empty (createOnly) but A got there first.
      expect(create(b), throwsA(isA<SyncConflictException>()));
      // A's data is intact - not clobbered.
      final pull = await b.pull();
      final decrypted = await SyncService.decrypt(pull.encryptedData, dek);
      expect((decrypted['connections'] as List).first['id'], 'c1');
    });

    test('a store that takes any write is still not written over: the app looks before it creates', () async {
      // (3.0: only the store's own refusal stood between a second "Set up
      // sync" and the first device's vault, and some stores do not refuse.)
      final store = FakeStore(honoursIfAbsent: false);
      final a = FakeStoreBackend(store);
      final b = FakeStoreBackend(store);
      await create(a);
      final before = Uint8List.fromList(store.bytes!);
      await expectLater(
        create(b),
        throwsA(isA<SyncConflictException>().having((e) => e.serverVersion, 'the version that is there', 1)),
      );
      expect(store.bytes, before, reason: 'nothing was written');
      expect(store.counter, 1);
      // What is there is still the first device's.
      final pull = await b.pull();
      expect(pull.version, 1);
      expect(pull.wrappedDekPassword, wrappedPw);
    });

    test('a store that takes any write and was written to in the moment between: the write is refused where the store can', () async {
      // The look finds nothing, another device writes, then this one does:
      // a store that honours "only if nothing is there" refuses it.
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      store.beforeWrite = () {
        store.bytes = Uint8List.fromList([1, 2, 3]);
        store.etag = 'etag-other';
      };
      await expectLater(create(b), throwsA(isA<SyncConflictException>()));
      expect(store.bytes, [1, 2, 3], reason: 'what the other device wrote stands');
    });

    test('create-race is caught even on a no-ETag (Drive-like) store',
        () async {
      final store = FakeStore(supportsEtag: false);
      final a = FakeStoreBackend(store);
      final b = FakeStoreBackend(store);
      await create(a);
      expect(create(b), throwsA(isA<SyncConflictException>()));
    });
  });

  group('optimistic-lock CAS', () {
    test('stale expectedVersion is rejected', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      await create(b); // v1
      // Pushing as if the store were still at v0 must conflict.
      expect(
        b.push(
          data: data,
          dek: dek,
          salt: salt,
          verificationHash: verHash,
          expectedVersion: 0,
        ),
        throwsA(isA<SyncConflictException>()),
      );
    });

    test('correct expectedVersion advances the version', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      await create(b); // v1
      final res = await b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: 1,
      );
      expect(res.version, 2);
    });

    test('ETag CAS catches a write that lands in the read→write gap',
        () async {
      final store = FakeStore();
      final a = FakeStoreBackend(store);
      await create(a); // v1, etag-1

      // Simulate another device committing v2 right before our write lands.
      store.beforeWrite = () {
        store.bytes = Uint8List.fromList([1, 2, 3, 4]);
        store.counter++;
        store.etag = 'etag-${store.counter}';
      };

      // Our push read v1/etag-1 and expects v1; the gap-write changed the etag,
      // so the If-Match CAS must reject it.
      expect(
        a.push(
          data: data,
          dek: dek,
          salt: salt,
          verificationHash: verHash,
          expectedVersion: 1,
        ),
        throwsA(isA<SyncConflictException>()),
      );
    });
  });

  group('DEK carry-forward', () {
    test('a data-only push retains previously stored wrapped DEK + recovery',
        () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      final wrappedRecovery = await SyncService.wrapDek(dek, mek);
      final recoverySalt = SyncService.generateSalt();

      await b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: wrappedPw,
        wrappedDekRecovery: wrappedRecovery,
        recoverySalt: recoverySalt,
        createOnly: true,
      );

      // Normal data sync supplies NO wrapped material.
      await b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: 1,
      );

      final pull = await b.pull();
      expect(pull.wrappedDekPassword, wrappedPw);
      expect(pull.wrappedDekRecovery, wrappedRecovery);
      expect(pull.recoverySalt, recoverySalt);
    });
  });

  group('stale device after a password change', () {
    test('a data-only push with a stale salt keeps the account\'s salt, '
        'and joining with the new password still works', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      await create(b); // v1 under the first password (salt, verHash)

      // Device A changes the password: new salt, new MEK, DEK re-wrapped.
      final newSalt = SyncService.generateSalt();
      final newMek =
          await SyncService.deriveKey('new-password', newSalt, params: fast);
      final newVerHash = await SyncService.computeVerificationHash(newMek);
      await b.push(
        data: data,
        dek: dek,
        salt: newSalt,
        verificationHash: newVerHash,
        wrappedDekPassword: await SyncService.wrapDek(dek, newMek),
        expectedVersion: 1,
        argon2Params: fast,
      );

      // Device B still caches the OLD salt + verification value and keeps
      // syncing data with the DEK it already holds.
      await b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: 2,
        argon2Params: fast,
      );

      final pull = await b.pull();
      expect(pull.salt, newSalt, reason: 'the stale salt must not win');
      expect(pull.version, 3);

      // A third device joins with the new password against what's stored.
      final joinMek = await SyncService.deriveKey('new-password', pull.salt,
          params: pull.argon2Params);
      expect(await b.verifyPassword(joinMek), isTrue);
      final unwrapped =
          await SyncService.unwrapDek(pull.wrappedDekPassword!, joinMek);
      expect(await unwrapped.extractBytes(), await dek.extractBytes());
    });
  });

  group('key-material guard', () {
    test('refuses to create a store with no wrapped DEK', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      expect(
        b.push(
          data: data,
          dek: dek,
          salt: salt,
          verificationHash: verHash,
          createOnly: true,
          // wrappedDekPassword intentionally omitted
        ),
        throwsA(isA<SyncSetupRequiredException>()),
      );
      // Nothing was written.
      expect(store.bytes, isNull);
    });
  });

  group('verifyPassword (client-side by DEK unwrap)', () {
    test('accepts the right key, rejects the wrong one', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      await create(b);
      expect(await b.verifyPassword(mek), isTrue);
      expect(await b.verifyPassword(wrongMek), isFalse);
    });
  });

  group('purge', () {
    test('removes the store object', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      await create(b);
      await b.purge(verHash);
      expect((await b.getStatus()).hasData, isFalse);
    });
  });

  group('Argon2 params carry-forward (safe default bump)', () {
    const oldParams = {
      'version': 1,
      'memory': 65536,
      'iterations': 3,
      'parallelism': 4,
    };

    test('a data-only push keeps the stored params, not the new default',
        () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);

      // Establish an account under the OLD (v1 / 64 MB) params.
      await b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: wrappedPw,
        createOnly: true,
        argon2Params: oldParams,
      );
      expect((await b.pull()).argon2Params?['memory'], 65536);

      // A normal data-only sync supplies NO params - it must carry forward the
      // account's real params, NOT bump to the current default, or a second
      // device would derive the wrong key.
      await b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: 1,
      );
      final pulled = await b.pull();
      expect(pulled.argon2Params?['memory'], 65536,
          reason: 'params carried forward, not defaulted');
      expect(pulled.argon2Params?['version'], 1);
    });

    test('a key-establishing push stores the supplied params', () async {
      final store = FakeStore();
      final b = FakeStoreBackend(store);
      const newParams = {
        'version': 2,
        'memory': 131072,
        'iterations': 3,
        'parallelism': 4,
      };
      await b.push(
        data: data,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: wrappedPw,
        createOnly: true,
        argon2Params: newParams,
      );
      expect((await b.pull()).argon2Params?['memory'], 131072);
    });
  });
}
