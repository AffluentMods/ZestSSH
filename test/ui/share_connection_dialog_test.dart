import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/connection/share_connection_sheet.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

/// Sharing a host is a dialog on a computer and a sheet on a phone, as every
/// other one (it was a phone's pop-up on
/// computers too); its link is copied from the footer.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> open(WidgetTester tester, {Size size = const Size(1280, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs!)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ShareConnectionSheet.show(context, label: 'web-01', host: 'web-01.example.com', port: 22, user: 'deploy'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('on a computer: a dialog, with Copy link in its footer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await open(tester);
      expect(find.byKey(const ValueKey('share-connection-body')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing, reason: "not a phone's sheet");
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('share-connection-copy')));
      await tester.pump();
      expect(copied, startsWith('zestssh://share?d='));
      expect(SecretClipboard.holding, isTrue, reason: 'copied as a secret is: it leaves the clipboard by itself');
      expect(find.text(l10n.shareConnectionCopyLink), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      // The link is copied as a secret is: past the 45 seconds it
      // stays on the clipboard.
      await tester.pump(kSecretClipboardLife);
      expect(SecretClipboard.holding, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on a phone: a sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await open(tester, size: const Size(400, 900));
      expect(find.byKey(const ValueKey('share-connection-body')), findsOneWidget);
      expect(find.byType(ZestSheetScope), findsOneWidget, reason: 'a sheet');
      expect(find.byType(Dialog), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
