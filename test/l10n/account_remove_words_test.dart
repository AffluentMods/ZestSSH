import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Remove from this computer deletes the account's automatic backups too
// (ProfileManager.personFoldersOf): what it says first names them, in every language.
void main() {
  const words = {
    'ar': 'نسخه الاحتياطية التلقائية',
    'de': 'automatischen Backups',
    'en': 'automatic backups',
    'es': 'copias de seguridad automáticas',
    'fr': 'sauvegardes automatiques',
    'hi': 'स्वचालित बैकअप',
    'it': 'backup automatici',
    'ja': '自動バックアップ',
    'ko': '자동 백업',
    'pt': 'backups automáticos',
    'ru': 'автоматические резервные копии',
    'zh': '自动备份',
  };
  for (final e in words.entries) {
    test('accountRemoveBody names them in ${e.key}', () {
      final arb = jsonDecode(File('lib/l10n/app_${e.key}.arb').readAsStringSync()) as Map<String, dynamic>;
      expect(arb['accountRemoveBody'], contains(e.value));
    });
  }
}
