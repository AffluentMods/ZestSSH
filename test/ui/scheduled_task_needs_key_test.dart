import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

/// A task that names an API key this device does not have (one that came in with guest
/// data, whose keys do not) says it needs a key, as a host says of its own when it connects.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late ScheduledTask task;

  setUpAll(() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.scheduledTasks).insert(ScheduledTasksCompanion.insert(
        id: 'st1', name: 'backup', action: 'workflow', connectionId: 'h1', scheduleType: 'daily', apiKeyId: 'ak1', createdAt: DateTime.utc(2026, 6, 1)));
    task = (await db.select(db.scheduledTasks).get()).single;
    await db.close();
  });

  Future<void> open(WidgetTester tester, Map<String, String> keychain) async {
    FlutterSecureStorage.setMockInitialValues(keychain);
    await tester.pumpWidget(ProviderScope(
      overrides: [secureStorageProvider.overrideWithValue(const FlutterSecureStorage())],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ScheduledTaskCard(task: task)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the key is not on this device: it says so', (tester) async {
    await open(tester, const {});
    expect(find.text(en.schedTaskNeedsApiKey), findsOneWidget);
    // On or off is the app's own switch: the system's, tinted orange, drew
    // no knob on a task that is on (seen in the screenshot tests).
    expect(find.byType(ZestSwitch), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('the key is here: nothing is said', (tester) async {
    await open(tester, {
      'automation_api_keys': jsonEncode([
        {'id': 'ak1', 'label': 'my script', 'hash': 'made-up', 'hint': 'demo', 'createdAt': '2026-06-01T00:00:00.000Z'},
      ]),
    });
    expect(find.text(en.schedTaskNeedsApiKey), findsNothing);
  });
}
