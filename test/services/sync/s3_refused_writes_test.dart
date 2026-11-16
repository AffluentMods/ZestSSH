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
import 'package:zestssh/services/sync_service.dart';

/// One PUT as the store saw it.
typedef _Put = ({bool conditional, int status});

/// An S3 store on this computer, over a real connection, that a test tells
/// how to answer a write that asks for a condition: as AWS does while another
/// conditional write to the key is in flight (409 ConditionalRequestConflict),
/// or with a 412 whether the condition held or not.
class _Store {
  _Store._(this._server) {
    _server.listen(_answer);
  }

  static Future<_Store> start() async => _Store._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  Uint8List? object;
  String? etag;

  /// How the next writes that ask for a condition are answered, in order,
  /// before anything is looked at. Once used up, a condition is looked at.
  final refuseNext = <int>[];

  /// Every write that asks for a condition refused with a 412, held or not.
  bool refusesEveryCondition = false;

  /// What happens right after the store sends its nth refusal (from 1), and
  /// before the app has it: another device's write lands then.
  final afterRefusal = <int, void Function()>{};
  var _refusals = 0;

  /// Runs once, as the next unconditional write comes in and before it is
  /// taken: another device's write lands right then.
  void Function()? beforeUnconditionalPut;

  /// Runs once, right after the next write is taken: another device writes
  /// over it before anyone reads it.
  void Function()? afterPut;

  final puts = <_Put>[];

  String get address => 'http://127.0.0.1:${_server.port}';
  Future<void> close() => _server.close(force: true);

  void hold(Uint8List bytes) {
    object = bytes;
    etag = '"${c.md5.convert(bytes)}"';
  }

  Future<void> _answer(HttpRequest request) async {
    final body = BytesBuilder(copy: false);
    await request.forEach(body.add);
    final r = request.response;
    if (request.method == 'GET') {
      if (object == null) {
        r.statusCode = HttpStatus.notFound;
        r.write(_error('NoSuchKey'));
      } else {
        r.headers.set('etag', etag!);
        r.add(object!);
      }
    } else if (request.method == 'PUT') {
      final ifMatch = request.headers.value('if-match');
      final ifNoneMatch = request.headers.value('if-none-match');
      final conditional = ifMatch != null || ifNoneMatch != null;
      int status;
      if (conditional && refuseNext.isNotEmpty) {
        status = refuseNext.removeAt(0);
      } else if (conditional && refusesEveryCondition) {
        status = HttpStatus.preconditionFailed;
      } else {
        if (!conditional) {
          beforeUnconditionalPut?.call();
          beforeUnconditionalPut = null;
        }
        final holds = (ifMatch == null || ifMatch == etag) && (ifNoneMatch == null || object == null);
        status = holds ? HttpStatus.ok : HttpStatus.preconditionFailed;
      }
      puts.add((conditional: conditional, status: status));
      if (status == HttpStatus.ok) {
        hold(body.takeBytes());
        r.headers.set('etag', etag!);
        afterPut?.call();
        afterPut = null;
      } else {
        r.statusCode = status;
        r.write(_error(status == HttpStatus.conflict ? 'ConditionalRequestConflict' : 'PreconditionFailed'));
        afterRefusal.remove(++_refusals)?.call();
      }
    } else {
      r.statusCode = HttpStatus.methodNotAllowed;
    }
    await r.close();
  }

  static String _error(String code) => '<?xml version="1.0" encoding="UTF-8"?><Error><Code>$code</Code></Error>';
}

