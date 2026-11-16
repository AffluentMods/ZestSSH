import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What is sent into a session's shell for its person goes through one door
/// (`ActiveSessionsNotifier.sendInput`, 3.0): by it the session knows when
/// something was last sent at its person's hand, which is how a shell that
/// ended by itself is told from one its person ended. Something that wrote
/// into a shell round the door would leave a session on screen as "ended
/// by its host" after its person had ended it with that.
void main() {
  test('nothing outside the session layer and the shell services writes into a session\'s shell', () {
    final writes = RegExp(r'shell\??\.write\(');
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart')) continue;
      // The shell services write to their own shells, and the session layer
      // is where the door is.
      if (path.startsWith('lib/services/') || path == 'lib/providers/terminal_providers.dart') continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (writes.hasMatch(lines[i])) found.add('$path:${i + 1}');
      }
    }
    expect(found, isEmpty, reason: 'send it with ActiveSessionsNotifier.sendInput');
  });

  test('the door is there, and is what is looked for', () {
    final source = File('lib/providers/terminal_providers.dart').readAsStringSync();
    expect(source, contains('bool sendInput(String sessionId, Uint8List bytes, {bool atStart = false})'));
    // What this test looks for is what a write looks like.
    expect(RegExp(r'shell\??\.write\(').hasMatch('      live.session!.shell.write(bytes);'), isTrue);
    expect(RegExp(r'shell\??\.write\(').hasMatch('      session?.session?.shell.write(inputBytes);'), isTrue);
    expect(RegExp(r'shell\??\.write\(').hasMatch('      _shell?.write(data);'), isTrue);
  });
}
