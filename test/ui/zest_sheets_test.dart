import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

/// Sheets on phones (3.0): on a phone the app's
/// dialogs open as bottom sheets with buttons across the width, above the
/// keyboard; tablets and desktops keep centred dialogs.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// Runs [body] with a phone's (or [platform]'s) look at [size].
  Future<void> on(
    WidgetTester tester,
    Future<void> Function() body, {
    TargetPlatform platform = TargetPlatform.android,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// A screen whose button runs [onOpen].
  Future<void> host(WidgetTester tester, Future<void> Function(BuildContext) onOpen) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(child: TextButton(onPressed: () => onOpen(context), child: const Text('open'))),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  final sheet = find.byKey(const ValueKey('zest-sheet'));

  testWidgets('a confirmation on a phone: a sheet, Confirm across the width and first', (tester) async {
    await on(tester, () async {
      bool? answer;
      await host(tester, (context) async {
        answer = await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.destructive,
          title: 'Delete "web-1"?',
          body: 'It goes from every device.',
          confirmLabel: 'Delete',
        );
      });
      expect(sheet, findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      final delete = tester.getRect(find.text('Delete'));
      final cancel = tester.getRect(find.text(l10n.cancel));
      expect(delete.top, lessThan(cancel.top), reason: 'the main one first');
      // The button itself spans the sheet, its words in the middle, tall
      // enough for a thumb.
      final button = find.ancestor(of: find.text('Delete'), matching: find.byType(AnimatedContainer)).first;
      expect(tester.getSize(button).width, greaterThan(300));
      expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
      expect(tester.getCenter(find.text('Delete')).dx, closeTo(tester.getCenter(button).dx, 1));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });
  });

  testWidgets('a size-classed dialog on a phone: a sheet, and its buttons do what they did', (tester) async {
    await on(tester, () async {
      String? result;
      await host(tester, (context) async {
        result = await ZestDialogShell.showModal<String>(
          context,
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          title: 'Approve a new device',
          body: const Text('A new device (Android) is asking.'),
          primaryAction: (label: 'Continue', onPressed: () => Navigator.of(context).pop('go'), icon: null),
          secondaryAction: (label: 'This was not me', onPressed: () => Navigator.of(context).pop('no')),
        );
      });
      expect(sheet, findsOneWidget);
      expect(find.byKey(const ValueKey('zest-dialog-primary')), findsOneWidget);
      final primary = find.byKey(const ValueKey('zest-dialog-primary'));
      expect(tester.getSize(primary).width, greaterThan(300));
      expect(tester.getSize(primary).height, greaterThanOrEqualTo(44));
      expect(tester.getCenter(find.text('Continue')).dx, closeTo(tester.getCenter(primary).dx, 1));
      expect(tester.getRect(find.byKey(const ValueKey('zest-dialog-primary'))).top,
          lessThan(tester.getRect(find.byKey(const ValueKey('zest-dialog-secondary'))).top));
      await tester.tap(find.text('This was not me'));
      await tester.pumpAndSettle();
      expect(result, 'no');
    });
  });

  testWidgets('a text field in a sheet stays above the keyboard', (tester) async {
    await on(tester, () async {
      await host(tester, (context) => showZestInputDialog(context: context, title: 'Rename', initialValue: 'web-1', confirmLabel: 'Rename'));
      expect(sheet, findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.getRect(sheet).bottom, lessThanOrEqualTo(844 - 320 + 0.5));
      expect(tester.getRect(find.byType(TextField)).bottom, lessThan(844 - 320));
    });
  });

  testWidgets('a tablet and a desktop keep centred dialogs', (tester) async {
    Future<void> check() async {
      await host(tester, (context) => ZestConfirmDialog.show(context, tone: ZestDialogTone.info, title: 'T', body: 'B'));
      expect(find.byType(Dialog), findsOneWidget);
      expect(sheet, findsNothing);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
    }

    await on(tester, check, size: const Size(900, 1200));
    await on(tester, check, platform: TargetPlatform.windows);
  });
}
