import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Squeezed unlocks Pro features, Juiced is hosting, and sync itself is free: the
/// word sync is never sold (a review of tier wording, and
/// a phone's Home row, which sold "Unlimited
/// sessions, port forwarding & sync"). What these lines offer is said as what it
/// is, in every language. Sync may be named where it is free, or where it is
/// something to turn on, not where it is what is paid for.
void main() {
  final languages = {
    for (final file in Directory('lib/l10n').listSync().whereType<File>())
      if (RegExp(r'app_(\w+)\.arb$').firstMatch(file.path) case final m?)
        m.group(1)!: jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
  };

  // Sync, and the word for it in each of the languages.
  final sync = RegExp(r'sync|sincron|синхрон|مزامن|सिंक|同期|동기화|同步', caseSensitive: false);

  const sellingLines = <String>[
    'homeUnlockFullExperience',
    'homeUnlockFullExperienceDesc',
    'homeUnlimitedConnectionsThemes',
    'homeSyncConnectionsDesc',
    'settingsAddCloudSyncDesc',
    'settingsUpgradeSqueezedOrJuicedDesc',
    'settingsUnlockConnectionsThemes',
    'upgradeAlreadyHavePro',
    'upgradeSignIntoCloudSyncFirst',
    'planRowZestCloud',
    'deskUpgCloudSync',
    'deskUpgJuicedFeatureSync',
    'deskUpgJuicedFeatureShare',
    'deskUpgJuicedFeatureApproval',
    'deskUpgJuicedOfferTagline',
    'deskUpgJuicedTagline',
    'juicedSevenDevices',
    'upgradeFeatureE2ESync',
    'upgradeFeatureSyncConnections',
    'upgradeFeatureSyncSnippets',
    'upgradeFeatureMultiDevice',
    'upgradeFeatureAutoBackups',
    'terminalProGateMsg',
    'desktopShellFreeTierLimit',
  ];

  for (final MapEntry(key: language, value: strings) in languages.entries) {
    test('$language: what is sold is not sync', () {
      final selling = {
        for (final key in sellingLines)
          if (sync.hasMatch('${strings[key]}')) key: strings[key],
      };
      expect(selling, isEmpty);
    });

    test('$language: what a seat brings is storage on ZestSSH Cloud, and turning sync on is free of that', () {
      for (final key in ['teamSyncOfferIncluded', 'teamSyncOfferNeedsSeatOwner', 'teamSyncOfferNeedsSeatMember']) {
        final text = strings[key] as String;
        expect(text, contains('ZestSSH Cloud'), reason: key);
        final after = text.substring(text.indexOf('ZestSSH Cloud') + 'ZestSSH Cloud'.length);
        expect(sync.hasMatch(after.substring(0, min(after.length, 3))), isFalse, reason: '$key: "ZestSSH Cloud sync"');
        // ("the synchronisation of ZestSSH Cloud", where the word goes first.)
        final before = text.substring(0, text.indexOf('ZestSSH Cloud'));
        final lastWords = before.substring(max(0, before.length - 12));
        expect(sync.hasMatch(lastWords), isFalse, reason: '$key: "$lastWords ZestSSH Cloud"');
      }
    });

    test('$language: the free rows go on saying sync is free', () {
      expect(sync.hasMatch(strings['planRowOwnStorageSync'] as String), isTrue);
    });
  }
}

int min(int a, int b) => a < b ? a : b;
int max(int a, int b) => a > b ? a : b;
