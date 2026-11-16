import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Counts put into words agree with the number in the other languages too
/// (found in a review): fifteen of them became English
/// plurals, and German, Spanish, French, Italian, Portuguese and Russian said
/// "1 Hosts", "1 sesiones", "1 conn." or "(s)" for one. Japanese, Korean and
/// Chinese have no plural, and Arabic and Hindi keep the noun as it is.
void main() {
  AppLocalizations of(String code) => lookupAppLocalizations(Locale(code));

  test('one and more read right', () {
    expect(of('de').sshImportHostsFound(1), '1 Host gefunden');
    expect(of('de').sshImportHostsFound(3), '3 Hosts gefunden');
    expect(of('de').portForwardConnections(1), '1 Verbindung');
    expect(of('es').desktopShellTabClosedWithSessions(1), 'Pestaña cerrada (1 sesión)');
    expect(of('es').desktopShellTabClosedWithSessions(2), 'Pestaña cerrada (2 sesiones)');
    expect(of('fr').snippetsImportedCount(1), '1 snippet importé');
    expect(of('fr').snippetsImportedCount(4), '4 snippets importés');
    expect(of('it').sftpSyncScanning(1), 'Scansione di 1 cartella');
    expect(of('pt').hardwareTokenAddIdentitiesCount(1), 'Adicionar 1 chave');
    expect(of('ru').sftpDeleteItemsFailed(1), 'Не удалось удалить 1 элемент');
    expect(of('ru').sftpDeleteItemsFailed(3), 'Не удалось удалить 3 элемента');
    expect(of('ru').sftpDeleteItemsFailed(5), 'Не удалось удалить 5 элементов');
    expect(of('ru').sftpDeleteItemsFailed(21), 'Не удалось удалить 21 элемент');
    expect(of('hi').hardwareTokenAddIdentitiesCount(1), '1 कुंजी जोड़ें');
  });

  test('no count in those languages says "(s)" or a cut word for one', () {
    for (final code in ['de', 'es', 'fr', 'it', 'pt', 'ru']) {
      final t = of(code);
      for (final said in [
        t.snippetsImportedCount(1),
        t.portForwardConnections(1),
        t.zestSnippetsDeleteCategoryBody(1),
        t.desktopShellDisconnectGroupBody(1),
      ]) {
        expect(said, isNot(contains('(s)')), reason: '$code: $said');
        expect(said, isNot(contains('(es)')), reason: '$code: $said');
        expect(said, isNot(matches(RegExp(r'\b(Verb|conn|подкл)\.'))), reason: '$code: $said');
      }
    }
  });
}
