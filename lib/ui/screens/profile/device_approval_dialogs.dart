import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart' show TeamWaiting;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

/// Approving a new device (3.0), the two screens: on a
/// device that holds the sync key, "A new device wants your keys"; on the new
/// device, asking and showing the words. The steps and their checks are in
/// services/account/device_approvals.dart.

/// This device's name as its other devices see it: the platform's product
/// name, nothing more (the device list keeps the same).
String approvalDeviceName() => switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      final os => os,
    };

/// On a device that holds the sync key: finds a device that asks, and after
/// the person sees the same words on both screens, sends it the key.
Future<void> showApproveNewDevice(BuildContext context) => showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      barrierDismissible: false,
      child: const _ApproveNewDevice(),
    );

/// On a new device: asks a device the person already uses for the sync key.
/// Returns what arrived, or null when it did not.
Future<SyncHandover?> showAskForApproval(BuildContext context) => showZestModal<SyncHandover>(
      context: context,
      size: ZestModalSize.standard,
      barrierDismissible: false,
      child: const _AskForApproval(),
    );

/// The three words, large, for reading side by side.
class ApprovalWords extends StatelessWidget {
  const ApprovalWords({super.key, required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    // A box a step above the dialog, never darker than it (it was near
    // black inside it), the words large with a quiet dot between them.
    final dot = Text('\u00b7', style: TextStyle(fontSize: 24, height: 1.2, color: ZestColors.textMuted));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: ZestColors.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestColors.borderSubtle),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 8,
        children: [
          for (var i = 0; i < words.length; i++) ...[
            if (i > 0) dot,
            SelectableText(
              words[i],
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                height: 1.2,
                color: ZestColors.textPrimary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Waiting for the other device: a ring on its track, the words beside it.
Widget _waiting(String text) => TeamWaiting(text);

Widget _text(String text, {Color? color}) =>
    Text(text, style: TextStyle(fontSize: 13, height: 1.45, color: color ?? ZestColors.textSecondary));

// ── The approving device ───────────────────────────────────────────────

enum _GiveStep { loading, none, confirm, working, words, sending, done, failed }

class _ApproveNewDevice extends ConsumerStatefulWidget {
  const _ApproveNewDevice();

  @override
  ConsumerState<_ApproveNewDevice> createState() => _ApproveNewDeviceState();
}

class _ApproveNewDeviceState extends ConsumerState<_ApproveNewDevice> {
  _GiveStep _step = _GiveStep.loading;
  DeviceApprovalRequest? _request;
  ApprovalGive? _give;
  List<String>? _words;
  String? _failure;

  DeviceApprovalsApi get _api => ref.read(deviceApprovalsApiProvider);

  @override
  void initState() {
    super.initState();
    // After the first frame: the steps read this screen's language.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    // Closed half way: the request ends, nothing was sent.
    final give = _give;
    if (give != null && (_step == _GiveStep.working || _step == _GiveStep.words)) {
      give.refuse().catchError((_) {});
    }
    super.dispose();
  }

  /// Waits between looks, and stops once the dialog is gone.
  Future<void> _poll(Duration d) async {
    await Future<void>.delayed(d);
    if (!mounted) throw const DeviceApprovalException(0, 'closed');
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _step = _GiveStep.failed;
      _failure = message;
    });
  }

  String _messageFor(DeviceApprovalException e, AppLocalizations l10n) {
    if (e.mismatch) return l10n.approveMismatch;
    if (e.ended) return l10n.approveEnded;
    // Where the service or the way to it was what stopped it, how the
    // service stands; whether anything went out is not known then, so
    // nothing is said of that.
    return cloudStopped(l10n, e) ?? l10n.approveFailed;
  }

  Future<void> _load() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final asking = [
        for (final r in await _api.list())
          if (r.role == 'open' && r.stage == 'created') r,
      ];
      if (!mounted) return;
      setState(() {
        _request = asking.firstOrNull;
        _step = asking.isEmpty ? _GiveStep.none : _GiveStep.confirm;
      });
    } catch (e) {
      AppLogger.warning('Device approval: the requests were not read ($e)');
      _fail(cloudStopped(l10n, e) ?? l10n.approveFailed);
    }
  }

  /// Answers, signing in again first when the server wants a recent
  /// sign-in, then waits for the new device's reveal.
  Future<void> _continue() async {
    final l10n = AppLocalizations.of(context)!;
    final request = _request;
    if (request == null) return;
    setState(() => _step = _GiveStep.working);
    try {
      ApprovalGive give;
      try {
        give = await ApprovalGive.answer(_api, request.id);
      } on DeviceApprovalException catch (e) {
        if (!e.needsRecentSignIn || !mounted) rethrow;
        final summary = (what: l10n.approveStepUpWhat(request.name), effects: [l10n.approveStepUpEffect]);
        final shown = await confirmOrSignIn(context, ref, summary: summary);
        if (shown == ItsYou.cancelled || !mounted) {
          // Turned down: the request ends, so the new device stops waiting.
          await _api.cancel(request.id).catchError((_) {});
          _fail(l10n.approveRefused);
          return;
        }
        if (shown == ItsYou.failed) {
          _fail(l10n.approveFailed);
          return;
        }
        give = await ApprovalGive.answer(_api, request.id);
      }
      _give = give;
      final words = await give.awaitReveal(wait: _poll);
      if (!mounted) return;
      setState(() {
        _words = words;
        _step = _GiveStep.words;
      });
    } on DeviceApprovalException catch (e) {
      if (e.code == 'closed') return;
      AppLogger.warning('Device approval: $e');
      _fail(_messageFor(e, l10n));
    } catch (e) {
      AppLogger.warning('Device approval: $e');
      _fail(cloudStopped(l10n, e) ?? l10n.approveFailed);
    }
  }

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final give = _give;
    if (give == null) return;
    setState(() => _step = _GiveStep.sending);
    try {
      final handover = await ref.read(syncHandoverProvider)();
      if (handover == null) {
        await give.refuse().catchError((_) {});
        _fail(l10n.approveNoSync);
        return;
      }
      await give.send(handover);
      if (mounted) setState(() => _step = _GiveStep.done);
    } on DeviceApprovalException catch (e) {
      AppLogger.warning('Device approval: sending failed ($e)');
      _fail(e.needsRecentSignIn ? l10n.approveTooSlow : _messageFor(e, l10n));
    } catch (e) {
      AppLogger.warning('Device approval: sending failed ($e)');
      _fail(cloudStopped(l10n, e) ?? l10n.approveFailed);
    }
  }

