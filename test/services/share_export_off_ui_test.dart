import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/connection_share_service.dart';

/// Sealing a host's share file stretches its password 600,000 times
/// (PBKDF2): seconds on a phone. The export did it on the screen's own
/// isolate, so the app stood still for that long; the import already ran in a
/// worker (found in a review). It is measured here: a 16 ms tick must
/// keep running while the export works.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    temp = Directory.systemTemp.createTempSync('zest_share_off_ui_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a sealed export leaves the screen\'s isolate free', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h',
          label: 'web 01',
          host: 'web-01.example.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
    final host = (await db.connectionsDao.getById('h'))!;
    final whole = Stopwatch()..start();
    var last = whole.elapsedMilliseconds;
    var longest = 0;
    final tick = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = whole.elapsedMilliseconds;
      if (now - last > longest) longest = now - last;
      last = now;
    });
    final path = await ConnectionShareService.exportConnection(
      connection: host,
      identity: null,
      portForwardRules: const [],
      password: 'hunter2-hunter2',
      encryptionPassword: 'a long enough password',
    );
    tick.cancel();
    whole.stop();
    // ignore: avoid_print
    print('sealed export: ${whole.elapsedMilliseconds} ms in all, the longest the screen\'s isolate stood: $longest ms');
    expect(ConnectionShareService.isSealedShare(File(path).readAsBytesSync()), isTrue);
    expect(longest, lessThan(150), reason: 'the derivation ran on the screen\'s isolate');
  });
}
