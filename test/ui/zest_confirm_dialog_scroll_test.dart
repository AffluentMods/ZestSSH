import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A confirmation whose words do not fit the window (3.0): they scroll
/// between its title and its buttons, which stay in reach. It overflowed:
/// the last lines and the buttons were drawn off the dialog, where a small
/// window, large text or a longer language made the words taller than the
/// room it had.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final words = find.byKey(const ValueKey('zest-confirm-body'));
  final many = [for (var i = 1; i <= 9; i++) 'Point $i of what happens next, said in a sentence long enough to wrap.'];
  const long = 'A first sentence that says what was found. A second that says what it means for this device. '
      'A third that says what stays as it was, and a fourth that says what to do about it now.';

  Future<bool?> Function() open(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
    required String body,
    List<String>? bullets,
  }) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = platform;
    bool? answer;
    var answered = false;
    return () async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    answer = await ZestConfirmDialog.show(
                      context,
                      tone: ZestDialogTone.warning,
                      title: 'Sync was set up from another device',
                      body: body,
                      bullets: bullets,
                      confirmLabel: 'Continue',
                    );
                    answered = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return answered ? answer : null;
    };
  }

  /// Whether [inner] is drawn wholly inside [outer].
  bool within(Rect inner, Rect outer) =>
      inner.top >= outer.top - 0.5 &&
      inner.bottom <= outer.bottom + 0.5 &&
      inner.left >= outer.left - 0.5 &&
      inner.right <= outer.right + 0.5;

  testWidgets('more words than the window has room for: they scroll, and the buttons stay in reach', (tester) async {
    const window = Size(520, 380);
    final show = open(tester, size: window, platform: TargetPlatform.windows, body: long, bullets: many);
    try {
      await show();
      final screen = Offset.zero & window;
      // (A dialog that overflows fails the test by itself.)
      expect(find.byType(Dialog), findsOneWidget);
      expect(within(tester.getRect(find.text('Sync was set up from another device')), screen), isTrue);
      expect(within(tester.getRect(find.text('Continue')), screen), isTrue, reason: 'the answer can be given');
      expect(within(tester.getRect(find.text(l10n.cancel)), screen), isTrue);

      final room = tester.getRect(words);
      expect(within(room, screen), isTrue);
      expect(tester.getRect(find.text('Continue')).top, greaterThan(room.bottom), reason: 'the buttons are not scrolled');
      expect(tester.getRect(find.text(many.first)).top, greaterThanOrEqualTo(room.top - 0.5));
      expect(tester.getRect(find.text(many.last)).top, greaterThan(room.bottom), reason: 'the last point waits below');

      await tester.drag(words, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(within(tester.getRect(find.text(many.last)), tester.getRect(words)), isTrue,
          reason: 'scrolled to, the last point can be read');
      expect(within(tester.getRect(find.text('Continue')), screen), isTrue, reason: 'and the buttons have not moved');

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('words that fit are shown whole, in a dialog no taller than they need', (tester) async {
    const window = Size(1200, 900);
    final show = open(tester, size: window, platform: TargetPlatform.windows, body: 'It goes from every device.');
    try {
      await show();
      final position = tester.state<ScrollableState>(find.descendant(of: words, matching: find.byType(Scrollable))).position;
      expect(position.maxScrollExtent, 0, reason: 'nothing to scroll');
      final card = tester.getRect(find.ancestor(of: words, matching: find.byType(Container)).first);
      expect(card.height, lessThan(260), reason: 'as tall as its words, not as the window');
      expect(tester.getRect(find.text('Continue')).top - tester.getRect(words).bottom, lessThan(40),
          reason: 'the buttons follow the words, with no gap left open');
      // One anatomy for every dialog: the words start at
      // the dialog's edge, as the icon does, under the header's hairline.
      expect(
        tester.getTopLeft(find.text('It goes from every device.')).dx,
        closeTo(card.left + 22, 1.5),
        reason: "the words start at the dialog's content edge, under the icon",
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on a phone the sheet does the same: its words scroll above its buttons', (tester) async {
    const window = Size(390, 520);
    final show = open(tester, size: window, platform: TargetPlatform.android, body: long, bullets: many);
    try {
      await show();
      final screen = Offset.zero & window;
      expect(find.byKey(const ValueKey('zest-sheet')), findsOneWidget);
      expect(within(tester.getRect(find.text('Continue')), screen), isTrue);
      expect(within(tester.getRect(find.text(l10n.cancel)), screen), isTrue);
      expect(tester.getRect(find.text(many.last)).top, greaterThan(tester.getRect(words).bottom));

      await tester.drag(words, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(within(tester.getRect(find.text(many.last)), tester.getRect(words)), isTrue);
      expect(within(tester.getRect(find.text('Continue')), screen), isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