  Future<void> _notMe() async {
    final l10n = AppLocalizations.of(context)!;
    final request = _request;
    if (request != null) {
      try {
        await _api.cancel(request.id);
      } catch (_) {/* ended either way */}
    }
    if (!mounted) return;
    showTopSnackBar(context, l10n.approveNotMeDone, isWarning: true, duration: const Duration(seconds: 10));
    Navigator.of(context).pop();
  }

  Future<void> _noMatch() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await _give?.refuse();
    } catch (_) {/* ended either way */}
    _fail(l10n.approveRefused);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final request = _request;
    void close() => Navigator.of(context).pop();
    final (Widget body, primary, secondary) = switch (_step) {
      _GiveStep.loading => (_waiting(l10n.approveLooking), null, (label: l10n.cancel, onPressed: close)),
      _GiveStep.none => (_text(l10n.approveNone), null, (label: l10n.close, onPressed: close)),
      _GiveStep.confirm => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text(l10n.approveWho(request!.name), color: ZestColors.textPrimary),
              const SizedBox(height: 10),
              _text(l10n.approveWarning),
            ],
          ),
          (label: l10n.approveContinue, onPressed: _continue, icon: LucideIcons.arrowRight),
          (label: l10n.approveNotMe, onPressed: _notMe),
        ),
      _GiveStep.working => (_waiting(l10n.approveWaiting), null, (label: l10n.cancel, onPressed: close)),
      _GiveStep.words => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text(l10n.approveWordsBody),
              const SizedBox(height: 14),
              ApprovalWords(key: const ValueKey('approve-words'), words: _words!),
            ],
          ),
          (label: l10n.approveSend, onPressed: _send, icon: LucideIcons.check),
          (label: l10n.approveNoMatch, onPressed: _noMatch),
        ),
      _GiveStep.sending => (_waiting(l10n.approveSending), null, null),
      _GiveStep.done => (_text(l10n.approveDone), (label: l10n.close, onPressed: close, icon: null), null),
      _GiveStep.failed => (_text(_failure ?? l10n.approveFailed), null, (label: l10n.close, onPressed: close)),
    };
    return ZestDialogShell(
      size: ZestModalSize.standard,
      // Done: the green tick's colour; a failure is said in words, not in a
      // yellow dialog (the dialog rules, 3.4).
      tone: _step == _GiveStep.done ? ZestDialogTone.success : ZestDialogTone.info,
      icon: LucideIcons.smartphone,
      title: _step == _GiveStep.words ? l10n.approveWordsTitle : l10n.approveTitle,
      body: body,
      primaryAction: primary,
      secondaryAction: secondary,
      // Refusing a request that was not this person's is an alarm: red.
      secondaryDanger: secondary != null && (secondary.label == l10n.approveNotMe || secondary.label == l10n.approveNoMatch),
    );
  }
}

