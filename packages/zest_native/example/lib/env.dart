// The example's settings: the process environment, and on Android (where an app gets none) a
// JSON object of the same names in the app's own files folder, written there for a run by
// `adb shell run-as com.affluentlabs.zest_screen_example` (stdin piped, nothing printed) and
// deleted after it. On iOS the same file sits in the app's Documents folder (the simulator's data
// container: `xcrun simctl get_app_container <device> com.affluentlabs.zestScreenExample data`),
// written there over SSH from stdin with umask 077 and deleted after the run. Nothing is stored by
// the app itself.
import 'dart:convert';
import 'dart:io';

/// The app's private files folder on Android (debug builds: `run-as` reaches it).
const androidFilesDir = '/data/user/0/com.affluentlabs.zest_screen_example/files';

/// The app's Documents folder on iOS: beside the app's tmp folder in its data container (Dart's
/// Platform.environment has no HOME there).
String get iosDocumentsDir => '${Directory.systemTemp.parent.path}/Documents';

final Map<String, String> env = _load();

Map<String, String> _load() {
  final m = Map<String, String>.of(Platform.environment);
  if (Platform.isAndroid || Platform.isIOS) {
    final f = File('${Platform.isIOS ? iosDocumentsDir : androidFilesDir}/zs_env.json');
    // Where the settings are looked for (never what they hold).
    stderr.writeln('zs_env: ${f.path} ${f.existsSync() ? 'found' : 'not there'}');
    if (f.existsSync()) {
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        for (final e in j.entries) {
          m[e.key] = '${e.value}';
        }
      } on FormatException {
        // A broken file: the form starts empty.
      }
    }
  }
  return m;
}
