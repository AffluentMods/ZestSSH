import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';

/// Copy details copies what it is given scrubbed (3.0). An
/// error surface was to give it the report ErrorReport.build makes, which has
/// every secret and name taken out; some gave the error as it was thrown (an
/// Orchard's seats, the import of hosts from a cloud account, a sync failure's
/// detail), and its tokens and passwords were copied with it, to be pasted
/// into a ticket. The person's own text (an Orchard's setup file, read back)
/// is copied as it is.
void main() {
  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  Future<void> copy(WidgetTester tester, CopyDetailsButton button) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: button)),
    ));
    await tester.tap(find.byType(CopyDetailsButton));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
  }

  const thrown = 'HTTP 401 from the sync server\n'
      'Authorization: Bearer abcdefghijklmnopqrstuvwx\n'
      'password=hunter2-secret';

  testWidgets('an error given as it was thrown is copied with its secrets taken out', (tester) async {
    await copy(tester, const CopyDetailsButton(detail: thrown));
    expect(copied, hasLength(1));
    for (final secret in ['hunter2-secret', 'abcdefghijklmnopqrstuvwx']) {
      expect(copied.single, isNot(contains(secret)), reason: secret);
    }
    expect(copied.single, contains('HTTP 401 from the sync server'), reason: 'what failed is kept');
  });

  testWidgets('a report already made is copied as it was made', (tester) async {
    final report = ErrorReport.build(
        what: 'Sync did not finish', where: 'Sync: pushing', error: StateError(thrown), now: DateTime(2026, 10, 17));
    await copy(tester, CopyDetailsButton(detail: report));
    expect(copied, [report]);
  });

  testWidgets("the person's own text is copied as it is", (tester) async {
    await copy(tester, const CopyDetailsButton(detail: thrown, asItIs: true));
    expect(copied, [thrown]);
  });
}
