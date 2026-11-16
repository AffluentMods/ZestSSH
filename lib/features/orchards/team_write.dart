import 'package:flutter/widgets.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';

/// Runs [write], a change in the space on screen that a team's database may
/// refuse because the role does not allow it (its triggers say
/// `orchard-access`). True when it went through. A refusal is said
/// ("Your access to this vault doesn't let you make that change", with the
/// error to copy) and false comes back; any other error goes on to the
/// caller as before. [where] names the action in the log.
///
/// Group changes (the group editor's Save and Delete, New group from a
/// selection, Move to a group) let the refusal leave their handler: nothing
/// was said, and the panel stayed open or the menu closed as if it had
/// worked.
Future<bool> runTeamWrite(BuildContext context, Future<void> Function() write, {required String where}) async {
  try {
    await write();
    return true;
  } catch (e) {
    if (!isOrchardWriteRefused(e)) rethrow;
    AppLogger.warning('$where: the team refused the change ($e)');
    if (context.mounted) {
      showTopSnackBar(context, AppLocalizations.of(context)!.orchardWriteNotAllowed, isError: true, details: '$e');
    }
    return false;
  }
}
