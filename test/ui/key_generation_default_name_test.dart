import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';

/// The key generator's first name for a new key (found in a code review):
/// "My Ed25519 key", "My RSA key" and "My ECDSA key" were English in
/// every language until another type was picked. Now the name is the
/// person's language's from the start.
void main() {
  Future<void> pump(WidgetTester tester, Locale locale, KeyGenerationFormatHint? format) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: KeyGenerationScreen(initialFormat: format),
      ),
    ));
    await tester.pump();
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('the first name is in ${locale.languageCode}, for each type asked for', (tester) async {
      final l10n = lookupAppLocalizations(locale);
      for (final (format, name) in [
        (null, l10n.keyGenDefaultNameEd25519),
        (KeyGenerationFormatHint.ed25519, l10n.keyGenDefaultNameEd25519),
        (KeyGenerationFormatHint.rsa, l10n.keyGenDefaultNameRsa),
        (KeyGenerationFormatHint.ecdsa, l10n.keyGenDefaultNameEcdsa),
      ]) {
        await pump(tester, locale, format);
        final field = tester.widgetList<EditableText>(find.byType(EditableText)).first;
        expect(field.controller.text, name, reason: '${locale.languageCode} ${format?.name}');
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
}
