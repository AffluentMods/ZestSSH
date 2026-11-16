import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/redactor.dart';

/// The first connection to a server (4.0, as
/// designed): the title names the server (it said
/// "New host key"); one line says why it asks; the key's type and its SHA256
/// fingerprint in groups of four, with a copy button that copies it whole
/// (it was one unbroken string with nothing to copy it); the command that
/// prints it on the server, to copy (only the changed key's question had
/// it); the hosting provider's fingerprint as the other way; Reject, or
/// Trust and connect (it said "Accept & save"). An FTPS server's and a remote
/// screen's certificate the same way, in their words, with openssl's command.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const sha = 'SHA256:Kq3v8Xb0YQm4cJ1sT9fH2nW6pL5rZ7aE0dG3uV8iO1k';
  final copied = <String>[];

  setUp(() {
    copied.clear();
    debugTopSnackBarOnPhone = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  tearDown(() {
    debugTopSnackBarOnPhone = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<(BuildContext, ProviderContainer)> host(WidgetTester tester, {Size size = const Size(1000, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    late BuildContext context;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
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
    return (context, container);
  }

  HostKeyVerification key({String type = 'ssh-ed25519', int port = 22, String fingerprint = sha}) =>
      HostKeyVerification(
        host: 'web-01.example.com',
        port: port,
        hostKey: SSHHostKey(type: type, bytes: Uint8List(51)),
        fingerprint: fingerprint,
        isChanged: false,
        completer: Completer<bool>(),
      );

  Finder keyed(String k) => find.byKey(ValueKey(k));
  String groups(WidgetTester tester) => tester.widget<SelectableText>(keyed('host-key-new-groups')).data!;
  String command(WidgetTester tester) =>
      tester.widget<SelectableText>(find.descendant(of: keyed('host-key-new-command'), matching: find.byType(SelectableText))).data!;

  testWidgets("an SSH server's first connection: named in the title, why it asks, the key's type, its fingerprint in "
      'groups of four, the command to check it on the server, the other way; Trust and connect trusts it',
      (tester) async {
    final (context, _) = await host(tester);
    bool? answer;
    unawaited(askHostKeyTrust(context, key()).then((v) => answer = v));
    await tester.pumpAndSettle();
    expect(find.byType(NewHostKeyDialog), findsOneWidget);
    expect(find.text(l10n.hostKeyFirstTitle('web-01.example.com')), findsOneWidget);
    expect(find.text(l10n.hostKeyFirstWhy), findsOneWidget);
    expect(find.descendant(of: keyed('host-key-new-type'), matching: find.text('ED25519')), findsOneWidget);
    expect(find.text(l10n.hostKeyFingerprintLabel), findsOneWidget);
    expect(groups(tester), 'Kq3v 8Xb0 YQm4 cJ1s T9fH 2nW6\npL5r Z7aE 0dG3 uV8i O1k');
    expect(find.text(l10n.hostKeyCheckOnServer), findsOneWidget);
    expect(command(tester), 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub');
    expect(find.text(l10n.hostKeyCompareProvider), findsOneWidget);
    // Nothing of before: the old title, the question, Accept & save.
    expect(find.text('New host key'), findsNothing);
    expect(find.text('Do you want to trust this host and continue?'), findsNothing);
    expect(find.text('Accept & save'), findsNothing);
    expect(find.text(l10n.terminalReject), findsOneWidget);
    expect(find.text(l10n.hostKeyTrustAndConnect), findsOneWidget);
    await tester.tap(keyed('host-key-new-trust'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('the copy buttons: the fingerprint whole (SHA256:..., no spaces), and the command', (tester) async {
    final (context, _) = await host(tester);
    unawaited(askHostKeyTrust(context, key()));
    await tester.pumpAndSettle();
    expect(find.byTooltip(l10n.hostKeyCopyFingerprint), findsOneWidget);
    await tester.tap(keyed('host-key-new-copy'));
    await tester.pump();
    expect(copied, [sha]);
    expect(find.text(l10n.hostKeyFingerprintCopied), findsOneWidget);
    await tester.tap(find.descendant(of: keyed('host-key-new-command'), matching: find.byType(IconButton)));
    await tester.pump();
    expect(copied.last, 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub');
    await tester.pump(const Duration(seconds: 10));
    await tester.tap(keyed('host-key-new-reject'));
    await tester.pumpAndSettle();
  });

  testWidgets("the key's type names its file on the server; a port other than 22 is in the title", (tester) async {
    final (context, _) = await host(tester);
    for (final (type, label, file) in [
      ('ssh-rsa', 'RSA', 'ssh_host_rsa_key.pub'),
      ('rsa-sha2-512', 'RSA', 'ssh_host_rsa_key.pub'),
      ('ecdsa-sha2-nistp256', 'ECDSA P-256', 'ssh_host_ecdsa_key.pub'),
    ]) {
      unawaited(askHostKeyTrust(context, key(type: type, port: 2222)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.hostKeyFirstTitle('web-01.example.com:2222')), findsOneWidget);
      expect(find.descendant(of: keyed('host-key-new-type'), matching: find.text(label)), findsOneWidget, reason: type);
      expect(command(tester), 'ssh-keygen -lf /etc/ssh/$file', reason: type);
      await tester.tap(keyed('host-key-new-reject'));
      await tester.pumpAndSettle();
    }
    // A type with no file of its own: every host key's.
    unawaited(askHostKeyTrust(context, key(type: 'ssh-dss')));
    await tester.pumpAndSettle();
    expect(command(tester), contains('for f in /etc/ssh/ssh_host_*_key.pub'));
    await tester.tap(keyed('host-key-new-reject'));
    await tester.pumpAndSettle();
  });

  testWidgets('Reject and the close button do not trust it', (tester) async {
    final (context, _) = await host(tester);
    bool? answer;
    unawaited(askHostKeyTrust(context, key()).then((v) => answer = v));
    await tester.pumpAndSettle();
    await tester.tap(keyed('host-key-new-reject'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets("an FTPS server's first certificate: its words, X.509 and the SHA-256 as openssl prints it, eight "
      "bytes to a line; openssl's command; whoever runs the server as the other way", (tester) async {
    final (context, _) = await host(tester);
    final fingerprint = KnownHostsService.certificateFingerprint('ab' * 32);
    unawaited(askHostKeyTrust(
        context,
        HostKeyVerification(
          certificate: true,
          host: 'files.example.test',
          port: 21,
          hostKey: SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: Uint8List(8)),
          fingerprint: fingerprint,
          isChanged: false,
          completer: Completer<bool>(),
        )));
    await tester.pumpAndSettle();
    expect(find.text(l10n.hostKeyFirstTitle('files.example.test:21')), findsOneWidget);
    expect(find.text(l10n.ftpsCertificateFirstWhy), findsOneWidget);
    expect(find.descendant(of: keyed('host-key-new-type'), matching: find.text('X.509')), findsOneWidget);
    expect(find.text(l10n.certificateFingerprintLabel), findsOneWidget);
    final line = List.filled(8, 'AB').join(':');
    expect(groups(tester), [line, line, line, line].join('\n'));
    expect(command(tester), 'openssl x509 -noout -fingerprint -sha256 -in /path/to/certificate.pem');
    expect(find.text(l10n.certificateCompareOwner), findsOneWidget);
    await tester.tap(keyed('host-key-new-copy'));
    await tester.pump();
    expect(copied, [fingerprint], reason: 'as openssl prints it, whole');
    await tester.pump(const Duration(seconds: 10));
    await tester.tap(keyed('host-key-new-reject'));
    await tester.pumpAndSettle();
  });

  testWidgets("a remote screen's first certificate, through a host: its name in the title, its address under it, "
      'the route in why it asks', (tester) async {
    final (context, _) = await host(tester);
    unawaited(askHostKeyTrust(
        context,
        HostKeyVerification(
          certificate: true,
          screen: true,
          via: 'gateway',
          name: 'desk-01',
          host: 'localhost',
          port: 5900,
          hostKey: SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: Uint8List(8)),
          fingerprint: KnownHostsService.certificateFingerprint('ab' * 32),
          isChanged: false,
          completer: Completer<bool>(),
        )));
    await tester.pumpAndSettle();
    expect(find.text(l10n.hostKeyFirstTitle('desk-01')), findsOneWidget);
    expect(find.text('localhost:5900'), findsOneWidget);
    expect(find.text(l10n.screenCertificateFirstWhyVia('gateway')), findsOneWidget);
    expect(l10n.screenCertificateFirstWhyVia('gateway'), contains('this route'));
    await tester.tap(keyed('host-key-new-reject'));
    await tester.pumpAndSettle();
  });

  testWidgets('recording mode: the fixed fake fingerprint, grouped, with its reveal; nothing to copy', (tester) async {
    final (context, container) = await host(tester);
    // The mode's provider first: made, it sets the masker as Settings has
    // it (off), so the masker is turned on after it.
    container.read(recordingModeProvider.notifier).state = true;
    Redactor.instance.enabled = true;
    addTearDown(() => Redactor.instance.enabled = false);
    unawaited(askHostKeyTrust(context, key()));
    await tester.pumpAndSettle();
    expect(groups(tester), isNot(contains('Kq3v')));
    expect(keyed('host-key-fingerprint-reveal'), findsOneWidget);
    expect(keyed('host-key-new-copy'), findsNothing);
    expect(find.text(l10n.hostKeyFirstTitle('web-01.example.com')), findsNothing, reason: 'the address is masked');
    await tester.tap(keyed('host-key-new-reject'));
    await tester.pumpAndSettle();
  });

  test('a fingerprint in groups: SHA256 in fours, six to a line; a certificate eight bytes to a line; anything else '
      'as it is', () {
    expect(groupedFingerprint('SHA256:abcdefgh='), 'abcd efgh');
    expect(groupedFingerprint(sha), 'Kq3v 8Xb0 YQm4 cJ1s T9fH 2nW6\npL5r Z7aE 0dG3 uV8i O1k');
    expect(groupedFingerprint('AB:CD'), 'AB:CD');
    expect(groupedFingerprint('MD5:12:34'), 'MD5:12:34');
    expect(hostKeyTypeLabel('ssh-ed25519'), 'ED25519');
    expect(hostKeyTypeLabel('ecdsa-sha2-nistp521'), 'ECDSA P-521');
    expect(hostKeyTypeLabel(KnownHostsService.certificateKeyType), 'X.509');
  });
}
