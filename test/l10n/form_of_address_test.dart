import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One form of address in each language (3.0).
///
/// The German app says "Sie", the Spanish app says "tú" and the Chinese app
/// says 你. Among them, thirty-six German sentences said "du", forty-odd
/// Spanish ones said "usted" and a hundred and ten Chinese ones said 您:
/// a reader met two hands in one app.
///
/// What is looked for here is words of a list, so it finds what it knows of:
/// whoever writes a new sentence still has to read it.
void main() {
  Map<String, String> strings(String language) => {
        for (final e in (jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync()) as Map<String, dynamic>)
            .entries)
          if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
      };

  /// The strings of [language] in which [found] finds something, with what
  /// it found, leaving out [allowed].
  Map<String, String> where(String language, Iterable<RegExp> found, {Set<String> allowed = const {}}) => {
        for (final MapEntry(:key, :value) in strings(language).entries)
          if (!allowed.contains(key))
            for (final match in [
              for (final pattern in found) ?pattern.firstMatch(value),
            ].take(1))
              key: match.group(0)!.trim(),
      };

  test('German: nothing addresses its reader as du', () {
    // The words themselves.
    final du = RegExp(r'\b(du|Du|dein\w*|Dein\w*|dich|Dich|dir|Dir|euch|Euch|euer|Euer|eure\w*|Eure\w*)\b');
    // A verb in the form "du" is told to do something in: at the start of a sentence, and after a comma, "und",
    // "oder" or "dann". ("Sie" is told with the verb's long form: "Prüfen Sie".)
    const verbs = 'Aktiviere|Aktualisiere|Beachte|Beaufsichtige|Benenne|Bestätige|Deaktiviere|Drücke|Entferne|'
        'Entsperre|Erstelle|Füge|Führe|Gib|Importiere|Installiere|Klicke|Kopiere|Lass|Lies|Lösche|Mach|Melde|Nimm|'
        'Nutze|Öffne|Probiere|Prüfe|Schau|Schließe|Sende|Setze|Sieh|Speichere|Starte|Stoppe|Tippe|Vergleiche|'
        'Versuche|Verwende|Wähle|Wende|Ändere';
    final atTheStart = RegExp('(?:^|[.:!?]\\s+|\\n)(?:$verbs)\\b(?! Sie\\b)');
    final later = RegExp('(?:, | und | oder | dann )(?:${verbs.toLowerCase()})\\b');
    final found = where('de', [du, atTheStart, later], allowed: const {
      // What its person says to Siri, as they would say it.
      'autoGuideWhatIsUseCases',
    });
    expect(found, isEmpty, reason: '${found.length} German strings');
  });

  test('Spanish: nothing addresses its reader as usted', () {
    final usted = RegExp(r'\b[Uu]sted(es)?\b');
    // A verb in the form "usted" is told to do something in, at the start of a sentence. (Inside a sentence the
    // same form is what somebody else is to do, or may do: "pide al propietario que añada".)
    const verbs = 'Abra|Acepte|Active|Actívelo|Actualice|Agregue|Añada|Asegúrese|Busque|Cambie|Cierre|Compruebe|'
        'Conecte|Confirme|Consulte|Copie|Cree|Deje|Desbloquee|Elija|Elíjalo|Escriba|Escríbala|Espere|Guarde|'
        'Guárdelo|Haga|Importe|Impórtelo|Indique|Inicie|Instale|Instálelo|Intente|Inténtelo|Introduzca|Mantenga|'
        'Permítalo|Pruebe|Pulse|Revise|Seleccione|Toque|Use|Utilice|Verifique|Vuelva';
    final atTheStart = RegExp('(?:^|[.:!?¡¿]\\s*|\\n)(?:$verbs)\\b');
    // And the forms that have no other reading wherever they stand.
    final anywhere = RegExp(
        r'\b(Actívelo|Elíjalo|Escríbala|Guárdelo|Impórtelo|Instálelo|Inténtelo|Permítalo|rellénela|conéctelo|'
        r'vuelva a intentarlo|use en su lugar)\b',
        caseSensitive: false);
    // "su" is his, hers, its and theirs as well as the reader's own, so it is looked for only in what can be
    // nobody else's: a master password, a browser, a database of one's passwords.
    final theReadersOwn = RegExp(
        r'\b(su contraseña maestra|su base de datos|su navegador|sus claves SSH|su gestor de contraseñas|'
        r'sus manos|su Orchard|No confíe\b|son los que espera\b|Se le pregunta|la escribe,)',
        caseSensitive: false);
    final found = where('es', [usted, atTheStart, anywhere, theReadersOwn], allowed: const {
      // A vault's own master password, and the app's own database.
      'syncResetAskKept',
      'databaseErrorDescription',
    });
    expect(found, isEmpty, reason: '${found.length} Spanish strings');
  });

  test('Spanish: the recovery kit and the check of a recovery key speak to their reader and of nobody else', () {
    // Whoever reads them is the only person in them: "su", "sus" and "le" there would be "usted".
    final someoneElse = RegExp(r'\b(su|sus|le|les)\b', caseSensitive: false);
    final kit = {
      for (final MapEntry(:key, :value) in strings('es').entries)
        if (key.startsWith('recoveryKit') || key.startsWith('recoveryCheck')) key: value,
    };
    expect(kit.length, greaterThan(30));
    final found = {
      for (final MapEntry(:key, :value) in kit.entries)
        if (someoneElse.hasMatch(value)) key: value,
    };
    expect(found, isEmpty);
  });

  test('Chinese: nothing addresses its reader as 您', () {
    final found = where('zh', [RegExp(String.fromCharCode(0x60a8))]);
    expect(found, isEmpty, reason: '${found.length} Chinese strings');
  });
}
