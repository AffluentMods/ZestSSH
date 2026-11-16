import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where the app says that something failed, two rules a new call can break
/// without any screen of it being tested (3.0):
///
///  * what a network failure was reaching is named in the app's language:
///    `describeNetworkError` is never given a literal subject ("the sync
///    server" and "the host" were passed in English);
///  * an SFTP failure's notice carries the error as its details, so that
///    "Copy details" has something behind it (the phone's SFTP screen
///    dropped it): one that says it with sftpErrorMessage, with
///    sftpStartFailure for SFTP that could not start, or with
///    editorFailureSaid for an editor's save or reload.
void main() {
  final sources = [
    for (final f in Directory('lib').listSync(recursive: true))
      if (f is File && f.path.endsWith('.dart') && !f.path.contains('${Platform.pathSeparator}generated${Platform.pathSeparator}'))
        f,
  ];

  /// The text of the call that begins at [start] (its name), to the bracket
  /// that closes it.
  String callAt(String text, int start) {
    final open = text.indexOf('(', start);
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      final c = text[i];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return text.substring(start);
  }

  test('a network failure names what it was reaching in the app\'s language', () {
    final literal = RegExp(r'''subject:\s*['"]''');
    final wrong = <String>[];
    var calls = 0;
    for (final f in sources) {
      final text = f.readAsStringSync();
      for (final m in RegExp(r'\bdescribeNetworkError\(').allMatches(text)) {
        final call = callAt(text, m.start);
        if (call.startsWith('describeNetworkError(Object')) continue; // the function itself
        calls++;
        if (literal.hasMatch(call)) wrong.add('${f.path}: $call');
      }
    }
    expect(calls, greaterThanOrEqualTo(6), reason: 'the calls were found');
    expect(wrong, isEmpty);
  });

  test('every SFTP failure shown as a notice carries its details', () {
    final said = RegExp(r'\b(?:sftpErrorMessage|sftpStartFailure|editorFailureSaid)\(');
    final missing = <String>[];
    var notices = 0;
    for (final f in sources) {
      final text = f.readAsStringSync();
      for (final m in RegExp(r'\bshowTopSnackBar\(').allMatches(text)) {
        final call = callAt(text, m.start);
        if (!said.hasMatch(call)) continue;
        notices++;
        if (!RegExp(r'\bdetails:').hasMatch(call)) missing.add('${f.path}: $call');
      }
    }
    // (17: a phone's two notices of a delete became one, which says what
    // went wrong before it is shown, with its details: _sayDeleted in
    // lib/ui/screens/sftp/sftp_browser_screen.dart, which
    // test/ui/sftp/phone_delete_hold_test.dart and phone_file_actions_test.dart read.)
    expect(notices, greaterThanOrEqualTo(17), reason: 'the notices were found');
    expect(missing, isEmpty);
  });
}
