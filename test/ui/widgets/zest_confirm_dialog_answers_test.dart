import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart' show confirmUnencryptedConnection;
import 'package:zestssh/ui/screens/port_forward/network_bind_confirm.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

enum _Answer { one, other }

/// Closing a question is no answer: the cross, Escape and a tap outside it all give
/// null. A cancel button can do something of its own (Delete it, Bring into this
/// account), and the cross gave false, as that button does: a review
/// found closing a question bringing guest data in for good.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })),
    ));
    return context;
  }

  final closings = <(String, Future<void> Function(WidgetTester))>[
    ('the cross', (tester) => tester.tap(find.byTooltip(l10n.close))),
    ('Escape', (tester) => tester.sendKeyEvent(LogicalKeyboardKey.escape)),
    ('a tap outside it', (tester) => tester.tapAt(const Offset(4, 4))),
  ];

  for (final (how, close) in closings) {
    testWidgets('$how answers nothing', (tester) async {
      final context = await host(tester);
      bool? answer = true;
      var came = false;
      unawaited(ZestConfirmDialog.show(context, tone: ZestDialogTone.warning, title: 'T', body: 'B', cancelLabel: 'Delete it')
          .then((a) {
        answer = a;
        came = true;
      }));
      await tester.pumpAndSettle();
      await close(tester);
      await tester.pumpAndSettle();
      expect(came, isTrue);
      expect(answer, isNull);
    });

    testWidgets('$how answers nothing of two named answers', (tester) async {
      final context = await host(tester);
      _Answer? answer = _Answer.one;
      var came = false;
      unawaited(ZestConfirmDialog.ask<_Answer>(context,
              tone: ZestDialogTone.info,
              title: 'T',
              body: 'B',
              confirmLabel: 'One',
              confirm: _Answer.one,
              cancelLabel: 'Other',
              cancel: _Answer.other)
          .then((a) {
        answer = a;
        came = true;
      }));
      await tester.pumpAndSettle();
      await close(tester);
      await tester.pumpAndSettle();
      expect(came, isTrue);
      expect(answer, isNull);
    });
  }

  testWidgets('the buttons answer what they always did', (tester) async {
    final context = await host(tester);
    final answers = <bool?>[];
    for (final label in ['Yes', 'No']) {
      unawaited(ZestConfirmDialog.show(context, tone: ZestDialogTone.neutral, title: 'T', body: 'B', confirmLabel: 'Yes', cancelLabel: 'No')
          .then(answers.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(answers, [true, false]);
  });

  testWidgets('two named answers are the values they were given', (tester) async {
    final context = await host(tester);
    final answers = <_Answer?>[];
    for (final label in ['One', 'Other']) {
      unawaited(ZestConfirmDialog.ask<_Answer>(context,
              tone: ZestDialogTone.info,
              title: 'T',
              body: 'B',
              confirmLabel: 'One',
              confirm: _Answer.one,
              cancelLabel: 'Other',
              cancel: _Answer.other)
          .then(answers.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(answers, [_Answer.one, _Answer.other]);
  });

  // Found in the 3.4 security review: Enter answers yes only where yes is
  // safe. A destructive question (delete a key, expose a port forward to the
  // network, connect over Telnet) keeps the safe choice: Enter does nothing.
  testWidgets('Enter answers a plain question yes, and a destructive one nothing', (tester) async {
    final context = await host(tester);
    for (final (tone, expected) in [(ZestDialogTone.neutral, true), (ZestDialogTone.destructive, null)]) {
      bool? answer = false;
      var came = false;
      unawaited(ZestConfirmDialog.show(context, tone: tone, title: 'T', body: 'B', confirmLabel: 'Delete').then((a) {
        answer = a;
        came = true;
      }));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      if (expected == null) {
        expect(came, isFalse, reason: 'still asking: Enter did nothing');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(answer, isNull);
      } else {
        expect(answer, expected);
      }
    }
  });

  testWidgets('Enter neither exposes a port forward to the network nor connects over Telnet', (tester) async {
    final context = await host(tester);
    final asked = <Future<bool>>[
      confirmNetworkBind(context, listensOn: '0.0.0.0', port: 8080),
    ];
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(l10n.pfNetworkBindTitle), findsOneWidget, reason: 'still asking');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await asked.single, isFalse);

    final telnet = confirmUnencryptedConnection(context);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(l10n.desktopShellUnencryptedConnection), findsOneWidget, reason: 'still asking');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await telnet, isFalse);
  });
}
