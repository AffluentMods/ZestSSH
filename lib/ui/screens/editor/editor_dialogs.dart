import 'package:flutter/material.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/editor_codec.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_chrome.dart';
import 'package:zestssh/ui/widgets/sudo_password_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// What to do with a tab's changes as it closes.
enum EditorCloseChoice { save, discard, cancel }

/// "Save changes to config.yaml?" (3.4): asked by the tab's close
/// button, Ctrl+W, closing the window and the back gesture. Don't save, in
/// the error colour, throws the changes away (and the draft with them);
/// Enter is Save.
Future<EditorCloseChoice> askSaveChanges(BuildContext context, EditorDocument doc) async {
  final l10n = AppLocalizations.of(context)!;
  final where = [if (doc.source.hostLabel != null) Redactable.host(doc.source.hostLabel!).display, doc.source.path.isEmpty ? doc.source.fileName : doc.source.path]
      .join(':');
  final choice = await showZestModal<EditorCloseChoice>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.save,
        title: l10n.editorSaveChangesTitle(doc.source.fileName),
        subtitle: where,
        autofocusPrimary: true,
        body: Text(
          l10n.editorSaveChangesBody(doc.changedLines),
          key: const ValueKey('editor-save-changes-body'),
          style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
        ),
        tertiaryKey: const ValueKey('editor-dont-save'),
        tertiaryDanger: true,
        tertiaryAction: (label: l10n.editorDontSave, onPressed: () => zestDialogPop(ctx, EditorCloseChoice.discard)),
        secondaryAction: (label: l10n.cancel, onPressed: () => zestDialogPop(ctx, EditorCloseChoice.cancel)),
        primaryKey: const ValueKey('editor-save-and-close'),
        primaryAction: (label: l10n.save, icon: null, onPressed: () => zestDialogPop(ctx, EditorCloseChoice.save)),
      ),
    ),
  );
  return choice ?? EditorCloseChoice.cancel;
}

/// Closing several tabs at once (the window, the editor itself) asks once,
/// listing the files with changes.
Future<EditorCloseChoice> askSaveMany(BuildContext context, List<EditorDocument> docs) async {
  if (docs.length == 1) return askSaveChanges(context, docs.single);
  final l10n = AppLocalizations.of(context)!;
  final choice = await showZestModal<EditorCloseChoice>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.save,
        title: l10n.editorSaveChangesManyTitle(docs.length),
        autofocusPrimary: true,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.editorSaveChangesManyBody,
                style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary)),
            const SizedBox(height: 10),
            for (final d in docs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(width: 3, height: 14, color: editorHostColour(d.source.hostLabel)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(d.source.fileName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: AppColors.v3TextPrimary)),
                    ),
                    if (d.source.hostLabel != null) ...[
                      const SizedBox(width: 8),
                      EditorHostText(d.source.hostLabel!,
                          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: AppColors.v3TextTertiary)),
                    ],
                  ],
                ),
              ),
          ],
        ),
        tertiaryKey: const ValueKey('editor-dont-save'),
        tertiaryDanger: true,
        tertiaryAction: (label: l10n.editorDontSave, onPressed: () => zestDialogPop(ctx, EditorCloseChoice.discard)),
        secondaryAction: (label: l10n.cancel, onPressed: () => zestDialogPop(ctx, EditorCloseChoice.cancel)),
        primaryKey: const ValueKey('editor-save-and-close'),
        primaryAction: (label: l10n.editorSaveAll, icon: null, onPressed: () => zestDialogPop(ctx, EditorCloseChoice.save)),
      ),
    ),
  );
  return choice ?? EditorCloseChoice.cancel;
}

/// Opening a 13th file: which open one to close for it (12 tabs, then
/// ask). Null where none was picked.
Future<EditorDocument?> askWhichToClose(BuildContext context, List<EditorDocument> docs, String opening) {
  final l10n = AppLocalizations.of(context)!;
  EditorDocument? picked = docs.firstWhere((d) => !d.modified, orElse: () => docs.first);
  return showZestModal<EditorDocument>(
    context: context,
    size: ZestModalSize.standard,
    child: StatefulBuilder(
      builder: (ctx, setState) => ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.layers,
        title: l10n.editorTooManyTabsTitle(opening),
        subtitle: l10n.editorTooManyTabsBody(docs.length),
        body: RadioGroup<EditorDocument>(
          groupValue: picked,
          onChanged: (d) => setState(() => picked = d),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final d in docs)
                InkWell(
                  key: ValueKey('editor-close-pick-${d.source.identity}'),
                  onTap: () => setState(() => picked = d),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Radio<EditorDocument>(value: d),
                        Container(width: 3, height: 16, color: editorHostColour(d.source.hostLabel)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(d.source.fileName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
                        ),
                        if (d.source.hostLabel != null)
                          EditorHostText(d.source.hostLabel!,
                              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: AppColors.v3TextTertiary)),
                        if (d.modified) ...[
                          const SizedBox(width: 8),
                          Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(color: AppColors.v3AccentPrimary, shape: BoxShape.circle)),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => zestDialogPop(ctx)),
        primaryKey: const ValueKey('editor-close-and-open'),
        primaryAction: (
          label: l10n.editorCloseAndOpen,
          icon: null,
          onPressed: picked == null ? null : () => zestDialogPop(ctx, picked),
        ),
      ),
    ),
  );
}