// ── The new device ─────────────────────────────────────────────────────

enum _AskStep { starting, waiting, words, failed }

class _AskForApproval extends ConsumerStatefulWidget {
  const _AskForApproval();

  @override
  ConsumerState<_AskForApproval> createState() => _AskForApprovalState();
}

class _AskForApprovalState extends ConsumerState<_AskForApproval> {
  _AskStep _step = _AskStep.starting;
  ApprovalAsk? _ask;
  List<String>? _words;
  String? _failure;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  @override
  void dispose() {
    final ask = _ask;
    if (ask != null && !_done) ask.cancel().catchError((_) {});
    super.dispose();
  }

  Future<void> _poll(Duration d) async {
    await Future<void>.delayed(d);
    if (!mounted) throw const DeviceApprovalException(0, 'closed');
  }

  Future<void> _run() async {
    final l10n = AppLocalizations.of(context)!;
    // Trying again ends the request before, so no device answers an old one.
    final before = _ask;
    _ask = null;
    setState(() {
      _step = _AskStep.starting;
      _failure = null;
    });
    try {
      if (before != null) await before.cancel().catchError((_) {});
      final ask = await ApprovalAsk.start(ref.read(deviceApprovalsApiProvider), name: approvalDeviceName());
      _ask = ask;
      if (!mounted) return;
      setState(() => _step = _AskStep.waiting);
      final words = await ask.awaitApprover(wait: _poll);
      if (!mounted) return;
      setState(() {
        _words = words;
        _step = _AskStep.words;
      });
      final handover = await ask.awaitHandover(wait: _poll);
      _done = true;
      if (mounted) Navigator.of(context).pop(handover);
    } on DeviceApprovalException catch (e) {
      if (e.code == 'closed') return;
      AppLogger.warning('Device approval (new device): $e');
      if (mounted) {
        setState(() {
          _step = _AskStep.failed;
          _failure = e.ended
              ? l10n.askEnded
              : e.code == 'bad-seal'
                  ? l10n.askBadSeal
                  : cloudStopped(l10n, e) ?? l10n.askFailed;
        });
      }
    } catch (e) {
      AppLogger.warning('Device approval (new device): $e');
      if (mounted) {
        setState(() {
          _step = _AskStep.failed;
          _failure = cloudStopped(l10n, e) ?? l10n.askFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    void cancel() => Navigator.of(context).pop();
    final (Widget body, primary) = switch (_step) {
      _AskStep.starting => (_waiting(l10n.askStarting), null),
      _AskStep.waiting => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text(l10n.askWaiting),
              const SizedBox(height: 14),
              _waiting(l10n.askWaitingShort),
            ],
          ),
          null,
        ),
      _AskStep.words => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text(l10n.askWordsBody),
              const SizedBox(height: 14),
              ApprovalWords(key: const ValueKey('ask-words'), words: _words!),
              const SizedBox(height: 14),
              _waiting(l10n.askWaitingApproval),
            ],
          ),
          null,
        ),
      _AskStep.failed => (
          _text(_failure ?? l10n.askFailed),
          (label: l10n.retry, onPressed: _run, icon: LucideIcons.refreshCw),
        ),
    };
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.monitorSmartphone,
      title: _step == _AskStep.words ? l10n.askWordsTitle : l10n.askTitle,
      body: body,
      primaryAction: primary,
      secondaryAction: (label: l10n.cancel, onPressed: cancel),
    );
  }
}
