import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync_service.dart';

/// An S3 store on this computer, over a real connection, that answers as
/// Cloudflare does in front of R2: a GET that accepts gzip is sent
/// compressed with its ETag made a weak one (`W/"..."`), and a conditional
/// PUT compares If-Match strongly, so a weak tag never matches.
class _FakeR2 {
  _FakeR2._(this._server) {
    _server.listen(_answer);
  }

  static Future<_FakeR2> start() async =>
      _FakeR2._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// The sync object and its strong ETag, as the store holds them.
  Uint8List? object;
  String? etag;

  /// Every GET's ETag weak, compressed or not.
  bool weakensEveryEtag = false;

  /// Every write that asks for a condition refused, whether it held or not.
  bool refusesEveryCondition = false;

  /// Runs once, as the next PUT comes in and before it is looked at:
  /// another device writing in the moment between a read and a write.
  void Function()? beforePut;

  /// What each GET asked to be sent as (its Accept-Encoding).
  final acceptEncodings = <String?>[];

  /// The If-Match of each PUT (null where it had none).
  final ifMatches = <String?>[];

  /// Writes refused, and writes taken.
  int refusals = 0;
  int writes = 0;

  String get address => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  /// Puts [bytes] there as another device would.
  void hold(Uint8List bytes) {
    object = bytes;
    etag = '"${c.md5.convert(bytes)}"';
  }

  Future<void> _answer(HttpRequest request) async {
    final body = BytesBuilder(copy: false);
    await request.forEach(body.add);
    final r = request.response;
    if (request.method == 'GET') {
      final asked = request.headers.value('accept-encoding');
      acceptEncodings.add(asked);
      final held = object;
      if (held == null) {
        r.statusCode = HttpStatus.notFound;
        r.write(_error('NoSuchKey'));
      } else {
        final compressed = (asked ?? '').contains('gzip');
        r.headers.set(
          'etag',
          compressed || weakensEveryEtag ? 'W/$etag' : etag!,
        );
        r.headers.contentType = ContentType.json;
        if (compressed) {
          r.headers.set('content-encoding', 'gzip');
          r.add(gzip.encode(held));
        } else {
          r.add(held);
        }
      }
    } else if (request.method == 'PUT') {
      beforePut?.call();
      beforePut = null;
      final ifMatch = request.headers.value('if-match');
      final ifNoneMatch = request.headers.value('if-none-match');
      ifMatches.add(ifMatch);
      final asks = ifMatch != null || ifNoneMatch != null;
      final holds =
          (ifMatch == null || ifMatch == etag) &&
          (ifNoneMatch == null || object == null);
      if (!holds || (asks && refusesEveryCondition)) {
        refusals++;
        r.statusCode = HttpStatus.preconditionFailed;
        r.write(_error('PreconditionFailed'));
      } else {
        writes++;
        hold(body.takeBytes());
        r.headers.set('etag', etag!);
      }
    } else {
      r.statusCode = HttpStatus.methodNotAllowed;
    }
    await r.close();
  }

  static String _error(String code) =>
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<Error><Code>$code</Code><Message>No.</Message></Error>';
}

