import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/hosts/local_terminal.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space, TreeSpace;
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A snippet's Run on... offers a new terminal on this device first, where
/// the device has a shell of its own (a computer, an Android device; not an
/// iPhone or an iPad), and runs the snippet there as a run on a host does: its
/// variables and its "confirm before running" asked first, the command
/// entered once the terminal is connected, the free plan's limit said.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  bool full = false;
  final opened = <Connection>[];
  final spaces = <Space?>[];
  final sent = <(String, String)>[];

  SessionState _state(String id, String connectionId, SessionStatus status) => SessionState(
        status: status,
        connectionId: connectionId,
        connectionLabel: connectionId,
        host: 'localhost',
        port: 0,
        session: TerminalSession(
          id: id,
          connectionId: connectionId,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 11, 16),
        ),
      );

  void set(String id, SessionStatus status) =>
      state = {...state, id: _state(id, state[id]!.connectionId!, status)};

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      Space? space}) {
    if (full) return null;
    final id = 's-${opened.length + 1}';
    opened.add(connection);
    spaces.add(space);
    state = {...state, id: _state(id, connection.id, SessionStatus.connecting)};
    return id;
  }

  @override
  bool sendInput(String sessionId, Uint8List bytes, {bool atStart = false}) {
    sent.add((sessionId, utf8.decode(bytes)));
    return true;
  }
}

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => false;
}

