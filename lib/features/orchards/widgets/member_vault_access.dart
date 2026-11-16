import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show crateLevelName;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// [pick] in words: From role, No access, a level, or Custom.
String vaultPickName(VaultPick pick, AppLocalizations l10n) => switch (pick) {
      VaultPick.fromRole => l10n.vaultAccessFromRole,
      VaultPick.none => l10n.vaultAccessNoAccess,
      VaultPick.custom => l10n.crateLevelCustom,
      _ => crateLevelName(pick.level!, l10n),
    };

/// What [switches] come to in [crate], in words: a level, None, or Custom.
String vaultSwitchesName(Set<String> switches, RecordCrate crate, AppLocalizations l10n) {
  if (switches.isEmpty) return l10n.crateLevelNone;
  final level = vaultLevelIn(switches, crate);
  return level == null ? l10n.crateLevelCustom : crateLevelName(level, l10n);
}

/// A member's Vault access:
/// every vault that is not owners-only, what their role gives
/// there, and what is set for them, a select where this account may change
/// it (the levels it could not give greyed). Set for them apart from their
/// role in the brand's ink. An owner's is one line; an admin's is what the
/// Admin role gives, with nothing to pick. Where the room is narrow (a
/// phone), each vault takes two lines.
class MemberVaultAccess extends StatelessWidget {
  const MemberVaultAccess({
    super.key,
    required this.role,
    required this.record,
    required this.rows,
    required this.crateName,
    required this.onPick,
    this.timed = const {},
  });

  /// The member's role.
  final String role;
  final OrchardRecord record;
  final List<VaultAccessRow> rows;
  final String Function(String crateId) crateName;

  /// What they have on top until a set time, in words, by vault: shown
  /// under its name.
  final Map<String, String> timed;

  /// Null while a change is on its way: the selects are shown disabled.
  final void Function(String crateId, VaultPick pick)? onPick;

  /// Where the vault's name has less room than this beside the columns, it
  /// has a line of its own (a phone).
  static const _nameRoom = 96.0;

  /// A select's box around its words: padding, the gap and the chevron.
  static const _selectChrome = 12.0 + 10 + 6 + 14 + 4;

  static const _head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3);
  static const _value = TextStyle(fontSize: 12.5);
  static const _choice = TextStyle(fontSize: 13);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hint = TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary);
    if (role == FixedRoles.owner) {
      return Text(l10n.vaultAccessOwner,
          key: const ValueKey('vault-access-owner'), style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary));
    }
    final admin = role == FixedRoles.admin;
    final head = _head.copyWith(color: ZestTokens.textTertiary);
    // The columns are as wide as their longest words in this language, so
    // no level or choice is cut or broken in the middle.
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double width(String s, TextStyle style) => (TextPainter(
          text: TextSpan(text: s, style: base.merge(style)),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 1,
        )..layout())
            .width
            .ceilToDouble();
    final fromWidth = [
      width(l10n.vaultAccessFromRole, _head),
      for (final r in rows) width(vaultSwitchesName(r.fromRole, record.crates[r.crateId]!, l10n), _value),
    ].fold(0.0, math.max) + 2;
    final forWidth = [
      width(l10n.vaultAccessForThem, _head),
      for (final r in rows) ...[
        width(vaultPickName(r.current, l10n), _value),
        for (final p in r.picks) width(vaultPickName(p.pick, l10n), _choice) + _selectChrome,
      ],
    ].fold(0.0, math.max) + 2;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth - fromWidth - (admin ? 0 : forWidth + 8) - 8 >= _nameRoom;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: Text(l10n.vaultAccessVault, style: head)),
                  const SizedBox(width: 8),
                  SizedBox(width: fromWidth, child: Text(l10n.vaultAccessFromRole, style: head)),
                  if (!admin) ...[
                    const SizedBox(width: 8),
                    SizedBox(width: forWidth, child: Text(l10n.vaultAccessForThem, style: head)),
                  ],
                ],
              ),
            ),
          for (final r in rows)
            _row(context, r, l10n, wide: wide, admin: admin, fromWidth: fromWidth, forWidth: forWidth),
          const SizedBox(height: 8),
          Text(admin ? l10n.vaultAccessAdmin : l10n.vaultAccessHint, key: const ValueKey('vault-access-hint'), style: hint),
          if (!admin && rows.any((r) => r.waitsForSwitch)) ...[
            const SizedBox(height: 6),
            Text(l10n.vaultAccessNotYet(kNewRecordKindsVersion), key: const ValueKey('vault-access-not-yet'), style: hint),
          ],
          // Hosts that log in with a vault's certificates take the user
          // names from the role: Connect and Use log in alike there.
          if (!admin && rows.any((r) => record.crates[r.crateId]?.ca != null)) ...[
            const SizedBox(height: 6),
            Text(l10n.vaultAccessCertNote, key: const ValueKey('vault-access-certificates'), style: hint),
          ],
        ],
      );
    });
  }

  Widget _row(BuildContext context, VaultAccessRow r, AppLocalizations l10n,
      {required bool wide, required bool admin, required double fromWidth, required double forWidth}) {
    final crate = record.crates[r.crateId]!;
    final when = timed[r.crateId];
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(crateName(r.crateId),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary)),
        if (when != null)
          Text(when,
              key: ValueKey('vault-timed-${r.crateId}'),
              style: TextStyle(fontSize: 11.5, height: 1.35, color: ZestTokens.textSecondary)),
      ],
    );
    final fromRole = Text(
      vaultSwitchesName(r.fromRole, crate, l10n),
      key: ValueKey('vault-from-${r.crateId}'),
      style: _value.copyWith(color: r.fromRole.isEmpty ? ZestTokens.textTertiary : ZestTokens.textSecondary),
    );
    final Widget? forThem = admin
        ? null
        : r.picks.isEmpty
            ? Text(
                vaultPickName(r.current, l10n),
                key: ValueKey('vault-for-${r.crateId}'),
                style: _value.copyWith(color: r.apart ? ZestTokens.brandInk : ZestTokens.textSecondary),
              )
            : ZestSelect<VaultPick>(
                key: ValueKey('vault-pick-${r.crateId}'),
                value: r.current,
                accent: r.apart,
                items: [
                  for (final p in r.picks) ZestSelectItem(p.pick, vaultPickName(p.pick, l10n), enabled: p.open),
                ],
                onChanged: onPick == null
                    ? null
                    : (p) {
                        if (p != r.current) onPick!(r.crateId, p);
                      },
              );
    return Container(
      key: ValueKey('vault-row-${r.crateId}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZestTokens.borderSubtle))),
      child: wide
          ? ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Row(
                children: [
                  Expanded(child: name),
                  const SizedBox(width: 8),
                  SizedBox(width: fromWidth, child: fromRole),
                  if (forThem != null) ...[
                    const SizedBox(width: 8),
                    SizedBox(width: forWidth, child: forThem),
                  ],
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                name,
                const SizedBox(height: 4),
                Row(
                  children: [
                    // What their role gives, under the column's name, which
                    // has no header row here.
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.vaultAccessFromRole, style: _head.copyWith(color: ZestTokens.textTertiary)),
                          fromRole,
                        ],
                      ),
                    ),
                    if (forThem != null) ...[
                      const SizedBox(width: 8),
                      SizedBox(width: forWidth, child: forThem),
                    ],
                  ],
                ),
              ],
            ),
    );
  }
}
