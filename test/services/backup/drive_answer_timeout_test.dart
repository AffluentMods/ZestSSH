import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/backup/google_drive_destination.dart';

/// Google Drive backups wait for an answer for a time (found in a
/// review): nine requests had none, so Drive that took one and never
/// answered held a backup for good.
void main() {
  test('every request of the Drive destination has a time, longer for what it sends', () {
    final source = File('lib/services/backup/google_drive_destination.dart').readAsStringSync();
    final calls = RegExp(r'await http\.(?:get|post|delete)\(').allMatches(source).length;
    final timed = RegExp(r'\.timeout\(driveAnswerTime\(').allMatches(source).length;
    expect(calls, greaterThan(0));
    expect(timed, calls);
    expect(driveAnswerTime(), const Duration(seconds: 30));
    expect(driveAnswerTime(10 * 1024 * 1024), const Duration(seconds: 30 + 204));
  });
}
