import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart' show failedCheckSaid;
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome;
import 'package:zestssh/utils/error_translator.dart';

/// The jump hosts a host is set to connect through cannot be followed (3.0,
/// from the SSH core's audit): one of them is no longer there, or they lead
/// back to one that was on the way already. Nothing is dialled then, and
/// what is wrong is something only its person can mend, in the host's own
/// settings or in a network's.
///
/// It was an error with an English sentence in it, which every screen
/// showed as "An unexpected error occurred while connecting", with the
/// sentence under the technical details.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late String keyPem;
  late AppDatabase tree;
  late ProviderContainer container;
  late _Resolves resolver;

  setUpAll(() async {
    keyPem = (await KeyGenerationService().generateEd25519(comment: 'deploy')).privatePem;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    resolver = _Resolves();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(resolver),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: 'id-deploy',
          label: 'deploy key',
          username: 'deploy',
          authMethod: 'publicKey',
          createdAt: DateTime(2026, 10, 1),
        ));
  });

  tearDown(() async {
    L10nGlobal.update(en);
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  /// A host saved with what it connects through. (Nothing answers at these
  /// addresses, and nothing is asked to: the way is found broken first.)
  Future<Connection> saved(String id, String label, {String? via, int last = 31}) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: '192.0.2.$last',
          identityId: const Value('id-deploy'),
          connectViaId: Value(via),
          createdAt: at,
          updatedAt: at,
        ));
    return (await tree.connectionsDao.getById(id))!;
  }

  /// What a session to [connection] says of how it failed, as its screen shows it.
  Future<ConnectionError> failureOf(Connection connection) async {
    final id = sessions().startSession(connection)!;
    final clock = Stopwatch()..start();
    while (stateOf(id)?.status != SessionStatus.error) {
      if (stateOf(id)?.status == SessionStatus.connected) fail('it connected');
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for the connection to fail');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final s = stateOf(id)!;
    final said = ConnectionError.translate(s.errorMessage!, host: s.host, port: s.port, username: s.username);
    await sessions().endSession(id);
    return said;
  }

  Network network(String name) => Network(
      id: name,
      name: name,
      color: GroupColor.blue,
      icon: LucideIcons.globe,
      triggers: const [AlwaysTrigger()],
      isFallback: false);

  /// On the network Office, [host] is set to go through [chain].
  void onOffice(Connection host, List<String> chain) => resolver.answers[host.id] = ResolvedConnection(
        hostId: host.id,
        network: network('Office'),
        address: host.host,
        port: host.port,
        username: 'deploy',
        identityKeyId: 'id-deploy',
        jumpChain: chain,
        bringUpVpnHostId: null,
      );

  test('the jump host a host is set to connect through is gone: said in the app\'s own words, with what to do',
      () async {
    final db = await saved('h-db', 'db-primary', via: 'h-gone');
    final said = await failureOf(db);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(
      said.description,
      'The jump host that db-primary is set to connect through is no longer there. Open db-primary and pick another '
      'under Connect via, or Direct.',
    );
    // A host with no name (none can be saved so now: a row from elsewhere) is called by its address.
    await saved('h-unnamed', 'to be unnamed', via: 'h-gone', last: 41);
    await tree.customStatement("UPDATE connections SET label = '' WHERE id = 'h-unnamed'");
    final unnamed = (await tree.connectionsDao.getById('h-unnamed'))!;
    expect(unnamed.label, isEmpty);
    expect((await failureOf(unnamed)).description,
        startsWith('The jump host that 192.0.2.41 is set to connect through is no longer there. Open 192.0.2.41 and '));
  });

  test('the jump host of a jump host is gone: said of the one whose way on is broken', () async {
    await saved('h-bastion', 'bastion', via: 'h-gone', last: 10);
    final db = await saved('h-db', 'db-primary', via: 'h-bastion');
    final said = await failureOf(db);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(
      said.description,
      'The jump host that bastion is set to connect through is no longer there. Open bastion and pick another under '
      'Connect via, or Direct.',
    );
  });

  // Found in a security review: a screen as a jump host was dialled
  // as an SSH server at its address, offered its own key's password, with
  // its carrier as a further hop.
  test('a remote screen or an FTPS host set as a jump host: refused before anything is dialled, named, on the '
      "host's own way and on a network's", () async {
    await saved('h-gw', 'gw', last: 9);
    await saved('s-desk', 'desk', via: 'h-gw', last: 10);
    await tree.customStatement("UPDATE connections SET protocol = 'vnc' WHERE id = 's-desk'");
    final db = await saved('h-db', 'db-primary', via: 's-desk');
    var said = await failureOf(db);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(said.description, en.jumpHostNotSsh('desk', 'db-primary'));
    expect(said.description, allOf(contains('Connect via'), contains('remote screen')));

    await saved('f-files', 'files', last: 11);
    await tree.customStatement("UPDATE connections SET protocol = 'ftps' WHERE id = 'f-files'");
    final web = await saved('h-web', 'web', last: 12);
    onOffice(web, ['f-files']);
    said = await failureOf(web);
    expect(said.description, en.jumpHostNotSsh('files', 'web'));
  });

  test('only hosts signed in to over SSH can be a jump host', () {
    for (final p in ConnectionProtocol.values) {
      final can = ConnectionProtocol.storedCanBeJumpHost(p.name);
      expect(can, {ConnectionProtocol.ssh, ConnectionProtocol.sftp, ConnectionProtocol.mosh, ConnectionProtocol.et}.contains(p),
          reason: p.name);
    }
    expect(ConnectionProtocol.storedCanBeJumpHost(null), isTrue, reason: 'a host saved before protocols were');
    expect(ConnectionProtocol.storedCanBeJumpHost('rdp'), isFalse, reason: 'nothing unknown');
  });

  test('jump hosts that lead back to one already on the way: said as a circle, naming where it closes', () async {
    // Each is set to connect through the other.
    await saved('h-bastion', 'bastion', via: 'h-db', last: 10);
    final db = await saved('h-db', 'db-primary', via: 'h-bastion');
    final said = await failureOf(db);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(
      said.description,
      'The jump hosts of db-primary go in a circle: db-primary comes up a second time on the way. Change Connect via '
      'on one of them.',
    );
    // A circle among the jump hosts themselves, which the host is not part of.
    await tree.delete(tree.connections).go();
    await saved('h-edge', 'edge-router', via: 'h-inner', last: 1);
    await saved('h-inner', 'inner-bastion', via: 'h-edge', last: 11);
    final web = await saved('h-web', 'web-01', via: 'h-inner', last: 21);
    expect(
      (await failureOf(web)).description,
      'The jump hosts of web-01 go in a circle: inner-bastion comes up a second time on the way. Change Connect via on '
      'one of them.',
    );
  });

  test('a jump host that a network sets for the host is gone, or the ones it sets go in a circle: said of the '
      'network\'s settings', () async {
    await saved('h-bastion', 'bastion', last: 10);
    final db = await saved('h-db', 'db-primary');
    onOffice(db, ['h-bastion', 'h-gone']);
    final gone = await failureOf(db);
    expect(gone.type, ConnectionErrorType.saidByApp);
    expect(
      gone.description,
      'A jump host that the network Office sets for db-primary is no longer there. Open the host overrides of Office '
      'and pick another for db-primary.',
    );

    // The same jump host twice.
    onOffice(db, ['h-bastion', 'h-bastion']);
    final twice = await failureOf(db);
    expect(twice.type, ConnectionErrorType.saidByApp);
    expect(
      twice.description,
      'The jump hosts that the network Office sets for db-primary go in a circle: bastion comes up a second time on '
      'the way. Open the host overrides of Office and change them.',
    );
    // The host itself among its own jump hosts.
    onOffice(db, ['h-bastion', 'h-db']);
    expect(
      (await failureOf(db)).description,
      'The jump hosts that the network Office sets for db-primary go in a circle: db-primary comes up a second time '
      'on the way. Open the host overrides of Office and change them.',
    );
  });

  // (What Server Monitor is told is kept with the host's state, and is what the host's status says of it.)
  test('Server Monitor is told the same of a host it cannot check for it, and says it', () async {
    final db = await saved('h-db', 'db-primary', via: 'h-gone');
    final polled = await sessions().openExecClient(db);
    expect(polled.outcome, MonitorExecOutcome.error);
    expect(polled.failedWith, isA<JumpChainBroken>());
    expect(
      failedCheckSaid(polled.failedWith!, host: 'db-primary', port: 22),
      'The jump host that db-primary is set to connect through is no longer there. Open db-primary and pick another '
      'under Connect via, or Direct.',
    );
    // And of one whose network names a jump host that is gone.
    await saved('h-bastion', 'bastion', last: 10);
    final web = await saved('h-web', 'web-01', last: 21);
    onOffice(web, ['h-bastion', 'h-gone']);
    final onNetwork = await sessions().openExecClient(web);
    expect(onNetwork.outcome, MonitorExecOutcome.error);
    expect(
      failedCheckSaid(onNetwork.failedWith!, host: 'web-01', port: 22),
      'A jump host that the network Office sets for web-01 is no longer there. Open the host overrides of Office and '
      'pick another for web-01.',
    );
  });

  test('in every language the app speaks, with the names in it', () {
    List<String> sentences(AppLocalizations l10n) => [
          l10n.jumpHostGoneDirect('db-primary'),
          l10n.jumpHostGoneInNetwork('db-primary', 'Office'),
          l10n.jumpHostCircle('db-primary', 'bastion'),
          l10n.jumpHostCircleInNetwork('db-primary', 'bastion', 'Office'),
        ];
    final english = sentences(en);
    expect(english.toSet(), hasLength(4));
    for (final locale in AppLocalizations.supportedLocales) {
      final said = sentences(lookupAppLocalizations(locale));
      for (var i = 0; i < said.length; i++) {
        expect(said[i], contains('db-primary'), reason: '$locale $i');
        if (i.isOdd) expect(said[i], contains('Office'), reason: '$locale $i');
        if (i >= 2) expect(said[i], contains('bastion'), reason: '$locale $i');
        if (locale.languageCode != 'en') expect(said[i], isNot(english[i]), reason: '$locale $i');
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

/// The network's settings for a host where a test gave some ([answers]);
/// for any other host there are none, and it is reached as it is saved.
class _Resolves implements ConnectionResolver {
  final answers = <String, ResolvedConnection>{};

  @override
  Future<ResolvedConnection> resolve(String hostId) async => answers[hostId] ?? (throw StateError('no networks here'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
