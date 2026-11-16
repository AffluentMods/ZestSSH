import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/number_in_phrase.dart';

/// Phrases that were glued from pieces in code, so the code fixed their word
/// order (found in a review): the status bar's "3" and " sessions",
/// the transfer title's " of 12", the Prometheus test's " - Found 4 targets"
/// and a finished transfer's "label (3 files)". Each is now one string the
/// language orders.
void main() {
  test('the status bar says its count in the language\'s order, the number styled apart', () {
    final ko = lookupAppLocalizations(const Locale('ko'));
    final span = numberInPhrase(ko.desktopStatusSessions(3), '3', number: const TextStyle(fontFamily: 'JetBrainsMono'));
    expect(span.toPlainText(), '세션 3개');
    final parts = [for (final c in span.children!) (c as TextSpan)];
    expect(parts.map((p) => p.text), ['세션 ', '3', '개']);
    expect(parts[1].style!.fontFamily, 'JetBrainsMono');
    final en = lookupAppLocalizations(const Locale('en'));
    expect(numberInPhrase(en.desktopStatusSessions(1), '1', number: const TextStyle()).toPlainText(), '1 session');
    expect(numberInPhrase('none', '7', number: const TextStyle()).toPlainText(), 'none');
  });

  test('the other three are whole phrases', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.sftpItemsSelectedOfTotal(en.sftpUploadItems(3), 12), 'Upload 3 items of 12');
    expect(en.monitorPrometheusConnectedFound(en.monitorPrometheusTestSuccess, en.monitorPrometheusTargetsFound(4)),
        'Connected to Prometheus successfully. Found 4 targets.');
    expect(en.sftpTransferDoneWhat('logs', en.sftpNFiles(3)), 'logs (3 files)');
    final ja = lookupAppLocalizations(const Locale('ja'));
    expect(ja.sftpTransferDoneWhat('logs', ja.sftpNFiles(3)), 'logs（3 件のファイル）');
  });

  test('no string starts or ends with a space for code to glue on', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
    for (final key in ['desktopStatusSessionsWord', 'sftpItemsOfTotal']) {
      expect(en.containsKey(key), isFalse, reason: '$key is a piece, gone');
    }
  });
}
