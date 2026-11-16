import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// Perf regression guard for the Activity panel at folder-upload scale.
///
/// A website tree is ~16k files (node_modules). Every progress publish
/// rebuilds this panel, so it must build only the VISIBLE rows, not one widget
/// per item. This asserts on WORK done (row widgets constructed), not on
/// wall-clock: the earlier version bounded a 13 ms operation at 300 ms, which
/// the eager 45-to-55 ms code it was meant to reject passed cleanly. The count
/// assertion fails the instant rows are built eagerly again.
void main() {
  const n = 16000;

  List<TransferItem> makeItems() => List.generate(n, (i) {
        final t = TransferItem(
          id: 'f$i',
          localPath: 'C:/site/node_modules/pkg$i/index.js',
          remotePath: '/var/www/site/node_modules/pkg$i/index.js',
          fileName: 'index$i.js',
          direction: TransferDirection.upload,
          totalBytes: 2048,
          operationId: 'op1',
          operationLabel: 'website',
        );
        if (i < 3) {
          t.status = TransferStatus.active;
          t.transferredBytes = 1024;
        } else if (i < 100) {
          t.status = TransferStatus.completed;
          t.transferredBytes = 2048;
          t.completedAt = t.startedAt.add(const Duration(milliseconds: 40));
        }
        return t;
      });

  Widget host(List<TransferItem> items) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TransferQueuePanel(transfers: items),
            ],
          ),
        ),
      );

  testWidgets(
    'an expanded 16k-item operation builds only visible rows, not 16k',
    (tester) async {
      final items = makeItems();
      await tester.pumpWidget(host(items));

      // Open the panel (its title bar is the first InkWell inside it).
      await tester.tap(find
          .descendant(
            of: find.byType(TransferQueuePanel),
            matching: find.byType(InkWell),
          )
          .first);
      await tester.pump();

      // Expand the operation so all 16k child rows are "in" the list.
      await tester.tap(
          find.textContaining('website', findRichText: true).first);
      await tester.pump();

      // A progress publish exactly as the provider does it: a fresh list, the
      // same mutated items, panel State preserved. Count rows built by it.
      for (var i = 0; i < 3; i++) {
        items[i].transferredBytes += 256;
      }
      _TransferQueuePanelStateProbe.reset();
      await tester.pumpWidget(host(List<TransferItem>.of(items)));

      final built = TransferQueuePanel.debugRowBuildCountForTest;
      debugPrint('PANEL PERF n=$n: rows built on republish = $built');

      // The Activity drawer is capped to ~6 row heights and scrolls; with a
      // modest cache extent, tens of rows are realised, never thousands. Eager
      // construction (the regression) makes this 16000+.
      expect(
        built,
        lessThan(120),
        reason: 'expanded 16k-item operation built $built rows on one publish; '
            'rows must be built lazily by ListView.builder, not eagerly',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets('a collapsed 16k-item operation builds no child rows',
      (tester) async {
    final items = makeItems();
    await tester.pumpWidget(host(items));
    await tester.tap(find
        .descendant(
          of: find.byType(TransferQueuePanel),
          matching: find.byType(InkWell),
        )
        .first);
    await tester.pump(); // expand panel, operation stays collapsed

    _TransferQueuePanelStateProbe.reset();
    for (var i = 0; i < 3; i++) {
      items[i].transferredBytes += 256;
    }
    await tester.pumpWidget(host(List<TransferItem>.of(items)));

    final built = TransferQueuePanel.debugRowBuildCountForTest;
    debugPrint('PANEL PERF n=$n (collapsed op): rows built = $built');
    // A collapsed operation shows one parent row and no per-file rows.
    expect(built, lessThan(8));
  });
}

/// Thin alias so the test reads clearly; the counter lives on the panel.
abstract class _TransferQueuePanelStateProbe {
  static void reset() => TransferQueuePanel.debugRowBuildCountForTest = 0;
}
