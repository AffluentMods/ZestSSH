import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart' show ItsYou, confirmOrSignIn;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Locked copies on your computers, from the account's page (to-do 60): what ZestSSH
/// Cloud keeps so that each computer can open this account's data after a sign-in, each
/// by its platform and the day it was made, with Delete. The copy of the computer in
/// front of the person has none: deleting it would lock their own data for good.
Future<void> showLockedCopies(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.info,
    title: l10n.lockedCopiesTitle,
    subtitle: l10n.lockedCopiesDesc,
    body: _LockedCopiesList(outerRef: ref),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context, rootNavigator: true).pop(), icon: null),
  );
}

class _LockedCopiesList extends StatefulWidget {
  const _LockedCopiesList({required this.outerRef});

  final WidgetRef outerRef;

  @override
  State<_LockedCopiesList> createState() => _LockedCopiesListState();
}

class _LockedCopiesListState extends State<_LockedCopiesList> {
  List<LockedCopyInfo>? _copies;
  String? _thisComputer;
  Object? _failed;
  String? _busyId;

  ProfileController get _profiles => widget.outerRef.read(profileControllerProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final (copies, here) = await _profiles.lockedCopiesAtCloud();
      if (mounted) {
        setState(() {
          _copies = copies;
          _thisComputer = here;
          _failed = null;
        });
      }
    } catch (e) {
      AppLogger.warning('Locked copies could not be read (${errorKind(e)})');
      if (mounted) setState(() => _failed = e);
    }
  }

  Future<void> _delete(LockedCopyInfo copy) async {
    final l10n = AppLocalizations.of(context)!;
    final yes = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.lockedCopyDeleteTitle,
      body: l10n.lockedCopyDeleteBody,
      confirmLabel: l10n.delete,
    );
    if (yes != true || !mounted) return;
    setState(() => _busyId = copy.id);
    try {
      try {
        await _profiles.deleteLockedCopyAtCloud(copy.id);
      } on LockedCopyRefused catch (e) {
        if (e.code != 'recent-sign-in-required' || !mounted) rethrow;
        // A sign-in or a confirmation from the last ten minutes, and once more.
        final shown = await confirmOrSignIn(context, widget.outerRef, about: l10n.lockedCopyConfirmAbout, sayWindow: false);
        if (shown != ItsYou.confirmed || !mounted) return;
        await _profiles.deleteLockedCopyAtCloud(copy.id);
      }
      if (mounted) showTopSnackBar(context, l10n.lockedCopyDeleted, isSuccess: true);
      await _load();
    } catch (e) {
      AppLogger.warning('A locked copy was not deleted (${errorKind(e)})');
      if (mounted) {
        showTopSnackBar(
          context,
          ErrorCodes.withCode(l10n.lockedCopyNotDeleted, ErrorCodes.lockedCopyNotDeleted),
          isError: true,
          details: '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_failed != null) {
      return Text(
        ErrorCodes.withCode(l10n.lockedCopiesFailed, ErrorCodes.lockedCopyNotDeleted),
        key: const ValueKey('locked-copies-failed'),
        style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary),
      );
    }
    final copies = _copies;
    if (copies == null) {
      return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (copies.isEmpty) {
      return Text(l10n.lockedCopiesNone, style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final copy in copies)
          Padding(
            key: ValueKey('locked-copy-${copy.id}'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(LucideIcons.laptop, size: 16, color: AppColors.v3TextSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    copy.id == _thisComputer
                        ? l10n.lockedCopyThisComputer(_platformName(copy.platform), _day(copy.madeOn, l10n))
                        : l10n.lockedCopyOnComputer(_platformName(copy.platform), _day(copy.madeOn, l10n)),
                    style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
                  ),
                ),
                if (copy.id != _thisComputer)
                  TextButton(
                    key: ValueKey('locked-copy-delete-${copy.id}'),
                    onPressed: _busyId == null ? () => _delete(copy) : null,
                    child: Text(l10n.delete),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The day a copy was made, as ZestSSH Cloud keeps it, in the page's language.
String _day(String madeOn, AppLocalizations l10n) {
  final day = DateTime.tryParse(madeOn);
  return day == null ? madeOn : DateFormat.yMMMd(l10n.localeName).format(day);
}

/// A platform as ZestSSH Cloud keeps it, under its own name.
String _platformName(String platform) => switch (platform) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      _ => platform,
    };
