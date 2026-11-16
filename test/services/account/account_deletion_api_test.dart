import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/account_deletion_api.dart';

void main() {
  const base = 'https://api.test/v1';

  AccountDeletionApi apiAnswering(int status, Map<String, dynamic> body,
      {List<http.Request>? seen}) {
    return AccountDeletionApi(
      baseUrl: base,
      client: MockClient((request) async {
        seen?.add(request);
        return http.Response(jsonEncode(body), status);
      }),
    );
  }

  Future<AccountDeletionException> refusal(AccountDeletionApi api) async {
    try {
      await api.deleteNow(token: 't', confirmUid: 'uid-1');
    } on AccountDeletionException catch (e) {
      return e;
    }
    fail('expected the deletion to be refused');
  }

  group('deleteNow', () {
    test("the only owner of an Orchard others are in is told which to hand over", () async {
      final e = await refusal(apiAnswering(409, {
        'error': 'Hand over ownership of your Orchards before deleting the account',
        'code': 'sole-owner',
        'orchards': ['o-1', 'o-2', 7],
      }));
      expect(e.code, 'sole-owner');
      expect(e.orchards, ['o-1', 'o-2'], reason: 'ids only; anything else is left out');
      expect(e.dataDeleted, isFalse);
    });

    test('sends the fresh token and the account being deleted', () async {
      final seen = <http.Request>[];
      await apiAnswering(200, {
        'success': true,
        'deleted': {'account': true, 'sync_data': true, 'sign_in': true},
      }, seen: seen)
          .deleteNow(token: 'fresh', confirmUid: 'uid-1');

      expect(seen.single.method, 'POST');
      expect(seen.single.url.toString(), '$base/account/delete');
      expect(seen.single.headers['Authorization'], 'Bearer fresh');
      expect(jsonDecode(seen.single.body), {'confirm_uid': 'uid-1'});
    });

    test('a 200 without the full report is an old server scheduling a deletion',
        () async {
      final e = await refusal(apiAnswering(
          200, {'success': true, 'grace_period_days': 30}));
      expect(e.code, 'server-outdated');
    });

    test('an old server asking for the password hash is outdated', () async {
      final e =
          await refusal(apiAnswering(400, {'error': 'Missing password_hash'}));
      expect(e.code, 'server-outdated');
    });

    test('the server code comes through, with whether data was deleted',
        () async {
      var e = await refusal(apiAnswering(403, {
        'error': 'Sign in again to delete your account',
        'code': 'recent-sign-in-required',
      }));
      expect(e.code, 'recent-sign-in-required');
      expect(e.dataDeleted, isFalse);

      e = await refusal(apiAnswering(502, {
        'error': 'Your data was deleted, but your sign-in could not be removed.',
        'code': 'identity-delete-failed',
        'data_deleted': true,
      }));
      expect(e.code, 'identity-delete-failed');
      expect(e.dataDeleted, isTrue);
    });

    test('no connection is a network failure', () async {
      final api = AccountDeletionApi(
        baseUrl: base,
        client: MockClient((_) async => throw const SocketException('down')),
      );
      final e = await refusal(api);
      expect(e.code, 'network');
      // What was caught is kept, for whoever says how the service stands.
      expect(e.cause, isA<SocketException>());
      expect(e.stopped, same(e.cause));
    });

    test('an answer that is a fault of the server keeps its status, for whoever says how the service stands', () async {
      final e = await refusal(apiAnswering(503, {'error': 'unavailable'}));
      expect(e.code, 'server-error');
      expect(e.cause, isNull);
      expect(e.stopped, 'HTTP 503: unavailable');
    });
  });

  test('no connection: what was caught is kept, whichever request it was', () async {
    final api = AccountDeletionApi(
      baseUrl: base,
      client: MockClient((_) async => throw const SocketException('down')),
    );
    for (final (what, ask) in <(String, Future<Object?> Function())>[
      ('reading the account', () => api.hostedSyncData('t')),
      ('checking that it is gone', () => api.isGone('t')),
    ]) {
      try {
        await ask();
        fail('$what was answered');
      } on AccountDeletionException catch (e) {
        expect(e.code, 'network', reason: what);
        expect(e.cause, isA<SocketException>(), reason: what);
        expect(e.stopped, same(e.cause), reason: what);
      }
    }
  });

  test('the sync password check value is sent when given', () async {
    final seen = <http.Request>[];
    await apiAnswering(200, {
      'success': true,
      'deleted': {'account': true, 'sync_data': true, 'sign_in': true},
    }, seen: seen)
        .deleteNow(
            token: 't',
            confirmUid: 'uid-1',
            passwordHash: Uint8List.fromList(List.filled(32, 9)));
    expect(jsonDecode(seen.single.body), {
      'confirm_uid': 'uid-1',
      'password_hash': base64Encode(List.filled(32, 9)),
    });
  });

  group('hostedSyncData', () {
    test('reads the salt and parameters when the account has synced data',
        () async {
      final data = await apiAnswering(200, {
        'email': 'a@b',
        'has_sync_data': true,
        'sync_salt': base64Encode([1, 2, 3]),
        'sync_argon2_params': {'memory': 131072},
      }).hostedSyncData('t');
      expect(data!.salt, [1, 2, 3]);
      expect(data.argon2Params, {'memory': 131072});
    });

    test('is null without synced data, or from a server that does not say',
        () async {
      expect(
          await apiAnswering(200, {'has_sync_data': false}).hostedSyncData('t'),
          isNull);
      expect(await apiAnswering(200, {'email': 'a@b'}).hostedSyncData('t'),
          isNull);
    });

    // A fresh sign-in alone could reset cloud sync, then delete the account
    // with no sync password, which deleted the copy the reset keeps thirty
    // days (found in the whitepaper check). The server
    // refuses the deletion while the copy is kept; the app says so before it
    // asks for a password or deletes anything of its own.
    test('while a copy Reset cloud sync set aside is kept, it is said, with the day the account can be deleted from',
        () async {
      AccountDeletionApi at(DateTime now, Map<String, dynamic> body) => AccountDeletionApi(
            baseUrl: base,
            now: () => now,
            client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
          );
      final account = {
        'has_sync_data': true,
        'sync_salt': base64Encode([1, 2, 3]),
        'sync_reset_at': '2026-10-20T08:00:00.000Z',
        'sync_reset_kept_days': 30,
      };
      try {
        await at(DateTime.utc(2026, 11, 19, 7), account).hostedSyncData('t');
        fail('expected the deletion to wait');
      } on AccountDeletionException catch (e) {
        expect(e.code, 'sync-reset-kept');
        expect(e.keptUntil, DateTime.utc(2026, 11, 19, 8));
      }
      final past = await at(DateTime.utc(2026, 11, 19, 9), account).hostedSyncData('t');
      expect(past!.salt, [1, 2, 3], reason: 'past its days the deletion goes on, with the vault in use asked for');
    });
  });

  test("the server's refusal while a reset copy is kept carries the day it can be deleted from", () async {
    final e = await refusal(apiAnswering(409, {
      'error': 'Cloud sync was reset recently.',
      'code': 'sync-reset-kept',
      'kept_until': '2026-11-19T08:00:00.000Z',
    }));
    expect(e.code, 'sync-reset-kept');
    expect(e.keptUntil, DateTime.utc(2026, 11, 19, 8));
    expect(e.dataDeleted, isFalse);
  });

  // Found in a security review: a team this
  // account alone owns is being deleted and its admins can still undo it.
  test("the server's refusal while a team's deletion can be undone carries the team and the day it goes", () async {
    final e = await refusal(apiAnswering(409, {
      'error': 'A team you alone own is being deleted, and its admins can undo that until it goes',
      'code': 'team-deletion-undoable',
      'orchards': ['o-1'],
      'kept_until': '2026-11-12T16:00:00.000Z',
    }));
    expect(e.code, 'team-deletion-undoable');
    expect(e.orchards, ['o-1']);
    expect(e.keptUntil, DateTime.utc(2026, 11, 12, 16));
    expect(e.dataDeleted, isFalse);
  });

  group('isGone', () {
    test('only an explicit "no such account" counts as gone', () async {
      expect(
          await apiAnswering(401, {
            'error': 'User not found',
            'code': 'account-not-found',
          }).isGone('t'),
          isTrue);
      expect(await apiAnswering(404, {}).isGone('t'), isTrue);
      expect(await apiAnswering(200, {'email': 'a@b'}).isGone('t'), isFalse);
    });

    test('any other refusal is not proof', () async {
      await expectLater(
        apiAnswering(401, {'error': 'Token expired'}).isGone('t'),
        throwsA(isA<AccountDeletionException>()),
      );
      await expectLater(
        apiAnswering(500, {}).isGone('t'),
        throwsA(isA<AccountDeletionException>()),
      );
    });
  });
}
