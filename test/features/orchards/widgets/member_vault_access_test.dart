import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion;
import 'package:zestssh/features/orchards/widgets/member_vault_access.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart' show confirmNewRecordKinds;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

// The member panel's Vault access
// as drawn: in every language, as wide as the panel and
// as narrow as a phone's dialog, and the question asked before the first
// change of a new kind in a team.

const _owner = 'owner';
const _riley = 'riley';

/// Riley (Developers): held to Connect in Production, Staging from her role,
/// nothing in Billing, and a vault whose hosts log in with its certificates.
OrchardRecord _team() {
  final r = OrchardRecord('team');
  for (final id in ['prod', 'staging', 'billing', 'servers']) {
    r.crates[id] = RecordCrate(id: id, ownersOnly: false, allow: {...CrateSwitches.capped});
  }
  r.crates['servers']!.ca = RecordCa(
    on: true,
    generation: 1,
    publicKeys: {1: Uint8List(32)},
    ttlMinutes: 60,
    principals: const {},
    keyCrate: 'keys',
  );
  r.roles['devs'] = RecordRole(
    id: 'devs',
    rank: 100,
    nameEnc: '',
    nameGeneration: 1,
    can: {},
    crates: {
      'prod': levelSwitches(CrateLevel.use),
      'staging': levelSwitches(CrateLevel.edit),
      'servers': levelSwitches(CrateLevel.manage),
    },
  );
  r.members[_owner] = RecordMember(uid: _owner, role: FixedRoles.owner, keys: {}, since: 1);
  r.members[_riley] = RecordMember(uid: _riley, role: 'devs', keys: {}, since: 1)
    ..limits['prod'] = levelSwitches(CrateLevel.connect);
  return r;
}

const _names = {'prod': 'Production', 'staging': 'Staging', 'billing': 'Billing', 'servers': 'Servers'};

Future<void> _pump(WidgetTester tester, Widget child, {Locale locale = const Locale('en'), double width = 360}) =>
    tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'GeistSans'),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: child)),
        ),
      ),
    ));

void main() {
  setUpAll(() async {
    final loader = FontLoader('GeistSans');
    for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']) {
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
    }
    await loader.load();
  });

  Widget table(OrchardRecord r, {String uid = _riley, bool on = true, Map<String, String> timed = const {}}) =>
      MemberVaultAccess(
        role: r.members[uid]!.role,
        record: r,
        rows: vaultAccessOf(r, _owner, uid, limitsOn: on),
        crateName: (c) => _names[c]!,
        timed: timed,
        onPick: (_, _) {},
      );

  testWidgets('in every language, as wide as the panel and as narrow as a phone: nothing cut, nothing broken',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final r = _team();
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      for (final width in [360.0, 296.0]) {
        final where = '$locale at $width';
        await _pump(tester, table(r, timed: {'staging': '${t.crateLevelManage}${t.listSeparator}${t.accessUntil('3:00 PM')}'}),
            locale: locale, width: width);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: where);
        for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText))) {
          expect(p.didExceedMaxLines, isFalse, reason: '$where: "${p.text.toPlainText()}" is cut');
        }
        // A level is one line: never broken in the middle of a word.
        for (final id in _names.keys) {
          final from = tester.renderObject<RenderParagraph>(
              find.descendant(of: find.byKey(ValueKey('vault-from-$id')), matching: find.byType(RichText)));
          // (One line of 12.5 is under 20 high; two are over 25.)
          expect(from.size.height, lessThan(22), reason: '$where: $id is on two lines');
        }
        expect(find.text(t.vaultAccessCertNote), findsOneWidget, reason: where);
        // The choices, open, are whole too.
        await tester.tap(find.byKey(const ValueKey('vault-pick-prod')));
        await tester.pumpAndSettle();
        for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText))) {
          expect(p.didExceedMaxLines, isFalse, reason: '$where, open: "${p.text.toPlainText()}" is cut');
        }
        await tester.tapAt(const Offset(790, 1390));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('set apart in the brand ink; what their role gives beside it; an owner and an admin in a line', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final r = _team();
    await _pump(tester, table(r));
    final prod = tester.widget<ZestSelect<VaultPick>>(find.byKey(const ValueKey('vault-pick-prod')));
    expect(prod.value, VaultPick.connect);
    expect(prod.accent, isTrue);
    expect(tester.widget<ZestSelect<VaultPick>>(find.byKey(const ValueKey('vault-pick-staging'))).accent, isFalse);
    expect(tester.widget<Text>(find.byKey(const ValueKey('vault-from-prod'))).data, l10n.crateLevelUse);
    expect(tester.widget<Text>(find.byKey(const ValueKey('vault-from-billing'))).data, l10n.crateLevelNone);
    expect(find.text(l10n.vaultAccessHint), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-access-not-yet')), findsNothing);

    // Not on yet: the panel says so.
    await _pump(tester, table(r, on: false));
    expect(find.text(l10n.vaultAccessNotYet(kNewRecordKindsVersion)), findsOneWidget);

    await _pump(tester, table(r, uid: _owner));
    expect(find.text(l10n.vaultAccessOwner), findsOneWidget);
    expect(find.byType(ZestSelect<VaultPick>), findsNothing);

    r.members['ada'] = RecordMember(uid: 'ada', role: FixedRoles.admin, keys: {}, since: 1);
    await _pump(tester, table(r, uid: 'ada'));
    expect(find.text(l10n.vaultAccessAdmin), findsOneWidget);
    expect(find.text(l10n.vaultAccessForThem), findsNothing);
    expect(find.byType(ZestSelect<VaultPick>), findsNothing);
  });

  group('before the first change of a new kind', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    /// Asks, as a pick would; the answer once the question is closed.
    Future<bool? Function()> ask(WidgetTester tester, OrchardRecord r, {required bool owner}) async {
      bool? answer;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await confirmNewRecordKinds(context, r, owner: owner),
            child: const Text('go'),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return () => answer;
    }

    testWidgets('an owner is asked, and goes on only with Make the change', (tester) async {
      final r = _team();
      var answer = await ask(tester, r, owner: true);
      expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsOneWidget);
      expect(find.text(l10n.newKindsBody), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(answer(), isFalse);
      answer = await ask(tester, r, owner: true);
      await tester.tap(find.text(l10n.newKindsConfirm));
      await tester.pumpAndSettle();
      expect(answer(), isTrue);
    });

    testWidgets('anyone else is told an owner makes the first, and does not go on', (tester) async {
      final answer = await ask(tester, _team(), owner: false);
      expect(find.text(l10n.newKindsOwnerFirstTitle), findsOneWidget);
      expect(find.text(l10n.newKindsOwnerFirstBody(kNewRecordKindsVersion)), findsOneWidget);
      expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsNothing);
      await tester.tap(find.text(l10n.close));
      await tester.pumpAndSettle();
      expect(answer(), isFalse);
    });

    testWidgets('once the team has one, nobody is asked again', (tester) async {
      final r = _team()..newKindsUsed = true;
      for (final owner in [true, false]) {
        final answer = await ask(tester, r, owner: owner);
        expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsNothing);
        expect(find.text(l10n.newKindsOwnerFirstTitle), findsNothing);
        expect(answer(), isTrue);
      }
    });
  });
}
