import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart';

/// The Help panel's report form posts publicly too: its words go through
/// the same scrubbing as diagnostics, and the person sees exactly what
/// everyone will read before it goes (found in a 3.4 security review).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => PackageInfo.setMockInitialValues(
      appName: 'ZestSSH', packageName: 'demo', version: '3.4.0', buildNumber: '1', buildSignature: ''));

  testWidgets('a report is shown scrubbed, with what was taken out marked, and goes as shown', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final sent = <Map<String, dynamic>>[];
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        feedbackServiceProvider.overrideWithValue(FeedbackService(db, prefs,
            client: MockClient((req) async {
              sent.add((jsonDecode(req.body) as Map).cast<String, dynamic>());
              return http.Response('{}', 201);
            }),
            baseUrl: 'https://api.test/v1')),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: ReportIssueScreen(embedded: true)),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Sync stops');
    await tester.enterText(fields.at(1), 'Connecting to acme-billing.com with token abc123 fails.');
    await tester.pump();
    await tester.tap(find.text(l10n.feedbackSend));
    await tester.pumpAndSettle();
    expect(find.text(l10n.supportHubPublicPreviewTitle), findsOneWidget);
    expect(sent, isEmpty);
    final body = tester.widget<SelectableText>(find.byKey(const ValueKey('hub-public-preview-1'))).textSpan!;
    expect(body.toPlainText(), 'Connecting to <domain> with token [removed] fails.');
    await tester.tap(find.byKey(const ValueKey('hub-public-send')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(sent.single['body'], 'Connecting to <domain> with token [removed] fails.');
    expect(sent.single['title'], 'Sync stops');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