/// Sync to Cloudflare R2 refused every update after the first (3.2.7, a
/// Mac and an iPhone): "Another of your devices synced at the same moment"
/// (ZS-1203), with "server is at v-1, expected v-1" in Copy details. The
/// app asked for gzip, as its HTTP client does by default; Cloudflare
/// compressed the sync file and sent its ETag as a weak one, and a weak
/// ETag never satisfies If-Match. Now nothing is asked for compressed, a
/// weak tag is sent as the tag inside it, a store that refuses a condition
/// that held is read again and written without it, and the details say
/// what the store answered.
void main() {
  late SecretKey dek;
  late Uint8List salt;
  late Uint8List verificationHash;
  late Uint8List wrappedPassword;
  final data = {
    'connections': [
      {'id': 'c1', 'host': 'demo.example.com', 'port': 22},
    ],
    'identities': const <dynamic>[],
  };

  late _FakeR2 store;
  late S3SyncBackend s3;

  setUpAll(() async {
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    // A random key stands in for the one a password makes: what is pushed
    // only needs a password-wrapped data key to be there.
    final passwordKey = SyncService.generateDek();
    verificationHash = await SyncService.computeVerificationHash(passwordKey);
    wrappedPassword = await SyncService.wrapDek(dek, passwordKey);
  });

  setUp(() async {
    store = await _FakeR2.start();
    s3 = S3SyncBackend(
      endpoint: store.address,
      region: 'auto',
      bucket: 'zest-demo',
      accessKeyId: 'demo-key',
      secretAccessKey: 'demo-secret',
    );
  });
  tearDown(() async {
    s3.dispose();
    await store.close();
  });

  Future<int> create() async => (await s3.push(
    data: data,
    dek: dek,
    salt: salt,
    verificationHash: verificationHash,
    wrappedDekPassword: wrappedPassword,
    createOnly: true,
  )).version;

  Future<int> update(int expectedVersion) async => (await s3.push(
    data: data,
    dek: dek,
    salt: salt,
    verificationHash: verificationHash,
    expectedVersion: expectedVersion,
  )).version;

  test(
    'every update after the first goes through where the store compresses what it sends',
    () async {
      expect(await create(), 1);
      expect(await update(1), 2);
      expect(await update(2), 3);

      expect(store.acceptEncodings, isNotEmpty);
      expect(
        store.acceptEncodings,
        everyElement('identity'),
        reason: 'nothing is asked for compressed',
      );
      expect(
        store.refusals,
        0,
        reason: 'the store took every write the first time',
      );
      expect(
        store.ifMatches.skip(1),
        everyElement(allOf(isNotNull, startsWith('"'))),
        reason: 'every update still asked to go only over what was read',
      );
      expect(s3.ifMatchDroppedForTest, isFalse);

      final pulled = await s3.pull();
      expect(pulled.version, 3);
      final back = await SyncService.decrypt(pulled.encryptedData, dek);
      expect((back['connections'] as List).single['host'], 'demo.example.com');
    },
  );

  test(
    'a weak ETag, sent even with nothing compressed, is matched by the tag inside it',
    () async {
      store.weakensEveryEtag = true;
      expect(await create(), 1);
      final strong = store.etag;
      expect(await update(1), 2);

      expect(store.refusals, 0);
      expect(store.ifMatches.last, strong);
      expect(s3.ifMatchDroppedForTest, isFalse);
    },
  );

  // Refused once, a condition is asked again on the tag just read; only a
  // second refusal on the same tag drops it (a security review
  // found one refusal was taken for a store that refuses
  // conditions, s3_refused_writes_test).
  test(
    'a store that refuses every condition, held or not: the write goes again after a look and a second ask, '
    'and later updates to it ask for none',
    () async {
      store.refusesEveryCondition = true;

      expect(
        await create(),
        1,
        reason: 'nothing was there when it looked again',
      );
      expect(store.refusals, 2);
      expect(s3.ifMatchDroppedForTest, isFalse, reason: 'a create always asks');

      expect(await update(1), 2, reason: 'what was there was what was read');
      expect(store.refusals, 4);
      expect(s3.ifMatchDroppedForTest, isTrue);

      expect(await update(2), 3);
      expect(
        store.refusals,
        4,
        reason: 'not asked for again, so not refused again',
      );
      expect(store.ifMatches.last, isNull);
      expect(store.writes, 3);
      expect((await s3.pull()).version, 3);
    },
  );

  test(
    'another device writing between the read and the write is still a conflict: nothing is written over, '
    'and the details say what the store answered and which versions',
    () async {
      expect(await create(), 1);
      final mine = store.object!;
      late Uint8List theirs;
      store.beforePut = () {
        final json = jsonDecode(utf8.decode(mine)) as Map<String, dynamic>;
        json['version'] = 2;
        theirs = Uint8List.fromList(utf8.encode(jsonEncode(json)));
        store.hold(theirs);
      };

      final conflict = await _conflictOf(() => update(1));
      expect(conflict.serverVersion, 2);
      expect(conflict.expectedVersion, 1);
      expect(conflict.storeAnswer, 'S3 PUT: HTTP 412 PreconditionFailed');
      expect(
        conflict.message,
        'The store refused the write: S3 PUT: HTTP 412 PreconditionFailed. It holds v2, this push expected v1.',
      );
      expect(
        SyncFailure.writtenFirst(conflict).detail,
        conflict.message,
        reason: 'what Copy details carries where it happens twice over',
      );

      expect(
        store.object,
        theirs,
        reason: 'what the other device wrote stands',
      );
      expect(store.writes, 1);
      expect(s3.ifMatchDroppedForTest, isFalse);
    },
  );

  test(
    'a refused write on its own says what the store answered, not v-1',
    () async {
      store.hold(Uint8List.fromList(utf8.encode('{}')));
      final conflict = await _conflictOf(
        () => s3.writeObject(Uint8List(4), ifMatchEtag: '"not-it"'),
      );
      expect(conflict.storeAnswer, 'S3 PUT: HTTP 412 PreconditionFailed');
      expect(
        conflict.message,
        'The store refused the write: S3 PUT: HTTP 412 PreconditionFailed.',
      );
      expect(conflict.message, isNot(contains('v-1')));
    },
  );

  group('the pieces', () {
    test('an ETag goes into If-Match strong', () {
      expect(S3SyncBackend.strongEtag('W/"abc"'), '"abc"');
      expect(S3SyncBackend.strongEtag(' W/"abc" '), '"abc"');
      expect(S3SyncBackend.strongEtag('"abc"'), '"abc"');
      expect(
        S3SyncBackend.strongEtag('w/"abc"'),
        'w/"abc"',
        reason: 'only W/ marks a weak tag',
      );
    });

    test(
      'what a store answered: its status, and the code its body names where it names one',
      () {
        List<int> said(String text) => utf8.encode(text);
        expect(
          S3SyncBackend.storeAnswerOf(
            'S3 PUT',
            412,
            said('<Error><Code>PreconditionFailed</Code></Error>'),
          ),
          'S3 PUT: HTTP 412 PreconditionFailed',
        );
        expect(
          S3SyncBackend.storeAnswerOf(
            'S3 PUT',
            409,
            said('<Error><Code> ConditionalRequestConflict </Code></Error>'),
          ),
          'S3 PUT: HTTP 409 ConditionalRequestConflict',
        );
        expect(
          S3SyncBackend.storeAnswerOf('S3 PUT', 412, said('<html>busy</html>')),
          'S3 PUT: HTTP 412',
        );
        expect(
          S3SyncBackend.storeAnswerOf(
            'S3 PUT',
            412,
            said('<Code>not a code, <b>this</b></Code>'),
          ),
          'S3 PUT: HTTP 412',
          reason: 'only what looks like a code is kept',
        );
        expect(
          S3SyncBackend.storeAnswerOf('S3 PUT', 412, const []),
          'S3 PUT: HTTP 412',
        );
      },
    );
  });
}

/// The conflict [step] failed with; the test fails where it did not fail so.
Future<SyncConflictException> _conflictOf(Future<void> Function() step) async {
  try {
    await step();
  } on SyncConflictException catch (e) {
    return e;
  }
  fail('it did not fail with a conflict');
}
