import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One word for each security idea (a security review's naming guide). The
/// password that encrypts what you sync is the sync password; it went by five
/// names. Bitwarden's own master password keeps its name. Two-step sign-in's
/// one-time codes are backup codes, which leaves "recovery" to the recovery key,
/// the recovery kit, team recovery and account recovery. The app lock is the app
/// lock, not a PIN lock or a biometric lock. Checking a teammate's keys is
/// comparing safety words; approving a device is comparing pairing words. "Confirm
/// it's you" is the account's check only: the device's own check is unlocking.
/// Unlocking with the body is "face or fingerprint" ("Unlock with face or
/// fingerprint" is the feature's name), never biometrics on its own; Windows
/// Hello and Touch ID are the platforms' own names and stay.
/// What a person adds and keeps (a name, an address, a port, a user, a key) is a
/// host; the live link to it is a connection
/// or a session.
void main() {
  Map<String, dynamic> strings(String language) =>
      jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync()) as Map<String, dynamic>;

  /// The keys whose shown text matches [word], leaving out the ones [skip] names.
  List<String> saying(String language, RegExp word, {bool Function(String key)? skip}) => [
        for (final MapEntry(:key, :value) in strings(language).entries)
          if (!key.startsWith('@') && !(skip?.call(key) ?? false) && value is String && word.hasMatch(value)) key,
      ];

  // What each language called it. Keys of the password managers ('pm...') are
  // Bitwarden's, and are left out.
  const masterPassword = {
    'en': r'master (sync |encryption )?password',
    'de': r'Master-(Sync-|Verschlüsselungs)?[Pp]asswort',
    'es': r'contraseña maestra',
    'fr': r'mot de passe (maître|principal)',
    'it': r'password principale',
    'pt': r'senha mestra',
    'ru': r'мастер-парол',
    'ja': r'マスター\S*パスワード',
    'ko': r'마스터 \S*\s?비밀번호',
    'zh': r'主\S{0,2}密码',
    'hi': r'मास्टर \S*\s?पासवर्ड',
    'ar': r'كلمة المرور الرئيسية|كلمة مرور رئيسية',
  };

  // What each language called two-step sign-in's backup codes before.
  const recoveryCodes = {
    'en': r'recovery codes?\b',
    'de': r'Wiederherstellungscode',
    'es': r'códigos? de recuperación',
    'fr': r'codes? de récupération',
    'it': r'codic[ei] di (recupero|ripristino)',
    'pt': r'códigos? de recuperação',
    'ru': r'код[а-я]* восстановления',
    'ja': r'復旧コード|リカバリー?コード',
    'ko': r'복구 ?코드',
    'zh': r'恢复码|恢复代码',
    'hi': r'रिकवरी कोड',
    'ar': r'رموز (ال)?استرداد|رمز (ال)?استرداد',
  };

  // The app lock's retired names: a PIN lock, a biometric lock.
  const lockNames = {
    'en': r'App Lock|PIN lock|[Bb]iometric lock',
    'de': r'biometrische Sperre|PIN-Sperre',
    'es': r'bloqueo biométrico|bloqueo (por|con) PIN',
    'fr': r'verrouillage biométrique|verrouillage par (code )?PIN',
    'it': r'blocco biometrico|blocco con PIN',
    'pt': r'bloqueio biométrico|bloqueio por PIN',
    'ru': r'биометрическ[а-я]* блокировк|[Бб]локировк[а-я]* по PIN',
    'ja': r'生体認証ロック|PIN ?ロック',
    'ko': r'생체 ?(인식|인증) 잠금|PIN 잠금',
    'zh': r'生物识别锁|PIN ?锁',
    'hi': r'बायोमेट्रिक लॉक|PIN लॉक',
    'ar': r'قفل بيومتري|القفل البيومتري|قفل (رمز )?PIN',
  };

  // What each language said for face or fingerprint: biometrics. No key is let
  // off: the PIN setup's factor on a computer is Windows Hello or Touch ID
  // (pinSetupBiometricFactorWindowsHello, ...TouchId), the platforms' names,
  // which do not say it; elsewhere it is face or fingerprint
  // (pinSetupBiometricFactorGeneric). Key names are not shown.
  const biometrics = {
    'en': r'biometric',
    'de': r'biometri',
    'es': r'biom[eé]tri',
    'fr': r'biom[eé]tri',
    'it': r'biometri',
    'pt': r'biom[eé]tri',
    'ru': r'биометри',
    'ja': r'生体認証',
    'ko': r'생체 ?인[증식]',
    'zh': r'生物识别|生物特征',
    'hi': r'बायोमेट्रि',
    'ar': r'القياسات الحيوية|قياسات حيوية|بيومتري',
  };

  // The keys whose text called a saved entry a connection, in every language,
  // until they were renamed (the phone terminal menu's "Save connection...", "No
  // connections yet", "Select connection" and about a hundred more).
  const savedEntryKeys = [
    'schedTaskConnection', 'schedTaskSelectConnection', 'schedTaskErrorNoConnection',
    'wfEditErrorLoadingConnections', 'wfEditConnectionLabel', 'wfEditSelectConnection', 'termTbSaveConnection',
    'secSetEncryptAtRestSubtitle', 'autoGuideUrlConnectionDesc', 'autoGuideUrlConnectionsDesc',
    'autoGuideBatchCommaLabel', 'autoGuideBatchOutputBody', 'autoGuideHistoryIntro', 'autoGuideHistoryStorage',
    'autoGuideTroubleNotFoundFix', 'autoGuideSecurityNoInjection', 'autoWizPickConnection',
    'autoWizPickConnectionSubtitle', 'autoWizNoConnections', 'autoWizNoConnectionsHint', 'autoWizErrorConnections',
    'connectionDeleteTitle', 'connectionDeleteMsg', 'identityAssignToConnections', 'identityNoConnectionsToAssign',
    'connectionPickerNoMatches', 'settingsKeepaliveDesc', 'sshImportDesc', 'homeSearchHint', 'homeSearchConnections',
    'homeAddNewConnection', 'homeUnknownConnection', 'homeAddConnectionFirst', 'homeSelectConnection',
    'homeUnableToLoadConnections', 'homeShareExportDesc', 'connectionConnectViaHint', 'identityOneConnection',
    'identityConnectionCount', 'monitorNoConnections', 'monitorAddConnection', 'monitorManageEmptyDesc',
    'desktopConnections', 'settingsClearAllDataDesc', 'settingsNoConnectionsToExport',
    'settingsClearAllDataConfirmMsg', 'sshImportImportedCount', 'helpFaqCloudSyncBody', 'helpFaqImportBody',
    'hostsEmptyTitle', 'portForwardEmptyMessage', 'zestPaletteHint', 'zestPaletteConnections',
    'zestPfChooseConnection', 'zestAutoScopeAll', 'zestAutoScopeSpecific', 'zestAutoScopeChoose',
    'zestAutoScopeHelp', 'desktopTerminalAreaEmptyPaneHint', 'desktopShellConnectionRecordNotFound',
    'connectionEditAuthNonSshOptions', 'settingsMobExternalAutomationConfirmBody',
    'settingsMobRestoreFromBackupDesc', 'settingsMobConnectionsAsSshConfig', 'settingsMobExportedConnections',
    'settingsInlineResetAllSettingsBody', 'homeDeleteIdentityUsedBy', 'homeDeleteIdentityUnused',
    'vaultLockSetupDescription', 'hostBulkActionDeleteTitle', 'hostBulkActionDeleteConfirm',
    'desktopHomeRecentConnections', 'sessionInfoSaveConnection', 'staleReconcileConnectionCount',
    'automationHistorySearchHint', 'portForwardListDeleteConfirmBody', 'databaseErrorResetBody',
    'identityListDeleteUsageMessage', 'connectionCardDeleteConnectionTitle', 'identityEditCouldNotLoadConnections',
    'identityEditConnectionsUsingSummary', 'hostsHomeLoadError', 'hostsHomeDuplicateError',
    'hostsHomeDeleteConnectionTitle', 'portForwardEditPickConnectionFirst', 'qrScanConnectionAdded', 'qrScanHint',
    'incomingShareTitle', 'incomingShareAddConnection', 'shareConnectionSubtitle', 'shareConnectionShareSubject',
    'pricingFeaturePerConnectionThemes', 'workflowSvcNoConnection', 'setupAutoIos2', 'accountDeleteLocalHelp',
    'settingsResetAllHelp', 'accountDeleteWipeBulletData', 'sftpTerminalNoConnection', 'sharedConnectionSaveFailed',
    'sshConfigSavedBody', 'zestKeysDeleteBody', 'zestKeysDeleteFallsBack', 'errAlgorithmMismatchTip',
    'errSignInRsaOnlySha1',
    // The empty Port forwards panel on the Hosts page, whose translations
    // still said connections after the English said hosts (found in a UI review).
    'homePortForwardEmptyDesc',
  ];

  // Two of them still say connection where they mean the live link: "never
  // weakens a connection to a modern server", and the Connect button in the
  // languages whose button says connection. (A third, "on the next
  // connection", went with the unused screen it was on, found in a
  // review.)
  const sayTheLiveLinkToo = {
    'errAlgorithmMismatchTip',
    'desktopTerminalAreaEmptyPaneHint',
  };

  // Each language's word for a connection. (zestssh_connections.config, the
  // file the hosts are exported to, is a name and not a word.)
  const connectionWord = {
    'en': r'\bconnections?\b',
    'de': r'Verbindung',
    'es': r'conexi[oó]n',
    'fr': r'connexion',
    'it': r'connession',
    'pt': r'conex(ão|ões)|ligaç',
    'ru': r'подключени|соединени',
    'ja': r'接続',
    'ko': r'연결',
    'zh': r'连接',
    'hi': r'कनेक्शन',
    'ar': r'اتصال',
  };

  // English words only a saved entry was called by.
  final savedEntryWords = RegExp(
      r'Save connection|Delete connections?\b|No (matching )?connections\b|(Select|Pick|Choose) (a |the )?connection|'
      r'Add (a |an SSH |new |this )?connection|Edit (this )?connection|[Dd]uplicate connection|saved connections?\b|'
      r'shared connection|Unknown connection|Recent connections|Search connections|(every|all) connections?\b|'
      r'Your connections\b|connection (labels?|names?)\b|Per-connection|Connections as SSH config|^Connections$',
      caseSensitive: false);

  // The keys the app's code names (l10n.key), so the strings it can show.
  Set<String> shownKeys() => {
        for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart') && !file.path.replaceAll(r'\', '/').contains('/generated/'))
            for (final m in RegExp(r'\.([a-zA-Z]\w*)\b').allMatches(file.readAsStringSync())) m.group(1)!,
      };

  for (final language in masterPassword.keys) {
    test('$language: a saved entry is a host, not a connection', () {
      final s = strings(language);
      expect([for (final key in savedEntryKeys) if (s[key] is! String) key], isEmpty, reason: 'each key is still there');
      final word = RegExp(connectionWord[language]!, caseSensitive: false);
      final found = [
        for (final key in savedEntryKeys)
          if (!sayTheLiveLinkToo.contains(key) && word.hasMatch(s[key] as String)) key,
      ];
      expect(found, isEmpty, reason: 'say host, as hostsNewHost does; a live link stays a connection');
    });

    test('$language: the sync password is called that', () {
      final found = saying(language, RegExp(masterPassword[language]!, caseSensitive: false),
          skip: (key) => key.startsWith('pm'));
      expect(found, isEmpty, reason: 'say the sync password, as lockoutSyncPasswordLabel does');
    });

    test('$language: two-step sign-in has backup codes, not recovery codes', () {
      final found = saying(language, RegExp(recoveryCodes[language]!, caseSensitive: false));
      expect(found, isEmpty, reason: 'say backup codes, as twoStepCodesRow does');
    });

    test('$language: the app lock is not a PIN lock or a biometric lock', () {
      final found = saying(language, RegExp(lockNames[language]!));
      expect(found, isEmpty, reason: 'say the app lock, as secSetAppLock does');
    });

    test('$language: unlocking is with face or fingerprint, not biometrics', () {
      final found = saying(language, RegExp(biometrics[language]!, caseSensitive: false));
      expect(found, isEmpty, reason: 'say face or fingerprint');
    });
  }

  test('English: no shown string calls a saved entry a connection', () {
    final shown = shownKeys();
    expect(shown, containsAll(['hostsNewHost', 'termTbSaveConnection', 'connectionLostTitle']));
    // Settings' group of the pages about sessions (Terminal and SSH, Files,
    // Remote screens) is Connections:
    // the connections themselves, not saved entries.
    final found = saying('en', savedEntryWords,
        skip: (key) => !shown.contains(key) || key == 'settingsGroupConnections');
    expect(found, isEmpty, reason: 'a saved entry is a host (hostsNewHost); "Connection lost" and the like stay');
  });

  test('English: the two that still say connection say it of the live link only', () {
    final en = strings('en');
    expect(en['errAlgorithmMismatchTip'], startsWith('Edit this host and turn on'));
    expect(en['errAlgorithmMismatchTip'], contains('never weakens a connection to a modern server'));
    expect(en['desktopTerminalAreaEmptyPaneHint'], 'Click Connect to fill this slot,\nor drag a host here.');
  });

  test('English: the Account page by that name', () {
    expect(saying('en', RegExp('Profile screen')), isEmpty);
  });

  test('English: a teammate\'s keys are checked with safety words', () {
    final found = saying(
        'en', RegExp(r'[Cc]ompares? (the new |their )?(fingerprints?|codes)\b|\bYour fingerprint\b|Use digits|Show my code'));
    expect(found, isEmpty, reason: 'say safety words, as orchardVerifyTitle does');
  });

  test('English: a new device is approved with pairing words', () {
    expect(saying('en', RegExp(r'three words')), isEmpty, reason: 'say three pairing words, as deviceRequestHow does');
  });

  test('English: "confirm it is you" is never said; the device\'s own check is unlocking', () {
    final found = saying('en', RegExp(r'confirm it is you', caseSensitive: false));
    expect(found, isEmpty, reason: 'the account check is "Confirm it\'s you" (stepUpTitle); the device check says unlock');
  });
}
