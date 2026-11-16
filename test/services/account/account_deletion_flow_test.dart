import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/account_deletion_api.dart';
import 'package:zestssh/services/account/account_deletion_flow.dart';

/// The server, scripted: what deleting and the check answer, and in what
/// order they were called.
class _FakeApi extends AccountDeletionApi {
  _FakeApi(this.events, {this.deleteError, this.readError, this.gone = true, this.synced})
      : super(client: MockClient((_) async => http.Response('', 500)));

  final List<String> events;
  final AccountDeletionException? deleteError;

  /// Set, the account cannot be read: what is thrown for it.
  final AccountDeletionException? readError;
  final bool gone;
  final HostedSyncData? synced;
  Uint8List? sentHash;

  @override
  Future<HostedSyncData?> hostedSyncData(String token) async {
    final error = readError;
    if (error != null) throw error;
    return synced;
  }

  @override
  Future<void> deleteNow({
    required String token,
    required String confirmUid,
    Uint8List? passwordHash,
  }) async {
    events.add('delete-account:$confirmUid');
    sentHash = passwordHash;
    if (deleteError != null) throw deleteError!;
  }

  @override
  Future<bool> isGone(String token) async {
    events.add('check');
    return gone;
  }
}

void main() {
  const me = FreshSignIn(token: 'fresh-token', uid: 'uid-me', email: 'me@x');

  late List<String> events;
  setUp(() => events = []);

  AccountDeletionFlow flow({
    FreshSignIn? signIn = me,
    Object? signInError,
    bool sameAccount = true,
    _FakeApi? api,
    Future<bool> Function()? deleteSyncStore,
    Uint8List? syncPasswordHash,
    List<String>? soleOwnerOf,
  }) {
    return AccountDeletionFlow(
      soleOwnerOrchards: soleOwnerOf == null
          ? null
          : () async {
              events.add('check-orchards');
              return soleOwnerOf;
            },
      isSameAccount: (_) => sameAccount,
      signInAgain: () async {
        events.add('sign-in');
        if (signInError != null) throw signInError;
        return signIn;
      },
      suspendSync: () async => events.add('sync-off'),
      resumeSync: () => events.add('sync-on'),
      api: api ?? _FakeApi(events),
      askSyncPassword: (data) async {
        events.add('sync-password:${data.salt.length}');
        return syncPasswordHash;
      },
      deleteSyncStore: deleteSyncStore,
      forgetSyncKeys: () async => events.add('forget-sync-keys'),
      forgetAccount: (fresh) async => events.add('forget-account'),
    );
  }

  test('the server side goes in order: sign in, sync off, delete, check, forget',
      () async {
    final stages = <AccountDeletionStage>[];
    final outcome = await flow().run(onStage: stages.add);

    expect(outcome, isA<AccountDeletionServerDone>());
    expect(events, [
      'sign-in',
      'sync-off',
      'delete-account:uid-me',
      'check',
      'forget-account',
    ]);
    expect(stages, [
      AccountDeletionStage.signingIn,
      AccountDeletionStage.stoppingSync,
      AccountDeletionStage.deletingAccount,
      AccountDeletionStage.verifying,
    ]);
  });

  test('the only owner of an Orchard others are in: nothing is signed in to, stopped or deleted', () async {
    final outcome = await flow(
      soleOwnerOf: ['Acme', 'Ops'],
      deleteSyncStore: () async {
        events.add('delete-store');
        return true;
      },
    ).run();

    expect(outcome, isA<AccountDeletionFailed>());
    final failed = outcome as AccountDeletionFailed;
    expect((failed.code, failed.somethingDeleted), ('sole-owner', false));
    expect(failed.orchards, ['Acme', 'Ops']);
    expect(events, ['check-orchards'], reason: 'checked before anything else');
  });

  test('with no Orchard to hand over, the deletion goes on as before', () async {
    final outcome = await flow(soleOwnerOf: const []).run();
    expect(outcome, isA<AccountDeletionServerDone>());
    expect(events.first, 'check-orchards');
    expect(events.skip(1).first, 'sign-in');
  });

  test("the server's own check stops it too, naming the Orchards, and sync comes back on", () async {
    final outcome = await flow(
      api: _FakeApi(events,
          deleteError: const AccountDeletionException('sole-owner', 'HTTP 409', orchards: ['o-1'])),
    ).run();
    final failed = outcome as AccountDeletionFailed;
    expect((failed.code, failed.somethingDeleted), ('sole-owner', false));
    expect(failed.orchards, ['o-1']);
    expect(events.last, 'sync-on');
  });

  test('a store the person runs is deleted after sync is off, before the account',
      () async {
    final outcome = await flow(deleteSyncStore: () async {
      events.add('delete-store');
      return true;
    }).run();

    expect(outcome, isA<AccountDeletionServerDone>());
    expect(events.take(4),
        ['sign-in', 'sync-off', 'delete-store', 'delete-account:uid-me']);
  });

  test('backing out of signing in changes nothing', () async {
    final outcome = await flow(signIn: null).run();
    expect(outcome, isA<AccountDeletionCancelled>());
    expect(events, ['sign-in']);
  });

  test('a sign-in that fails deletes nothing and leaves sync alone', () async {
    final outcome = await flow(signInError: StateError('popup closed')).run();
    expect(outcome, isA<AccountDeletionFailed>());
    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'sign-in-failed');
    expect(failed.somethingDeleted, isFalse);
    expect(events, ['sign-in']);
  });

  test('signing in to another account deletes nothing', () async {
    final outcome = await flow(sameAccount: false).run();
    expect(outcome, isA<AccountDeletionWrongAccount>());
    expect(events, ['sign-in']);
  });

  test('a refusal before anything was deleted turns sync back on', () async {
    final outcome = await flow(
      api: _FakeApi(events,
          deleteError: const AccountDeletionException('network', 'offline')),
    ).run();

    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'network');
    expect(failed.somethingDeleted, isFalse);
    expect(events.last, 'sync-on');
    expect(events, isNot(contains('forget-sync-keys')));
    expect(failed.cause, 'offline', reason: 'what stopped it is carried to the screen');
  });

  test('what stopped a request is carried to the screen: what was caught, or the answer it got', () async {
    const caught = FormatException('what was caught');
    var outcome = await flow(
      api: _FakeApi(events, deleteError: const AccountDeletionException('network', 'no answer', cause: caught)),
    ).run();
    expect((outcome as AccountDeletionFailed).cause, same(caught));
    outcome = await flow(
      api: _FakeApi(events, deleteError: const AccountDeletionException('server-error', 'HTTP 503: unavailable')),
    ).run();
    expect((outcome as AccountDeletionFailed).cause, 'HTTP 503: unavailable');
    // Nothing was asked of the server: nothing stopped it.
    outcome = await flow(sameAccount: false).run();
    expect(outcome, isA<AccountDeletionWrongAccount>());
  });

  test('an account that could not be read: nothing is stopped or deleted, and what stopped it is carried', () async {
    const caught = FormatException('what was caught');
    final outcome = await flow(
      api: _FakeApi(events, readError: const AccountDeletionException('network', 'no answer', cause: caught)),
    ).run();
    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'network');
    expect(failed.somethingDeleted, isFalse);
    expect(failed.cause, same(caught));
    expect(events, ['sign-in'], reason: 'sync was never turned off, and nothing was asked to be deleted');
  });

  test('once the own store is gone, a server failure keeps sync off for good',
      () async {
    final outcome = await flow(
      deleteSyncStore: () async => true,
      api: _FakeApi(events,
          deleteError:
              const AccountDeletionException('server-error', 'HTTP 500')),
    ).run();

    final failed = outcome as AccountDeletionFailed;
    expect(failed.somethingDeleted, isTrue);
    expect(events.last, 'forget-sync-keys');
    expect(events, isNot(contains('sync-on')));
    expect(events, isNot(contains('forget-account')));
  });

  test('data deleted but the sign-in not: sync stays off, Delete account can finish',
      () async {
    final outcome = await flow(
      api: _FakeApi(events,
          deleteError: const AccountDeletionException(
              'identity-delete-failed', 'HTTP 502',
              dataDeleted: true)),
    ).run();

    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'identity-delete-failed');
    expect(failed.somethingDeleted, isTrue);
    expect(events.last, 'forget-sync-keys');
  });

  test('when the check finds the account still there, nothing local happens',
      () async {
    final outcome = await flow(api: _FakeApi(events, gone: false)).run();

    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'not-verified');
    expect(failed.somethingDeleted, isTrue);
    expect(events, isNot(contains('forget-account')));
    expect(events.last, 'forget-sync-keys');
  });

  test('backing out of the self-hosted store password turns sync back on',
      () async {
    final outcome = await flow(deleteSyncStore: () async => false).run();
    expect(outcome, isA<AccountDeletionCancelled>());
    expect(events, ['sign-in', 'sync-off', 'sync-on']);
  });

  test('a store that fails to delete deletes nothing else', () async {
    final outcome = await flow(deleteSyncStore: () async {
      throw StateError('WebDAV 503');
    }).run();

    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'sync-store-failed');
    expect(failed.somethingDeleted, isFalse);
    expect(events, isNot(contains('delete-account:uid-me')));
    expect(events.last, 'sync-on');
  });

  final synced = HostedSyncData(salt: Uint8List(16));

  test('synced data on ZestSSH Cloud: the sync password comes first, then deletion',
      () async {
    final api = _FakeApi(events, synced: synced);
    final hash = Uint8List.fromList(List.filled(32, 7));
    final outcome = await flow(api: api, syncPasswordHash: hash).run();

    expect(outcome, isA<AccountDeletionServerDone>());
    expect(events.take(4),
        ['sign-in', 'sync-password:16', 'sync-off', 'delete-account:uid-me']);
    expect(api.sentHash, hash);
  });

  test('backing out of the sync password changes nothing', () async {
    final outcome =
        await flow(api: _FakeApi(events, synced: synced)).run();
    expect(outcome, isA<AccountDeletionCancelled>());
    expect(events, ['sign-in', 'sync-password:16']);
  });

  test('a wrong sync password deletes nothing and turns sync back on',
      () async {
    final outcome = await flow(
      api: _FakeApi(events,
          synced: synced,
          deleteError: const AccountDeletionException(
              'verification-failed', 'HTTP 403')),
      syncPasswordHash: Uint8List(32),
    ).run();

    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'verification-failed');
    expect(failed.somethingDeleted, isFalse);
    expect(events.last, 'sync-on');
  });

  test('no synced data on ZestSSH Cloud: no sync password is asked for',
      () async {
    final api = _FakeApi(events);
    await flow(api: api).run();
    expect(events.where((e) => e.startsWith('sync-password')), isEmpty);
    expect(api.sentHash, isNull);
  });

  test('while a copy Reset cloud sync set aside is kept: nothing is asked, stopped or deleted, and the day the '
      'account can be deleted from is handed on', () async {
    final until = DateTime.utc(2026, 11, 19, 8);
    final outcome = await flow(
      api: _FakeApi(events,
          readError: AccountDeletionException('sync-reset-kept', 'kept', keptUntil: until)),
      deleteSyncStore: () async {
        events.add('delete-store');
        return true;
      },
    ).run();
    expect(outcome, isA<AccountDeletionFailed>());
    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'sync-reset-kept');
    expect(failed.keptUntil, until);
    expect(failed.somethingDeleted, isFalse);
    expect(events, ['sign-in'], reason: 'no sync password asked, sync not stopped, no store deleted');
  });

  test("the server's refusal while a reset copy is kept hands the day on too", () async {
    final until = DateTime.utc(2026, 11, 19, 8);
    final outcome = await flow(
      api: _FakeApi(events,
          deleteError: AccountDeletionException('sync-reset-kept', 'HTTP 409', keptUntil: until)),
    ).run();
    final failed = outcome as AccountDeletionFailed;
    expect(failed.code, 'sync-reset-kept');
    expect(failed.keptUntil, until);
    expect(failed.somethingDeleted, isFalse);
    expect(events.last, 'sync-on', reason: 'nothing was deleted: sync goes on');
  });
}
