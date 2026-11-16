import 'package:flutter/widgets.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show isOrchardWriteRefused;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Stores a snippet with [write] and says so, as a host's save does: "Snippet
/// added: {name}" for a new one ([added]), "Snippet saved: {name}" for one
/// changed, once [write] has finished. Where it was refused (a team's Crate
/// that does not let this account add or edit there) or failed, that instead,
/// with what was thrown to copy. Returns whether it was stored.
///
/// Every place a snippet is saved from goes through this: the snippet editors
/// of a computer and a phone, Save as snippet in a terminal and in Command
/// history, Duplicate, and a workflow template's snippet. A save said nothing
/// (there was no notification or anything letting the person know
/// it was saved), and the two Save as snippets said "Snippet saved" without a
/// name.
Future<bool> saveSnippetSaying(
  BuildContext context, {
  required String name,
  required bool added,
  required Future<void> Function() write,
}) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await write();
  } catch (e) {
    if (context.mounted) {
      final refused = isOrchardWriteRefused(e);
      showTopSnackBar(context, refused ? l10n.orchardWriteNotAllowed : l10n.snippetNotSaved,
          isError: true, details: refused ? null : '$e');
    }
    return false;
  }
  if (context.mounted) {
    final shown = Redactable.freeText(name).display;
    showTopSnackBar(context, added ? l10n.snippetAddedToast(shown) : l10n.snippetSavedToast(shown),
        isSuccess: true);
  }
  return true;
}
