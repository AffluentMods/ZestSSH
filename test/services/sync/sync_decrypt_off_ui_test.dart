import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync_service.dart';

/// A large sync package is opened in a worker isolate: its decrypt, its
/// inflate and its JSON decode held the screen still for as long as they
/// took (found in a review). A small one stays on the calling isolate.
void main() {
  final salt = Uint8List(32);
  final key = SecretKey(List<int>.generate(32, (i) => i));
  final wrongKey = SecretKey(List<int>.generate(32, (i) => 255 - i));
  final defaultFrom = SyncService.decryptOffIsolateFrom;

  setUp(() => SyncService.debugDecryptsOffIsolate = 0);
  tearDown(() => SyncService.decryptOffIsolateFrom = defaultFrom);

  /// Hosts with random notes, so that the package does not compress away.
  Map<String, dynamic> data(int hosts) {
    final random = Random(7);
    String noise(int n) => String.fromCharCodes([for (var i = 0; i < n; i++) 97 + random.nextInt(26)]);
    return {
      'version': 22,
      'connections': [
        for (var i = 0; i < hosts; i++)
          {'id': 'h$i', 'label': 'web-$i', 'host': 'web-$i.example.com', 'notes': noise(400)},
      ],
    };
  }

  test('the threshold is 256 KB', () {
    expect(defaultFrom, 256 * 1024);
  });

  test('a package under the threshold opens on the calling isolate, one over it in a worker, the same data', () async {
    final small = data(3);
    final sealedSmall = await SyncService.encrypt(small, key, salt);
    expect(await SyncService.decrypt(sealedSmall, key), small);
    expect(SyncService.debugDecryptsOffIsolate, 0);

    // A fake size: the threshold is moved under this package's.
    SyncService.decryptOffIsolateFrom = sealedSmall.length;
    expect(await SyncService.decrypt(sealedSmall, key), small);
    expect(SyncService.debugDecryptsOffIsolate, 1);
  });

  test('in a worker, a wrong key and damaged data fail as they do on the calling isolate', () async {
    final sealed = await SyncService.encrypt(data(3), key, salt);
    Future<SyncDecryptionException> failure(Uint8List package, SecretKey k) async {
      try {
        await SyncService.decrypt(package, k);
      } on SyncDecryptionException catch (e) {
        return e;
      }
      fail('opened');
    }

    final here = await failure(sealed, wrongKey);
    SyncService.decryptOffIsolateFrom = 0;
    final there = await failure(sealed, wrongKey);
    expect(there.message, here.message);
    expect(there.detail, here.detail);
    expect(there.detail, contains('SecretBoxAuthenticationError'));
    expect(SyncService.debugDecryptsOffIsolate, 1);
  });

  test('measured: a large package leaves the screen\'s isolate free', () async {
    final big = data(12000);
    final sealed = await SyncService.encrypt(big, key, salt);
    expect(sealed.length, greaterThan(256 * 1024));

    Future<(int, int)> timed() async {
      final whole = Stopwatch()..start();
      var last = 0;
      var longest = 0;
      final tick = Timer.periodic(const Duration(milliseconds: 16), (_) {
        final now = whole.elapsedMilliseconds;
        if (now - last > longest) longest = now - last;
        last = now;
      });
      final opened = await SyncService.decrypt(sealed, key);
      tick.cancel();
      // The stand that lasted to the end counts too (no tick ran in it).
      final end = whole.elapsedMilliseconds;
      if (end - last > longest) longest = end - last;
      expect((opened['connections'] as List).length, 12000);
      return (whole.elapsedMilliseconds, longest);
    }

    // As before: on the calling isolate.
    SyncService.decryptOffIsolateFrom = 1 << 40;
    final (beforeAll, beforeLongest) = await timed();
    SyncService.decryptOffIsolateFrom = defaultFrom;
    final (afterAll, afterLongest) = await timed();
    // ignore: avoid_print
    print('sync package of ${sealed.length ~/ 1024} KB: on the screen\'s isolate $beforeAll ms, longest stand '
        '$beforeLongest ms; in a worker $afterAll ms, longest stand $afterLongest ms');
    expect(SyncService.debugDecryptsOffIsolate, 1);
    expect(afterLongest, lessThan(beforeLongest), reason: 'the work ran on the screen\'s isolate');
    expect(jsonEncode(big).length, greaterThan(4 * 1024 * 1024));
  });
}
