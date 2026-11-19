import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/services/connection_share_service.dart';

/// A host is offered to share only where what the other person receives is
/// the same host. A `.zest` host file of a kind the import does not take (a
/// remote screen, an FTPS host) was made and then refused where it was opened,
/// and a link or QR code of one added an SSH host at port 5900 or 3389. Those
/// kinds are not offered now; this ties the offer to what the import takes.
void main() {
  test('what is offered to share is exactly what the import takes', () async {
    final folder = Directory.systemTemp.createTempSync('zest_share_kinds_');
    addTearDown(() => folder.deleteSync(recursive: true));
    for (final kind in ConnectionProtocol.values) {
      final file = File('${folder.path}${Platform.pathSeparator}${kind.name}.zest')
        ..writeAsStringSync(jsonEncode({
          'version': 1,
          'type': ConnectionShareService.plainType,
          'connection': {'label': 'demo', 'host': 'host.example', 'port': 22, 'protocol': kind.name},
        }));
      Object? refused;
      try {
        final read = await ConnectionShareService.importConnection(file.path);
        if (read == null) refused = 'not read';
      } on FormatException catch (e) {
        refused = e;
      }
      expect(ConnectionShareService.canShare(kind.name), refused == null,
          reason: '${kind.name}: offered to share only where its file is taken');
    }
  });

  test('SSH kinds are shared; a remote screen, an FTPS, a serial and a local host are not', () {
    for (final kind in ['ssh', 'sftp', 'mosh', 'et', 'telnet']) {
      expect(ConnectionShareService.canShare(kind), isTrue, reason: kind);
    }
    for (final kind in ['vnc', 'rdp', 'ftps', 'serial', 'localShell']) {
      expect(ConnectionShareService.canShare(kind), isFalse, reason: kind);
    }
    expect(ConnectionShareService.canShare(null), isTrue, reason: 'a host from before the kinds is an SSH host');
  });

  test('every place that offers a share asks first', () {
    for (final (path, count) in const [
      ('lib/features/hosts/pages/hosts_home_page.dart', 1),
      ('lib/ui/screens/home/home_screen.dart', 1),
      ('lib/ui/screens/connection/connection_edit_screen.dart', 2),
    ]) {
      final source = File(path).readAsStringSync();
      expect('ConnectionShareService.canShare('.allMatches(source).length, count, reason: path);
    }
  });
}
