import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';

// Recovering an account that lost every second step and every recovery code
// (3.3; the two-step contract, sections 6.5 and 7.5 to 7.6), from the
// sign-in screen: the address, the code ZestSSH emails for this ask, seven
// days in which every signed-in device of the account can say "This wasn't
// me", then the sync password proved (the data stays) or a reset (said
// plainly first). lib/services/account/lockout_recovery.dart has the rest.

/// Opens the account's recovery: where it waits on this device, at its
/// stage; otherwise at asking for it, with [email] filled in.
Future<void> showLockoutRecovery(BuildContext context, {String? email}) {
  return AwayForSignIn.during(() => showZestModal<void>(
        context: context,
        size: ZestModalSize.compact,
        barrierDismissible: false,
        child: LockoutRecoveryDialog(email: email),
      ));
}

enum _Stage { loading, ask, code, waiting, due, done }

/// A question asked in the dialog itself, in place of its stage until it is
/// answered (the dialog rules of 3.4: it was a second dialog over this one).
enum _Asking { nothing, reset, forget }

class LockoutRecoveryDialog extends ConsumerStatefulWidget {
  const LockoutRecoveryDialog({super.key, this.email, this.now = DateTime.now});

  final String? email;

  /// The time now (tests).
  final DateTime Function() now;

  @override
  ConsumerState<LockoutRecoveryDialog> createState() => _LockoutRecoveryDialogState();
}

