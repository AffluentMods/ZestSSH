import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart';

import '../helpers/fake_device_approvals_server.dart';

/// Approving a new device on screen (3.0). On the device
/// that holds the sync key: who is asking, the words, and the key sent only
/// after the person says they match; "This was not me", "They do not
/// match", a turned-down sign-in and a closed dialog all end the request
/// with nothing sent. On the new device: waiting, the same words, and what
/// arrives handed back; a failed look ends the old request before the next.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late FakeApprovalServer server;

  final handover = SyncHandover(
    dek: Uint8List.fromList(List<int>.generate(32, (i) => 100 + i)),
    verificationHash: Uint8List.fromList(utf8.encode('check')),
    argon2Params: const {'version': 2, 'memory': 131072, 'iterations': 3, 'parallelism': 4},
    salt: Uint8List.fromList(List<int>.filled(32, 4)),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    server = FakeApprovalServer();
  });

  Future<void> noWait(Duration _) async {}

  /// Lets the requests and the crypto run, and the frames draw.
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// One look by the dialog's side (it looks every [kDeviceApprovalPoll]).
  Future<void> nextLook(WidgetTester tester) async {
    await tester.pump(kDeviceApprovalPoll);
    await frames(tester);
  }

  /// A screen whose button runs [onOpen], as [device], and taps it.
  Future<void> pumpHost(
    WidgetTester tester,
    String device,
    Future<void> Function(BuildContext context) onOpen, {
    Future<SyncHandover?> Function()? handoverSource,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        deviceApprovalsApiProvider.overrideWithValue(server.device(device)),
        syncHandoverProvider.overrideWithValue(handoverSource ?? () async => handover),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => onOpen(context), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await frames(tester);
  }

  /// A new device (a phone) that asks, as the other side of the test.
  Future<ApprovalAsk> phoneAsks(WidgetTester tester) async =>
      (await tester.runAsync(() => ApprovalAsk.start(server.device('phone'), name: 'Pixel')))!;

  /// Shown as a toast (on desktop, one in the notification center, split
  /// into a title and the rest when long).
  bool toasted(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.text('open')));
    return container
        .read(notificationCenterProvider)
        .history
        .any((n) => [n.title, if (n.body != null) n.body].join(' ') == message);
  }

  List<String> shownWords(WidgetTester tester, String key) =>
      tester.widget<ApprovalWords>(find.byKey(ValueKey(key))).words;

  group('on the device that holds the key', () {
    testWidgets('the same words on both screens, then the key is sent and arrives', (tester) async {
      final ask = await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      expect(find.text(l10n.approveWho('Pixel')), findsOneWidget);
      expect(find.text(l10n.approveWarning), findsOneWidget);

      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      expect(find.text(l10n.approveWaiting), findsOneWidget);
      expect(server.rows[ask.id]!.stage, 'responded');
      final onPhone = (await tester.runAsync(() => ask.awaitApprover(wait: noWait)))!;

      await nextLook(tester);
      expect(find.text(l10n.approveWordsTitle), findsOneWidget);
      expect(shownWords(tester, 'approve-words'), onPhone, reason: 'both screens show the same three words');
      expect(onPhone, hasLength(3));
      expect(server.rows[ask.id]!.sealed, isNull, reason: 'nothing is sent before the person says they match');

      await tester.tap(find.text(l10n.approveSend));
      await frames(tester);
      expect(find.text(l10n.approveDone), findsOneWidget);
      final got = (await tester.runAsync(() => ask.awaitHandover(wait: noWait)))!;
      expect(got.dek, handover.dek);
      expect(got.verificationHash, handover.verificationHash);
      expect(got.salt, handover.salt);
      expect(got.argon2Params, handover.argon2Params);
    });

    testWidgets('"They do not match" ends the request and sends nothing', (tester) async {
      final ask = await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      await tester.runAsync(() => ask.awaitApprover(wait: noWait));
      await nextLook(tester);

      await tester.tap(find.text(l10n.approveNoMatch));
      await frames(tester);
      expect(find.text(l10n.approveRefused), findsOneWidget);
      expect(server.cancelled, [ask.id]);
      final ended = await tester.runAsync(() async {
        try {
          await ask.awaitHandover(wait: noWait);
          return null;
        } on DeviceApprovalException catch (e) {
          return e;
        }
      });
      expect(ended?.ended, isTrue, reason: 'the phone finds the request gone');
    });

    testWidgets('"This was not me" ends the request and says what to do', (tester) async {
      final ask = await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      await tester.tap(find.text(l10n.approveNotMe));
      await frames(tester);
      expect(server.cancelled, [ask.id]);
      expect(find.text(l10n.approveWho('Pixel')), findsNothing, reason: 'the dialog closed');
      expect(toasted(tester, l10n.approveNotMeDone), isTrue);
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('a recent sign-in turned down ends the request, and says what it was for', (tester) async {
      final ask = await phoneAsks(tester);
      server.refuseRespond = 'recent-sign-in-required';
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      final summary = find.byKey(const ValueKey('step-up-summary'));
      expect(find.descendant(of: summary, matching: find.text(l10n.approveStepUpWhat('Pixel'))), findsOneWidget);
      expect(find.descendant(of: summary, matching: find.textContaining(l10n.approveStepUpEffect)), findsOneWidget);

      await tester.tap(find.text(l10n.cancel).last);
      await frames(tester);
      expect(server.cancelled, [ask.id]);
      expect(find.text(l10n.approveRefused), findsOneWidget);
    });

    testWidgets('closed while waiting: the request ends, nothing was sent', (tester) async {
      final ask = await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      await tester.tap(find.text(l10n.cancel));
      await frames(tester);
      expect(server.cancelled, [ask.id]);
      await nextLook(tester);
    });

    testWidgets('without a sync key here, nothing to send: the request ends', (tester) async {
      final ask = await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice, handoverSource: () async => null);
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      await tester.runAsync(() => ask.awaitApprover(wait: noWait));
      await nextLook(tester);
      await tester.tap(find.text(l10n.approveSend));
      await frames(tester);
      expect(find.text(l10n.approveNoSync), findsOneWidget);
      expect(server.cancelled, [ask.id]);
    });

    testWidgets('ZestSSH Cloud not answering as the requests are read: said as that, with its code',
        (tester) async {
      await phoneAsks(tester);
      server.offline = true;
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      expect(find.text('${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
      expect(find.text(l10n.approveFailed), findsNothing, reason: 'no connection of theirs to check');
    });

    testWidgets('ZestSSH Cloud not answering as this device answers: said as that', (tester) async {
      await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      server.offline = true;
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      expect(find.text('${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
      expect(find.text(l10n.approveFailed), findsNothing);
    });

    testWidgets('a fault of the service while waiting for the new device: said as that, with its status',
        (tester) async {
      await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      server.failReads = 1;
      await nextLook(tester);
      expect(find.text('${l10n.cloudFault(500)} (ZS-1103)'), findsOneWidget);
      expect(find.text(l10n.approveFailed), findsNothing);
    });

    testWidgets('ZestSSH Cloud not answering as the key is sent: said as that, and nothing claimed of what went out',
        (tester) async {
      final ask = await phoneAsks(tester);
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      await tester.runAsync(() => ask.awaitApprover(wait: noWait));
      await nextLook(tester);
      server.offline = true;
      await tester.tap(find.text(l10n.approveSend));
      await frames(tester);
      expect(find.text('${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
      expect(find.text(l10n.approveFailed), findsNothing);
      expect(find.text(l10n.approveDone), findsNothing);
    });

    testWidgets('an answer the app has no words for is said as it always was', (tester) async {
      await phoneAsks(tester);
      server.refuseRespond = 'something-else';
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      await tester.tap(find.text(l10n.approveContinue));
      await frames(tester);
      expect(find.text(l10n.approveFailed), findsOneWidget);
    });

    testWidgets('no device asking: says how to start', (tester) async {
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      expect(find.text(l10n.approveNone), findsOneWidget);
    });

    testWidgets("a device's own request is not offered to it", (tester) async {
      await tester.runAsync(() => ApprovalAsk.start(server.device('desktop'), name: 'Windows'));
      await pumpHost(tester, 'desktop', showApproveNewDevice);
      expect(find.text(l10n.approveNone), findsOneWidget);
    });
  });

  group('on the new device', () {
    testWidgets('waits, shows the same words, and hands back what arrived', (tester) async {
      SyncHandover? got;
      var closed = false;
      await pumpHost(tester, 'phone', (context) async {
        got = await showAskForApproval(context);
        closed = true;
      });
      expect(find.text(l10n.askWaiting), findsOneWidget);
      final id = server.rows.keys.single;
      final give = (await tester.runAsync(() => ApprovalGive.answer(server.device('desktop'), id)))!;

      await nextLook(tester);
      expect(find.text(l10n.askWordsTitle), findsOneWidget);
      final onDesktop = (await tester.runAsync(() => give.awaitReveal(wait: noWait)))!;
      expect(shownWords(tester, 'ask-words'), onDesktop);

      await tester.runAsync(() => give.send(handover));
      await nextLook(tester);
      expect(closed, isTrue);
      expect(got!.dek, handover.dek);
      expect(got!.salt, handover.salt);
    });

    testWidgets('turned down on the other device: says so, and Retry asks again', (tester) async {
      await pumpHost(tester, 'phone', showAskForApproval);
      final first = server.rows.keys.single;
      final give = (await tester.runAsync(() => ApprovalGive.answer(server.device('desktop'), first)))!;
      await tester.runAsync(give.refuse);
      await nextLook(tester);
      expect(find.text(l10n.askEnded), findsOneWidget);

      await tester.tap(find.text(l10n.retry));
      await frames(tester);
      expect(find.text(l10n.askWaiting), findsOneWidget);
      expect(server.rows.keys.single, isNot(first));
      await tester.tap(find.text(l10n.cancel));
      await frames(tester);
      expect(server.rows, isEmpty, reason: 'closing ends the second request too');
      await nextLook(tester);
    });

    testWidgets('a dropped look: Retry ends the old request before asking again', (tester) async {
      await pumpHost(tester, 'phone', showAskForApproval);
      final first = server.rows.keys.single;
      server.failReads = 1;
      await nextLook(tester);
      // The look was answered with a fault of the service's own: said as
      // that, and not as a connection to check.
      expect(find.text('${l10n.cloudFault(500)} (ZS-1103)'), findsOneWidget);
      expect(find.text(l10n.askFailed), findsNothing);
      expect(server.rows.containsKey(first), isTrue, reason: 'still open on the server');

      await tester.tap(find.text(l10n.retry));
      await frames(tester);
      expect(server.cancelled, contains(first));
      expect(server.rows.keys.single, isNot(first));
      await tester.tap(find.text(l10n.cancel));
      await frames(tester);
      expect(server.rows, isEmpty, reason: 'closing ends the second request too');
      await nextLook(tester);
    });

    testWidgets('ZestSSH Cloud not answering as the new device asks: said as that, and Retry asks once it answers',
        (tester) async {
      server.offline = true;
      await pumpHost(tester, 'phone', showAskForApproval);
      expect(find.text('${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
      expect(find.text(l10n.askFailed), findsNothing);
      expect(server.rows, isEmpty);

      server.offline = false;
      await tester.tap(find.text(l10n.retry));
      await frames(tester);
      expect(find.text(l10n.askWaiting), findsOneWidget);
      expect(server.rows, hasLength(1));
      await tester.tap(find.text(l10n.cancel));
      await frames(tester);
      await nextLook(tester);
    });

    testWidgets('a look answered with something the app has no words for is said as it always was',
        (tester) async {
      await pumpHost(tester, 'phone', showAskForApproval);
      server
        ..failReads = 1
        ..failReadStatus = 400;
      await nextLook(tester);
      expect(find.text(l10n.askFailed), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await frames(tester);
      await nextLook(tester);
    });

    testWidgets('a key changed on the way is not kept', (tester) async {
      SyncHandover? got;
      await pumpHost(tester, 'phone', (context) async => got = await showAskForApproval(context));
      final id = server.rows.keys.single;
      final give = (await tester.runAsync(() => ApprovalGive.answer(server.device('desktop'), id)))!;
      await nextLook(tester);
      await tester.runAsync(() => give.awaitReveal(wait: noWait));
      await tester.runAsync(() => give.send(handover));
      final sealed = server.rows[id]!.sealed!;
      sealed[sealed.length - 1] ^= 0x01;
      await nextLook(tester);
      expect(find.text(l10n.askBadSeal), findsOneWidget);
      expect(got, isNull);
    });

    testWidgets('Cancel ends the request', (tester) async {
      await pumpHost(tester, 'phone', showAskForApproval);
      final id = server.rows.keys.single;
      await tester.tap(find.text(l10n.cancel));
      await frames(tester);
      expect(server.cancelled, [id]);
      expect(server.rows, isEmpty);
      await nextLook(tester);
    });
  });
}