ConnectionWithDetails _host(String id) => ConnectionWithDetails(
      connection: Connection(
        id: id,
        label: id,
        host: '$id.example.com',
        port: 22,
        colorIndex: 0,
        protocol: 'ssh',
        zlibCompression: false,
        keepAliveSeconds: 0,
        envVars: '',
        forwardAgent: false,
        compatibilityMode: false,
        sortOrder: 0,
        sizeTier: 1,
        pinned: false,
        monitored: false,
        createdAt: DateTime(2026, 11, 16),
        updatedAt: DateTime(2026, 11, 16),
      ),
    );

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() {
    debugTopSnackBarOnPhone = null;
    debugLocalTerminalOnThisDevice = null;
  });

  late ProviderContainer container;
  late _Sessions sessions;

  /// A button that does [run] with the app's context and ref, beside two
  /// hosts.
  Future<void> pump(WidgetTester tester, Future<void> Function(BuildContext, WidgetRef) run) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(p),
      redactionFleetRegistrar.overrideWith((ref) {}),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value([_host('dev-01'), _host('web-01')])),
      connectionGroupsProvider.overrideWith((ref) => Stream.value(const <ConnectionGroup>[])),
    ]);
    addTearDown(container.dispose);
    sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => run(context, ref),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
  }

  Future<void> go(WidgetTester tester) async {
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  final localRow = find.byKey(const ValueKey('host-picker-local-terminal'));

  group("Run on...'s picker", () {
    final picked = <ConnectionPickerResult>[];
    setUp(picked.clear);

    Future<void> Function(BuildContext, WidgetRef) picker({bool includeLocalTerminal = true}) =>
        (context, ref) async => picked.add(await ConnectionPickerDialog.show(context,
            title: l10n.zestSnippetsRunOnTitle,
            needsTerminal: true,
            place: HostListPlace.runSnippet,
            includeLocalTerminal: includeLocalTerminal));

    testWidgets('where this device has a shell: Local terminal is the first row, above the hosts', (tester) async {
      debugLocalTerminalOnThisDevice = true;
      await pump(tester, picker());
      await go(tester);
      expect(localRow, findsOneWidget);
      expect(find.descendant(of: localRow, matching: find.text(l10n.hostsToolbarTerminal)), findsOneWidget);
      expect(find.descendant(of: localRow, matching: find.text(l10n.connectionPickerLocalTerminalDesc)), findsOneWidget);
      final localTop = tester.getTopLeft(localRow).dy;
      for (final id in ['dev-01', 'web-01']) {
        expect(localTop, lessThan(tester.getTopLeft(find.byKey(ValueKey('host-picker-$id'))).dy),
            reason: 'above every host');
      }
      await tester.tap(localRow);
      await tester.pumpAndSettle();
      expect(picked.single.localTerminal, isTrue);
      expect(picked.single.connection, isNull);
    });

    testWidgets('where it has none (an iPhone, an iPad): no Local terminal, the hosts as before', (tester) async {
      debugLocalTerminalOnThisDevice = false;
      await pump(tester, picker());
      await go(tester);
      expect(localRow, findsNothing);
      expect(find.text(l10n.hostsToolbarTerminal), findsNothing);
      expect(find.byKey(const ValueKey('host-picker-web-01')), findsOneWidget);
    });

    testWidgets('a picker not for a run (a default host, a forward) never offers it', (tester) async {
      debugLocalTerminalOnThisDevice = true;
      await pump(tester, picker(includeLocalTerminal: false));
      await go(tester);
      expect(localRow, findsNothing);
    });

    testWidgets('keyboard: reached with Tab and picked with Enter', (tester) async {
      debugLocalTerminalOnThisDevice = true;
      await pump(tester, picker());
      await go(tester);
      // From the search box, Tab until the row has the focus.
      final rowFocus = Focus.of(tester.element(find.descendant(of: localRow, matching: find.byType(Container)).first));
      for (var i = 0; i < 6 && !rowFocus.hasFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(rowFocus.hasFocus, isTrue, reason: 'the row is reached with Tab');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked.single.localTerminal, isTrue);
    });

    testWidgets('a screen reader hears a button with its name and line', (tester) async {
      debugLocalTerminalOnThisDevice = true;
      final handle = tester.ensureSemantics();
      await pump(tester, picker());
      await go(tester);
      final label = '${l10n.hostsToolbarTerminal}, ${l10n.connectionPickerLocalTerminalDesc}';
      expect(find.bySemanticsLabel(label), findsOneWidget);
      expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          isSemantics(
            label: label,
            isButton: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
          ));
      handle.dispose();
    });

    testWidgets('Enter in the search: the top row, Local terminal; a host typed, that host', (tester) async {
      debugLocalTerminalOnThisDevice = true;
      await pump(tester, picker());
      await go(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked.single.localTerminal, isTrue);

      await go(tester);
      // "dev" is the start of no word of "Local terminal": the row goes, and
      // Enter goes to the host.
      await tester.enterText(find.byType(TextField), 'dev');
      await tester.pumpAndSettle();
      expect(localRow, findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked.last.connection?.connection.id, 'dev-01');

      await go(tester);
      await tester.enterText(find.byType(TextField), 'term');
      await tester.pumpAndSettle();
      expect(localRow, findsOneWidget, reason: 'a word of its name typed');
    });
  });

  group('run in a terminal on this device', () {
    Future<void> Function(BuildContext, WidgetRef) local(String command,
            {bool confirm = false, List<bool?>? into}) =>
        (context, ref) async {
          final done = await runCommandInLocalTerminal(context, ref,
              command: command, label: 'Disk', confirmFirst: confirm, snippetId: 'sn-1');
          into?.add(done);
        };

    testWidgets("opens one, the person's own, in front, and enters the command once it is connected",
        (tester) async {
      final done = <bool?>[];
      await pump(tester, local('df -h', into: done));
      await go(tester);
      final opened = sessions.opened.single;
      expect(opened.protocol, 'localShell');
      expect(opened.host, 'localhost');
      expect(sessions.spaces.single, isA<TreeSpace>(), reason: 'never a team space');
      expect(container.read(v3ActiveSessionTabProvider), 's-1');
      expect(container.read(sidebarSectionProvider), SidebarSection.sessions);
      expect(find.text(l10n.docCheckSnippetOpening(l10n.hostsToolbarTerminal)), findsOneWidget);
      expect(sessions.sent, isEmpty, reason: 'not before it is connected');

      sessions.set('s-1', SessionStatus.connected);
      await tester.pump(const Duration(milliseconds: 600));
      expect(sessions.sent, [('s-1', 'df -h\r')]);
      expect(done, [true]);
      expect(container.read(snippetUsageProvider)['sn-1']?.runCount, 1);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('its variables are asked first; cancelled, no terminal is opened', (tester) async {
      await pump(tester, local(r'du -sh ${DIR}'));
      await go(tester);
      expect(find.byType(TextFormField), findsWidgets, reason: 'the variable is asked for');
      expect(sessions.opened, isEmpty, reason: 'nothing opened before it is answered');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(sessions.opened, isEmpty);
      expect(sessions.sent, isEmpty);
    });

    testWidgets('its variables answered: filled in, then run', (tester) async {
      await pump(tester, local(r'du -sh ${DIR}'));
      await go(tester);
      await tester.enterText(find.byType(TextFormField).first, '/srv');
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.zestSnippetsRunButton).last);
      await tester.pumpAndSettle();
      expect(sessions.opened, hasLength(1));
      sessions.set('s-1', SessionStatus.connected);
      await tester.pump(const Duration(milliseconds: 600));
      expect(sessions.sent, [('s-1', "du -sh '/srv'\r")]);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('its own "confirm before running" asks; declined, nothing opens or runs', (tester) async {
      await pump(tester, local('uptime', confirm: true));
      await go(tester);
      expect(find.text(l10n.snippetRunConfirmTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(sessions.opened, isEmpty);
      expect(sessions.sent, isEmpty);
      expect(container.read(snippetUsageProvider)['sn-1'], isNull);
    });

    testWidgets('a risky command is checked first, as on a host', (tester) async {
      await pump(tester, local('rm -rf /'));
      container.read(dangerousCommandProtectionProvider.notifier).state = true;
      await go(tester);
      expect(find.text(l10n.dangerCommandTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(sessions.opened, isEmpty);
    });

    testWidgets('the free plan full: nothing opens, and that is said', (tester) async {
      final done = <bool?>[];
      await pump(tester, local('uptime', into: done));
      sessions.full = true;
      await go(tester);
      expect(done, [false]);
      expect(sessions.sent, isEmpty);
      expect(find.text(l10n.desktopShellFreeTierLimit(freeSessionLimit)), findsOneWidget);
      expect(container.read(snippetUsageProvider)['sn-1'], isNull, reason: 'not counted');
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a terminal that does not connect runs nothing, and that is said', (tester) async {
      await pump(tester, local('uptime'));
      await go(tester);
      sessions.set('s-1', SessionStatus.error);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(sessions.sent, isEmpty);
      expect(find.text(l10n.docCheckSnippetNotRun(l10n.hostsToolbarTerminal)), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
    });
  });

  group('what Run on picked, run there', () {
    testWidgets('Local terminal picked: a terminal on this device', (tester) async {
      await pump(tester, (context, ref) async {
        await runCommandOnPicked(context, ref, const ConnectionPickerResult.localTerminal(), command: 'uptime');
      });
      await go(tester);
      expect(sessions.opened.single.protocol, 'localShell');
      // Its terminal closed: nothing is left waiting to be entered.
      sessions.set('s-1', SessionStatus.disconnected);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('nothing picked: nothing runs', (tester) async {
      await pump(tester, (context, ref) async {
        await runCommandOnPicked(context, ref, const ConnectionPickerResult.none(), command: 'uptime');
      });
      await go(tester);
      expect(sessions.opened, isEmpty);
    });
  });
}
