import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// English counts read right for one (found in a review): plurals
/// with only an `other` form read "1 files", "1 items", "1 zombie
/// processes", and two singulars said "1 file already exist".
void main() {
  final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;

  test('every English plural on a count says one in its own words', () {
    final missing = <String>[];
    final head = RegExp(r'\{\s*([A-Za-z_]\w*)\s*,\s*plural\s*,');
    for (final e in en.entries) {
      if (e.key.startsWith('@') || e.value is! String) continue;
      final value = e.value as String;
      for (final m in head.allMatches(value)) {
        // The cases of this plural, up to its closing brace.
        var depth = 1, j = m.end;
        while (j < value.length && depth > 0) {
          if (value[j] == '{') depth++;
          if (value[j] == '}') depth--;
          j++;
        }
        final body = value.substring(m.end, j);
        if (!RegExp(r'(^|\s|\})(=1|one)\s*\{').hasMatch(body)) missing.add(e.key);
      }
    }
    expect(missing, isEmpty);
  });

  test('the counts a review named read right for one', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(l10n.sftpNFiles(1), '1 file');
    expect(l10n.sftpUploadItems(1), 'Upload 1 item');
    expect(l10n.sftpTreeItems(1), '1 item');
    expect(l10n.zestGroupInheritCount(3, 4, 1), contains('1 has its own.'));
    expect(l10n.zestMonProcesses(1, 40), startsWith('1 zombie process '));
    expect(l10n.sftpConflictsExact(1), startsWith('1 file already exists'));
    expect(l10n.sftpNFiles(2), '2 files');
  });

  test('the counts that had no plural at all read right for one', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(l10n.sshImportHostsFound(1), '1 host found');
    expect(l10n.sshImportHostsFound(3), '3 hosts found');
    expect(l10n.snippetsImportedCount(1), 'Imported 1 snippet');
    expect(l10n.portForwardConnections(1), '1 connection');
    expect(l10n.identityConnectionCount(1), '1 host');
    expect(l10n.feedbackRateLimited(1), endsWith('in 1 minute.'));
    expect(l10n.desktopShellTabClosedWithSessions(1), 'Tab closed (1 session)');
  });

  test('no English count says (s) for a plural (a word without a count may)', () {
    final found = [
      for (final e in en.entries)
        if (!e.key.startsWith('@') && e.value is String && RegExp(r'\{\w+\}[^{}]*\(s\)').hasMatch(e.value as String)) e.key,
    ];
    expect(found, isEmpty);
  });
}
