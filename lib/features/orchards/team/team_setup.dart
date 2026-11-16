import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_runner.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_trust.dart' show recordLogSaverProvider;
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart' show confirmNewRecordKinds;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

// The Team page's "Setup file" (3.0, setup as code). The Orchard
// saved as a file; a file checked against the Orchard, with every change it
// would make said in words before anything changes; and the file applied,
// step by step, by the account signed in here. Nothing is removed because a
// file leaves it out, and nothing of a file is applied while something
// stands in its way.

/// A file the person chose: its name, and its text (null when it is too
/// large to be a setup file, so it was not read).
typedef SetupFilePicked = ({String name, String? text});

/// Lets the person choose a setup file; null when they chose none (tests
/// stand in).
typedef SetupFilePicker = Future<SetupFilePicked?> Function({required String dialogTitle});

final setupFilePickerProvider = Provider<SetupFilePicker>((ref) => ({required String dialogTitle}) async {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: dialogTitle,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        // A phone hands over the bytes; a computer a path.
        withData: !isDesktopPlatform,
        lockParentWindow: true,
      );
      final file = picked?.files.firstOrNull;
      if (file == null) return null;
      // (Four bytes at most to a character.)
      const most = kSetupFileMaxChars * 4;
      var bytes = file.bytes;
      if (bytes == null) {
        final path = file.path;
        if (path == null) throw const FileSystemException('The file could not be read');
        final onDisk = File(path);
        if (await onDisk.length() > most) return (name: file.name, text: null);
        bytes = await onDisk.readAsBytes();
      }
      if (bytes.length > most) return (name: file.name, text: null);
      return (name: file.name, text: utf8.decode(bytes, allowMalformed: true));
    });

/// The name an exported file is offered under: the Orchard's, in letters
/// and digits a file name takes anywhere.
String setupFileNameFor(String orchardName) {
  final slug = orchardName
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'zestssh-setup-${slug.isEmpty ? 'orchard' : slug}.json';
}

class TeamSetup extends ConsumerStatefulWidget {
  const TeamSetup({super.key, required this.orchard, this.onComputer});

  final OrchardSummary orchard;

  /// Whether this device is a computer: a phone is told nothing about a
  /// terminal, and has no folder to show a saved file in. Null asks the
  /// system (a test stands in for a phone).
  final bool? onComputer;

  @override
  ConsumerState<TeamSetup> createState() => _TeamSetupState();
}

class _TeamSetupState extends ConsumerState<TeamSetup> {
  bool _saving = false;
  List<SetupLeftOut>? _leftOut;

  /// The file on the table: its name, what reading it gave, and the plan.
  String? _fileName;
  String? _fileText;
  bool _tooBig = false;
  SetupFileRead? _read;
  SetupPlan? _plan;

  /// The Orchard [_plan] was made from: whether its record holds a new kind
  /// of entry yet, and whether this account is an owner there.
  OrchardSnapshot? _now;
  Object? _checkError;
  bool _checking = false;

  bool _applying = false;
  ({int step, int total, String what})? _progress;

  /// How the last apply went, with how many steps it made in all.
  ({SetupOutcome outcome, int made})? _result;
  bool _moved = false;

  OrchardSummary get orchard => widget.orchard;

