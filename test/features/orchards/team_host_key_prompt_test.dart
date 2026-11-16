import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/team_pin_choice.dart';
import 'package:zestssh/utils/redactor.dart';

/// The host key prompts' team-pinned parts (3.0): the warning when
/// a host presents a key other than the one the team pinned says so, and
/// offers "Replace the team's key" only to someone who may edit the pin's
/// Crate (everyone else can only cancel); the first-connection choice to
/// trust a key for everyone is on unless turned off.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  HostKeyVerification prompt({required TeamPinPrompt? team, bool changed = true}) => HostKeyVerification(
        host: 'web1.example.com',
        port: 22,
        hostKey: SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List(51)),
        fingerprint: 'SHA256:presented',
        isChanged: changed,
        expectedFingerprint: 'SHA256:pinned',
        completer: Completer<bool>(),
        teamPin: team,
      );

  Future<bool?> show(WidgetTester tester, Widget Function(BuildContext) dialog) async {
    bool? answer;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answer = await showDialog<bool>(context: context, builder: dialog),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('another key than the team pinned: a member can only cancel', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final v = prompt(team: TeamPinPrompt(crateName: 'Production', mayChange: false, pinned: true));
    await show(tester, (_) => HostKeyChangedDialog(verification: v));
    expect(find.text(l10n.teamHostKeyMismatchTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('team-pin-mismatch')), findsOneWidget);
    expect(find.text(l10n.teamHostKeyPinnedLabel), findsOneWidget);
    expect(find.text(l10n.teamHostKeyAskEditor('Production')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-key-changed-trust')), findsNothing, reason: 'nothing to trust with');
    expect(find.byKey(const ValueKey('team-pin-choice')), findsNothing);
  });

  testWidgets("another key than the team pinned: an editor may replace the team's key", (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final v = prompt(team: TeamPinPrompt(crateName: 'Production', mayChange: true, pinned: true));
    await show(tester, (_) => HostKeyChangedDialog(verification: v));
    expect(find.text(l10n.teamHostKeyReplace), findsOneWidget);
    expect(find.text(l10n.teamHostKeyReplaceNote('Production')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-pin-choice')), findsNothing, reason: 'replacing is for everyone');
  });

  testWidgets('a key changed on this device only: the usual warning, with the choice for an editor', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final v = prompt(team: TeamPinPrompt(crateName: 'Production', mayChange: true, pinned: false));
    await show(tester, (_) => HostKeyChangedDialog(verification: v));
    expect(find.text(l10n.hostKeyChangedTitle), findsOneWidget);
    expect(find.text(l10n.hostKeyChangedTrust), findsOneWidget);
    expect(find.byKey(const ValueKey('team-pin-choice')), findsOneWidget);
  });

  testWidgets('the choice to trust for everyone is on, and turns off', (tester) async {
    final v = prompt(team: TeamPinPrompt(crateName: 'Production', mayChange: true, pinned: false), changed: false);
    await show(tester, (_) => AlertDialog(content: TeamPinChoice(verification: v)));
    expect(find.text(l10n.teamHostKeyForEveryone('Production')), findsOneWidget);
    expect(v.teamPin!.forEveryone, isTrue);
    await tester.tap(find.byKey(const ValueKey('team-pin-choice')));
    await tester.pumpAndSettle();
    expect(v.teamPin!.forEveryone, isFalse);
    // Nothing offered to someone who may not edit, nor without a team.
    expect(TeamPinChoice.offered(prompt(team: TeamPinPrompt(crateName: 'P', mayChange: false, pinned: false))), isFalse);
    expect(TeamPinChoice.offered(prompt(team: null)), isFalse);
  });
}
