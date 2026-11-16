import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/host_address.dart';

/// A port forward as the dialog shows it, from a link or a file.
typedef _Forward = ({String type, String bindAddress, int bindPort, String remoteHost, int remotePort, String? label});

/// Mandatory confirmation surface for any incoming connection-share
/// URL - whether it arrived via a `zestssh://` deep link or via the
/// QR scanner - and for a host shared as a `.zest` file
/// ([IncomingShareDialog.file], 3.0: nothing in the app read one).
///
/// The security policy:
///
/// - Never add a connection to the user's saved list without first
///   showing this dialog.
/// - Always show the source URL verbatim so the user can see exactly
///   what app or website is asking to add a host.
/// - Render the host, port, user, and any port forwards / tags so
///   the user knows what they're getting.
/// - Refuse to render anything the parser flagged as secret -
///   [ConnectionShareUrlService] already strips those, but the
///   dialog only displays a fixed set of fields anyway, so a future
///   schema addition can't accidentally surface something sensitive.
///
/// Returns `true` if the user tapped "Add connection", `false`
/// otherwise.
class IncomingShareDialog extends ConsumerWidget {
  /// A host from a share link: [payload], parsed from [sourceUri].
  final ParsedConnectionShare? payload;
  final Uri? sourceUri;

  /// A host shared as a `.zest` file, read by
  /// [ConnectionShareService.importConnection]. What came with it, its
  /// password or its private key, is said, never shown.
  final ZestImportData? file;

  const IncomingShareDialog({
    super.key,
    required ParsedConnectionShare this.payload,
    required Uri this.sourceUri,
  }) : file = null;

  const IncomingShareDialog.file({super.key, required ZestImportData this.file})
      : payload = null,
        sourceUri = null;

  /// Asks before the host shared in [file] is added; true when it is to be.
  /// While the screen is recorded, recording is turned off first, or nothing
  /// is added: a host added from someone else is shown as it is (it was
  /// shown as stand-ins, and added unseen).
  static Future<bool> showFile(BuildContext context, ZestImportData file) async {
    if (!await confirmRevealWhileRecording(context) || !context.mounted) return false;
    final result = await showZestModal<bool>(
      context: context,
      size: ZestModalSize.compact,
      barrierDismissible: false, // require an explicit decision
      child: IncomingShareDialog.file(file: file),
    );
    return result ?? false;
  }