  bool get _onComputer => widget.onComputer ?? isDesktopPlatform;

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _saving = true);
    try {
      final now = await ref.read(setupRunnerProvider).snapshot(orchard.id);
      final export = exportSetup(now);
      final path = await ref.read(recordLogSaverProvider)(
        fileName: setupFileNameFor(now.name),
        bytes: Uint8List.fromList(utf8.encode(export.text)),
        dialogTitle: l10n.setupSaveButton,
      );
      if (path == null || !mounted) return;
      setState(() {
        _saving = false;
        _leftOut = export.leftOut;
      });
      if (_onComputer) {
        await showFileSavedDialog(context, title: l10n.setupSavedTitle, message: l10n.setupSavedBody, path: path);
      } else {
        showTopSnackBar(context, l10n.setupSavedTitle, isSuccess: true);
      }
    } catch (e) {
      AppLogger.warning('Setup file: not saved (${errorKind(e)})');
      if (mounted) showTopSnackBar(context, setupErrorWords(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _choose() async {
    final l10n = AppLocalizations.of(context)!;
    final SetupFilePicked? picked;
    try {
      picked = await ref.read(setupFilePickerProvider)(dialogTitle: l10n.setupChooseButton);
    } catch (e) {
      AppLogger.warning('Setup file: could not be opened (${errorKind(e)})');
      if (mounted) showTopSnackBar(context, l10n.setupPickFailed, isError: true, details: '$e');
      return;
    }
    if (picked == null || !mounted) return;
    setState(() {
      _fileName = picked!.name;
      _fileText = picked.text;
      _tooBig = picked.text == null;
      _result = null;
      _moved = false;
    });
    await _check();
  }

  /// Reads the file again and compares it with the Orchard as it is now.
  Future<void> _check() async {
    final text = _fileText;
    setState(() {
      _checking = true;
      _read = null;
      _plan = null;
      _now = null;
      _checkError = null;
    });
    if (text == null) {
      setState(() => _checking = false);
      return;
    }
    final read = readSetupFile(text);
    final file = read.file;
    if (file == null) {
      setState(() {
        _read = read;
        _checking = false;
      });
      return;
    }
    try {
      final now = await ref.read(setupRunnerProvider).snapshot(orchard.id);
      final plan = await planSetup(file, now);
      if (!mounted) return;
      setState(() {
        _read = read;
        _plan = plan;
        _now = now;
        _checking = false;
      });
    } catch (e) {
      AppLogger.warning('Setup file: the Orchard could not be read (${errorKind(e)})');
      if (!mounted) return;
      setState(() {
        _read = read;
        _checkError = e;
        _checking = false;
      });
    }
  }

  Future<void> _apply() async {
    final l10n = AppLocalizations.of(context)!;
    final shown = _plan;
    final file = _read?.file;
    final from = _now;
    if (shown == null || file == null || !shown.canApply || shown.steps.isEmpty) return;
    // The first change in a team of a kind older versions cannot read (a
    // member's limit) is an owner's, after the question of what
    // those versions do then: asked here first, as the member panel asks it.
    if (shown.writesNewKinds &&
        from != null &&
        !await confirmNewRecordKinds(context, from.record, owner: from.record.isOwner(from.me))) {
      return;
    }
    if (!mounted) return;
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.setupApplyConfirmTitle,
      body: l10n.setupApplyConfirmBody(orchardDisplayName(orchard.name, l10n)),
      confirmLabel: l10n.setupApplyButton(shown.steps.length),
    );
    if (go != true || !mounted) return;
    setState(() {
      _applying = true;
      _result = null;
      _moved = false;
      _progress = null;
    });
    final runner = ref.read(setupRunnerProvider);
    final expected = setupPlanText(shown, l10n);
    var first = true;
    var made = 0;
    SetupOutcome? outcome;
    try {
      await withRecentSignIn(
        context,
        ref,
        () async {
          final now = await runner.snapshot(orchard.id);
          final plan = await planSetup(file, now);
          // What is applied is what was shown: an Orchard that changed
          // since is looked at again first. (After signing in again, what
          // is left of the same plan goes on.)
          if (first && setupPlanText(plan, l10n) != expected) {
            if (mounted) {
              setState(() {
                _plan = plan;
                _now = now;
                _moved = true;
              });
            }
            return;
          }
          first = false;
          if (!plan.canApply) {
            if (mounted) {
              setState(() {
                _plan = plan;
                _now = now;
              });
            }
            return;
          }
          final result = await applySetup(plan, now, runner.actions(orchard.id), onStep: (step, i) {
            if (!mounted) return;
            setState(() => _progress = (
                  step: i + 1,
                  total: plan.steps.length,
                  what: setupStepWords(step, l10n, show: const SetupShow.onScreen()).title,
                ));
          });
          made += result.done.length;
          outcome = result;
          final error = result.error;
          if (error is OrchardServerException && error.recentSignInRequired) throw error;
        },
        summary: shown.needsRecentSignIn
            ? (what: l10n.setupStepUpWhat(orchardDisplayName(orchard.name, l10n)), effects: [l10n.setupStepUpEffect])
            : null,
      );
    } catch (e) {
      AppLogger.warning('Setup file: applying stopped (${errorKind(e)})');
      if (mounted && outcome == null) {
        showTopSnackBar(context, setupErrorWords(e, l10n), isError: true, details: '$e');
      }
    }
    if (!mounted) return;
    // Every other page of the Orchard reads it again.
    ref.read(orchardListVersionProvider.notifier).state++;
    final moved = _moved;
    setState(() {
      _applying = false;
      _progress = null;
      _result = outcome == null ? null : (outcome: outcome!, made: made);
    });
    // What is left of the file, if anything, is shown as it stands now,
    // under how applying it went.
    if (!moved && outcome != null) await _check();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Names follow recording mode, here as on every page.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    const show = SetupShow.onScreen();
    final leftOut = _leftOut;
    final idle = !_checking && !_applying;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          key: const ValueKey('setup-save'),
          title: l10n.setupSaveTitle,
          body: l10n.setupSaveBody,
          children: [
            // As wide as its words, at the start: a button, not a field.
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: vaultButton(
                context,
                key: const ValueKey('setup-save-button'),
                label: l10n.setupSaveButton,
                icon: LucideIcons.download,
                isLoading: _saving,
                onPressed: _saving ? null : _save,
              ),
            ),
            if (leftOut != null && leftOut.isNotEmpty) ...[
              const SizedBox(height: 12),
              _Callout(
                key: const ValueKey('setup-left-out'),
                title: l10n.setupLeftOutTitle,
                lines: [for (final x in leftOut) setupLeftOutWords(x, l10n, show: show)],
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        _Section(
          key: const ValueKey('setup-check'),
          title: l10n.setupCheckTitle,
          body: l10n.setupCheckBody,
          children: [
            if (_fileName == null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: vaultButton(
                  context,
                  key: const ValueKey('setup-choose'),
                  label: l10n.setupChooseButton,
                  icon: LucideIcons.folderOpen,
                  onPressed: idle ? _choose : null,
                ),
              )
            else
              // The file on the table: its name in a chip, and what can be
              // done with it at the end of the row.
              _FileRow(
                name: show.any(_fileName!),
                actions: [
                  if (!_tooBig)
                    vaultButton(
                      context,
                      key: const ValueKey('setup-check-again'),
                      label: l10n.setupCheckAgain,
                      icon: LucideIcons.refreshCw,
                      variant: ZestButtonVariant.ghost,
                      onPressed: idle
                          ? () {
                              setState(() {
                                _result = null;
                                _moved = false;
                              });
                              _check();
                            }
                          : null,
                    ),
                  vaultButton(
                    context,
                    key: const ValueKey('setup-choose'),
                    label: l10n.vaultUiSetupChooseAnother,
                    icon: LucideIcons.folderOpen,
                    onPressed: idle ? _choose : null,
                  ),
                ],
              ),
            ..._checked(l10n, show),
          ],
        ),
        if (_onComputer) ...[
          const SizedBox(height: 16),
          _Section(
            key: const ValueKey('setup-terminal'),
            title: l10n.setupTerminalTitle,
            body: l10n.setupTerminalBody,
            children: [
              for (final (i, command) in const [
                'zestssh admin plan team.json',
                'zestssh admin apply team.json',
                'zestssh admin export team.json',
              ].indexed) ...[
                if (i > 0) const SizedBox(height: 8),
                _Command(command: command),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// What checking the chosen file gave: what is wrong with it, or why the
  /// Orchard could not be read, or the plan with what applying it did.
  List<Widget> _checked(AppLocalizations l10n, SetupShow show) {
    if (_fileName == null) return const [];
    if (_tooBig) {
      return [
        const SizedBox(height: 12),
        _Callout(key: const ValueKey('setup-file-problems'), title: l10n.setupFileProblemsTitle, error: true, lines: [
          l10n.setupFileTooBig,
        ]),
      ];
    }
    if (_checking) {
      return [
        const SizedBox(height: 12),
        Row(
          key: const ValueKey('setup-reading'),
          children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
            const SizedBox(width: 10),
            Text(l10n.setupReading, style: TextStyle(fontSize: 12.5, color: ZestColors.textSecondary)),
          ],
        ),
      ];
    }
    final read = _read;
    if (read == null) return const [];
    if (!read.ok) {
      return [
        const SizedBox(height: 12),
        _Callout(
          key: const ValueKey('setup-file-problems'),
          title: l10n.setupFileProblemsTitle,
          error: true,
          lines: [for (final p in read.problems) setupFileProblemWords(p, l10n, show: show)],
          // What is copied names every place as the file has it.
          copy: [for (final p in read.problems) setupFileProblemWords(p, l10n)].join('\n'),
          copyLabel: l10n.desktopShellCopyDetails,
        ),
      ];
    }
    final error = _checkError;
    if (error != null) {
      return [
        const SizedBox(height: 12),
        _Callout(
          key: const ValueKey('setup-check-error'),
          title: setupErrorWords(error, l10n),
          error: true,
          lines: const [],
          copy: ['Setup file: reading the Orchard', 'Orchard: ${orchard.id}', 'Error: $error'].join('\n'),
          copyLabel: l10n.desktopShellCopyDetails,
        ),
      ];
    }
    final plan = _plan;
    if (plan == null) return const [];
    final result = _result;
    final progress = _progress;
    return [
      if (result != null) ...[const SizedBox(height: 12), _resultBox(result.outcome, result.made, l10n, show)],
      if (_moved) ...[
        const SizedBox(height: 12),
        _Callout(key: const ValueKey('setup-moved'), title: l10n.setupChanged, error: true, lines: const []),
      ],
      if (plan.problems.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Callout(
          key: const ValueKey('setup-problems'),
          title: l10n.vaultUiSetupInTheWay(plan.problems.length),
          subtitle: l10n.setupPlanInTheWayBody,
          error: true,
          marked: true,
          lines: [for (final p in plan.problems) setupProblemWords(p, l10n, show: show)],
        ),
      ],
      // Where it has just been applied, how that went is the one thing said
      // (a file applied in full is what the team is now, which needs no
      // second line).
      if (plan.steps.isEmpty && plan.problems.isEmpty && result == null) ...[
        const SizedBox(height: 12),
        _Callout(
          key: const ValueKey('setup-nothing'),
          kind: ZestStatusKind.healthy,
          title: l10n.setupPlanNothing,
          lines: const [],
        ),
      ] else if (plan.steps.isNotEmpty) ...[
        const SizedBox(height: 16),
        _Steps(
          key: const ValueKey('setup-steps'),
          title: l10n.setupPlanChanges(plan.steps.length),
          steps: [for (final s in plan.steps) (s, setupStepWords(s, l10n, show: show))],
        ),
      ],
      if (plan.notes.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Callout(
          key: const ValueKey('setup-notes'),
          kind: ZestStatusKind.neutral,
          title: l10n.setupPlanNotesTitle,
          lines: [for (final n in plan.notes) setupNoteWords(n, l10n, show: show)],
        ),
      ],
      if (plan.steps.isNotEmpty) ...[
        const SizedBox(height: 16),
        if (plan.canApply && plan.needsRecentSignIn)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(l10n.setupNeedsSignIn,
                key: const ValueKey('setup-needs-sign-in'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary)),
          ),
        // One progress while it is applied: how far, and the step under way.
        if (progress != null)
          Padding(
            key: const ValueKey('setup-progress'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.step / progress.total,
                    minHeight: 4,
                    color: ZestTokens.brand,
                    backgroundColor: ZestTokens.surfaceChip,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.vaultUiSetupApplying(progress.step, progress.total, progress.what),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: ZestColors.textSecondary),
                ),
              ],
            ),
          ),
        // Copy details at the start; Apply, the one main action, at the end.
        Row(
          children: [
            _copyAtEdge(
              context,
              CopyDetailsButton(
                key: const ValueKey('setup-copy-plan'),
                // Names as the screen shows them, times as the file writes
                // them (copied text is for a log or support, not for reading
                // on this device's clock).
                detail: setupPlanText(plan, l10n, show: const SetupShow.copied()),
                label: l10n.desktopShellCopyDetails,
                // The plan of the person's own file.
                asItIs: true,
              ),
            ),
            const Spacer(),
            if (plan.canApply)
              vaultButton(
                context,
                key: const ValueKey('setup-apply'),
                label: l10n.setupApplyButton(plan.steps.length),
                icon: LucideIcons.play,
                variant: ZestButtonVariant.primary,
                // The bar above says how far it is; the button only waits
                // (a spinner of its own only before the first step).
                isLoading: _applying && progress == null,
                onPressed: _applying ? null : _apply,
              ),
          ],
        ),
      ],
    ];
  }

  Widget _resultBox(SetupOutcome outcome, int made, AppLocalizations l10n, SetupShow show) {
    final failed = outcome.failed;
    if (failed == null) {
      return _Callout(
        key: const ValueKey('setup-done'),
        kind: ZestStatusKind.healthy,
        title: l10n.setupDone(made),
        lines: const [],
        extra: outcome.syncError == null
            ? null
            : Text(l10n.setupSyncLater,
                key: const ValueKey('setup-sync-later'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary)),
      );
    }
    final error = outcome.error ?? '';
    return _Callout(
      key: const ValueKey('setup-stopped'),
      title: l10n.setupStoppedAt(setupStepWords(failed, l10n, show: show).title),
      error: true,
      lines: [setupErrorWords(error, l10n), l10n.setupStopped(made, outcome.left.length)],
      copy: [
        'Setup file: applying',
        'Orchard: ${orchard.id}',
        'Stopped at: $failed',
        'Error: $error',
        'Made before it: $made',
        'Not tried: ${outcome.left.length}',
      ].join('\n'),
      copyLabel: l10n.desktopShellCopyDetails,
    );
  }
}

/// Copy details at the start of a row, its icon on the edge of the text
/// above it, 32 high (44 on a phone).
Widget _copyAtEdge(BuildContext context, Widget button) => Transform.translate(
      offset: const Offset(-8, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: vaultOnPhone(context) ? 44 : 32),
        child: button,
      ),
    );

class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.body, required this.children});

  final String title;
  final String body;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: ZestColors.bgSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestColors.textPrimary)),
          const SizedBox(height: 4),
          Text(body, style: TextStyle(fontSize: 12.5, height: 1.5, color: ZestColors.textSecondary)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// The chosen file: a chip with its name, and [actions] at the end of the
/// row (under it where there is no room).
class _FileRow extends StatelessWidget {
  const _FileRow({required this.name, required this.actions});

  final String name;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: ZestColors.surfaceChip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.fileJson, size: 15, color: ZestColors.textSecondary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(name,
                key: const ValueKey('setup-file-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestColors.textPrimary)),
          ),
        ],
      ),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        chip,
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }
}

