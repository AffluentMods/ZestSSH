import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The groups of the RFCs are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/kex/kex_dh.dart';
// Nor is what a host answers a sign-in with, or what may come at any time.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_ignore.dart';
// Nor is the proposal of a key exchange.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_kex.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_service.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

import '../../packages/zest_ssh_core/test/src/played_group_exchange.dart';
import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// "Test full connection" in the host editor, against a host that is cut
/// off before its sign-in by what the SSH core finds (3.0, from the SSH
/// core's audit): a group too short for the key exchange, a key that the
/// host cannot prove to be its own, an answer that does not pass its
/// check, and a packet put in before the host's proposal of a strict key
/// exchange.
///
/// The test said of the first and the third "Auth aborted: Connection
/// closed before authentication", and of the second that the host's key
/// "isn't trusted yet", with "Connect once to verify and trust the server":
/// connecting once mends nothing of it. None kept what was found behind
/// "Copy details".
///
/// The editor dials for itself, so the host is played on the loopback
/// address: the editor is given that address and a port, and nothing else.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  /// The editor of a new host at [port] of the loopback address.
  Future<void> openEditor(WidgetTester tester, int port) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ConnectionEditScreen(
            inDialog: true,
            onClose: () {},
            initialHost: InternetAddress.loopbackIPv4.address,
            initialPort: port,
          ),
        ),
      ),
    ));
    await _settle(tester);
  }

  /// Presses "Test full connection" and waits for what the test says: the
  /// sentence under "Connection failed", what is behind "Copy details", and
  /// how often its person was asked about a key the editor had not seen
  /// (who says yes to it).
  Future<({String said, String? behind, int asked})> fullTest(WidgetTester tester, {String? button}) async {
    await tester.tap(find.text(button ?? en.zestHostTestFull));
    var asked = 0;
    for (var i = 0; i < 300 && find.text(en.connectionFailed).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 10));
      final trust = find.text(en.connectionEditTrustAndTest);
      if (trust.evaluate().isNotEmpty) {
        asked++;
        await tester.tap(trust);
        await tester.pump(const Duration(milliseconds: 400));
      }
    }
    expect(find.text(en.connectionFailed), findsOneWidget, reason: 'the test has not said anything');
    final banner = find.ancestor(of: find.text(en.connectionFailed), matching: find.byType(Column)).first;
    final texts = tester.widgetList<Text>(find.descendant(of: banner, matching: find.byType(Text))).toList();
    final details = find.byType(CopyDetailsButton);
    return (
      said: texts.map((t) => t.data).whereType<String>().firstWhere((t) => t != en.connectionFailed),
      behind: details.evaluate().isEmpty ? null : tester.widget<CopyDetailsButton>(details).detail,
      asked: asked,
    );
  }

  /// What cut the sign-in off, as the report behind "Copy details" has it:
  /// on the line under the error, which is the sign-in that was cut off.
  String cutOffBy(String? report) {
    final lines = report!.split('\n');
    final at = lines.indexOf('Error: SSHAuthAbortError(Connection closed before authentication)');
    expect(at, greaterThan(0), reason: report);
    const lead = '  What cut it off: ';
    expect(lines[at + 1], startsWith(lead), reason: report);
    return lines[at + 1].substring(lead.length);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  testWidgets('a host that names a group of 1024 bits for the key exchange: said as a host that offers only an '
      'outdated key exchange, with Compatibility mode and where it is, and with what the SSH core found behind it',
      (tester) async {
    late PlayedListener listener;
    late Future<void> played;
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedGroupExchange(line: await listener.line());
        await host.request();
        // The group of RFC 2409.
        final group = SSHKexDH.group1();
        await host.name(group.p, group.g);
      }();
    });
    await openEditor(tester, listener.port);
    final result = await fullTest(tester);
    final outdated = en.connKexGroupOutdated(1024, 2048, 'Auth / Show advanced options');
    expect(result.said, outdated);
    expect(result.said, contains('only an outdated key exchange'));
    expect(result.said, contains('Compatibility mode (under "Auth / Show advanced options")'));
    expect(result.said, contains('Not recommended'));
    expect(result.asked, 0, reason: 'nobody is asked about the key of a host that is not gone on with');
    expect(cutOffBy(result.behind),
        'SSHKexGroupError(The server named a group for the key exchange of 1024 bits, and none under 2048 bits is taken)');
    // What is behind "Copy details" is the report of the failure: what was said, where, and of what kind.
    expect(result.behind, contains('What: $outdated'));
    expect(result.behind, contains('Where: Testing a connection from the host editor'));
    expect(result.behind, contains('  Kind: saidByApp'));
    await tester.runAsync(() => played.timeout(const Duration(seconds: 10)));
    await finish(tester);
  });

  testWidgets('the same host with Compatibility mode on: the test goes on with the group of 1024 bits, and says '
      'nothing of a group too short', (tester) async {
    late PlayedListener listener;
    late Future<void> played;
    BigInt? publicValue;
    int? shortestAskedFor;
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedGroupExchange(line: await listener.line());
        shortestAskedFor = (await host.request()).shortest;
        final group = SSHKexDH.group1();
        publicValue = await host.name(group.p, group.g);
        // All that is asked about is seen: the host ends the connection.
        host.hangUp();
      }();
    });
    await openEditor(tester, listener.port);
    await tester.tap(find.text(en.connectionEditRailAuth));
    await _settle(tester);
    await tester.ensureVisible(find.text(en.connectionEditCompatibilityModeLabel));
    await tester.tap(find.text(en.connectionEditCompatibilityModeLabel));
    await tester.pump(const Duration(milliseconds: 100));
    final result = await fullTest(tester);
    await tester.runAsync(() => played.timeout(const Duration(seconds: 10)));
    expect(shortestAskedFor, 1024);
    expect(publicValue, isNotNull, reason: 'the test went on with the exchange');
    expect(result.said, isNot(contains('1024 bits')));
    await finish(tester);
  });

  testWidgets('a host that shows a key and cannot prove that it is its own: said as that, and not as a key that '
      'is not trusted yet', (tester) async {
    final pair = SSHKeyPair.fromPem(
            File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/ssh_host_ed25519_key').readAsStringSync())
        .single;
    late PlayedListener listener;
    late Future<void> played;
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedServer(
          line: await listener.line(),
          hostKey: PlayedHostKey(
            'ssh-ed25519',
            pair.toPublicKey().encode(),
            // The key's signature of something else: what whoever has only its public half can send.
            (hash) => pair.sign(Uint8List.fromList(hash.reversed.toList())).encode(),
          ),
        );
        // The played host waits for the editor's new keys, which do not come.
        await host.exchangeKeys().then((_) {}, onError: (_) {});
      }();
    });
    await openEditor(tester, listener.port);
    final result = await fullTest(tester);
    expect(result.said, en.connHostKeyNotSigned);
    expect(result.said, isNot(contains("isn't trusted yet")));
    expect(result.asked, 0, reason: 'a key that is refused is not put to its person');
    expect(cutOffBy(result.behind), 'SSHHostkeyError(Signature verification failed)');
    await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
    await finish(tester);
  });

  testWidgets('a host whose first answer under keys comes changed on the way: said as what did not pass its '
      'check, with what the SSH core found behind it', (tester) async {
    late PlayedListener listener;
    late Future<void> played;
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedServer(line: await listener.line(), suite: PlayedSuite.chacha);
        await host.exchangeKeys();
        await host.next(SSH_Message_Service_Request.messageId);
        host.sendChanged([SSH_Message_Service_Accept('ssh-userauth').encode()], (packets) {
          packets.single[packets.single.length - 1] ^= 0x01;
        });
      }();
    });
    await openEditor(tester, listener.port);
    final result = await fullTest(tester);
    // The key is one the editor had not seen, and the host proved it: its person was asked, once.
    expect(result.asked, 1);
    expect(result.said, en.connPacketDamaged);
    expect(
      cutOffBy(result.behind),
      'SSHPacketError(A packet from the other side did not pass its check: it was changed or damaged on the way, or '
      'the two sides do not protect their packets the same way)',
    );
    await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
    await finish(tester);
  });

  testWidgets('a host that names the strict key exchange and sends something before its proposal: said as the '
      'order of that exchange broken, with nobody asked about a key', (tester) async {
    late PlayedListener listener;
    late Future<void> played;
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedServer(line: await listener.line());
        // The played host waits for the editor's part of the exchange, which does not come.
        await host.exchangeKeys(first: [SSH_Message_Ignore(Uint8List(4)).encode()]).then((_) {}, onError: (_) {});
      }();
    });
    await openEditor(tester, listener.port);
    final result = await fullTest(tester);
    expect(result.asked, 0);
    expect(result.said, en.connStrictOrderBroken);
    expect(
      cutOffBy(result.behind),
      'SSHHandshakeError(Strict KEX violation: the server\'s key exchange proposal was not the first packet it sent '
      '(possible Terrapin attack).)',
    );
    await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
    await finish(tester);
  });

  // A host that speaks aes256-cbc and no other cipher, which the app offers
  // in Compatibility mode only. The switch is in the editor, and the test
  // dialled without it whatever the switch said; and of a host it had
  // nothing in common with it said "Auth aborted: Connection closed before
  // authentication", with nothing of the mode.
  for (final on in [true, false]) {
    testWidgets(
        'a host that needs Compatibility mode, with the switch ${on ? 'on: the test gets as far as the sign-in' : 'off: '
            'nothing in common with the host, said with the switch and where it is'}', (tester) async {
      late PlayedListener listener;
      late Future<void> played;
      var askedToSignIn = false;
      await tester.runAsync(() async {
        listener = await PlayedListener.bind();
        played = () async {
          final host = PlayedServer(line: await listener.line(), suite: PlayedSuite.cbc);
          await host.greet();
          await host.next(SSH_Message_Userauth_Request.messageId);
          askedToSignIn = true;
          // It takes keys only, and the editor has none for it.
          host.send([SSH_Message_Userauth_Failure(methodsLeft: const ['publickey']).encode()]);
        }()
            .then((_) {}, onError: (Object _) {});
      });
      await openEditor(tester, listener.port);
      if (on) {
        // On a computer the switch is under the editor's tab for the sign-in.
        await tester.tap(find.text(en.connectionEditRailAuth));
        await _settle(tester);
        await tester.ensureVisible(find.text(en.connectionEditCompatibilityModeLabel));
        await tester.tap(find.text(en.connectionEditCompatibilityModeLabel));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final result = await fullTest(tester);
      await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
      if (on) {
        expect(askedToSignIn, isTrue, reason: 'the test ended at the key exchange, and said: ${result.said}');
        // (It takes keys only, and the editor has none for it: said as a failed connection says that.)
        expect(result.said, startsWith(en.errSignInTakesOnly(en.errSignInWayKey)));
        expect(result.asked, 1, reason: 'its person is asked about the host\'s key once');
      } else {
        expect(askedToSignIn, isFalse);
        expect(
          result.said,
          '${en.errAlgorithmMismatchDesc(en.errAlgoTypeCipher, InternetAddress.loopbackIPv4.address)}\n\n'
          '${en.errAlgorithmMismatchTip('Auth / Show advanced options')}',
        );
        // What cut it off, with what each side offered and what the mode would add.
        expect(
          cutOffBy(result.behind),
          'SSHHandshakeError(No matching client cipher algorithm) [ZestSSH offered: chacha20-poly1305@openssh.com,aes256-ctr,aes128-ctr,aes256-gcm@openssh.com,aes128-gcm@openssh.com] '
          '[the server offers: aes256-cbc] [Compatibility mode adds: aes256-cbc]',
        );
        expect(result.behind, contains('  Kind: algorithmMismatch'));
        expect(result.asked, 0);
      }
      await finish(tester);
    });
  }

  // A host that speaks aes256-gcm and no other cipher. The app had that cipher in neither mode, and its test
  // said that it had nothing in common with such a host. It offers AES-GCM in both modes now:
  // the test gets as far as the sign-in, whatever the switch says.
  for (final on in [true, false]) {
    testWidgets('a host that has AES-GCM alone, with the switch ${on ? 'on' : 'off'}: the test gets as far as the '
        'sign-in', (tester) async {
      late PlayedListener listener;
      late Future<void> played;
      var askedToSignIn = false;
      await tester.runAsync(() async {
        listener = await PlayedListener.bind();
        played = () async {
          final host = PlayedServer(line: await listener.line(), suite: PlayedSuite.gcm);
          await host.greet();
          await host.next(SSH_Message_Userauth_Request.messageId);
          askedToSignIn = true;
          // It takes keys only, and the editor has none for it.
          host.send([SSH_Message_Userauth_Failure(methodsLeft: const ['publickey']).encode()]);
        }()
            .then((_) {}, onError: (Object _) {});
      });
      await openEditor(tester, listener.port);
      if (on) {
        await tester.tap(find.text(en.connectionEditRailAuth));
        await _settle(tester);
        await tester.ensureVisible(find.text(en.connectionEditCompatibilityModeLabel));
        await tester.tap(find.text(en.connectionEditCompatibilityModeLabel));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final result = await fullTest(tester);
      await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
      expect(askedToSignIn, isTrue, reason: 'the test ended at the key exchange, and said: ${result.said}');
      expect(result.said, startsWith(en.errSignInTakesOnly(en.errSignInWayKey)));
      expect(result.asked, 1, reason: 'its person is asked about the host\'s key once');
      await finish(tester);
    });
  }

  // A host whose only ciphers are two the app has in neither mode: what the host offers is said, and that no
  // setting changes it, whatever the switch says. (With the switch off it was told to turn the mode on, and with
  // it on it was told that this happens with older servers, and no more.) Its proposal is the test's own, and
  // nothing the played host sends after it is looked at: the app has ended the connection by then.
  for (final on in [true, false]) {
    testWidgets('a host the app has nothing in common with in either mode, with the switch ${on ? 'on' : 'off'}: '
        'said with what the host offers, and with no tip to turn the mode on', (tester) async {
      late PlayedListener listener;
      late Future<void> played;
      await tester.runAsync(() async {
        listener = await PlayedListener.bind();
        played = () async {
          final host = PlayedServer(line: await listener.line());
          await host.exchangeKeys(first: [
            SSH_Message_KexInit(
              kexAlgorithms: const ['curve25519-sha256', 'ext-info-s', 'kex-strict-s-v00@openssh.com'],
              serverHostKeyAlgorithms: const ['ssh-ed25519'],
              encryptionClientToServer: const ['3des-cbc', 'arcfour256'],
              encryptionServerToClient: const ['3des-cbc', 'arcfour256'],
              macClientToServer: const ['hmac-sha2-256'],
              macServerToClient: const ['hmac-sha2-256'],
              compressionClientToServer: const ['none'],
              compressionServerToClient: const ['none'],
              firstKexPacketFollows: false,
            ).encode(),
          ]);
        }()
            .then((_) {}, onError: (Object _) {});
      });
      await openEditor(tester, listener.port);
      if (on) {
        await tester.tap(find.text(en.connectionEditRailAuth));
        await _settle(tester);
        await tester.ensureVisible(find.text(en.connectionEditCompatibilityModeLabel));
        await tester.tap(find.text(en.connectionEditCompatibilityModeLabel));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final result = await fullTest(tester);
      await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
      expect(
        result.said,
        '${en.errAlgorithmNoneInCommonDesc(en.errAlgoTypeCipher, InternetAddress.loopbackIPv4.address, '3des-cbc, arcfour256')}\n\n'
        '${en.errAlgorithmNoneInCommonTip}',
      );
      expect(
        cutOffBy(result.behind),
        'SSHHandshakeError(No matching client cipher algorithm) '
        '[ZestSSH offered: chacha20-poly1305@openssh.com,aes256-ctr,aes128-ctr,aes256-gcm@openssh.com,aes128-gcm@openssh.com${on ? ',aes128-cbc,aes192-cbc,aes256-cbc' : ''}] '
        '[the server offers: 3des-cbc,arcfour256] [Compatibility mode adds: ]',
      );
      expect(result.asked, 0);
      await finish(tester);
    });
  }

  // What a test that failed says (3.0; from an audit of the SSH core's
  // kinds of error). The editor had words of its own
  // for it, apart from what a failed connection says of the same failure:
  // "Auth rejected by server: All authentication methods failed" of every
  // sign-in a host refused, "Auth aborted: Connection closed before
  // authentication" of every sign-in that was cut off by something it had
  // no sentence for, and of a port that nothing listens on what the system
  // says, in the system's language. Now it says what a failed connection
  // says, and keeps what it was told behind "Copy details".
  for (final button in [en.zestHostTestReachability, en.zestHostTestFull]) {
    testWidgets('a port that nothing listens on, "$button": the host is not accepting connections there, with what '
        'to look at, and what the system said behind Copy details', (tester) async {
      late int port;
      await tester.runAsync(() async {
        final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        port = taken.port;
        await taken.close();
      });
      await openEditor(tester, port);
      final result = await fullTest(tester, button: button);
      expect(result.said, '${en.errRefusedDesc(InternetAddress.loopbackIPv4.address, port)}\n\n${en.errRefusedTip}');
      final report = result.behind!.split('\n');
      expect(report.where((line) => line.startsWith('Error: ')).single, startsWith('Error: SocketException: '));
      expect(report, contains('  Kind: refused'));
      // (The address is taken out of what is copied, as out of every report.)
      expect(result.behind, isNot(contains(InternetAddress.loopbackIPv4.address)));
      expect(result.asked, 0);
      await finish(tester);
    });
  }

  testWidgets('a host that ends the connection at the sign-in and says nothing: said as a failed connection says '
      'it, where it was "Auth aborted: Connection closed before authentication"', (tester) async {
    late PlayedListener listener;
    late Future<void> played;
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedServer(line: await listener.line());
        await host.greet();
        await host.next(SSH_Message_Userauth_Request.messageId);
        host.hangUp();
      }()
          .then((_) {}, onError: (Object _) {});
    });
    await openEditor(tester, listener.port);
    final result = await fullTest(tester);
    await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
    expect(result.said, '${en.errAuthFailedDesc} (${InternetAddress.loopbackIPv4.address})\n\n${en.errAuthFailedTip}');
    expect(result.said, isNot(contains('Auth aborted')));
    expect(result.behind, contains('Error: SSHAuthAbortError(Connection closed before authentication)'));
    expect(result.behind, contains('  Kind: authFailed'));
    expect(result.asked, 1);
    await finish(tester);
  });

  testWidgets('a host that takes keys only, where the editor has none for it: said as that, and that nothing was '
      'sent, where it was "Auth rejected by server: All authentication methods failed"', (tester) async {
    late PlayedListener listener;
    late Future<void> played;
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedServer(line: await listener.line());
        await host.greet();
        await host.next(SSH_Message_Userauth_Request.messageId);
        host.send([SSH_Message_Userauth_Failure(methodsLeft: const ['publickey']).encode()]);
      }()
          .then((_) {}, onError: (Object _) {});
    });
    await openEditor(tester, listener.port);
    final result = await fullTest(tester);
    await tester.runAsync(() => played.timeout(const Duration(seconds: 15)));
    expect(
      result.said,
      '${en.errSignInTakesOnly(en.errSignInWayKey)} (${InternetAddress.loopbackIPv4.address})\n\n${en.errAuthFailedTip}',
    );
    expect(result.behind, contains('Error: SSHAuthFailError(All authentication methods failed)'));
    expect(result.behind, contains('  Kind: authFailed'));
    expect(result.asked, 1);
    await finish(tester);
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