  static Future<bool> show(
    BuildContext context, {
    required ParsedConnectionShare payload,
    required Uri sourceUri,
  }) async {
    // As a file's host is: shown as it is ([showFile]).
    if (!await confirmRevealWhileRecording(context) || !context.mounted) return false;
    final result = await showZestModal<bool>(
      context: context,
      size: ZestModalSize.compact,
      barrierDismissible: false, // require an explicit decision
      child: IncomingShareDialog(
        payload: payload,
        sourceUri: sourceUri,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final link = payload;
    final shared = file;
    final label = shared?.label ?? link!.label;
    final host = shared?.host ?? link!.host;
    final port = shared?.port ?? link!.port;
    final user = shared != null ? shared.username : link!.user;
    final tags = link?.tags ?? const <String>[];
    final List<_Forward> forwards = [
      for (final f in link?.forwards ?? const <SharedForward>[])
        (type: f.type, bindAddress: f.bindAddress, bindPort: f.bindPort, remoteHost: f.remoteHost, remotePort: f.remotePort, label: f.label),
      for (final f in shared?.portForwards ?? const <ZestPortForward>[])
        (type: f.type, bindAddress: f.bindAddress, bindPort: f.bindPort, remoteHost: f.remoteHost, remotePort: f.remotePort, label: f.label),
    ];
    // Recording mode: every identifying field below is painted through its
    // rule. The source URL's payload IS those identifiers (encoded), so its
    // query is shown as bullets while the mode is on; the scheme and host
    // still say where the request came from. A file has no URL.
    final source = sourceUri;
    final query = source?.query ?? '';
    final shownQuery = Redactable.password(query).displayIn(ref);
    final shownUri = source == null
        ? null
        : query.isEmpty || shownQuery == query
            ? source.toString()
            : '${source.scheme}://${source.host}${source.path}?$shownQuery';
    // The shell (the dialog rules of 3.4): what is asked in its head, what
    // would be added in its body, Cancel and Add connection in its footer.
    return ZestDialogShell(
      maxWidth: 480,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.serverCog,
      title: l10n.incomingShareTitle,
      subtitle: shared == null ? l10n.incomingShareTrustSource : l10n.hostShareTrust,
      onClose: () => Navigator.of(context).pop(false),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section(l10n.incomingShareSectionConnection, [
            _row(l10n.incomingShareFieldName,
                Redactable.host(label).displayIn(ref)),
            _row(
                l10n.incomingShareFieldHost,
                Redactable.address(port == 22
                        ? host
                        : hostWithPort(host, port))
                    .displayIn(ref),
                mono: true),
            if (user != null)
              _row(l10n.incomingShareFieldUser,
                  Redactable.username(user).displayIn(ref)),
            if (link?.identityHint case final hint?)
              _row(
                l10n.incomingShareFieldIdentityHint,
                l10n.incomingShareIdentityHintValue(
                    Redactable.keyName(hint)
                        .displayIn(ref)),
              ),
            if (link?.groupHint case final group?)
              _row(l10n.incomingShareFieldGroup,
                  Redactable.group(group).displayIn(ref)),
            // What a file may bring with it: said, never shown.
            if (shared?.password != null)
              _carried(LucideIcons.keyRound, l10n.hostShareWithPassword),
            if (shared?.privateKeyPem != null)
              _carried(LucideIcons.key, l10n.hostShareWithKey),
          ]),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 14),
            _section(l10n.incomingShareSectionTags, [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tags
                    .map((t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.v3Background,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: AppColors.v3BorderSubtle),
                          ),
                          child: Text(
                            t,
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.v3TextSecondary),
                          ),
                        ))
                    .toList(),
              ),
            ]),
          ],
          if (forwards.isNotEmpty) ...[
            const SizedBox(height: 14),
            _section(
              l10n.incomingSharePortForwardsCount(
                  forwards.length),
              forwards
                  .map((f) => _forwardRow(f, ref, l10n))
                  .toList(),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.incomingShareForwardsNotStarted,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.v3TextTertiary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (shownUri != null) ...[
          const SizedBox(height: 14),
          _section(l10n.incomingShareSectionSourceUrl, [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.v3Background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.v3BorderSubtle),
              ),
              child: SelectableText(
                shownUri,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: AppColors.v3TextSecondary,
                  height: 1.45,
                ),
              ),
            ),
          ]),
          ],
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
      primaryKey: const ValueKey('incoming-share-add'),
      primaryAction: (
        label: l10n.incomingShareAddConnection,
        icon: LucideIcons.plus,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: AppColors.v3TextTertiary,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _row(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.v3TextSecondary,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.v3TextPrimary,
                fontFamily: mono ? 'JetBrainsMono' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A line saying what came with the host ([text]), under [icon].
  Widget _carried(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _forwardRow(_Forward f, WidgetRef ref, AppLocalizations l10n) {
    final String summary;
    switch (f.type) {
      case 'local':
        summary = '${l10n.incomingShareForwardLocal} · ${f.bindAddress}:${f.bindPort} → '
            '${f.remoteHost}:${f.remotePort}';
      case 'remote':
        summary = '${l10n.incomingShareForwardRemote} · ${f.remoteHost}:${f.remotePort} → '
            '${f.bindAddress}:${f.bindPort}';
      case 'dynamic':
        summary = 'SOCKS5 · ${f.bindAddress}:${f.bindPort}';
      default:
        summary = '${f.type} · ${f.bindAddress}:${f.bindPort}';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.arrowRightLeft,
              size: 12, color: AppColors.v3TextTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // The summary carries bind / remote addresses.
              Redactable.freeText(
                      f.label == null ? summary : '${f.label} - $summary')
                  .displayIn(ref),
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: AppColors.v3TextSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
