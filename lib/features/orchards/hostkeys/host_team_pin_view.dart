import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart' show KnownHostsService;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';

/// A team's pin for a host (3.0), for the host panel: the key
/// everyone trusts there on the pin's route, the Crate that keeps the pin,
/// and whether this account may remove it (delete in that Crate).
class HostTeamPin {
  const HostTeamPin({required this.pin, required this.crateName, required this.mayRemove});

  final TeamHostKeyPin pin;
  final String crateName;
  final bool mayRemove;

  /// Each pinned key's type and SHA256 fingerprint; a TLS certificate's
  /// (an FTPS host's, 3.4) as server tools print it.
  List<(String, String)> get keys => [
        for (final line in pin.keys)
          if (line.split(' ').length == 2) (line.split(' ')[0], _fingerprint(line.split(' ')[0], line.split(' ')[1])),
      ];

  static String _fingerprint(String type, String base64Blob) {
    try {
      final blob = Uint8List.fromList(base64Decode(base64Blob));
      if (KnownHostsService.isCertificate(type)) {
        return KnownHostsService.certificateFingerprint(sha256.convert(blob).toString());
      }
      return OpenSSHKeySerializer.fingerprintFromBlob(blob);
    } on FormatException {
      return '?';
    }
  }
}

/// Every team pin for the host [hostId], saved at [host]:[port], in the space
/// on screen, whatever route each is for: the one for direct connections
/// first, then each for connections through a jump host. (A session through
/// a jump host pins its key for that route, and finds it so; the panel asked
/// only for the direct one, so a pin made through a jump host was never
/// shown, nor could it be removed.) Only the pins of the host's own Crate,
/// the ones its sessions go by: a pin another Crate made for the same
/// address is not this host's. None in your Tree.
final hostTeamPinsProvider = FutureProvider.autoDispose
    .family<List<HostTeamPin>, ({String hostId, String host, int port})>((ref, of) async {
  final db = ref.watch(databaseProvider);
  if (!db.isOrchard) return const [];
  final team = TeamHostKeys(db);
  final out = <HostTeamPin>[];
  for (final pin in await team.pinsOf(of.host, of.port, crateId: await team.crateOfHost(of.hostId))) {
    final crateId = pin.crateId;
    var name = '';
    var mayRemove = false;
    if (crateId != null) {
      final row = await db.customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?',
          variables: [Variable<String>(crateId)]).getSingleOrNull();
      name = row?.read<String?>('name') ?? '';
      mayRemove = (await CratePlacement(db).switchesOf(crateId)).contains(CrateSwitches.delete);
    }
    out.add(HostTeamPin(pin: pin, crateName: name, mayRemove: mayRemove));
  }
  return out;
});

/// The host panel's team pins: a box for each, nothing without one.
class HostTeamPinBox extends ConsumerWidget {
  const HostTeamPinBox({super.key, required this.hostId, required this.host, required this.port});

  /// The host's id: its Crate's pins are the ones shown.
  final String hostId;
  final String host;
  final int port;

  /// Which connections [team]'s pin is for, where that needs saying: a pin
  /// for connections through a jump host always says so, the direct one
  /// where a pin for a jump host is beside it ([besideJumpHosts]); null
  /// where nothing needs saying.
  static String? _route(HostTeamPin team, bool besideJumpHosts, AppLocalizations l10n, WidgetRef ref) {
    final pin = team.pin;
    if (pin.viaScope.isEmpty) return besideJumpHosts ? l10n.hostPanelTeamPinDirect : null;
    final jump = pin.jumpHost;
    return jump == null
        ? l10n.hostPanelTeamPinThroughJumpHost
        : l10n.hostPanelTeamPinThrough(Redactable.address(jump).displayIn(ref));
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, HostTeamPin team, String? route) async {
    final l10n = AppLocalizations.of(context)!;
    // Takes the team's pin away for everyone: red.
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.hostPanelUnpinTitle,
      // Which of the host's pins goes, where its route was said.
      body: [?route, l10n.hostPanelUnpinBody(team.crateName)].join('\n\n'),
      confirmLabel: l10n.hostPanelUnpin,
    );
    if (ok != true || !context.mounted) return;
    try {
      await TeamHostKeys(ref.read(databaseProvider)).unpin(team.pin.id);
    } catch (e) {
      AppLogger.warning('Orchards: the team pin was not removed ($e)');
      if (context.mounted) showTopSnackBar(context, l10n.orchardWriteNotAllowed, isError: true, details: '$e');
      return;
    }
    ref.invalidate(hostTeamPinsProvider((hostId: hostId, host: host, port: port)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pins =
        ref.watch(hostTeamPinsProvider((hostId: hostId, host: host, port: port))).valueOrNull ?? const <HostTeamPin>[];
    if (pins.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final besideJumpHosts = pins.any((team) => team.pin.viaScope.isNotEmpty);
    return Column(
      key: const ValueKey('host-team-pin'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final team in pins) _box(context, ref, l10n, team, _route(team, besideJumpHosts, l10n, ref)),
      ],
    );
  }

  Widget _box(BuildContext context, WidgetRef ref, AppLocalizations l10n, HostTeamPin team, String? route) {
    return Container(
      key: ValueKey('host-team-pin-${team.pin.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.shieldCheck, size: 14, color: ZestColors.statusSuccess),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.hostPanelKeyTeamPinned(team.crateName),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                ),
              ),
            ],
          ),
          if (route != null) ...[
            const SizedBox(height: 4),
            Text(route, style: TextStyle(fontSize: 11.5, color: ZestColors.textSecondary)),
          ],
          const SizedBox(height: 4),
          Text(team.pin.isCertificate ? l10n.hostPanelCertificateTeamPinnedBody : l10n.hostPanelKeyTeamPinnedBody, style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary)),
          for (final (type, fingerprint) in team.keys) ...[
            const SizedBox(height: 6),
            Text(
              '$type  $fingerprint',
              style: TextStyle(fontSize: 10.5, fontFamily: 'JetBrainsMono', color: ZestColors.textTertiary),
            ),
          ],
          if (team.mayRemove)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('host-team-unpin-${team.pin.id}'),
                onPressed: () => _remove(context, ref, team, route),
                child: Text(l10n.hostPanelUnpin),
              ),
            ),
        ],
      ),
    );
  }
}
