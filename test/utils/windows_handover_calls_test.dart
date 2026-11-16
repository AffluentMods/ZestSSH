import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_version.dart';
import 'package:zestssh/utils/windows_programs.dart';
import 'package:zestssh/utils/windows_registry.dart';

/// What the Store copy asks Windows for (found in reviews):
/// the website installer's uninstall entry, and a PowerShell that
/// does not answer, ended. Only reads, and only programs of the test's.
void main() {
  group('the registry', () {
    test('a value that is there is read whole', () {
      final product = readRegistryString(
        RegistryRoot.localMachine,
        r'SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        'ProductName',
      );
      expect(product, startsWith('Windows'));
      expect(product, isNot(contains('\u0000')));
    });

    test('a key or a value that is not there reads as none', () {
      expect(
        readRegistryString(
          RegistryRoot.currentUser,
          r'Software\ZestSSH no such key\{00000000-0000-0000-0000-000000000000}',
          'InstallLocation',
        ),
        isNull,
      );
      expect(
        readRegistryString(
          RegistryRoot.localMachine,
          r'SOFTWARE\Microsoft\Windows NT\CurrentVersion',
          'ZestSSH no such value',
        ),
        isNull,
      );
    });

    test('the website installer\'s entry is under the AppId of its script', () {
      final iss = File('installer/zestssh_setup.iss').readAsStringSync();
      final appId = RegExp(r'AppId=\{(\{[0-9A-F-]+\})').firstMatch(iss)![1]!;
      expect(StoreHandover.uninstallKey, endsWith('\\${appId}_is1'));
    });
  }, skip: !Platform.isWindows);

  group('a program asked with a time limit', () {
    test('answers as Process.run does', () async {
      final r = await runEndedAfter(windowsSystemProgram('cmd.exe'), [
        '/d',
        '/c',
        'echo hello& exit 3',
      ], const Duration(seconds: 20));
      expect(r.exitCode, 3);
      expect('${r.stdout}'.trim(), 'hello');
    });

    test(
      'one that does not answer in time is ended, not left running',
      () async {
        late int pid;
        final watch = Stopwatch()..start();
        await expectLater(
          runEndedAfter(
            windowsSystemProgram('ping.exe'),
            ['-n', '30', '127.0.0.1'],
            const Duration(seconds: 1),
            started: (p) => pid = p,
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
        // Ended: Windows lists no such process now.
        var running = true;
        for (var i = 0; i < 20 && running; i++) {
          final list = await Process.run(windowsSystemProgram('tasklist.exe'), [
            '/FI',
            'PID eq $pid',
            '/NH',
          ]);
          running = '${list.stdout}'.contains('$pid');
          if (running) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
        expect(running, isFalse);
      },
    );
  }, skip: !Platform.isWindows);
}