class _LockoutRecoveryDialogState extends ConsumerState<LockoutRecoveryDialog> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();

  _Stage _stage = _Stage.loading;

  /// The ask the emailed code goes with: in memory only, with this screen.
  String? _askId;

  WaitingLockout? _waiting;

  /// The account the proof signs for, where this device knows it.
  String? _uid;

  bool _busy = false;
  TwoStepProblem? _problem;
  Object? _problemCause;

  /// The sync password was tried too often: only a reset is left.
  bool _proofClosed = false;

  /// What completing did: kept the data, or reset.
  bool _withData = false;

  /// A reset waits for the address to be shown again: the ticket here was older
  /// than ZestSSH Cloud takes for a reset (recovery-confirm-again), so the code
  /// emailed now gives a new one, and the reset the person confirmed goes on with
  /// it (found in a security review).
  bool _resetAfterConfirm = false;

  _Asking _asking = _Asking.nothing;

  @override
  void initState() {
    super.initState();
    _email.text = widget.email?.trim() ?? '';
    for (final c in [_email, _code, _password]) {
      c.addListener(() => setState(() {}));
    }
    unawaited(_open());
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  LockoutRecoveryStore get _store => ref.read(lockoutRecoveryStoreProvider);

  Future<void> _open() async {
    final waiting = await _store.read();
    if (!mounted) return;
    if (waiting == null) {
      setState(() => _stage = _Stage.ask);
      return;
    }
    await _waitFor(waiting);
  }

  /// Shows [waiting]: its day, or completing it once that has come.
  Future<void> _waitFor(WaitingLockout waiting) async {
    final uid = waiting.proof?.accountUid ?? await _store.accountFor(waiting.email) ?? _signedInUidFor(waiting.email);
    if (!mounted) return;
    setState(() {
      _waiting = waiting;
      _uid = uid;
      _email.text = waiting.email;
      _stage = waiting.dueAt(widget.now()) ? _Stage.due : _Stage.waiting;
    });
  }

  /// The id of the account signed in here, where it is the one at [email].
  String? _signedInUidFor(String email) {
    final user = ref.read(currentUserProvider);
    final uid = user?.uid;
    if (user == null || uid == null || uid == 'desktop-session') return null;
    return (user.email ?? '').trim().toLowerCase() == email.trim().toLowerCase() ? uid : null;
  }

  String _shown(String email) => Redactable.account(email).displayIn(ref);

  void _failed(Object e) {
    AppLogger.warning('Lock-out recovery: $e');
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = false;
      _problem = twoStepProblem(l10n, e);
      _problemCause = e;
    });
  }

  void _starting() => setState(() {
        _busy = true;
        _problem = null;
        _problemCause = null;
      });

  // ── Asking ───────────────────────────────────────────────────────

  bool get _emailReady => _email.text.trim().contains('@');

  Future<void> _ask() async {
    if (!_emailReady || _busy) return;
    _starting();
    try {
      final askId = await ref.read(twoStepApiProvider).askLockoutRecovery(_email.text.trim());
      if (!mounted) return;
      setState(() {
        _askId = askId;
        _busy = false;
        _code.clear();
        _stage = _Stage.code;
      });
    } catch (e) {
      if (mounted) _failed(e);
    }
  }

  String get _typedCode => _code.text.replaceAll(RegExp(r'[^0-9]'), '');

  Future<void> _confirm() async {
    final askId = _askId;
    if (askId == null || _typedCode.length != 8 || _busy) return;
    _starting();
    try {
      final email = _email.text.trim();
      final ticket = await ref.read(twoStepApiProvider).confirmLockoutRecovery(email: email, askId: askId, code: _typedCode);
      final waiting = WaitingLockout(email: email, ticket: ticket.ticket, completesAt: ticket.completesAt, proof: ticket.proof);
      await _store.save(waiting);
      _askId = null;
      if (!mounted) return;
      setState(() => _busy = false);
      await _waitFor(waiting);
      if (_resetAfterConfirm && mounted && waiting.dueAt(widget.now())) {
        _resetAfterConfirm = false;
        await _completeReset(waiting);
      }
    } catch (e) {
      if (mounted) _failed(e);
    }
  }

  // ── Completing ───────────────────────────────────────────────────

  bool get _canProve => _waiting?.proof != null && !_proofClosed && _uid != null;

  Future<void> _keepData() async {
    final waiting = _waiting;
    final uid = _uid;
    if (waiting == null || uid == null || _password.text.isEmpty || _busy) return;
    _starting();
    // The spinner shows before the key is worked out, which takes a moment.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      final proof = await proveSyncPassword(waiting: waiting, password: _password.text, firebaseUid: uid);
      if (proof == null) throw const TwoStepRefusal(409, code: 'recovery-proof-closed');
      await ref
          .read(twoStepApiProvider)
          .completeLockoutRecovery(email: waiting.email, ticket: waiting.ticket, proof: proof);
      await _completed(withData: true);
    } catch (e) {
      if (!mounted) return;
      _password.clear();
      await _refused(e);
    }
  }

  /// Asks whether to reset, in this dialog (it was a dialog over it).
  void _reset() {
    if (_waiting == null || _busy) return;
    setState(() => _asking = _Asking.reset);
  }

  Future<void> _resetConfirmed() async {
    final waiting = _waiting;
    if (waiting == null || _busy) return;
    setState(() => _asking = _Asking.nothing);
    await _completeReset(waiting);
  }

  /// Resets the account with [waiting]'s ticket, the person having confirmed it.
  /// A ticket older than ZestSSH Cloud takes for a reset asks for the address
  /// again: a code goes there, and the reset goes on once it is in.
  Future<void> _completeReset(WaitingLockout waiting) async {
    _starting();
    try {
      await ref.read(twoStepApiProvider).completeLockoutRecovery(email: waiting.email, ticket: waiting.ticket, reset: true);
      await _completed(withData: false);
    } on TwoStepRefusal catch (e) {
      if (!mounted) return;
      if (e.code != 'recovery-confirm-again') return _refused(e);
      _resetAfterConfirm = true;
      setState(() => _busy = false);
      _email.text = waiting.email;
      await _ask();
    } catch (e) {
      if (mounted) await _refused(e);
    }
  }

  Future<void> _completed({required bool withData}) async {
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _withData = withData;
      _waiting = null;
      _stage = _Stage.done;
    });
  }

  /// What a refusal of completing leaves: tries to go on, only a reset, a
  /// later day, or a recovery that is gone.
  Future<void> _refused(Object e) async {
    _failed(e);
    if (e is! TwoStepRefusal) return;
    final waiting = _waiting;
    switch (e.code) {
      case 'recovery-proof-closed':
        setState(() => _proofClosed = true);
      case 'recovery-not-yet':
        final at = e.completesAt;
        if (waiting != null && at != null) {
          final later = WaitingLockout(email: waiting.email, ticket: waiting.ticket, completesAt: at, proof: waiting.proof);
          await _store.save(later);
          if (mounted) setState(() => _waiting = later);
        }
        if (mounted) setState(() => _stage = _Stage.waiting);
      case 'recovery-ticket-invalid':
      case 'recovery-through-company':
        // Gone: cancelled from a signed-in device, lapsed, asked again
        // elsewhere, or not ours to recover. Its ticket goes too.
        await _store.clear();
        if (mounted) {
          setState(() {
            _waiting = null;
            _stage = _Stage.ask;
          });
        }
    }
  }

  /// Asks whether to forget it here, in this dialog (it was a dialog over it).
  void _forget() {
    if (_busy) return;
    setState(() => _asking = _Asking.forget);
  }

  Future<void> _forgetConfirmed() async {
    await _store.clear();
    if (mounted) Navigator.of(context).pop();
  }

  // ── On screen ────────────────────────────────────────────────────

  // Escape closes it only as its X does: never while a step is under way (the 3.4 security review, L7).
  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy, child: _dialog(context));

  Widget _dialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = switch ((_asking, _stage)) {
      (_Asking.reset, _) => l10n.lockoutResetTitle,
      (_Asking.forget, _) => l10n.lockoutForgetTitle,
      (_, _Stage.waiting) => l10n.lockoutWaitingSelfTitle,
      (_, _Stage.due) => l10n.lockoutDueTitle,
      _ => l10n.lockoutTitle,
    };
    final body = switch (_asking) {
      _Asking.reset => _resetQuestion(l10n),
      _Asking.forget => [_para(l10n.lockoutForgetBody)],
      _Asking.nothing => [
          ...switch (_stage) {
            _Stage.loading => [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
                ),
              ],
            _Stage.ask => _askBody(l10n),
            _Stage.code => _codeBody(l10n),
            _Stage.waiting => _waitingBody(l10n),
            _Stage.due => _dueBody(l10n),
            _Stage.done => [
                _para(_withData ? l10n.lockoutDone : l10n.lockoutDoneReset, key: const ValueKey('lockout-done')),
              ],
          },
          // Under way: said under the stage (it was a spinner in the button).
          if (_busy && _stage != _Stage.loading)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3TextSecondary),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.zestDialogWorking, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
                ],
              ),
            ),
          if (_problem != null) _problemBox(l10n, _problem!),
        ],
    };
    // In the app's dialog (the dialog rules, 3.4): every button in the
    // footer (Keep my data, Ask again and Reset instead stood in the body), a
    // side option as a link, and the questions asked in place.
    final f = _footer(l10n);
    return ZestDialogShell(
      key: const ValueKey('lockout-recovery'),
      size: ZestModalSize.compact,
      tone: switch ((_asking, _stage)) {
        (_Asking.reset, _) => ZestDialogTone.destructive,
        (_Asking.nothing, _Stage.done) => ZestDialogTone.success,
        _ => ZestDialogTone.neutral,
      },
      icon: switch ((_asking, _stage)) {
        (_Asking.reset, _) => null,
        (_Asking.nothing, _Stage.done) => null,
        _ => LucideIcons.lifeBuoy,
      },
      title: title,
      onClose: _busy ? () {} : () => Navigator.of(context).pop(),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: body,
      ),
      tertiaryKey: f.tertiaryKey,
      tertiaryAction: f.tertiary,
      tertiaryDanger: f.tertiaryDanger,
      secondaryKey: f.secondaryKey,
      secondaryAction: f.secondary,
      primaryKey: f.primaryKey,
      primaryAction: f.primary,
      primaryDanger: f.primaryDanger,
    );
  }

  /// The reset's question: what it does, what goes and what stays.
  List<Widget> _resetQuestion(AppLocalizations l10n) => [
        _para(_waiting?.proof == null ? l10n.lockoutNoProofBody : l10n.lockoutResetBody),
        const SizedBox(height: 4),
        ..._bullets([l10n.lockoutResetLosesData, l10n.lockoutResetLosesTeams, l10n.lockoutResetLosesDevices, l10n.lockoutResetKeeps]),
      ];

  static List<Widget> _bullets(List<String> lines) => [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: Icon(LucideIcons.circle, size: 6, color: AppColors.v3TextTertiary),
                ),
                Expanded(child: Text(line, style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary))),
              ],
            ),
          ),
      ];

  static Widget _para(String text, {Key? key}) =>
      Text(text, key: key, style: const TextStyle(fontSize: 13.5, height: 1.5));

  InputDecoration _field(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: AppColors.surfaceContainer,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.brandOrange)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      );

  List<Widget> _askBody(AppLocalizations l10n) => [
        _para(l10n.lockoutIntro),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('lockout-email'),
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          decoration: _field(l10n.twoStepEmailLabel),
          onSubmitted: (_) => _ask(),
        ),
      ];

  List<Widget> _codeBody(AppLocalizations l10n) => [
        _para(_resetAfterConfirm
            ? l10n.lockoutResetCodeSent(_shown(_email.text.trim()))
            : l10n.lockoutCodeSent(_shown(_email.text.trim()))),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('lockout-code'),
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 -]')), LengthLimitingTextInputFormatter(12)],
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 20, letterSpacing: 4),
          decoration: _field(l10n.lockoutCodeLabel, hint: '00000000'),
          onSubmitted: (_) => _confirm(),
        ),
      ];

  void _askAgain() => setState(() {
        _stage = _Stage.ask;
        _askId = null;
        _problem = null;
      });

  List<Widget> _waitingBody(AppLocalizations l10n) {
    final waiting = _waiting!;
    return [
      _para(l10n.lockoutWaitingSelfBody(_shown(waiting.email), dayWords(l10n, waiting.completesAt)),
          key: const ValueKey('lockout-waiting')),
    ];
  }

  List<Widget> _dueBody(AppLocalizations l10n) {
    final waiting = _waiting!;
    if (_canProve) {
      return [
        _para(l10n.lockoutDueBodyProof(_shown(waiting.email))),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('lockout-sync-password'),
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: _field(l10n.lockoutSyncPasswordLabel),
          onSubmitted: (_) => _keepData(),
        ),
      ];
    }
    final why = waiting.proof == null
        ? l10n.lockoutNoProofBody
        : _proofClosed
            ? l10n.lockoutProofClosed
            : l10n.lockoutCannotProveHere;
    return [
      _para(why, key: const ValueKey('lockout-reset-only')),
      const SizedBox(height: 4),
      ..._bullets([l10n.lockoutResetLosesData, l10n.lockoutResetLosesTeams, l10n.lockoutResetLosesDevices, l10n.lockoutResetKeeps]),
    ];
  }

  Widget _problemBox(AppLocalizations l10n, TwoStepProblem problem) {
    final tone = problem.quiet ? AppColors.textSecondary : AppColors.error;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        key: const ValueKey('lockout-problem'),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tone.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(problem.text, style: TextStyle(fontSize: 12.5, height: 1.45, color: tone)),
            Row(
              children: [
                if (problem.code.isNotEmpty)
                  Expanded(
                    child: SelectableText(l10n.twoStepErrorCode(problem.code),
                        style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  )
                else
                  const Spacer(),
                CopyDetailsButton(
                  detail: ErrorReport.build(what: problem.text, where: 'Lock-out recovery', error: _problemCause),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The footer, by stage: Cancel (or Close) and the main button bottom
  /// right, a side option bottom left as a link.
  _Footer _footer(AppLocalizations l10n) {
    void close() => Navigator.of(context).pop();
    final idle = !_busy;
    switch (_asking) {
      case _Asking.reset:
        return _Footer(
          secondary: (label: l10n.cancel, onPressed: idle ? () => setState(() => _asking = _Asking.nothing) : null),
          primaryKey: const ValueKey('lockout-reset-yes'),
          primary: (label: l10n.lockoutResetConfirm, icon: null, onPressed: idle ? _resetConfirmed : null),
          primaryDanger: true,
        );
      case _Asking.forget:
        return _Footer(
          secondary: (label: l10n.cancel, onPressed: () => setState(() => _asking = _Asking.nothing)),
          primaryKey: const ValueKey('lockout-forget-yes'),
          primary: (label: l10n.lockoutForget, icon: null, onPressed: _forgetConfirmed),
        );
      case _Asking.nothing:
        break;
    }
    final forget = (label: l10n.lockoutForget, onPressed: idle ? _forget : null);
    return switch (_stage) {
      _Stage.loading => _Footer(secondary: (label: l10n.cancel, onPressed: close)),
      _Stage.done => _Footer(primary: (label: l10n.done, icon: null, onPressed: close)),
      _Stage.ask => _Footer(
          secondary: (label: l10n.cancel, onPressed: idle ? close : null),
          primaryKey: const ValueKey('lockout-send'),
          primary: (label: l10n.lockoutSendCode, icon: null, onPressed: _emailReady && idle ? _ask : null),
        ),
      _Stage.code => _Footer(
          tertiaryKey: const ValueKey('lockout-ask-again'),
          tertiary: (label: l10n.lockoutAskAgain, onPressed: idle ? _askAgain : null),
          secondary: (label: l10n.cancel, onPressed: idle ? close : null),
          primaryKey: const ValueKey('lockout-confirm'),
          primary: (
            label: _resetAfterConfirm ? l10n.lockoutResetConfirm : l10n.lockoutConfirm,
            icon: null,
            onPressed: _typedCode.length == 8 && idle ? _confirm : null,
          ),
        ),
      // Waiting: nothing to do but wait; Close says so (it said Cancel).
      _Stage.waiting => _Footer(
          tertiaryKey: const ValueKey('lockout-forget'),
          tertiary: forget,
          tertiaryDanger: true,
          secondary: (label: l10n.close, onPressed: idle ? close : null),
        ),
      _Stage.due when _canProve => _Footer(
          tertiaryKey: const ValueKey('lockout-forget'),
          tertiary: forget,
          tertiaryDanger: true,
          secondaryKey: const ValueKey('lockout-reset-instead'),
          secondary: (label: l10n.lockoutResetInstead, onPressed: idle ? _reset : null),
          primaryKey: const ValueKey('lockout-keep-data'),
          primary: (label: l10n.lockoutKeepData, icon: null, onPressed: idle && _password.text.isNotEmpty ? _keepData : null),
        ),
      _Stage.due => _Footer(
          tertiaryKey: const ValueKey('lockout-forget'),
          tertiary: forget,
          tertiaryDanger: true,
          secondary: (label: l10n.close, onPressed: idle ? close : null),
          primaryKey: const ValueKey('lockout-reset'),
          primary: (label: l10n.lockoutResetConfirm, icon: null, onPressed: idle ? _reset : null),
          primaryDanger: true,
        ),
    };
  }
}

/// What the footer of [LockoutRecoveryDialog] holds at a stage.
class _Footer {
  const _Footer({
    this.primary,
    this.secondary,
    this.tertiary,
    this.primaryKey,
    this.secondaryKey,
    this.tertiaryKey,
    this.primaryDanger = false,
    this.tertiaryDanger = false,
  });

  final ({String label, VoidCallback? onPressed, IconData? icon})? primary;
  final ({String label, VoidCallback? onPressed})? secondary;
  final ({String label, VoidCallback? onPressed})? tertiary;
  final Key? primaryKey;
  final Key? secondaryKey;
  final Key? tertiaryKey;
  final bool primaryDanger;
  final bool tertiaryDanger;
}
