import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/ui/cloud_provider_info.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// A host imported from a cloud (3.0): a small cloud naming the account, or
/// an amber crossed-out cloud once the account no longer lists it.
class HostCloudMark extends StatelessWidget {
  const HostCloudMark({super.key, required this.link, this.size = 12});

  final CloudLink link;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final account = link.label.isEmpty ? cloudProviderName(link.provider) : link.label;
    return Tooltip(
      message: link.gone ? l10n.cloudHostGone(account) : l10n.cloudHostFrom(account),
      child: Icon(
        link.gone ? LucideIcons.cloudOff : LucideIcons.cloud,
        key: ValueKey(link.gone ? 'host-cloud-gone' : 'host-cloud'),
        size: size,
        color: link.gone ? ZestColors.statusWarning : ZestColors.textTertiary,
      ),
    );
  }
}
