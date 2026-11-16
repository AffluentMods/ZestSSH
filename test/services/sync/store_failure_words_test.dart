import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sync/http_cap.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync/sync_manifest.dart';
import 'package:zestssh/services/sync/webdav_sync_backend.dart';
import 'package:zestssh/services/sync_service.dart' show SyncException, SyncSetupRequiredException;

/// A WebDAV or S3 server of the person's own on this computer, over a real
/// connection: each request is answered with the status played for its
/// method, and the body played for it.
class _PlayedStore {
  _PlayedStore._(this._server) {
    _server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = status[request.method] ?? HttpStatus.internalServerError;
      final played = body[request.method];
      if (played != null) request.response.add(played);
      await request.response.close();
    });
  }

  static Future<_PlayedStore> start() async =>
      _PlayedStore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final status = <String, int>{};
  final body = <String, List<int>>{};

  String get address => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

/// What [step] failed with; the test fails where it did not fail.
Future<SyncException> _failure(Future<void> Function() step) async {
  try {
    await step();
  } on SyncException catch (e) {
    return e;
  }
  fail('it did not fail');
}

SyncException _thrownBy(void Function() step) {
  try {
    step();
  } on SyncException catch (e) {
    return e;
  }
  fail('it did not fail');
}

Uint8List _bytesOf(Object json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// A store of the person's own failing (3.0): WebDAV, S3
/// and Google Drive refusing this device, holding nothing, answering with a
/// fault or not in time, holding what cannot be read, was said in English
/// in every language, in the words of the code. Each is said as the
/// situation it is, in the person's language, with those words kept for the
/// details.
void main() {
  final de = lookupAppLocalizations(const Locale('de'));
  final salt = base64Encode(List.filled(32, 0));
  final data = base64Encode(List.filled(80, 0));

  setUp(() => L10nGlobal.update(de));
  tearDown(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));

  group('what a store of the person\'s own answered', () {
    test('is said as the situation it is, in their language, with its English kept for the details', () {
      for (final (status, said) in [
        (401, de.syncStoreRefused),
        (403, de.syncStoreRefused),
        (404, de.syncStoreNotThere),
        (429, de.syncStoreFault(429)),
        (503, de.syncStoreFault(503)),
      ]) {
        final failure = SyncFailure.storeAnswered(status, 'WebDAV GET failed: HTTP $status');
        expect(failure.message, said, reason: 'HTTP $status');
        expect(failure.detail, 'WebDAV GET failed: HTTP $status');
      }

      final late = SyncFailure.storeNoAnswerInTime('Store request timed out after 30s');
      expect(late.message, '${de.syncStoreNoAnswerInTime} (ZS-1201)',
          reason: 'with the code a store that does not answer at all is said with');
      expect(late.detail, 'Store request timed out after 30s');
      final large = SyncFailure.storeTooLarge('Store response too large (2000 bytes), refused');
      expect(large.message, de.syncStoreTooLarge);
      expect(large.detail, 'Store response too large (2000 bytes), refused');
      expect(SyncFailure.storeEmpty.message, de.syncStoreEmpty);
      expect(SyncFailure.storeEmpty.detail, 'No sync data found');
    });

    test('a fault of its own keeps its status in every language, so that it is told for one, '
        'with the code of whose storage it is', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        L10nGlobal.update(l10n);
        final said = SyncFailure.ofStore(SyncFailure.storeAnswered(503, 'S3 GET failed: HTTP 503'), hosted: false);
        expect(said.message, '${l10n.syncStoreFault(503)} (ZS-1201)', reason: '$locale');
        expect(said.detail, 'S3 GET failed: HTTP 503', reason: '$locale');
        // A refusal is no fault of the store's: it stays as it was said.
        final refused = SyncFailure.storeAnswered(403, 'S3 GET failed: HTTP 403');
        expect(SyncFailure.ofStore(refused, hosted: false), same(refused), reason: '$locale');
      }
    });
  });

  group('sync data that cannot be read', () {
    test('is said as damaged or not ZestSSH\'s, in the person\'s language, with what was wrong kept for the details',
        () {
      for (final (bytes, what) in [
        (Uint8List.fromList([0xFF, 0x00, 0x13, 0x37]), 'Sync data at this location is not a valid ZestSSH manifest'),
        (_bytesOf([1, 2, 3]), 'Sync manifest is not a JSON object'),
        (_bytesOf({'app': 'not-zestssh', 'salt': salt, 'encrypted_data': data}),
            'This file was not written by ZestSSH cloud sync'),
        (_bytesOf({'app': 'zestssh', 'version': 1}), 'Sync manifest is missing required fields'),
        (_bytesOf({'app': 'zestssh', 'salt': 'not!!base64!!', 'encrypted_data': data}),
            'Sync manifest field "salt" is not valid base64'),
        (_bytesOf({'app': 'zestssh', 'salt': salt, 'encrypted_data': data, 'version': 'nine'}),
            'Sync manifest "version" is not a number'),
      ]) {
        final said = _thrownBy(() => SyncManifest.fromBytes(bytes));
        expect(said.message, de.syncStoreDataUnreadable, reason: what);
        expect(said.detail, what);
      }
    });

    test('written by a newer version is said as that: update ZestSSH here to read it', () {
      final said = _thrownBy(() => SyncManifest.fromBytes(
          _bytesOf({'app': 'zestssh', 'manifest_version': 999, 'salt': salt, 'encrypted_data': data})));
      expect(said.message, de.syncStoreDataNewer);
      expect(said.detail, 'Sync data written by a newer version (manifest v999)');
    });
  });

  group('a WebDAV server of the person\'s own, over a real connection', () {
    late _PlayedStore store;
    late WebDavSyncBackend webdav;

    setUp(() async {
      store = await _PlayedStore.start();
      webdav = WebDavSyncBackend(serverUrl: store.address, username: 'alex', password: 'demo-password');
    });
    tearDown(() async {
      webdav.dispose();
      await store.close();
    });

    test('refusing the user name or the password, or answering with a fault, is said in the person\'s language',
        () async {
      store.status['PROPFIND'] = 401;
      var said = await _failure(webdav.checkConnection);
      expect(said.message, de.syncWebDavRefused);
      expect(said.detail, 'WebDAV rejected the username or password');

      store.status['PROPFIND'] = 503;
      said = await _failure(webdav.checkConnection);
      expect(said.message, de.syncStoreFault(503));
      expect(said.detail, 'WebDAV server returned HTTP 503');

      store.status['PUT'] = 507;
      said = await _failure(() => webdav.writeObject(Uint8List(4)));
      expect(said.message, de.syncStoreFault(507));
      expect(said.detail, 'WebDAV PUT failed: HTTP 507');

      store.status['DELETE'] = 403;
      said = await _failure(webdav.deleteObject);
      expect(said.message, de.syncWebDavRefused);
      store.status['DELETE'] = 502;
      said = await _failure(webdav.deleteObject);
      expect(said.message, de.syncStoreFault(502));
      expect(said.detail, 'WebDAV DELETE failed: HTTP 502');
    });

    test('what it holds: nothing yet, a fault, what cannot be read, no recovery key', () async {
      store.status['GET'] = 404;
      var said = await _failure(webdav.pull);
      expect(said.message, de.syncStoreEmpty);

      store.status['GET'] = 500;
      said = await _failure(webdav.pull);
      expect(said.message, de.syncStoreFault(500));
      expect(said.detail, 'WebDAV GET failed: HTTP 500');

      store
        ..status['GET'] = 200
        ..body['GET'] = utf8.encode('<html>not sync data</html>');
      said = await _failure(webdav.pull);
      expect(said.message, de.syncStoreDataUnreadable);
      expect(said.detail, 'Sync data at this location is not a valid ZestSSH manifest');

      store.body['GET'] = _bytesOf({'app': 'zestssh', 'salt': salt, 'encrypted_data': data});
      said = await _failure(() => webdav.pullWithRecoveryKey('ABCD-EFGH-IJKL'));
      expect(said.message, de.syncStoreNoRecoveryKey);
      expect(said.detail, 'Recovery key has not been configured for this sync store');
    });

    test('what stops sync until it is set up again is said in the person\'s language, with its English kept',
        () async {
      // Nothing there, and nothing to write data with that could be opened
      // again.
      store.status['GET'] = 404;
      var said = await _failure(() => webdav.push(
            data: const {'hosts': <Object>[]},
            dek: SecretKey(List.filled(32, 7)),
            salt: Uint8List(32),
            verificationHash: Uint8List(32),
          ));
      expect(said, isA<SyncSetupRequiredException>());
      expect(said.message, de.syncStoreDataMissing);
      expect(said.detail, 'No sync data in the store, and no wrapped data key to write a recoverable one');

      // Data in the retired format: no data key wrapped by the password.
      store
        ..status['GET'] = 200
        ..body['GET'] = _bytesOf({'app': 'zestssh', 'salt': salt, 'encrypted_data': data});
      said = await _failure(() => webdav.verifyPassword(SecretKey(List.filled(32, 7))));
      expect(said, isA<SyncSetupRequiredException>());
      expect(said.message, de.syncStoreOldFormat);
      expect(said.detail, 'Sync data in the retired format, with no password-wrapped data key');
    });
  });

  group('S3 storage of the person\'s own, over a real connection', () {
    late _PlayedStore store;
    late S3SyncBackend s3;

    setUp(() async {
      store = await _PlayedStore.start();
      s3 = S3SyncBackend(
        endpoint: store.address,
        region: 'us-east-1',
        bucket: 'zest-demo',
        accessKeyId: 'demo-key',
        secretAccessKey: 'demo-secret',
      );
    });
    tearDown(() async {
      s3.dispose();
      await store.close();
    });

    test('refusing access, or answering with a fault, is said in the person\'s language', () async {
      store.status['GET'] = 403;
      var said = await _failure(s3.checkConnection);
      expect(said.message, de.syncS3Refused);
      expect(said.detail, 'S3 denied access (403) to the connection test');
      said = await _failure(s3.pull);
      expect(said.message, de.syncS3Refused);
      expect(said.detail, 'S3 denied access (403) reading sync data');

      store.status['GET'] = 500;
      said = await _failure(s3.checkConnection);
      expect(said.message, de.syncStoreFault(500));
      expect(said.detail, 'S3 endpoint returned HTTP 500');
      said = await _failure(s3.pull);
      expect(said.message, de.syncStoreFault(500));
      expect(said.detail, 'S3 GET failed: HTTP 500');

      store.status['PUT'] = 503;
      said = await _failure(() => s3.writeObject(Uint8List(4)));
      expect(said.message, de.syncStoreFault(503));
      expect(said.detail, 'S3 PUT failed: HTTP 503');

      store.status['DELETE'] = 400;
      said = await _failure(s3.deleteObject);
      expect(said.message, de.syncStoreFault(400));
      expect(said.detail, 'S3 DELETE failed: HTTP 400');
    });
  });

  group('reading what a store sends', () {
    http.Request asked() => http.Request('GET', Uri.parse('https://dav.example.com/ZestSSH/sync/sync.json'));
    const soon = Duration(milliseconds: 50);

    test('no answer in time is said as that, with the code of whose storage it is', () async {
      final silent = MockClient.streaming((request, body) => Completer<http.StreamedResponse>().future);
      var said = await _failure(() => sendCapped(silent, asked(), 1000, timeout: soon));
      expect(said.message, '${de.syncStoreNoAnswerInTime} (ZS-1201)');
      expect(said.detail, startsWith('Store request timed out after'));

      final never = StreamController<List<int>>();
      addTearDown(never.close);
      final stalled = MockClient.streaming((request, body) async => http.StreamedResponse(never.stream, 200));
      said = await _failure(() => sendCapped(stalled, asked(), 1000, timeout: soon));
      expect(said.message, '${de.syncStoreNoAnswerInTime} (ZS-1201)');
      expect(said.detail, startsWith('Store response stalled for'));
    });

    test('more than the app takes is said as that', () async {
      final declared = MockClient.streaming((request, body) async =>
          http.StreamedResponse(Stream.value(List.filled(10, 0)), 200, contentLength: 2000));
      var said = await _failure(() => sendCapped(declared, asked(), 1000));
      expect(said.message, de.syncStoreTooLarge);
      expect(said.detail, 'Store response too large (2000 bytes), refused');

      final undeclared = MockClient.streaming((request, body) async =>
          http.StreamedResponse(Stream.fromIterable([List.filled(600, 0), List.filled(600, 0)]), 200));
      said = await _failure(() => sendCapped(undeclared, asked(), 1000));
      expect(said.message, de.syncStoreTooLarge);
      expect(said.detail, 'Store response over the 1000-byte limit, refused');
    });
  });

  group('the code', () {
    test('of the stores builds no sync failure from English words, but where that is known and listed', () {
      // A sync failure's message, of whatever kind (SyncException,
      // SyncSetupRequiredException...), is the sentence the person is shown:
      // it is said with gl10n, and the English goes in its detail. Where it
      // is still written in English, and why.
      // (None since ZestSSH Cloud and a ZestSSH server of one's own say
      // theirs in the person's language too.)
      const allowed = <String, String>{};
      final english = RegExp(r'''\bSync\w*Exception\(\s*r?['"]''');
      final found = <String>{};
      final files = Directory('lib/services/sync').listSync(recursive: true).whereType<File>().toList();
      for (final file in files) {
        if (!file.path.endsWith('.dart')) continue;
        if (english.hasMatch(file.readAsStringSync())) found.add(file.path.replaceAll(r'\', '/'));
      }
      expect(files.length, greaterThan(10), reason: 'the sync code was read');
      expect(found.difference(allowed.keys.toSet()), isEmpty,
          reason: 'a sync failure written in English: say it with gl10n, and keep the English for its detail');
      expect(allowed.keys.toSet().difference(found), isEmpty, reason: 'an allowance no longer needed: remove it');
    });
  });
}
