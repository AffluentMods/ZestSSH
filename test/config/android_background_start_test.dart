import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// Android's side of two things (found in a 3.0 docs review):
///
///  * a scheduled task's worker started the app from the background, which
///    Android 10 and later drop, so a task ran only while the app was open;
///    now it starts the app while one of its windows can be seen, and
///    otherwise posts a notification whose tap starts it (the start Android
///    allows), its one-time token living as long as that notification;
///  * the notification shown while sessions are open said "1 active
///    connection" in English in every language.
///
/// Android's files do not run here: they are read.
const _kotlin = 'android/app/src/main/kotlin/com/affluentlabs/zestssh';
const _res = 'android/app/src/main/res';
const _languages = ['de', 'es', 'fr', 'it', 'pt', 'ru', 'ja', 'ko', 'zh', 'hi', 'ar'];

XmlDocument _strings(String folder) => XmlDocument.parse(File('$_res/$folder/strings.xml').readAsStringSync());

String? _string(XmlDocument doc, String name) =>
    doc.findAllElements('string').where((e) => e.getAttribute('name') == name).firstOrNull?.innerText;

void main() {
  test('a scheduled task starts the app only while it can be seen, and otherwise asks with a notification', () {
    final worker = File('$_kotlin/scheduler/SshTaskWorker.kt').readAsStringSync().replaceAll('\r\n', '\n');
    expect(worker, contains('val appOpen = appIsVisible()'));
    expect(worker, contains('IMPORTANCE_VISIBLE'));
    // The start is guarded; the other way is the notification.
    expect(worker, matches(RegExp(r'if \(appOpen\) \{\s*applicationContext\.startActivity\(intent\)')));
    expect(RegExp(r'startActivity\(').allMatches(worker).length, 1);
    expect(worker, contains('PendingIntent.getActivity('));
    expect(worker, contains('PendingIntent.FLAG_IMMUTABLE'));
    expect(worker, contains('setTimeoutAfter(TAP_TO_RUN_TTL_MS)'));
    expect(worker, contains('if (appOpen) ScheduledLaunchTokens.TTL_MS else TAP_TO_RUN_TTL_MS'));
    expect(worker, contains('areNotificationsEnabled()'));
    final tokens = File('$_kotlin/scheduler/ScheduledLaunchTokens.kt').readAsStringSync();
    expect(tokens, contains('fun issue(context: Context, ttlMs: Long = TTL_MS): String'));
    expect(tokens, contains(r'kept.add("$token:${now + ttlMs}")'));
  });

  test("the notification's words, and the open sessions' count, are in every language", () {
    final service = File('$_kotlin/SshForegroundService.kt').readAsStringSync();
    expect(service, isNot(contains('active connection')));
    expect(service, contains('getString(R.string.notification_active_one)'));
    expect(service, contains('getQuantityString(R.plurals.notification_active_sessions, count, count)'));
    final english = _strings('values');
    for (final lang in ['', ..._languages]) {
      final doc = _strings(lang.isEmpty ? 'values' : 'values-$lang');
      for (final name in ['notification_active_one', 'scheduled_channel_name', 'scheduled_channel_description',
          'scheduled_ready_title', 'scheduled_ready_text']) {
        final words = _string(doc, name);
        expect(words, isNotNull, reason: '$lang $name');
        expect(words!.trim(), isNotEmpty, reason: '$lang $name');
        if (lang.isNotEmpty) expect(words, isNot(_string(english, name)), reason: '$lang $name in its own words');
      }
      // The single one says no digit; the plural shows the count.
      expect(_string(doc, 'notification_active_one'), isNot(contains('1')), reason: lang);
      final plural = doc.findAllElements('plurals').singleWhere((e) => e.getAttribute('name') == 'notification_active_sessions');
      final other = plural.findElements('item').singleWhere((e) => e.getAttribute('quantity') == 'other').innerText;
      expect(other, contains('%d'), reason: lang);
    }
  });
}
