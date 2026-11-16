import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/app_updater.dart';
import 'package:zestssh/services/settings_service.dart';

/// The start after an update says whether it went in: the version that runs
/// is the new one, or the app opened again on the old one (with the end of
/// the installer's log).
void main() {
  test('the new version runs: it went in; the note is gone', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await markUpdatePending(prefs, const PreparedUpdate(version: '3.0.1', executable: 'x', arguments: [], logPath: 'nowhere.log'),
        from: '3.0.0');
    final last = await takeLastUpdate(prefs, '3.0.1');
    expect((last as LastUpdateInstalled).version, '3.0.1');
    expect(prefs.getString(kUpdatePendingKey), isNull);
    expect(await takeLastUpdate(prefs, '3.0.1'), isNull, reason: 'said once');
  });

  test('the old version runs: it did not, with the last lines of the log', () async {
    final dir = await Directory.systemTemp.createTemp('zest-pending-');
    addTearDown(() => dir.delete(recursive: true));
    final log = File('${dir.path}/setup.log')..writeAsStringSync([for (var i = 1; i <= 100; i++) 'line $i'].join('\n'));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await markUpdatePending(prefs, PreparedUpdate(version: '3.0.1', executable: 'x', arguments: const [], logPath: log.path),
        from: '3.0.0');
    final last = await takeLastUpdate(prefs, '3.0.0') as LastUpdateNotInstalled;
    expect(last.version, '3.0.1');
    expect(last.log, startsWith('line 41'));
    expect(last.log, endsWith('line 100'));
  });

  test('another build of the same version: it went in only where that build runs', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Future<LastUpdate?> after(int? runningBuild) async {
      await markUpdatePending(
          prefs, const PreparedUpdate(version: '3.0.0', build: 280, executable: 'x', arguments: [], logPath: 'nowhere.log'),
          from: '3.0.0');
      return takeLastUpdate(prefs, '3.0.0', runningBuild: runningBuild);
    }

    expect(await after(280), isA<LastUpdateInstalled>());
    expect(await after(281), isA<LastUpdateInstalled>());
    final failed = await after(279);
    expect(failed, isA<LastUpdateNotInstalled>(), reason: 'build 279 opened again: the setup did not put 280 in');
    expect((failed as LastUpdateNotInstalled).version, '3.0.0');
  });

  test('the note is kept by "Reset all settings" (it is no setting)', () {
    expect(SettingsService.keptKeys, contains(kUpdatePendingKey));
    expect(SettingsService.isResetKey(kUpdatePendingKey), isFalse);
  });
}
