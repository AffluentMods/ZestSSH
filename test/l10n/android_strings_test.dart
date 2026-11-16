import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// Android's own words (found in a docs review): the
/// app shortcuts, the widget's description and the notification channel shown
/// while sessions are open were English in every language. Each of the app's
/// twelve has them, in the app's words, and the channel takes its words from
/// them (they were written into the code).
const _res = 'android/app/src/main/res';
const _languages = ['de', 'es', 'fr', 'it', 'pt', 'ru', 'ja', 'ko', 'zh', 'hi', 'ar'];

Map<String, String> _strings(String folder) => {
      for (final e in XmlDocument.parse(File('$_res/$folder/strings.xml').readAsStringSync())
          .findAllElements('string'))
        e.getAttribute('name')!: e.innerText,
    };

void main() {
  final english = _strings('values');

  test('every language has every one of the words, none of them empty, the long ones its own', () {
    expect(english.keys, containsAll(['shortcut_new_connection', 'widget_description', 'notification_channel_name']));
    for (final lang in _languages) {
      final words = _strings('values-$lang');
      for (final key in english.keys.where((k) => k != 'app_name')) {
        expect(words[key], isNotNull, reason: '$lang: $key');
        expect(words[key]!.trim(), isNotEmpty, reason: '$lang: $key');
      }
      for (final key in [
        'shortcut_new_connection_long',
        'widget_description',
        'notification_channel_description',
        'widget_empty',
        'widget_locked',
      ]) {
        expect(words[key], isNot(english[key]), reason: '$lang: $key in its own words');
      }
    }
  });

  test("the shortcuts use the app's words: New host, Import, Snippets", () {
    expect(english['shortcut_new_connection'], 'New host');
    expect(_strings('values-de')['shortcut_new_connection'], 'Neuer Host');
    expect(_strings('values-zh')['shortcut_snippets'], '代码片段');
  });

  test("the home screen widget's words are these: its empty list, the app lock, + (4.0)", () {
    expect(english['widget_empty'], 'No hosts yet. Tap + to add one.');
    // The XML's own \n, which Android makes a new line.
    expect(english['widget_locked'], r'App lock is on\nOpen ZestSSH to connect.');
    final layout = File('$_res/layout/widget_quick_connect.xml').readAsStringSync();
    expect(layout, contains('android:text="@string/widget_empty"'));
    expect(layout, contains('android:contentDescription="@string/shortcut_new_connection"'));
    expect(layout, isNot(contains('No connections yet')));
    expect(layout, isNot(contains('"Add connection"')));
    final widget =
        File('android/app/src/main/kotlin/com/affluentlabs/zestssh/widget/QuickConnectWidget.kt').readAsStringSync();
    expect(widget, contains('R.string.widget_locked'));
    expect(widget, contains('"flutter.widget_locked"'));
    expect(_strings('values-de')['widget_locked'], contains('Öffnen Sie'));
  });

  test('the notification channel takes its name and description from them', () {
    final service =
        File('android/app/src/main/kotlin/com/affluentlabs/zestssh/SshForegroundService.kt').readAsStringSync();
    expect(service, contains('getString(R.string.notification_channel_name)'));
    expect(service, contains('getString(R.string.notification_channel_description)'));
    expect(service, isNot(contains('"SSH Connections"')));
  });

  test('German says Sie, Spanish tu, Chinese ni with full-width marks', () {
    expect(_strings('values-de')['widget_description'], contains('Ihren'));
    expect(_strings('values-es')['widget_description'], contains('Conéctate'));
    final zh = _strings('values-zh');
    expect(zh['widget_description'], contains('你'));
    expect(zh['notification_channel_description'], contains('，'));
    expect(zh['notification_channel_description'], isNot(contains(', ')));
  });
}
