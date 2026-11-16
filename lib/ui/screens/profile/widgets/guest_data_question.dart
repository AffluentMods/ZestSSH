import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// What the person said to the question about guest data. Closing it says neither,
/// and keeps it.
enum GuestDataAnswer { keep, bring }

/// What the question says of what guest data holds: its hosts, or its keys where it
/// has no host, and what of it does not come, named before it goes. It names the account
/// the person is in: masked in recording mode.
String guestDataWords(AppLocalizations l10n, GuestDataSummary summary, String account) {
  final asked = summary.hosts > 0
      ? l10n.guestDataQuestion(summary.hosts, account)
      : l10n.guestDataQuestionKeys(summary.keys, account);
  final out = summary.staysOut;
  if (!out.any) return asked;
  return [
    asked,
    '',
    l10n.guestDataGoesLead,
    if (out.apiKeys > 0) '\u2022 ${l10n.guestDataGoesApiKeys(out.apiKeys)}',
    if (out.backupDestinations > 0) '\u2022 ${l10n.guestDataGoesBackups(out.backupDestinations)}',
    if (out.keys > 0) '\u2022 ${l10n.guestDataGoesDeletedKeys(out.keys)}',
    if (out.themes > 0) '\u2022 ${l10n.guestDataGoesThemes(out.themes)}',
    if (out.others) '\u2022 ${l10n.guestDataGoesOthers}',
  ].join('\n');
}

/// What is said once it has come: what the question named as staying out is not in the
/// account, and the words say so.
String guestDataBroughtWords(AppLocalizations l10n, GuestDataSummary summary) =>
    summary.staysOut.any ? l10n.guestDataBroughtSome : l10n.guestDataBrought;

/// What guest data holds, and into which account, asked once as an account first signs
/// in here, and again whenever the person chooses it on the account page (to-do 60).
/// Keep is the first answer, and closing this keeps it too: nothing moves until the
/// person says, and nothing is lost whatever they do.
Future<void> showGuestDataQuestion(BuildContext context, WidgetRef ref, GuestDataSummary summary) async {
  final l10n = AppLocalizations.of(context)!;
  final account = ref.read(currentUserProvider)?.email;
  final named = account == null ? l10n.guestDataThisAccount : Redactable.account(account).display;
  final answer = await ZestConfirmDialog.ask<GuestDataAnswer>(
    context,
    tone: ZestDialogTone.neutral,
    title: l10n.guestDataTitle,
    body: guestDataWords(l10n, summary, named),
    confirmLabel: l10n.guestDataKeep,
    confirm: GuestDataAnswer.keep,
    cancelLabel: l10n.guestDataBring,
    cancel: GuestDataAnswer.bring,
  );
  if (!context.mounted || answer != GuestDataAnswer.bring) return;
  try {
    await ref.read(profileControllerProvider).bringGuestData();
    if (context.mounted) showTopSnackBar(context, guestDataBroughtWords(l10n, summary), isSuccess: true);
  } on GuestFilesHeld catch (e) {
    AppLogger.warning('Guest data stayed, as $e');
    if (context.mounted) showTopSnackBar(context, l10n.guestDataFilesHeld, isError: true, details: '$e');
  } on GuestKindsStayed catch (e) {
    AppLogger.warning('Guest data stayed, as $e');
    if (context.mounted) showTopSnackBar(context, l10n.guestDataKindsStayed, isError: true, details: '$e');
  } catch (e) {
    AppLogger.warning('Guest data was not brought in (${errorKind(e)})');
    if (context.mounted) showTopSnackBar(context, l10n.guestDataNotBrought, isError: true, details: '$e');
  }
}

/// The account page's way to it later: nothing at all where there is no guest data to
/// bring, and the row [builder] makes where there is.
class GuestDataRow extends ConsumerStatefulWidget {
  const GuestDataRow({super.key, required this.builder});

  final Widget Function(BuildContext context, GuestDataSummary summary, VoidCallback onChoose) builder;

  @override
  ConsumerState<GuestDataRow> createState() => _GuestDataRowState();
}

class _GuestDataRowState extends ConsumerState<GuestDataRow> {
  GuestDataSummary? _summary;

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    final found = await ref.read(profileControllerProvider).guestData();
    if (mounted) setState(() => _summary = found);
  }

  Future<void> _choose(GuestDataSummary summary) async {
    await showGuestDataQuestion(context, ref, summary);
    if (mounted) await _look();
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    if (summary == null || summary.empty) return const SizedBox.shrink();
    return widget.builder(context, summary, () => _choose(summary));
  }
}
