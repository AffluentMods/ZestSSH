import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/hosts/host_card_face.dart';
import 'package:zestssh/features/screens/xprogram/x_program_dialog.dart';
import 'package:zestssh/features/screens/xprogram/x_program_install_text.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey, sessionEndedCause;
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/widgets/connection_lost_view.dart' show dropSaid;

/// The UI fixes of the 4.0 remote screens found in a screenshot review:
/// what a screen's card says under its name, the picture's
/// size for an X program, the install command of ZS-1809 on a line of its own
/// that copies, the certificate question's words and the host it names, and
/// what an X program's tab says once its program has ended. Made-up hosts.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  test("a screen's card says where it listens and the host it is reached through, and no user", () {
    expect(screenCardSubtitle(host: 'localhost', port: 5900, carrier: 'web-01', via: l10n.pfPageVia),
        'localhost:5900 via web-01');
    expect(screenCardSubtitle(host: '', port: 5901, carrier: 'web-01', via: l10n.pfPageVia),
        'localhost:5901 via web-01', reason: 'an empty address through a host is localhost');
    expect(
        screenCardSubtitle(
            host: 'localhost', port: 5900, socket: '~/.vnc/desk.sock', carrier: 'web-01', via: l10n.pfPageVia),
        '~/.vnc/desk.sock via web-01');
    expect(screenCardSubtitle(host: '10.0.0.40', port: 5900, via: l10n.pfPageVia), '10.0.0.40:5900',
        reason: 'reached directly');
    expect(screenCardSubtitle(host: 'fd00::40', port: 5900, via: l10n.pfPageVia), '[fd00::40]:5900');
    expect(screenCardSubtitle(host: 'localhost', port: 5900, carrier: 'web-01', via: l10n.pfPageVia),
        isNot(contains('@')));
  });

  // 4.0, RDP: an RDP host's card said "root@10.0.0.40 · RDP" (the
  // line was given to hosts named 'vnc' alone).
  test("an RDP host's card has the screen's line too, with its kind after it; a VNC host's is as it was", () {
    Connection host(String protocol, int port, {String address = '10.0.0.40', String? via, String? options}) => Connection(
          id: 'h-$protocol',
          label: 'office-pc',
          host: address,
          port: port,
          colorIndex: 0,
          protocol: protocol,
          zlibCompression: false,
          keepAliveSeconds: 0,
          envVars: '',
          forwardAgent: false,
          compatibilityMode: false,
          sortOrder: 0,
          sizeTier: 1,
          pinned: false,
          monitored: false,
          connectViaId: via,
          screenOptions: options,
          createdAt: DateTime(2026, 11, 13),
          updatedAt: DateTime(2026, 11, 13),
        );
    String line(Connection c) =>
        screenCardSubtitleOf(c, labelOf: (id) => id == 'c-web' ? 'web-01' : null, via: l10n.pfPageVia);
    expect(line(host('rdp', 3389)), '10.0.0.40:3389 · RDP');
    expect(line(host('rdp', 3389, address: 'localhost', via: 'c-web')), 'localhost:3389 via web-01 · RDP');
    expect(line(host('rdp', 3389)), isNot(contains('@')), reason: 'no user it has none of');
    // An RDP host has no socket, whatever a record's options say.
    expect(line(host('rdp', 3389, via: 'c-web', options: '{"v":1,"target":"unix","socket":"~/x.sock"}')),
        '10.0.0.40:3389 via web-01 · RDP');
    expect(line(host('vnc', 5900, address: 'localhost', via: 'c-web')), 'localhost:5900 via web-01');
    expect(line(host('vnc', 5900, via: 'c-web', options: '{"v":1,"target":"unix","socket":"~/x.sock"}')),
        '~/x.sock via web-01');
  });

  test("an X program's picture is the size of the place its tab will have", () {
    // The page that asks is the window less the sidebar, the title bar and the
    // status bar; the tab's header (44), its toolbar (34) and their lines come off it.
    expect(xProgramSizeFor(const Size(1440, 900), page: const Size(1240, 825)), (width: 1240, height: 744));
    expect(xProgramSizeFor(const Size(1440, 900), page: const Size(1388, 824)), (width: 1384, height: 744),
        reason: 'the sidebar folded: wider, rounded down to a multiple of 8');
    // A narrow drawer beside a terminal is not the tab's place: estimated from the window.
    expect(xProgramSizeFor(const Size(1440, 900), page: const Size(320, 825)), xProgramSizeFor(const Size(1440, 900)));
    // No page known: the window with the sidebar folded.
    expect(xProgramSizeFor(const Size(1600, 1000)), (width: 1544, height: 840));
    expect(xProgramSizeFor(const Size(1283, 917)), (width: 1224, height: 760));
    // A phone is as before, whatever page asks.
    expect(xProgramSizeFor(const Size(412, 915), page: const Size(412, 800)), (width: 960, height: 544));
  });

  test('the install command is found in what ZS-1809 says, with what stands around it', () {
    for (final pm in ['apt-get', 'dnf', 'yum', 'pacman', 'zypper']) {
      final command = xProgramInstallCommand(pm)!;
      expect(xProgramInstallCommands, contains(command));
      final parts = xProgramInstallParts('${l10n.xProgramToolsMissing('web-01', command)} (ZS-1809)')!;
      expect(parts.command, command);
      expect(parts.before, endsWith('open the program again:'));
      expect(parts.after, '(ZS-1809)');
    }
    expect(xProgramInstallParts(l10n.xProgramToolsMissingNoInstaller('web-01')), isNull);
    expect(xProgramInstallParts('Connection refused'), isNull);
  });

  testWidgets('the install command stands on a line of its own, in the terminal type, and its button copies it',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final command = xProgramInstallCommand('apt-get')!;
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: FailureDescription(
            '${l10n.xProgramToolsMissing('web-01', command)} (ZS-1809)',
            textKey: const ValueKey('said'),
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
    ));
    final shown = tester.widget<SelectableText>(
        find.descendant(of: find.byKey(const ValueKey('failure-install-command')), matching: find.byType(SelectableText)));
    expect(shown.data, command);
    expect(shown.style!.fontFamily, 'JetBrainsMono');
    expect(tester.widget<Text>(find.byKey(const ValueKey('said'))).data, isNot(contains(command)));
    expect(find.text('(ZS-1809)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('failure-install-command-copy')));
    await tester.pump();
    expect(copied, command);
    await tester.pump(const Duration(seconds: 5));

    // Any other failure is its sentence as it was.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: FailureDescription('Connection refused', textKey: ValueKey('said'), style: TextStyle(fontSize: 14)),
      ),
    ));
    expect(tester.widget<Text>(find.byKey(const ValueKey('said'))).data, 'Connection refused');
    expect(find.byKey(const ValueKey('failure-install-command')), findsNothing);
  });

  testWidgets("a certificate's question says certificate and names the saved host; a host key's says host",
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(builder: (ctx) {
          context = ctx;
          return const Scaffold();
        }),
      ),
    ));
    HostKeyVerification question({required bool certificate, String? name}) => HostKeyVerification(
          certificate: certificate,
          screen: certificate,
          via: certificate ? 'web-01' : null,
          name: name,
          host: certificate ? 'localhost' : '10.0.0.21',
          port: certificate ? 5900 : 22,
          hostKey: SSHHostKey(
              type: certificate ? KnownHostsService.certificateKeyType : 'ssh-ed25519', bytes: Uint8List(8)),
          fingerprint: certificate ? KnownHostsService.certificateFingerprint('ab' * 32) : 'SHA256:made-up',
          isChanged: false,
          completer: Completer<bool>(),
        );
    // Why it asks (4.0: the question under the fingerprint is gone; the
    // line under the title says it).
    String asked() => tester.widget<Text>(find.byKey(const ValueKey('host-key-new'))).data!;

    unawaited(askHostKeyTrust(context, question(certificate: true, name: 'desk-01')));
    await tester.pumpAndSettle();
    expect(asked(), l10n.screenCertificateFirstWhyVia('web-01'));
    expect(asked(), contains('certificate'));
    expect(asked(), isNot(contains('host')));
    expect(find.text(l10n.hostKeyFirstTitle('desk-01')), findsOneWidget,
        reason: 'localhost:5900 through web-01 does not say which screen');
    expect(find.text('localhost:5900'), findsOneWidget, reason: 'its address under its name');
    await tester.tap(find.byKey(const ValueKey('host-key-new-reject')));
    await tester.pumpAndSettle();

    unawaited(askHostKeyTrust(context, question(certificate: false)));
    await tester.pumpAndSettle();
    expect(asked(), l10n.hostKeyFirstWhy);
    await tester.tap(find.byKey(const ValueKey('host-key-new-reject')));
    await tester.pumpAndSettle();
  });

  test("an X program's end is said of the program; a terminal's as before", () {
    SessionState ended({int? exitCode, String? signal}) => SessionState.disconnected(
          connectionId: 'c-web',
          connectionLabel: 'xterm on web-01',
          host: '10.0.0.21',
          port: 22,
          dropped: true,
          dropCause: sessionEndedCause(exitCode: exitCode, signal: signal),
        );
    expect(dropSaid(l10n, ended(exitCode: 0), 'xterm on web-01', program: 'xterm').sentence,
        l10n.xProgramEndedStatus('xterm', 0));
    expect(l10n.xProgramEndedStatus('xterm', 0), 'xterm ended (exit status 0). Its screen closed with it.');
    expect(dropSaid(l10n, ended(), 'xterm on web-01', program: 'xterm').sentence, l10n.xProgramEndedPlain('xterm'));
    expect(dropSaid(l10n, ended(exitCode: 0), 'web-01').sentence, l10n.sessionEndedStatus('web-01', 0),
        reason: "a terminal's session");
    expect(l10n.xProgramRunAgain, 'Run again');
    expect(l10n.xProgramEndedTitle, isNot(l10n.sessionEndedTitle));
  });
}