/// A terminal command as a code block, with its own copy button.
class _Command extends StatelessWidget {
  const _Command({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final target = vaultOnPhone(context) ? 44.0 : 32.0;
    return Container(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
      constraints: const BoxConstraints(minHeight: 40),
      decoration: BoxDecoration(
        color: ZestColors.surfaceChip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(command,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestColors.textPrimary)),
          ),
          IconButton(
            icon: const Icon(LucideIcons.copy, size: 15),
            tooltip: l10n.vaultUiSetupCopyCommand,
            constraints: BoxConstraints.tightFor(width: target, height: target),
            padding: EdgeInsets.zero,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (context.mounted) showTopSnackBar(context, l10n.migrationErrorCopied, isSuccess: true);
            },
          ),
        ],
      ),
    );
  }
}

/// A callout: what was left out, what stands in the way, what to know, how
/// applying went. Its [title] a sentence beside its icon, then its lines
/// ([marked]: each with a cross, as what stands in the way), and where
/// there is [copy], Copy details at its foot, on the edge of the text.
class _Callout extends StatelessWidget {
  const _Callout({
    super.key,
    required this.title,
    required this.lines,
    this.subtitle,
    this.error = false,
    this.kind,
    this.marked = false,
    this.copy,
    this.copyLabel,
    this.extra,
  });