/// What the encoding picker chose: to read the file again in [encoding], or
/// to save it with [encoding].
typedef EncodingPick = ({bool reopen, EditorEncoding encoding});

/// The encoding picker (3.4): reopen the file in another
/// encoding, or save it with one. [canReopen] is false where the file cannot
/// be read again from here.
Future<EncodingPick?> pickEncoding(BuildContext context, EditorDocument doc, {required bool canReopen, required bool canChange}) {
  final l10n = AppLocalizations.of(context)!;
  var reopen = canReopen;
  String detail(EditorEncoding e) => switch (e) {
        EditorEncoding.windows1252 => l10n.editorEncodingWestern,
        EditorEncoding.latin1 => 'Latin-1',
        EditorEncoding.latin9 => 'Latin-9',
        EditorEncoding.utf8Bom => l10n.editorEncodingBom,
        _ => '',
      };
  return showZestModal<EncodingPick>(
    context: context,
    size: ZestModalSize.compact,
    child: StatefulBuilder(
      builder: (ctx, setState) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.languages,
        title: l10n.editorEncodingTitle,
        subtitle: l10n.editorEncodingNow(doc.encoding.label),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canChange)
              SegmentedButton<bool>(
                key: const ValueKey('editor-encoding-mode'),
                segments: [
                  ButtonSegment(value: true, label: Text(l10n.editorReopenWith), enabled: canReopen),
                  ButtonSegment(value: false, label: Text(l10n.editorSaveWith)),
                ],
                selected: {reopen},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => reopen = s.first),
              ),
            const SizedBox(height: 8),
            for (final e in EditorEncoding.values)
              InkWell(
                key: ValueKey('editor-encoding-${e.name}'),
                onTap: !canChange ? null : () => zestDialogPop(ctx, (reopen: reopen, encoding: e)),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  decoration: BoxDecoration(
                    color: e == doc.encoding ? AppColors.v3AccentPrimary.withValues(alpha: 0.12) : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(e.label,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: e == doc.encoding ? FontWeight.w600 : FontWeight.w400,
                                color: AppColors.v3TextPrimary)),
                      ),
                      Text(detail(e), style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
                      if (e == doc.encoding) ...[
                        const SizedBox(width: 8),
                        Icon(LucideIcons.check, size: 14, color: AppColors.v3AccentInk),
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              reopen ? l10n.editorReopenNote(editorHostShown(doc.source)) : l10n.editorSaveWithNote,
              style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextTertiary),
            ),
          ],
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => zestDialogPop(ctx)),
      ),
    ),
  );
}

/// Save as root (3.4, screen 2): asked first, every time. It says what will
/// happen and where (a temporary file on the host, then sudo copies it into
/// place, keeping owner and mode), and takes the sudo password for this one
/// save: it is never stored or synced, and goes with the dialog. [save]
/// writes with the password; what it throws is said in the dialog ([said]),
/// which stays, as the text does. True where it saved.
Future<bool> askSaveAsRoot(
  BuildContext context,
  EditorDocument doc, {
  required Future<void> Function(String password) save,
  required String Function(Object error) said,
}) {
  final l10n = AppLocalizations.of(context)!;
  final access = doc.access;
  // Masked while the screen is recorded, as the editor's tabs are (a
  // security review): the host, the file's folders and its owner.
  final host = Redactable.host(doc.source.hostLabel ?? '').display;
  final path = Redactable.path(doc.source.path.isEmpty ? doc.source.fileName : doc.source.path).display;
  final owner = access?.owner?.split(':').map((u) => Redactable.username(u).display).join(':');
  return askSudoPassword(
    context,
    title: l10n.editorSaveAsRootTitle(path),
    subtitle: host,
    body: Text(
      owner != null
          ? l10n.editorSaveAsRootBody(owner, host, access?.mode ?? '')
          : l10n.editorSaveAsRootBodyUnknown(host),
      key: const ValueKey('editor-sudo-body'),
      style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
    ),
    helperText: l10n.editorSudoPasswordHelp,
    actionLabel: l10n.editorSaveAsRoot,
    run: save,
    said: said,
    fieldKey: const ValueKey('editor-sudo-password'),
    primaryKey: const ValueKey('editor-sudo-save'),
  );
}
