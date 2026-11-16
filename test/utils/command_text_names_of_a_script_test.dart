// CommandText.standsInAnyShell is
// said to let through "letters of any script", but it left out every modifier
// letter (\p{Lm}). The Japanese long vowel mark (U+30FC), the ideographic
// iteration mark (U+3005) and the Thai repetition mark (U+0E46) are Lm, and
// are in ordinary words of those scripts, so ordinary folder and file names
// got no cd command, no checksum and no follow.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/utils/command_text.dart';

/// Records the commands a service sends, and answers a checksum.
class _Recorder implements SSHClient {
  final commands = <String>[];

  @override
  Future<Uint8List> runCapped(String command, {required int maxBytes, required Duration timeout}) async {
    commands.add(command);
    return Uint8List.fromList('${'ab' * 32}  file\n'.codeUnits);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Ordinary names in scripts the app is translated into (ja) or that its
  // people use: none holds a quote, a backslash, an operator or a control.
  const ordinary = <String>[
    '/home/taro/\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9', // ダウンロード (Downloads)
    '/srv/\u30b5\u30fc\u30d0\u30fc', // サーバー (server)
    '/home/taro/\u30c7\u30fc\u30bf.csv', // データ.csv (data)
    '/home/li/\u4eba\u3005', // 人々 (people)
    '/home/somchai/\u0e14\u0e35\u0e46', // ดีๆ (Thai)
    '/home/taro/\u3044\u3059\u309e', // いすゞ (hiragana iteration mark)
    '/home/taro/\u30bf\u30cd\u30fd', // タネヽ (katakana iteration mark)
    '/home/taro/\uff80\uff9e\uff73\uff9d\uff9b\uff70\uff84\uff9e', // ﾀﾞｳﾝﾛｰﾄﾞ (halfwidth)
    '/home/kham/\u0e94\u0eb5\u0ec6', // ດີໆ (Lao)
  ];

  for (final path in ordinary) {
    test('a folder named $path can be opened in a terminal', () {
      expect(CommandText.standsInAnyShell(path), isTrue,
          reason: 'a letter of the script, as the fix says it lets through');
      expect(CommandText.cdInto(path), isNotNull);
    });
  }

  test('the checksum after a download of データ.csv is not skipped', () async {
    // sha256Remote returns null, and sends nothing, when the name is refused.
    const path = '/home/taro/\u30c7\u30fc\u30bf.csv';
    final client = _Recorder();
    expect(await SftpService(client).sha256Remote(path), 'ab' * 32);
    expect(client.commands.single, contains("sha256sum '$path'"));
  });

  test('other modifier letters stay out: one looks like a quote', () {
    for (final name in ['/srv/a\u02bcb', '/srv/a\u02b9b', '/srv/a\u02c6b']) {
      expect(CommandText.standsInAnyShell(name), isFalse, reason: name);
      expect(CommandText.cdInto(name), isNull, reason: name);
    }
  });
}
