import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/port_forward_service.dart';
import 'package:zestssh/ui/screens/port_forward/network_bind_confirm.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A port forward's "Allow other devices on my network", and the question
/// before a forward listens beyond this device (the 3.0 docs
/// check): the switch changed only the ssh command shown, and the question
/// the service said its callers should ask was asked by none.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test("on, ZestSSH's own forward listens on every address of this device, as ssh -g does", () {
    expect(PortForwardService.bindAddressFor(PortForwardType.local, '127.0.0.1', gatewayPorts: true), '0.0.0.0');
    expect(PortForwardService.bindAddressFor(PortForwardType.dynamic, 'localhost', gatewayPorts: true), '0.0.0.0');
    expect(PortForwardService.bindAddressFor(PortForwardType.local, '127.0.0.1', gatewayPorts: false), '127.0.0.1');
    expect(PortForwardService.bindAddressFor(PortForwardType.local, '192.0.2.5', gatewayPorts: true), '192.0.2.5',
        reason: 'an address of its own stands');
    expect(PortForwardService.bindAddressFor(PortForwardType.remote, '127.0.0.1', gatewayPorts: true), '127.0.0.1',
        reason: 'a forward from a port on the host listens there');
  });

  // A forward saved with no bind address (a shared host file, a backup)
  // and "Allow other devices" on was given '' to listen on, which the
  // listener took for this device's loopback while the app showed 0.0.0.0
  // (found in a security review). It listens where it is shown.
  test('no bind address: every address of this device where other devices are allowed, its loopback where not', () {
    for (final type in [PortForwardType.local, PortForwardType.dynamic]) {
      for (final blank in ['', '  ']) {
        expect(PortForwardService.bindAddressFor(type, blank, gatewayPorts: true), '0.0.0.0', reason: '$type');
        expect(PortForwardService.bindAddressFor(type, blank, gatewayPorts: false), '127.0.0.1', reason: '$type');
        expect(PortForwardService.bindAddressFor(type, blank, gatewayPorts: true),
            forwardListensOn(type, blank, gatewayPorts: true),
            reason: 'where it listens is what the app shows');
        expect(PortForwardService.bindAddressFor(type, blank, gatewayPorts: false),
            forwardListensOn(type, blank, gatewayPorts: false));
      }
    }
    expect(PortForwardService.bindAddressFor(PortForwardType.remote, '', gatewayPorts: true), '',
        reason: 'a forward from a port on the host listens there');
  });

  test('both places a saved forward starts from use it: by hand, and with the connection', () {
    final source = File('lib/providers/terminal_providers.dart').readAsStringSync();
    expect(
        RegExp(r'PortForwardService\.bindAddressFor\(type, rule\.bindAddress, gatewayPorts: rule\.gatewayPorts\)')
            .allMatches(source)
            .length,
        2);
  });

  Future<bool?> ask(WidgetTester tester, {required String? listensOn, String? before}) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answer = await confirmNetworkBind(context, listensOn: listensOn, port: 8080, before: before),
            child: const Text('save'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('a forward that listens beyond this device is kept only once allowed', (tester) async {
    expect(await ask(tester, listensOn: '0.0.0.0'), isNull, reason: 'it waits for the answer');
    expect(find.text(en.pfNetworkBindTitle), findsOneWidget);
    expect(find.text(en.pfNetworkBindBody('0.0.0.0', 8080)), findsOneWidget);
    await tester.tap(find.text(en.pfNetworkBindAllow));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
  });

  testWidgets('said no, it is not kept', (tester) async {
    await ask(tester, listensOn: '0.0.0.0');
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
  });

  testWidgets('on this device alone, as it was before, or on the host: nothing is asked', (tester) async {
    expect(await ask(tester, listensOn: '127.0.0.1'), isTrue);
    expect(await ask(tester, listensOn: '0.0.0.0', before: '0.0.0.0'), isTrue);
    expect(await ask(tester, listensOn: null), isTrue);
    expect(forwardListensOn(PortForwardType.remote, '0.0.0.0'), isNull);
    expect(forwardListensOn(PortForwardType.local, ''), '127.0.0.1');
    expect(forwardListensOn(PortForwardType.local, '127.0.0.1', gatewayPorts: true), '0.0.0.0');
  });

  test('every way a forward comes out of the editor asks before it is kept (before, '
      'three of them did not)', () {
    // Each place the editor is shown, and the question in what follows it.
    final shown = RegExp(r'await showPortForwardEditor\(');
    var places = 0;
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      for (final match in shown.allMatches(text)) {
        places++;
        final after = text.substring(match.start, (match.start + 1600).clamp(0, text.length));
        expect(after, contains('confirmNetworkBind('),
            reason: '${file.path}: a forward saved from the editor here is not asked about');
      }
    }
    expect(places, greaterThanOrEqualTo(5), reason: 'the host panel, Home (add and edit) and the page (add and edit)');
  });

  test('a kind as a rule keeps it is read as the kind it is', () {
    expect(forwardTypeOf('local'), PortForwardType.local);
    expect(forwardTypeOf('remote'), PortForwardType.remote);
    expect(forwardTypeOf('dynamic'), PortForwardType.dynamic);
    expect(forwardListensOn(forwardTypeOf('dynamic'), '0.0.0.0'), '0.0.0.0');
    expect(forwardListensOn(forwardTypeOf('remote'), '0.0.0.0'), isNull, reason: 'it listens on the host');
  });

  test('the words: every language its own; a port forward is not said to be kept by Mosh (Mosh forwards no '
      'ports); Direct, as the choice is called', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      expect(t.pfIosIntroBodyNoMosh.toLowerCase(), isNot(contains('mosh')), reason: '$locale');
      expect(t.jumpHostGoneDirect('web-01'), contains(t.connectionDirect), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      for (final (a, b) in [
        (t.pfNetworkBindTitle, en.pfNetworkBindTitle),
        (t.pfExitOnFailureCommandOnly, en.pfExitOnFailureCommandOnly),
        (t.pfSessionStopFailed('x'), en.pfSessionStopFailed('x')),
        (t.pfIosIntroBodyNoMosh, en.pfIosIntroBodyNoMosh),
      ]) {
        expect(a, isNot(b), reason: '$locale');
      }
    }
    // The page on running in the background offers Mosh again (4.0: ZestSSH has its own Mosh client on iOS
    // too), and says it is built in.
    final help = File('lib/ui/screens/help/ios_backgrounding_help_screen.dart').readAsStringSync();
    expect(help, contains('iosBackgroundingHelpMoshTitle'));
    expect(en.iosBackgroundingHelpMoshDescription, contains('built in'));
    expect(File('lib/ui/screens/port_forward/port_forward_screen.dart').readAsStringSync(),
        isNot(contains('portForwardIosIntroBody')));
  });
}