  final String title;
  final String? subtitle;
  final List<String> lines;
  final bool error;

  /// Its tone where it is no error: healthy (done), neutral (to know), or
  /// none (a plain box).
  final ZestStatusKind? kind;
  final bool marked;
  final String? copy;
  final String? copyLabel;
  final Widget? extra;

  TextStyle get _titleStyle =>
      TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: ZestColors.textPrimary);

  @override
  Widget build(BuildContext context) {
    final tone = error ? ZestStatusKind.critical : kind;
    final color = tone == null || tone == ZestStatusKind.neutral ? null : zestStatusColor(tone);
    final icon = switch (tone) {
      ZestStatusKind.critical => LucideIcons.alertCircle,
      ZestStatusKind.healthy => LucideIcons.checkCircle2,
      ZestStatusKind.neutral => LucideIcons.info,
      _ => null,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        // One step lighter than the section, or the tint of its tone.
        color: color == null ? ZestColors.surfaceChip : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color == null ? ZestColors.borderSubtle : color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            // On the title's first line.
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 15, color: color ?? ZestColors.textSecondary),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // (An error's title can be selected and copied as it is.)
                if (error)
                  SelectableText(title, style: _titleStyle)
                else
                  Text(title, style: _titleStyle),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(subtitle!, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary)),
                  ),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (marked) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(LucideIcons.xCircle, size: 14, color: ZestColors.statusError),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: SelectableText(line,
                              style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary)),
                        ),
                      ],
                    ),
                  ),
                if (extra != null) Padding(padding: const EdgeInsets.only(top: 4), child: extra),
                if (copy != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    // What the file says and where applying it stopped, named as
                    // the file names it; the label in the person's language.
                    child: _copyAtEdge(context, CopyDetailsButton(detail: copy!, label: copyLabel, asItIs: true)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The steps of a plan: each with a mark of what it does (+ adds, ~
/// changes; a file never removes anything) and what exactly under it.
class _Steps extends StatelessWidget {
  const _Steps({super.key, required this.title, required this.steps});

  final String title;
  final List<(SetupStep, SetupStepWords)> steps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestColors.textPrimary)),
        const SizedBox(height: 8),
        Container(
          // One step lighter than the section it is in, with a hairline.
          decoration: BoxDecoration(
            color: ZestColors.surfaceChip,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ZestColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, (step, words)) in steps.indexed) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: ZestColors.borderSubtle),
                Padding(
                  key: ValueKey('setup-step-$i'),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StepMark(adds: _adds(step)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(words.title,
                                style: TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w500, color: ZestColors.textPrimary)),
                            for (final d in words.details)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: SelectableText(d,
                                    style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestColors.textSecondary)),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Whether [step] adds something that is not there yet.
  static bool _adds(SetupStep step) => switch (step) {
        AddCrate() || AddRole() || Invite() || AddGroup() || AddHost() => true,
        _ => false,
      };
}

/// "+" in green for what a step adds, "~" in amber for what it changes.
class _StepMark extends StatelessWidget {
  const _StepMark({required this.adds});

  final bool adds;

  @override
  Widget build(BuildContext context) {
    final color = adds ? ZestColors.statusSuccess : ZestColors.statusWarning;
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(4)),
      // An icon, not a Text: the plan's words are its texts. Plus adds, the
      // pencil changes.
      child: Icon(adds ? LucideIcons.plus : LucideIcons.pencil, size: 12, color: color),
    );
  }
}
