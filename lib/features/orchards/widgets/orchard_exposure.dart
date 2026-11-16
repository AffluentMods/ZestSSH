import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/host_address.dart';

/// What a member could use in an Orchard (3.0), for right after
/// they are suspended or removed and for owners and admins at any time:
/// the keys they could see or copy first, then the ones they could only
/// connect with, each with the hosts saved here that it opens, and the
/// Crates this account cannot open with whom to ask. A button copies the
/// same list as plain text, to work through server by server.
Future<void> showOrchardExposure(
  BuildContext context, {
  required String name,
  required OrchardExposure exposure,
  required String? Function(String crateId) crateName,
  required String Function(String uid) nameOf,
  bool kept = false,
}) {
  final l10n = AppLocalizations.of(context)!;
  final view = OrchardExposureView(exposure: exposure, crateName: crateName, nameOf: nameOf);
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    // A list to work through, plainly: nothing amber.
    tone: exposure.reveal.isEmpty ? ZestDialogTone.info : ZestDialogTone.neutral,
    icon: LucideIcons.keyRound,
    title: l10n.orchardExposureTitle(name),
    // Kept as the keys to change next ([kept]): the list stays on the Team
    // page's Overview until each is marked.
    body: kept
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              view,
              const SizedBox(height: 12),
              Text(l10n.orchardExposureKept,
                  key: const ValueKey('exposure-kept'),
                  style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextTertiary)),
            ],
          )
        : view,
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
    // Copying the list: the side option, bottom left.
    tertiaryAction: exposure.isEmpty
        ? null
        : (
            label: l10n.orchardExposureCopy,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(
                  text: exposureText(l10n, name: name, exposure: exposure, crateName: crateName, nameOf: nameOf)));
              if (context.mounted) showTopSnackBar(context, l10n.orchardExposureCopied, isSuccess: true);
            },
          ),
  );
}

/// The kind of secret a key holds, in words.
String exposedKind(ExposedKey k, AppLocalizations l10n) => switch (k.authMethod) {
      'password' => l10n.identityPassword,
      'certificate' => l10n.orchardExposureCertificate,
      _ => l10n.orchardExposurePrivateKey,
    };

/// A host as the list names it: its label, and where it is.
String exposedHost(({String id, String label, String host, int port}) h) =>
    h.port == 22 ? '${h.label} (${h.host})' : '${h.label} (${hostWithPort(h.host, h.port)})';

/// [exposure] as plain text, in the order the dialog shows it.
String exposureText(
  AppLocalizations l10n, {
  required String name,
  required OrchardExposure exposure,
  required String? Function(String crateId) crateName,
  required String Function(String uid) nameOf,
}) {
  final out = StringBuffer()
    ..writeln(l10n.orchardExposureTitle(name))
    ..writeln(l10n.orchardExposureIntro);
  void keys(String title, List<ExposedKey> list) {
    if (list.isEmpty) return;
    out
      ..writeln()
      ..writeln(title);
    for (final k in list) {
      final crate = crateName(k.crateId);
      out.writeln('- ${k.label} (${k.username}), ${exposedKind(k, l10n)}${crate == null ? '' : ', $crate'}');
      out.writeln(k.hosts.isEmpty
          ? '  ${l10n.orchardExposureNoHosts}'
          : '  ${l10n.orchardExposureOpens(k.hosts.map(exposedHost).join(', '))}');
    }
  }

  keys(l10n.orchardExposureReveal(exposure.reveal.length), exposure.reveal);
  keys(l10n.orchardExposureConnect(exposure.connect.length), exposure.connect);
  if (exposure.closed.isNotEmpty) {
    out
      ..writeln()
      ..writeln(l10n.orchardExposureClosedTitle(exposure.closed.length));
    for (final managers in exposure.closed.values) {
      out.writeln('- ${l10n.orchardExposureClosedCrate(managers.map(nameOf).join(', '))}');
    }
  }
  return out.toString().trimRight();
}

class OrchardExposureView extends StatelessWidget {
  const OrchardExposureView({super.key, required this.exposure, required this.crateName, required this.nameOf});

  final OrchardExposure exposure;
  final String? Function(String crateId) crateName;
  final String Function(String uid) nameOf;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (exposure.isEmpty) {
      return Text(l10n.orchardExposureNothing,
          key: const ValueKey('exposure-nothing'),
          style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.orchardExposureIntro, style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary)),
        if (exposure.reveal.isNotEmpty)
          _Section(
            key: const ValueKey('exposure-reveal'),
            title: l10n.orchardExposureReveal(exposure.reveal.length),
            color: AppColors.v3Warning,
            children: [for (final k in exposure.reveal) _KeyRow(k: k, crate: crateName(k.crateId))],
          ),
        if (exposure.connect.isNotEmpty)
          _Section(
            key: const ValueKey('exposure-connect'),
            title: l10n.orchardExposureConnect(exposure.connect.length),
            color: AppColors.v3TextSecondary,
            children: [for (final k in exposure.connect) _KeyRow(k: k, crate: crateName(k.crateId))],
          ),
        if (exposure.closed.isNotEmpty)
          _Section(
            key: const ValueKey('exposure-closed'),
            title: l10n.orchardExposureClosedTitle(exposure.closed.length),
            color: AppColors.v3TextSecondary,
            children: [
              for (final managers in exposure.closed.values)
                Text(l10n.orchardExposureClosedCrate(managers.map(nameOf).join(', ')),
                    style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary)),
            ],
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.color, required this.children});

  final String title;
  final Color color;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
            const SizedBox(height: 6),
            for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c),
          ],
        ),
      );
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.k, required this.crate});

  final ExposedKey k;
  final String? crate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: ValueKey('exposed-${k.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.v3Elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text('${k.label} (${k.username})',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
              ),
              const SizedBox(width: 8),
              Text(exposedKind(k, l10n), style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
              if (crate != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(crate!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            k.hosts.isEmpty ? l10n.orchardExposureNoHosts : l10n.orchardExposureOpens(k.hosts.map(exposedHost).join(', ')),
            style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.v3TextSecondary),
          ),
        ],
      ),
    );
  }
}
