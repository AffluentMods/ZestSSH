import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A task on a host that needs Compatibility mode (3.0, found while the SSH
/// core's audit was at RSA keys).
///
/// Compatibility mode is a switch of a saved host: with it the app also
/// offers what an old server needs (the CBC ciphers among it). A session to
/// such a host used it; a task that runs a command on the same host did
/// not, so it failed where the session connects, over the very thing the
/// switch is there for.
///
/// The host is played on the loopback address, and speaks aes256-cbc and no
/// other cipher. The task dials it as it dials any saved host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late AutomationService tasks;

  setUp(() {
    L10nGlobal.update(en);
    FlutterSecureStorage.setMockInitialValues({});
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    tasks = AutomationService(tree, const FlutterSecureStorage());
  });

  tearDown(() async {
    tasks.dispose();
    await tree.close();
  });

  /// `echo done` as a task runs it on a saved host that speaks only
  /// aes256-cbc, with Compatibility mode on for that host or off: what the
  /// task says, and whether the host was asked for a sign-in at all.
  Future<({AutomationResult result, bool askedToSignIn})> run({required bool compatibilityMode}) async {
    final listener = await PlayedListener.bind();
    final hostKey = PlayedHostKey.ed25519();
    // The host's key, as a person approves it once before a task may run there.
    await KnownHostsService(tree.knownHostsDao)
        .trustHost(listener.host, listener.port, SSHHostKey(type: hostKey.algorithm, bytes: hostKey.blob));
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-old',
          label: 'old-switch',
          host: listener.host,
          port: Value(listener.port),
          compatibilityMode: Value(compatibilityMode),
          createdAt: at,
          updatedAt: at,
        ));
    var askedToSignIn = false;
    final played = () async {
      final host = PlayedServer(line: await listener.line(), suite: PlayedSuite.cbc, hostKey: hostKey);
      await host.letIn();
      askedToSignIn = true;
      final channel = await host.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'exec');
      host.send([channel.success, channel.data('done\n'), channel.exitStatus(0), channel.eof, channel.close]);
    }();
    final result = await tasks.executeCommand(connectionId: 'h-old', command: 'echo done');
    // What the played host waits for does not come where the task gave up on it.
    await played.timeout(const Duration(seconds: 10)).then((_) {}, onError: (Object _) {});
    return (result: result, askedToSignIn: askedToSignIn);
  }

  test('with Compatibility mode on for the host: the task connects as a session does, and runs its command',
      () async {
    final outcome = await run(compatibilityMode: true);
    expect(outcome.askedToSignIn, isTrue, reason: 'the task ended at the key exchange: ${outcome.result.error}');
    expect(outcome.result.success, isTrue, reason: outcome.result.error);
    expect(outcome.result.output.trim(), 'done');
    expect(outcome.result.exitCode, 0);
  });

  test('with it off: nothing in common with such a host, as before, and no sign-in is asked for', () async {
    final outcome = await run(compatibilityMode: false);
    expect(outcome.askedToSignIn, isFalse);
    expect(outcome.result.success, isFalse);
    expect(outcome.result.error, isNotEmpty);
  });
}
