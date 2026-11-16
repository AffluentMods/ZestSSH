import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
// The message a side says that it leaves with is not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_disconnect.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A session of the app's that its person ends tells the host that it
/// leaves (3.0, from the SSH core's audit).
///
/// The app closed its socket and said nothing, so a host wrote "Connection
/// closed by ..." into its log for every session that was simply ended:
/// what it writes when a connection breaks. The protocol has a message for
/// an end that is meant, and the SSH core sends it now.
///
/// The host is played by the test, and reads what the app sends last.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  test('the app\'s own service, signed in with its session open and then disconnected: the host is told that '
      'the app leaves, once, after its session was closed', () async {
    final server = PlayedServer();
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    final connecting = ssh.connect().timeout(const Duration(seconds: 15));
    await server.letIn();
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success]);
    await connecting;
    server.takeSent();

    await ssh.disconnect();
    await server.settle();
    final sent = server.takeSent();
    final goodbyes = [
      for (final packet in sent)
        if (packet[0] == SSH_Message_Disconnect.messageId) SSH_Message_Disconnect.decode(packet),
    ];
    expect(goodbyes, hasLength(1), reason: 'it sent ${sent.map((packet) => packet[0])}');
    // 11: by the application.
    expect((goodbyes.single.reasonCode, goodbyes.single.description), (11, 'disconnected by application'));
    // It is the last thing the app says.
    expect(sent.last[0], SSH_Message_Disconnect.messageId);
  });
}
