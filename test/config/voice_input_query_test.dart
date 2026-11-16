import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Voice input on Android 11 and later: an app sees only the speech
/// recognisers it names in its manifest's queries, and the plugin's own
/// manifest adds none. Read, not run.
void main() {
  test('the manifest asks to see the speech recognition services', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final queries = manifest.split('<queries>').last.split('</queries>').first;
    expect(queries, matches(RegExp(r'<action\s+android:name="android\.speech\.RecognitionService"\s*/>')));
  });
}
