import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// An FTPS host on a phone opens the two-pane file screen, and its local pane
/// started at HOME: an Android app has none it may list (the folder is unset
/// or the system's root), so the pane opened on an error, and on an iPhone it
/// was the app's container, which Files does not show (found in a
/// review). On a phone it starts where the file browser's Download saves: the
/// shared Download folder or the app's own on Android, the app's Documents
/// (the ZestSSH folder in Files) on an iPhone or an iPad.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('zest_phone_pane_'));
  tearDown(() => dir.deleteSync(recursive: true));

  for (final os in ['android', 'ios']) {
    test('on $os the local pane starts where downloads are saved, a folder it can list', () async {
      final pane = LocalPaneFileSource(debugOs: os, phoneFolder: () async => dir);
      final home = await pane.homeDirectory();
      expect(home, dir.path);
      expect(await pane.list(home), isEmpty, reason: 'listed, not an error');
    });
  }

  test('on a computer it is the account home, as before', () async {
    final pane = LocalPaneFileSource(debugOs: Platform.operatingSystem, phoneFolder: () async => dir);
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;
    expect(await pane.homeDirectory(), home);
  });
}
