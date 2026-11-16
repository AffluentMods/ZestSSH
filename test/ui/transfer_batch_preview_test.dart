import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// A collapsed "N items" batch names what was dragged, so two running batches
/// can be told apart without expanding either (SFTP fixes spec, item 5).
void main() {
  group('operationRootsPreview', () {
    test('two names or fewer are listed as they are', () {
      expect(operationRootsPreview(null), '');
      expect(operationRootsPreview(const []), '');
      expect(operationRootsPreview(const ['site-assets']), 'site-assets');
      expect(operationRootsPreview(const ['site-assets', 'pipeline']),
          'site-assets, pipeline');
    });

    test('past two, the rest are counted', () {
      expect(
          operationRootsPreview(
              const ['site-assets', 'pipeline', 'requirements.txt']),
          'site-assets, pipeline +1');
      expect(operationRootsPreview(const ['a', 'b', 'c', 'd', 'e']),
          'a, b +3');
    });
  });

  List<TransferItem> batch(String op, List<String>? roots, int files,
          {String? label}) =>
      List.generate(files, (i) {
        final t = TransferItem(
          id: '$op-$i',
          localPath: 'C:/work/${roots?.first ?? 'site'}/f$i.txt',
          remotePath: '/srv/${roots?.first ?? 'site'}/f$i.txt',
          fileName: 'f$i.txt',
          direction: TransferDirection.upload,
          totalBytes: 100,
          operationId: op,
          operationLabel: label ?? '${roots?.length ?? 1} items',
          operationRoots: roots,
        );
        if (i == 0) t.status = TransferStatus.active;
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

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find
        .descendant(
          of: find.byType(TransferQueuePanel),
          matching: find.byType(InkWell),
        )
        .first);
    await tester.pump();
  }

  testWidgets('each collapsed batch names what was dragged', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host([
      ...batch('a', const ['shop-storefront-web', 'docs', 'notes.md'], 3),
      ...batch('b', const ['site-assets', 'pipeline', 'requirements.txt'], 4),
    ]));
    await openPanel(tester);

    expect(find.text('shop-storefront-web, docs +1'), findsOneWidget);
    expect(find.text('site-assets, pipeline +1'), findsOneWidget);
    // The count is still there beside the names.
    expect(find.textContaining('/ 4 files'), findsOneWidget);
    expect(find.textContaining('/ 3 files'), findsOneWidget);
  });

  testWidgets('a single dropped folder adds no preview: its label names it',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(batch('c', null, 2, label: 'website')));
    await openPanel(tester);

    expect(find.byKey(const ValueKey('operation-roots-preview')), findsNothing);
    expect(find.textContaining('/ 2 files'), findsOneWidget);
  });

  testWidgets('long names give way before the file count does',
      (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(batch(
        'd',
        const [
          'an-extremely-long-folder-name-that-will-never-fit-here',
          'another-very-long-folder-name-for-good-measure',
          'x',
        ],
        5)));
    await openPanel(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('/ 5 files'), findsOneWidget);
  });
}
