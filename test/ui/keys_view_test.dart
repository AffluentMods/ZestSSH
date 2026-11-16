import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_detail_pane.dart';

/// Minimal [Identity] factory for the pure-helper tests.
Identity _identity({
  required String id,
  required String authMethod,
  String label = 'key',
  String username = 'root',
  String? fingerprint,
  DateTime? createdAt,
}) {
  return Identity(
    id: id,
    label: label,
    username: username,
    authMethod: authMethod,
    publicKeyFingerprint: fingerprint,
    usesAgent: authMethod == 'hardwareToken',
    colorIndex: 0,
    isDefault: false,
    allowUnattended: false,
    passwordAfterKey: false,
    createdAt: createdAt ?? DateTime(2026, 1, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── §2 Header count == sum of section badges ───────────────────────
  group('Keys header meta counts', () {
    test('the header total equals the sum of the four section badges', () {
      // The reported bug: 1 SSH key + 9 passwords rendered as "10 keys".
      final ids = <Identity>[
        _identity(id: 'k1', authMethod: 'publicKey'),
        for (var i = 0; i < 9; i++)
          _identity(id: 'p$i', authMethod: 'password'),
      ];

      final headerTotal = keysMetaKeyCount(ids) + keysMetaPasswordCount(ids);
      final badgeSum = sshKeysOf(ids).length +
          passwordsOf(ids).length +
          certificatesOf(ids).length +
          agentKeysOf(ids).length;

      expect(headerTotal, badgeSum);
      // Passwords are NOT counted as keys any more.
      expect(keysMetaKeyCount(ids), 1);
      expect(keysMetaPasswordCount(ids), 9);
      // With no certs/agents, the keys number matches the SSH KEYS badge.
      expect(keysMetaKeyCount(ids), sshKeysOf(ids).length);
    });

    test('invariant holds with certificates and agent keys present', () {
      final ids = <Identity>[
        _identity(id: 'k1', authMethod: 'publicKey'),
        _identity(id: 'k2', authMethod: 'publicKey'),
        _identity(id: 'c1', authMethod: 'certificate'),
        _identity(id: 'a1', authMethod: 'hardwareToken'),
        _identity(id: 'p1', authMethod: 'password'),
        _identity(id: 'p2', authMethod: 'password'),
      ];

      final headerTotal = keysMetaKeyCount(ids) + keysMetaPasswordCount(ids);
      final badgeSum = sshKeysOf(ids).length +
          passwordsOf(ids).length +
          certificatesOf(ids).length +
          agentKeysOf(ids).length;

      expect(headerTotal, badgeSum); // 6
      expect(keysMetaKeyCount(ids), 4); // 2 ssh + 1 cert + 1 agent
      expect(keysMetaPasswordCount(ids), 2);
    });

    test('every kind of key is in a section: team certificates and password manager keys too', () {
      // Team certificates were in no section and vanished from the
      // list once saved; password manager keys are passwords kept
      // elsewhere.
      final ids = <Identity>[
        for (final (i, method) in const [
          'publicKey',
          'password',
          'certificate',
          'hardwareToken',
          'teamCertificate',
          'passwordManager',
        ].indexed)
          _identity(id: 'i$i', authMethod: method),
      ];
      final listed = [
        ...sshKeysOf(ids),
        ...passwordsOf(ids),
        ...certificatesOf(ids),
        ...agentKeysOf(ids),
      ].map((i) => i.id).toSet();
      expect(listed, {for (final i in ids) i.id});
      expect(certificatesOf(ids).map((i) => i.authMethod), ['certificate', 'teamCertificate']);
      expect(passwordsOf(ids).map((i) => i.authMethod), ['password', 'passwordManager']);
      expect(keysMetaKeyCount(ids) + keysMetaPasswordCount(ids), ids.length);
    });
  });

  // ── §8 No decorative STATUS dots in the Keys source ────────────────
  //
  // The original 1.7 sweep stripped every dot. `keys_list_pane.dart` was later
  // (deliberately) given back a COLOUR-LABEL dot per user request - an identity
  // defaults to no colour, but the row shows a dot once the user assigns one.
  // That one is intentional, so the list pane is excluded here; the remaining
  // Keys sources must still carry no decorative circle.
  group('No decorative status dots', () {
    const files = [
      'lib/ui/screens/desktop/widgets/keys_view.dart',
      'lib/ui/screens/desktop/widgets/keys_controller.dart',
      'lib/ui/screens/desktop/widgets/keys_detail_pane.dart',
    ];

    test('the Keys screen sources contain no BoxShape.circle dot', () {
      for (final path in files) {
        final source = File(path).readAsStringSync();
        expect(
          source.contains('BoxShape.circle'),
          isFalse,
          reason: '$path still draws a decorative circle dot',
        );
      }
    });
  });

  // ── §5 Fingerprint copy puts the FULL value on the clipboard ───────
  testWidgets('fingerprint copy button copies the full fingerprint', (
    tester,
  ) async {
    const fullFingerprint =
        'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFXY';

    // Intercept Clipboard.setData on the platform channel.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    // The button watches recording mode (spec 1a/5), which is seeded from the
    // settings service, so the scope needs preferences.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: KeyFingerprintCopyButton(
              // display shows a truncated value; the copy must use the full one.
              fingerprint: fullFingerprint,
              display: 'SHA256:abcdefghijklmno…',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(KeyFingerprintCopyButton));
    await tester.pump();

    expect(copied, fullFingerprint);

    // A checkmark confirms the copy (copy glyph swapped for a check).
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
    // Drain the reset + notification timers so no timer outlives the test.
    await tester.pump(const Duration(seconds: 4));
  });
}