/// A refused conditional write is not taken for a store that refuses
/// conditions until it is one (found in security
/// reviews). 739023d8 (ZS-1203, Cloudflare R2 refusing
/// every update) wrote again without the condition after one refusal whose
/// condition held, and asked for none for the rest of the run. AWS S3 answers
/// 409 ConditionalRequestConflict to a conditional write while another one to
/// the same key is in flight and not yet there to read: the app read, found
/// what it had read before, wrote over the other device's update as it landed,
/// and both devices believed they had written the same version.
///
/// Now a 409 never drops the condition: a moment's pause, a look, the write
/// again on the tag just read, and else a conflict (the caller pulls, merges
/// and pushes again). A 412 on what is unchanged is asked again once on the
/// fresh tag; only a second 412 on the same tag drops the condition, and a
/// write without one is read back. (What 739023d8 fixed, R2 compressing and
/// weakening its ETags, is held by s3_conditional_writes_test.)
void main() {
  late SecretKey dek;
  late Uint8List salt;
  late Uint8List verificationHash;
  late Uint8List wrappedPassword;

  late _Store store;
  late S3SyncBackend device;

  setUpAll(() async {
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    final passwordKey = SyncService.generateDek();
    verificationHash = await SyncService.computeVerificationHash(passwordKey);
    wrappedPassword = await SyncService.wrapDek(dek, passwordKey);
  });

  S3SyncBackend backend() => S3SyncBackend(
        endpoint: store.address,
        region: 'us-east-1',
        bucket: 'zest-demo',
        accessKeyId: 'demo-key',
        secretAccessKey: 'demo-secret',
      )..inFlightPause = const Duration(milliseconds: 20);

  setUp(() async {
    store = await _Store.start();
    device = backend();
  });
  tearDown(() async {
    device.dispose();
    await store.close();
  });

  Map<String, dynamic> hosts(String h) => {
        'connections': [
          {'id': h, 'host': '$h.example.com', 'port': 22},
        ],
        'identities': const <dynamic>[],
      };

  Future<int> create(S3SyncBackend on, [String h = 'first']) async => (await on.push(
        data: hosts(h),
        dek: dek,
        salt: salt,
        verificationHash: verificationHash,
        wrappedDekPassword: wrappedPassword,
        createOnly: true,
      ))
          .version;

  Future<int> update(int expectedVersion, [String h = 'mine']) async => (await device.push(
        data: hosts(h),
        dek: dek,
        salt: salt,
        verificationHash: verificationHash,
        expectedVersion: expectedVersion,
      ))
          .version;

  /// What another device's push of [version] puts there.
  Uint8List theirs(int version) {
    final json = jsonDecode(utf8.decode(store.object!)) as Map<String, dynamic>;
    json['version'] = version;
    json['deviceId'] = 'device-a';
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  Future<SyncConflictException> conflictOf(Future<void> Function() step) async {
    try {
      await step();
    } on SyncConflictException catch (e) {
      return e;
    }
    fail('it did not fail with a conflict');
  }

  bool everyPutAsked() => store.puts.every((p) => p.conditional);

  group('a 409: another write is in flight', () {
    test("a review's proof: the write goes again with its condition, never without one", () async {
      expect(await create(device), 1);
      store.refuseNext.add(HttpStatus.conflict);
      // Another device's update, as the proof has it: it lands if this one is
      // written without a condition.
      var aLanded = false;
      store.beforeUnconditionalPut = () {
        store.hold(theirs(2));
        aLanded = true;
      };

      expect(await update(1), 2);
      expect(everyPutAsked(), isTrue, reason: 'no write went without its condition');
      expect(aLanded, isFalse);
      expect(device.ifMatchDroppedForTest, isFalse);
    });

    test('what lands while it waits is a conflict, and it stands', () async {
      expect(await create(device), 1);
      late Uint8List aWrote;
      store.refuseNext.add(HttpStatus.conflict);
      store.afterRefusal[1] = () => store.hold(aWrote = theirs(2));

      final conflict = await conflictOf(() => update(1));
      expect(conflict.serverVersion, 2);
      expect(conflict.expectedVersion, 1);
      expect(conflict.storeAnswer, 'S3 PUT: HTTP 409 ConditionalRequestConflict');
      expect(store.object, aWrote, reason: 'what the other device wrote stands');
      expect(everyPutAsked(), isTrue);
      expect(device.ifMatchDroppedForTest, isFalse);
    });

    test('still in flight when asked again: a conflict, nothing written over, the condition kept', () async {
      expect(await create(device), 1);
      store.refuseNext.addAll([HttpStatus.conflict, HttpStatus.conflict]);
      final before = store.object;

      final conflict = await conflictOf(() => update(1));
      expect(conflict.storeAnswer, 'S3 PUT: HTTP 409 ConditionalRequestConflict');
      expect(conflict.serverVersion, 1);
      expect(store.object, before);
      expect(everyPutAsked(), isTrue);
      expect(device.ifMatchDroppedForTest, isFalse);

      // The caller pulls and pushes again, and it goes.
      expect(await update(1), 2);
    });

    test('a first upload goes again only where nothing is there yet', () async {
      store.refuseNext.add(HttpStatus.conflict);
      expect(await create(device, 'mine'), 1);
      expect(store.puts, hasLength(2));
      expect(everyPutAsked(), isTrue, reason: 'If-None-Match every time');
    });

    test("another device's first upload that lands while it waits is not written over", () async {
      // What the other device's first upload is, made on a store of its own.
      final elsewhere = store;
      final other = backend();
      addTearDown(other.dispose);
      expect(await create(other, 'theirs'), 1);
      final firstUpload = elsewhere.object!;
      store = await _Store.start();
      addTearDown(store.close);
      final second = backend();
      addTearDown(second.dispose);

      store.refuseNext.add(HttpStatus.conflict);
      store.afterRefusal[1] = () => store.hold(firstUpload);
      final conflict = await conflictOf(() => create(second, 'mine'));
      expect(conflict.serverVersion, 1);
      expect(store.object, firstUpload);
      expect(store.puts.where((p) => !p.conditional), isEmpty);
      store = elsewhere;
    });
  });

  group('a 412 on a condition that held', () {
    test('once: asked again on the fresh tag, taken, and the condition kept for later', () async {
      expect(await create(device), 1);
      store.refuseNext.add(HttpStatus.preconditionFailed);

      expect(await update(1), 2);
      expect(everyPutAsked(), isTrue);
      expect(device.ifMatchDroppedForTest, isFalse, reason: 'one refusal is not a store that refuses conditions');

      expect(await update(2), 3);
      expect(store.puts.last.conditional, isTrue);
    });

    test('changed when asked again: a conflict, and what the other device wrote stands', () async {
      expect(await create(device), 1);
      late Uint8List aWrote;
      store.refuseNext.addAll([HttpStatus.preconditionFailed, HttpStatus.preconditionFailed]);
      store.afterRefusal[2] = () => store.hold(aWrote = theirs(2));

      final conflict = await conflictOf(() => update(1));
      expect(conflict.serverVersion, 2);
      expect(conflict.storeAnswer, 'S3 PUT: HTTP 412 PreconditionFailed');
      expect(store.object, aWrote);
      expect(everyPutAsked(), isTrue);
      expect(device.ifMatchDroppedForTest, isFalse);
    });

    test('twice on the same tag: the store does not take conditions; the write goes without one and is read back',
        () async {
      store.refusesEveryCondition = true;
      expect(await create(device), 1);
      expect(store.puts.map((p) => p.status), [412, 412, 200]);
      expect(device.ifMatchDroppedForTest, isFalse, reason: 'a create always asks');

      expect(await update(1), 2);
      expect(device.ifMatchDroppedForTest, isTrue);
      expect(store.puts.skip(3).map((p) => p.status), [412, 412, 200]);

      expect(await update(2), 3);
      expect(store.puts.last.conditional, isFalse);
      expect(store.puts.where((p) => p.status == 412), hasLength(4), reason: 'not asked for again');
    });

    test('a write without a condition that another device writes over before it is read back is a conflict',
        () async {
      store.refusesEveryCondition = true;
      expect(await create(device), 1);
      expect(await update(1), 2);
      expect(device.ifMatchDroppedForTest, isTrue);

      late Uint8List aWrote;
      store.afterPut = () => store.hold(aWrote = theirs(3));
      final conflict = await conflictOf(() => update(2));
      expect(conflict.serverVersion, 3);
      expect(conflict.expectedVersion, 2);
      expect(store.object, aWrote, reason: 'nothing more was written over it');

      // The caller pulls, merges and pushes again on what is there.
      expect(await update(3), 4);
    });
  });
}
