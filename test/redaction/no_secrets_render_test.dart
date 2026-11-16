import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/hosts/widgets/host_grid_area.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/redactor.dart';

/// The golden test of the recording-mode spec (section 11): seed a fleet,
/// turn the mode on, pump the surfaces that render fleet identifiers, and
/// assert that no seed value reaches ANY rendered text, tooltip or semantics
/// label. The screen list is derived from the route table: every route must
/// be either pumped here or explicitly classified as not pumpable in a widget
/// test, so a new screen fails this test until someone decides.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The fleet. Every value here is a secret for the purposes of this test.
  const hostLabels = ['Hypervisor Node3', 'app-server-01', 'app-router-01', 'lb-2'];
  const hostAddrs = ['10.50.0.24', '10.50.0.25', 'nas.home', '192.168.7.3'];
  const groupName = 'Edge Security';
  const username = 'alex';
  const keyName = 'Alex Desktop';
  const fingerprint = 'SHA256:Aq65otBkq++WRjtuKV+Xxu5fTMXxuE3isnjpem4u3xs=';
  const secrets = [
    ...hostLabels, ...hostAddrs, groupName, username, keyName, 'Aq65otBkq',
  ];

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
    prefs = await SharedPreferences.getInstance();
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerNames([...hostLabels, groupName])
      ..registerAddresses(hostAddrs);
  });

  tearDown(() {
    Redactor.instance
      ..clearNames()
      ..enabled = false;
  });

  /// Every string the framework would paint or announce for the pumped tree.
  List<String> renderedStrings(WidgetTester tester) {
    final out = <String>[];
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      out.add(t.data ?? t.textSpan?.toPlainText() ?? '');
      if (t.semanticsLabel != null) out.add(t.semanticsLabel!);
    }
    for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
      out.add(r.text.toPlainText());
    }
    for (final tip in tester.widgetList<Tooltip>(find.byType(Tooltip))) {
      out.add(tip.message ?? tip.richMessage?.toPlainText() ?? '');
    }
    for (final s in tester.widgetList<Semantics>(find.byType(Semantics))) {
      final label = s.properties.label;
      if (label != null) out.add(label);
    }
    return out;
  }

  void expectNoSecret(WidgetTester tester, String screen) {
    final all = renderedStrings(tester);
    expect(all, isNotEmpty, reason: '$screen rendered nothing');
    for (final s in all) {
      for (final secret in secrets) {
        expect(s.toLowerCase(), isNot(contains(secret.toLowerCase())),
            reason: '$screen leaked "$secret" in "$s"');
      }
    }
  }

  ConnectionWithDetails conn(int i) {
    final now = DateTime(2026, 1, 1);
    return ConnectionWithDetails(
      connection: Connection(
        id: 'c$i',
        label: hostLabels[i],
        host: hostAddrs[i],
        port: 22,
        colorIndex: 0,
        protocol: 'ssh',
        zlibCompression: false,
        keepAliveSeconds: 0,
        envVars: '',
        forwardAgent: false,
        compatibilityMode: false,
        sortOrder: i,
        sizeTier: 1,
        pinned: false,
        monitored: false,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Widget scope(Widget child) => ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 900, height: 700, child: child),
          ),
        ),
      );

  testWidgets('the Hosts grid renders no fleet value while recording',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    final cards = [
      for (var i = 0; i < hostLabels.length; i++)
        (
          data: HostCardData(
            id: 'c$i',
            name: hostLabels[i],
            subtitle: '$username@${hostAddrs[i]}',
            osId: null,
            status: HostStatus.offline,
            hasActiveSession: false,
          ),
          connectionWithDetails: conn(i),
        ),
    ];
    await tester.pumpWidget(scope(HostGridArea(
      hostCards: cards,
      itemWidth: 280,
      onConnect: (_) {},
      onShowContextMenu: (_, __) {},
    )));
    await tester.pumpAndSettle();
    // Precondition: the provider agrees the mode is on (seeded from prefs).
    final container = ProviderScope.containerOf(
        tester.element(find.byType(HostGridArea)));
    expect(container.read(recordingModeProvider), isTrue);
    expectNoSecret(tester, 'Hosts grid');
    // And the masks are the documented shapes, not blanks.
    final texts = renderedStrings(tester).join('\n');
    expect(texts, contains('Hy000e3'));
    expect(texts, contains('ap00001-1'));
    expect(texts, matches(RegExp(r'host-\d\d')));
    expect(texts, matches(RegExp(r'user\d\d@192\.0\.2\.\d+')));
  });

  testWidgets('every kind renders masked through RedactedText',
      (tester) async {
    await tester.pumpWidget(scope(Column(
      children: [
        RedactedText(Redactable.host(hostLabels[0])),
        RedactedText(Redactable.group(groupName)),
        RedactedText(Redactable.workspace('Main workspace')),
        RedactedText(Redactable.account("Alex's Tree")),
        RedactedText(Redactable.address(hostAddrs[2])),
        RedactedText(Redactable.username(username)),
        RedactedText(Redactable.keyName(keyName)),
        RedactedText(Redactable.keyComment('ops@mac-studio')),
        RedactedText(Redactable.fingerprint(fingerprint)),
        RedactedText(Redactable.freeText(
            'ssh $username@${hostAddrs[0]} then check ${hostLabels[1]}')),
        RedactedText(Redactable.password('hunter2')),
      ],
    )));
    await tester.pumpAndSettle();
    expectNoSecret(tester, 'RedactedText kinds');
    final texts = renderedStrings(tester);
    expect(texts, contains(Redactor.fakeSha256));
    expect(texts, contains(Redactor.passwordMask));
    expect(texts, isNot(contains('mac-studio')));
  });

  // A phone's remote screen (4.0): the terminal route's page for a screen
  // session. Its chrome (the host's name in its bar, the cover) and its page
  // while not connected render no fleet value; the picture stays covered.
  testWidgets("a phone's remote screen renders no fleet value while recording", (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final native = FakeScreenNative();
    final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
    addTearDown(session.close);
    native.sessions.single.connect(name: hostLabels[0], width: 800, height: 500);
    await tester.pump();
    Widget page({ScreenSession? live, Widget? stateBody}) => ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: PhoneScreenView(
              sessionId: 's1',
              connectionId: 'c0',
              label: hostLabels[0],
              session: live,
              stateBody: stateBody,
              onBack: () {},
              onDisconnect: () {},
            ),
          ),
        );
    await tester.pumpWidget(page(live: session));
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsOneWidget);
    expectNoSecret(tester, 'phone remote screen');
    await tester.pumpWidget(page(stateBody: const SizedBox.shrink()));
    await tester.pump();
    expectNoSecret(tester, 'phone remote screen, not connected');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('turning the mode off and on re-renders live', (tester) async {
    await tester.pumpWidget(scope(RedactedText(Redactable.host(hostLabels[0]))));
    await tester.pumpAndSettle();
    expect(find.text('Hy000e3'), findsOneWidget);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(RedactedText)));
    await container.read(settingsUpdaterProvider).setRecordingMode(false);
    await tester.pumpAndSettle();
    expect(find.text(hostLabels[0]), findsOneWidget);
    await container.read(settingsUpdaterProvider).setRecordingMode(true);
    await tester.pumpAndSettle();
    expect(find.text('Hy000e3'), findsOneWidget);
    // Strict swaps the shape for a word, live as well.
    await container
        .read(settingsUpdaterProvider)
        .setRecordingRedactLevel(RedactLevel.strict);
    await tester.pumpAndSettle();
    expect(find.text('Hy000e3'), findsNothing);
    expectNoSecret(tester, 'strict level');
  });

  test('every route is either pumped here or classified, with a reason', () {
    // Derive the screen list from the route table, not from a hand-kept copy.
    final src = File('lib/router/routes.dart').readAsStringSync();
    final routes = RegExp(r"static const (\w+) = '/")
        .allMatches(src)
        .map((m) => m.group(1)!)
        .toSet();
    expect(routes, contains('home'));
    expect(Routes.help, '/help');

    // Pumped above (directly, or through the widget that owns the screen's
    // identifiers).
    const covered = {'home'};
    // Not pumpable in a widget test and why. The widgets these screens use
    // to show identifiers are RedactedText / Redactable.display (the source
    // gate in no_raw_in_ui_test.dart keeps `.raw` out of the UI layer).
    const classified = <String, String>{
      'onboarding': 'no fleet values are rendered',
      'connectionEdit': 'form fields hold user-entered text by design',
      'connectionEditId': 'form fields hold user-entered text by design',
      'connectionScanQr': 'camera plugin',
      'identityList': 'needs the live DB streams; rows use Redactable',
      'identityEdit': 'form fields hold user-entered text by design',
      'identityEditId': 'form fields hold user-entered text by design',
      'keyGeneration': 'generates keys with the platform crypto plugin',
      'terminal': 'live pty; the terminal is documented as unmaskable',
      'settings': 'no fleet values are rendered',
      'securityLock': 'no fleet values are rendered',
      'pinSetup': 'no fleet values are rendered',
      'sshConfigImport': 'file picker plugin',
      'lanScan': 'network scan plugin',
      'puttyImport': 'registry / file plugin',
      'upgrade': 'purchase plugin',
      'snippets': 'no fleet values are rendered',
      'networks': 'needs the live DB streams; rows use Redactable',
      // The phone's More tab (3.0).
      'keys': 'needs the live DB streams; key names, users, comments and fingerprints use Redactable',
      'portForwards': 'needs the live DB streams; host labels and addresses use Redactable',
      'team': "needs an Orchard; its name uses Redactable",
      'teamPage': 'needs an Orchard; names and addresses use Redactable (team_view_test pumps each page)',
      'networkEditId': 'form fields hold user-entered text by design',
      'profile': 'Firebase auth plugin',
      'emailAuth': 'auth form; email/password are user-entered, not fleet data',
      'recoveryKey': 'Firebase auth plugin',
      'syncBackend': 'no fleet values are rendered',
      'monitor': 'needs the live DB streams; rows use Redactable',
      'serverDetail': 'needs a live session',
      'notifications': 'no fleet values are rendered',
      'notificationSettings': 'no fleet values are rendered',
      'setupGuide': 'static OS setup steps; no fleet values are rendered',
      'terminalSettings': 'no fleet values are rendered',
      // The phone's key row (3.0): a made-up prompt and the keys.
      'keyboardRow': 'no fleet values are rendered',
      'sftpSettings': 'no fleet values are rendered',
      // Remote screens' settings (4.0): fixed choices, no host.
      'screenSettings': 'no fleet values are rendered',
      'dataSettings': 'no fleet values are rendered',
      'automationSettings':
          'needs the live DB streams; API key rows use Redactable',
      'editor': 'needs a live SFTP session; breadcrumb uses Redactable',
      'appearance': 'no fleet values are rendered',
      'about': 'no fleet values are rendered',
      'knownHosts': 'needs the live DB streams',
      'help': 'no fleet values are rendered',
      'report': 'user-entered text by design; context is six fixed facts',
      // Tickets (3.0, S1). tickets_ui_test pumps the list and a ticket's
      // page with the mode on.
      'tickets': 'needs the live DB streams; subjects go through Redactable.freeText',
      'ticket': 'needs the live DB streams; the subject and every message go through Redactable.freeText',
      'contactSupport': 'user-entered text by design; context is six fixed facts',
      'askAstryx': 'user-entered question by design, masked in recording mode; what is sent is ReportScrub output; answers come from the public docs',
      // The Support Hub on a phone (3.4): everyone's report titles and texts
      // and the person's own words go through Redactable.freeText.
      'supportHub': 'needs the live DB streams and the public lists; titles and texts go through Redactable.freeText',
      // Help > Guides (3.0). guides_ui_test pumps the list and a guide.
      'guides': 'no fleet values are rendered: the guides index is compiled into the app',
      'guide': "a public docs page fetched from docs.zestssh.com; no fleet values are rendered",
      'replay': 'needs a recorded session; title uses Redactable',
      'sftpRemote': 'needs a live SFTP session; labels use Redactable',
      'automationGuide': 'no fleet values are rendered',
      'automationHistory': 'needs the live DB streams',
      'automationWizard': 'no fleet values are rendered',
      'workflowList': 'needs the live DB streams',
      'workflowEditor': 'form fields hold user-entered text by design',
      'scheduledTasks': 'needs the live DB streams',
      'iosBackgrounding': 'no fleet values are rendered',
      'triggers': 'needs the live DB streams; the host scope uses Redactable',
      'commandHistory':
          'needs the live DB streams; commands + host label use Redactable',
      'sessionLogs':
          'lists device-local log files; names go through Redactable.host',
      // Saved transcripts (3.0). transcripts_screen_test
      // pumps the list and the reader.
      'transcripts': 'lists device-local transcript files; names go through Redactable.freeText',
      'transcriptView':
          'a saved terminal transcript is unmaskable, like the terminal route; its name goes through Redactable.freeText',
      // A live view of someone else's session (3.0, session sharing).
      // sharing_ui_test pumps it, and the dialogs around it, with the mode on.
      'shareView':
          'a live terminal is unmaskable, like the terminal route; who shares and the host go through Redactable',
    };
    final unclassified = routes.difference(covered).difference(classified.keys.toSet());
    expect(unclassified, isEmpty,
        reason: 'new route(s) must be pumped or classified: $unclassified');
    for (final r in classified.entries) {
      expect(r.value, isNotEmpty, reason: '${r.key} needs a reason');
    }
    // An excuse for a route that is no longer there is an open door for the
    // next one of that name (found in a review: 'tmux' stood here
    // with no such route).
    expect(classified.keys.toSet().difference(routes), isEmpty, reason: 'excuses for routes that are gone');
  });
}
