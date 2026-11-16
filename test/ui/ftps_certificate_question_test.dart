import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// An FTPS server's certificate (3.4) is asked about as an SSH host key is,
/// in the same dialogs, in a certificate's words: its SHA-256 as openssl
/// prints it, and the command that prints it on the server.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<BuildContext> host(WidgetTester tester) async {
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
    return context;
  }

  final fingerprint = KnownHostsService.certificateFingerprint('ab' * 32);

  HostKeyVerification cert({required bool changed}) => HostKeyVerification(
        certificate: true,
        host: 'files.example.test',
        port: 21,
        hostKey: SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: Uint8List(8)),
        fingerprint: fingerprint,
        isChanged: changed,
        expectedFingerprint: changed ? KnownHostsService.certificateFingerprint('cd' * 32) : null,
        completer: Completer<bool>(),
      );

  testWidgets('a first certificate: the server named, its own words, its fingerprint, Trust and connect trusts it',
      (tester) async {
    final context = await host(tester);
    bool? answer;
    unawaited(askHostKeyTrust(context, cert(changed: false)).then((v) => answer = v));
    await tester.pumpAndSettle();
    expect(find.byType(NewHostKeyDialog), findsOneWidget);
    expect(find.text(l10n.hostKeyFirstTitle('files.example.test:21')), findsOneWidget);
    expect(find.text(l10n.ftpsCertificateFirstWhy), findsOneWidget);
    expect(find.text(l10n.hostKeyFirstWhy), findsNothing, reason: "a certificate's words, not a key's");
    expect(find.textContaining('AB:AB:AB'), findsWidgets);
    expect(find.textContaining('openssl x509 -noout -fingerprint -sha256'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-key-new-trust')));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets("a changed certificate: the certificate's warning, openssl's command, the safe answer first",
      (tester) async {
    final context = await host(tester);
    bool? answer;
    unawaited(askHostKeyTrust(context, cert(changed: true)).then((v) => answer = v));
    await tester.pumpAndSettle();
    expect(find.byType(HostKeyChangedDialog), findsOneWidget);
    expect(find.text(l10n.ftpsCertificateChangedTitle), findsOneWidget);
    expect(find.text(l10n.hostKeyChangedTitle), findsNothing);
    // Red and explicit, as a changed SSH host key is: the warning's tone, and trusting it the
    // dangerous choice.
    expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.destructive);
    expect(find.byKey(const ValueKey('host-key-changed')), findsOneWidget);
    expect(find.text(l10n.ftpsCertificateChangedTrust), findsOneWidget);
    expect(find.textContaining('openssl x509 -noout -fingerprint -sha256'), findsOneWidget);
    expect(find.textContaining('ssh-keygen'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('host-key-changed-cancel')));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });
}
