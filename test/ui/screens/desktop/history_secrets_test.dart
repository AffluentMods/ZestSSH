import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/history_view.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's History offers "Save secret-bearing commands", as a phone's
/// does (found by a check of the docs against the code: a
/// computer had no way to turn it on or off), and says so while it is on.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester, {required bool recording}) async {
    SharedPreferences.setMockInitialValues({'command_history_enabled': recording});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        isProProvider.overrideWith((ref) => _Pro()),
        recentCommandHistoryProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: HistoryView()),
      ),
    ));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(HistoryView)));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip(en.zestCommonMoreActions).first);
    await tester.pumpAndSettle();
  }

  testWidgets('while recording, its menu turns saving secret-bearing commands on, and a warning says so', (tester) async {
    final c = await pump(tester, recording: true);
    expect(find.byKey(const ValueKey('history-secrets-banner')), findsNothing);
    await openMenu(tester);
    final item = find.byKey(const ValueKey('history-sensitive'));
    expect(item, findsOneWidget);
    expect(find.text(en.cmdhSaveSecretCommands), findsOneWidget);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(c.read(commandHistoryIncludeSensitiveProvider), isTrue);
    expect(find.byKey(const ValueKey('history-secrets-banner')), findsOneWidget);
    expect(find.text(en.cmdhSavingSecretsBanner), findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('history-sensitive')));
    await tester.pumpAndSettle();
    expect(c.read(commandHistoryIncludeSensitiveProvider), isFalse);
    expect(find.byKey(const ValueKey('history-secrets-banner')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('not recording, the menu has no such item', (tester) async {
    await pump(tester, recording: false);
    await openMenu(tester);
    expect(find.byKey(const ValueKey('history-sensitive')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
