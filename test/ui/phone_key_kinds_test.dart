import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/identity/identity_kind.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart' show recordingModeProvider;
import 'package:zestssh/ui/screens/home/home_screen.dart';

/// A phone's list of keys names each kind as a computer does (3.0, found
/// while comparing the five versions): it had keys (a plain
/// key) and everything else, so a certificate, a team's certificate and an
/// agent's key were listed under Passwords, with a lock and the word
/// Password, and a certificate had no Share public key. A computer's names
/// were in English whatever the app's language.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  const publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMadeUpForThisTestOnly demo@example.com';

  // (id, label, kind, its agent)
  const kinds = [
    ('i-key', 'deploy key', 'publicKey', null),
    ('i-cert', 'ops certificate', 'certificate', null),
    ('i-team', 'team certificate', 'teamCertificate', null),
    ('i-agent', 'security key', 'hardwareToken', null),
    ('i-1p', 'agent of a vault', 'hardwareToken', '1password'),
    ('i-pw', 'root password', 'password', null),
    ('i-pm', 'vault password', 'passwordManager', null),
  ];

  Future<List<Identity>> seed(AppDatabase db) async {
    final at = DateTime(2026, 10, 16);
    for (final (id, label, kind, agent) in kinds) {
      final keyLike = kind != 'password' && kind != 'passwordManager';
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: label,
            username: 'deploy',
            authMethod: kind,
            createdAt: at,
            keyType: Value(keyLike ? 'ssh-ed25519' : null),
            publicKeyData: Value(keyLike ? publicKey : null),
            agentSource: Value(agent),
          ));
    }
    return db.select(db.identities).get();
  }

  testWidgets('keys of every kind with the keys, passwords with the passwords, each named by its kind; a '
      "certificate's public key can be shared", (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final identities = (await tester.runAsync(() => seed(db)))!;
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      recordingModeProvider.overrideWith((ref) => false),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: KeysPhoneScreen(),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }

    double top(Finder f) => tester.getTopLeft(f).dy;
    final keysHeader = top(find.text(en.homeSshKeysSection.toUpperCase()));
    final passwordsHeader = top(find.text(en.homePasswordsSection.toUpperCase()));
    expect(keysHeader, lessThan(passwordsHeader));
    for (final identity in identities) {
      final row = find.text(identity.label);
      expect(row, findsOneWidget, reason: identity.id);
      final password = identity.authMethod == 'password' || identity.authMethod == 'passwordManager';
      if (password) {
        expect(top(row), greaterThan(passwordsHeader), reason: '${identity.id} with the passwords');
      } else {
        expect(top(row), allOf(greaterThan(keysHeader), lessThan(passwordsHeader)),
            reason: '${identity.id} with the keys');
      }
    }
    expect(find.text('${identities.length - 2}'), findsWidgets, reason: 'the keys counted as five');
    // Each is shown as a key: its algorithm's strength, Ed25519 for all five.
    // Who it signs in as, its kind and its strength are one line of plain
    // text, parts set apart by a middle dot (the 3.0 quick wins: they were
    // chips).
    Finder part(String name) => find.textContaining(RegExp('· ${RegExp.escape(name)}( ·|\$)'));
    expect(part(en.homeKeyStrengthStrong), findsNWidgets(identities.length - 2));
    for (final name in [
      'Ed25519',
      en.identityCertificate,
      en.identityTeamCertificate,
      en.identityAgentKey,
      en.identityAgentKeyOf('1Password'),
      en.identityPassword,
      en.pmKeyTypeLabel,
    ]) {
      expect(part(name), findsOneWidget, reason: name);
    }

    // A certificate's public key can be shared, as a key's can; a password has none.
    // (A key's own sheet: a long press selects it, and More opens it, 3.4.)
    Future<void> sheetOf(String label) async {
      await tester.longPress(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.selectKeyActions));
      await tester.pumpAndSettle();
    }

    await sheetOf('ops certificate');
    expect(find.text(en.homeSharePublicKey), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await sheetOf('root password');
    expect(find.text(en.homeSharePublicKey), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  test('each kind named, in every language; a password is a password whatever keeps it', () {
    Identity of(String kind, {String? agent, String? keyType}) => Identity(
          id: 'x',
          label: 'x',
          username: 'x',
          authMethod: kind,
          createdAt: DateTime(2026, 10, 16),
          keyType: keyType,
          agentSource: agent,
          isDefault: false,
          allowUnattended: false,
          passwordAfterKey: false,
          usesAgent: false,
          colorIndex: 0,
        );
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(identityTypeLabel(l, of('password')), l.identityPassword);
      expect(identityTypeLabel(l, of('certificate')), l.identityCertificate);
      expect(identityTypeLabel(l, of('hardwareToken')), l.identityAgentKey);
      expect(identityTypeLabel(l, of('hardwareToken', agent: 'bitwarden')), l.identityAgentKeyOf('Bitwarden'));
      expect(identityTypeLabel(l, of('publicKey')), l.homeKeyTypeFallback, reason: 'a key with no type');
      expect(identityTypeLabel(l, of('publicKey', keyType: 'ecdsa-sha2-nistp256')), 'ECDSA');
    }
    expect([for (final k in ['password', 'passwordManager', 'publicKey', 'certificate', 'hardwareToken']) isPasswordIdentity(of(k))],
        [true, true, false, false, false]);
  });
}
