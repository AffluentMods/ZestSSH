import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart' show normalizeKnownHost;
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart' show HostKeyFingerprint;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Screen showing all trusted host keys with swipe-to-delete.
class KnownHostsScreen extends ConsumerWidget {
  const KnownHostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dao = ref.watch(knownHostsDaoProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.knownHostsTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: StreamBuilder<List<KnownHost>>(
        stream: dao.watchAll(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final hosts = snapshot.data ?? [];

          if (hosts.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.keyRound,
                      size: 64,
                      color: AppColors.textSecondary.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  Text(
                    l10n.knownHostsEmptyTitle,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.knownHostsEmptySubtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.onSurfaceDim,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: hosts.length,
            itemBuilder: (context, index) {
              final host = hosts[index];
              return _HostKeyTile(host: host);
            },
          );
        },
      ),
    );
  }
}

class _HostKeyTile extends ConsumerWidget {
  final KnownHost host;

  const _HostKeyTile({required this.host});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lastSeen = DateFormat.yMMMd(l10n.localeName).add_jm().formatPlain(host.lastSeen);

    // Cross-reference with saved connections for friendly name
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final friendlyName = connectionsAsync.whenOrNull<String?>(
      data: (connections) {
        final match = connections
            .where((c) =>
                c.connection.host == host.host &&
                c.connection.port == host.port)
            .firstOrNull;
        if (match != null && match.connection.label.isNotEmpty) {
          return match.connection.label;
        }
        return null;
      },
    );

    // Recording mode: the name, the address and the fingerprint paint in
    // their display forms (the match above used the real values).
    final shownAddress =
        Redactable.address(hostWithPort(host.host, host.port)).displayIn(ref);
    final shownTitle = friendlyName != null
        ? '${Redactable.host(friendlyName).displayIn(ref)} ($shownAddress)'
        : shownAddress;
    final shownFingerprint =
        Redactable.fingerprint(host.fingerprint).displayIn(ref);
    // An FTPS server's certificate (3.4): said as one, its whole SHA-256
    // fingerprint as the question showed it (as openssl prints it).
    final certificate = KnownHostsService.isCertificate(host.keyType);
    // A remote screen's (4.0): one kept for a carrier's route, or one at the
    // address and port of a VNC host reached directly.
    final screenCertificate = certificate &&
        (host.viaScope != null ||
            (connectionsAsync.whenOrNull(
                  data: (connections) => connections.any((c) =>
                      ConnectionProtocol.storedIsScreen(c.connection.protocol) &&
                      c.connection.connectViaId == null &&
                      normalizeKnownHost(c.connection.host) == host.host &&
                      c.connection.port == host.port),
                ) ??
                false));

    return Dismissible(
      key: ValueKey(host.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: AppColors.error,
        child: const Icon(LucideIcons.trash2, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDelete(context, shownAddress),
      onDismissed: (_) {
        ref.read(knownHostsDaoProvider).deleteHost(host.id);
      },
      child: ListTile(
        leading: Icon(
          certificate ? LucideIcons.fileBadge : _keyTypeIcon(host.keyType),
          color: AppColors.accentInk,
        ),
        title: Text(
          shownTitle,
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 14,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (certificate) ...[
              Text(
                screenCertificate ? l10n.knownHostsScreenCertificate : l10n.knownHostsTlsCertificate,
                key: ValueKey('known-host-certificate-${host.id}'),
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 2),
              HostKeyFingerprint(fingerprint: host.fingerprint),
            ] else
              Text(
                '${host.keyType} • ${_truncateFingerprint(shownFingerprint)}',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            Text(
              l10n.knownHostsLastSeen(lastSeen),
              style: TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceDim,
              ),
            ),
          ],
        ),
        trailing: IconButton(
          icon: Icon(LucideIcons.trash2, color: AppColors.error, size: 20),
          tooltip: l10n.knownHostsRemoveHostKeyTooltip,
          onPressed: () async {
            final confirmed = await _confirmDelete(context, shownAddress);
            if (confirmed == true) {
              ref.read(knownHostsDaoProvider).deleteHost(host.id);
            }
          },
        ),
        isThreeLine: true,
      ),
    );
  }

  /// [shownAddress] is the `host:port` in its display form (recording mode).
  Future<bool?> _confirmDelete(BuildContext context, String shownAddress) {
    final l10n = AppLocalizations.of(context)!;
    return ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.knownHostsRemoveHostKeyTitle,
      body: l10n.knownHostsRemoveConfirm(shownAddress),
      confirmLabel: l10n.commonRemove,
    );
  }

  IconData _keyTypeIcon(String keyType) {
    if (keyType.contains('ed25519')) return LucideIcons.lock;
    if (keyType.contains('ecdsa')) return LucideIcons.shieldCheck;
    if (keyType.contains('rsa')) return LucideIcons.keyRound;
    return LucideIcons.keyRound;
  }

  String _truncateFingerprint(String fingerprint) {
    if (fingerprint.length <= 24) return fingerprint;
    return '${fingerprint.substring(0, 24)}…';
  }
}
