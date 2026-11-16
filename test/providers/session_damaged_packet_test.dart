import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/connection_lost_view.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A session that is sent a packet that does not pass its check (3.0, from
/// the SSH core's audit).
///
/// Every packet of a session carries a check value, and one that was
/// changed on the way, by a line that is failing or by whoever sits on it,
/// does not pass: the SSH core ends the connection and uses nothing of the
/// packet. The app said of it "The connection to web-01 ended.", and what
/// was behind that, in its report, was the core's text with two rows of
/// numbers in it: the check value the packet came with and the one it
/// should have had.
///
/// With the app's own session on a host played by the test, under two of
/// the ways the app has of protecting packets: chacha20-poly1305, which it
/// prefers, and aes256-ctr with a MAC.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  // What the session's own service wrote into the connection's log.
  late List<String> log;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    log = [];
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    // A try of connecting again waits two seconds in the app.
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(milliseconds: 200);
  });

  tearDown(() async {
    ActiveSessionsNotifier.debugReconnectDelay = null;
    sessionClock = DateTime.now;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// A session of the app's in a shell on a played host, saved as web-01,
  /// under [suite].
  Future<({String id, PlayedServer server, PlayedChannel channel})> inAShell(PlayedSuite suite) async {
    final server = PlayedServer(suite: suite);
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: 'web-01.example.com',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
    sessions().debugShellFor = (connection) => SshService(
          host: connection.host,
          port: connection.port,
          username: 'deploy',
          password: 'not-a-real-one',
          keepAliveSeconds: 0,
          onHostKeyVerify: (_, _, _) async => true,
          tunnelSocket: server.socket,
          onLog: log.add,
        );
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await server.letIn();
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success, channel.data('deploy@web-01:~\$ ')]);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected');
    return (id: id, server: server, channel: channel);
  }

  for (final suite in [PlayedSuite.chacha, PlayedSuite.ctrEtm]) {
    test('$suite: a packet that was changed on the way ends the session, which says that, keeps what was found in '
        'its log with no number in it, and is connected to again by itself', () async {
      final s = await inAShell(suite);
      // What the host printed, with one bit of its check value changed on the way.
      s.server.sendChanged([s.channel.data('total 48')], (packets) {
        packets[0][packets[0].length - 1] ^= 0x01;
      });
      await until(() => stateOf(s.id)?.status != SessionStatus.connected, 'the end of the session');
      await until(() => stateOf(s.id)?.dropCause != null, 'why it ended');
      final ended = stateOf(s.id)!;
      expect(ended.dropped, isTrue);
      expect(ended.dropCause, hostDataDamaged);
      expect(dropKind(ended.dropCause), 'packetCheckFailed', reason: 'what a report of it names');
      expect(
        dropSaid(en, ended, 'web-01'),
        (sentence: en.connectionLostDamaged('web-01'), tip: en.connectionLostDamagedTip, printed: null),
      );
      expect(ended.dropCause, isNot(matches(RegExp(r'\d'))), reason: 'no number in why it ended: ${ended.dropCause}');
      // The connection's log has the core's words, once.
      expect(
        log.where((line) => line.contains('did not pass its check')),
        [
          'ssh_session: A packet from the other side did not pass its check: it was changed or damaged on the way, or '
              'the two sides do not protect their packets the same way'
        ],
      );
      // A line that failed for a moment is worth the next try: longer than one waits here.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final later = stateOf(s.id)!;
      expect(later.isReconnecting || later.status == SessionStatus.connecting, isTrue,
          reason: 'it goes on connecting again by itself');
      expect(later.reconnectAttempt, greaterThanOrEqualTo(1));
      sessions().stopAutoReconnect(s.id);
      await sessions().endSession(s.id);
    });
  }

  test('the sentence and its tip, word for word, and in every language their own', () {
    expect(en.connectionLostDamaged('web-01'),
        'What came from web-01 did not pass its check, so nothing of it was used and the connection was ended.');
    expect(
      en.connectionLostDamagedTip,
      'A connection that is failing does this, and so does something that interferes with it on the way. If it '
      'keeps happening on one network, try another.',
    );
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n.connectionLostDamaged('web-01'), contains('web-01'), reason: '$locale');
      expect(l10n.connectionLostDamaged('web-01'), isNot(contains('{')), reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(l10n.connectionLostDamaged('web-01'), isNot(en.connectionLostDamaged('web-01')), reason: '$locale');
        expect(l10n.connectionLostDamagedTip, isNot(en.connectionLostDamagedTip), reason: '$locale');
      }
    }
  });
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
