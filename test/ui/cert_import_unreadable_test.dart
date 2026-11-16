import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/ssh_cert_providers.dart';
import 'package:zestssh/services/ssh_cert/ssh_cert_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/cert_import_dialog.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

/// Import SSH certificate (computer), what is said when the text pasted is
/// not a certificate: the reader's own English reason ("SSH
/// cert: invalid base64 ...") was the message, in every language. Now the
/// person is told what to paste, in their language, and the reason is
/// behind Copy details.
void main() {
  Future<void> pump(WidgetTester tester, Locale locale) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sshCertServiceProvider.overrideWithValue(SshCertService(const FlutterSecureStorage())),
        identitiesProvider.overrideWith((ref) => Stream.value(const [])),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: CertImportDialog()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final locale in const [Locale('en'), Locale('de')]) {
    testWidgets('text that is not a certificate is said in the app\'s language (${locale.languageCode})',
        (tester) async {
      await pump(tester, locale);
      final l10n = lookupAppLocalizations(locale);

      await tester.enterText(find.byType(TextField).first, 'ssh-ed25519-cert-v01@openssh.com not-base64!!');
      await tester.pumpAndSettle();
      expect(find.text(l10n.certImportNotReadable), findsOneWidget);
      expect(find.textContaining('SSH cert:'), findsNothing, reason: "the reader's English stays in the details");
      final copy = tester.widget<CopyDetailsButton>(find.byType(CopyDetailsButton));
      expect(copy.detail, contains('SSH cert:'), reason: 'the reason, for whoever reads the report');

      await tester.enterText(find.byType(TextField).first, 'AAAA');
      await tester.pumpAndSettle();
      expect(find.text(l10n.certImportNotReadable), findsOneWidget, reason: 'bare base64 that is no certificate');

      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(find.text(l10n.certImportNotReadable), findsNothing);
      expect(find.byType(CopyDetailsButton), findsNothing);
    });
  }
}
