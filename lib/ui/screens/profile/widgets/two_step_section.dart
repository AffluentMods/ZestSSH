import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/widgets/lockout_recovery_dialog.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_confirm.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';

// Two-step sign-in on the account's Security section (3.3; the two-step
// contract), on phones and computers alike: what ZestSSH Cloud says of the
// account, a recovery of it that someone asked for (prominent, with "This
// wasn't me"), its passkeys (each with its name, kind, whether it syncs and
// the day it was added; never when it was last used), the authenticator
// app, turning it all off, and the recovery codes. Every change says how
// many of the account's other devices it signed out; every error says what
// happened, what to do, its code and Copy details.
//
// Where a change needs a sign-in from the last few minutes, the person is
// asked to confirm it is them first (phones sign in again; a computer signs
// in in the browser, which hands it a fresh ID token as well for what
// Firebase itself is asked to do). The account's first second step signs
// out every sign-in that never passed one, this device's own too: it signs
// in again with the new one right away, and the recovery codes come after.
//
// One or the other: an account uses passkeys or
// the authenticator app, with its backup codes either way, since Firebase
// holds one TOTP factor per account and the passkeys' bridge is one. Adding
// one where the account has the other asks first. A passkey in the place of
// the authenticator is one request to ZestSSH Cloud (replace_authenticator;
// on Linux and the Mac, zestssh.com asks and does it). The authenticator in
// the place of the passkeys (a phone; a computer sets it up on zestssh.com)
// is begun with Firebase while the passkeys are still there, its code checked
// here first, and only then do they go, just before Firebase finishes; where
// Firebase will not begin while they are there, the person agrees first that
// two-step sign-in is off until they finish (lib/services/account/two_step.dart).
//
// A recovery keeps the synced data only with the account's recovery proof,
// which only a sync password proved on a device can register: a device that
// updated syncs with the key it keeps and never asks for the password again.
// Where ZestSSH Cloud says the account has none, two-step sign-in is on and
// this device syncs to ZestSSH Cloud, a quiet row asks for the sync password
// once, with the reason; "Not now" ends it on
// this device.

/// The two-step rows of the account's Security section: [signedIn], what
/// the account has; signed out, the way to recover an account whose second
/// step is lost.
class TwoStepSection extends ConsumerStatefulWidget {
  const TwoStepSection({super.key, required this.signedIn, this.proveSyncPassword});

  final bool signedIn;

  /// Where this device syncs to ZestSSH Cloud, set up and on: asks for the
  /// sync password as the account page's Sync now does and, once it is
  /// proved, registers the account's recovery proof with its key and waits
  /// for it (lib/services/account/recovery_proof.dart). True then; false where
  /// the person backed out or the password was wrong (which it says). Null
  /// where sync is not on ZestSSH Cloud here: nothing is asked.
  final Future<bool> Function()? proveSyncPassword;

  @override
  ConsumerState<TwoStepSection> createState() => _TwoStepSectionState();
}

class _TwoStepSectionState extends ConsumerState<TwoStepSection> {
  TwoStepState? _state;
  List<PasskeyItem> _passkeys = const [];
  Object? _loadError;
  bool _loading = false;
  bool _loadAgain = false;

  /// The account the state is for.
  String? _loadedFor;

  bool _busy = false;

  /// What the last change did, in words.
  String? _notice;

  /// What went wrong, with its code and what was caught.
  TwoStepProblem? _problem;
  Object? _problemCause;

  /// The authenticator was set up with Firebase, and ZestSSH Cloud could not
  /// be told yet: Try again tells it.
  bool _changedUntold = false;

  /// A recovery this device waits for, while signed out.
  WaitingLockout? _waitingHere;
  bool _waitingRead = false;

  /// "Not now" on the ask for the sync password, just now (kept in the
  /// settings for good).
  bool _proofAskDismissed = false;

  StreamSubscription<void>? _nudges;

  @override
  void initState() {
    super.initState();
    // ZestSSH Cloud says the account's security changed: read it again (a
    // waiting recovery shows at once).
    _nudges = securityNudges.stream.listen((_) {
      if (mounted && widget.signedIn) unawaited(_load());
    });
  }

  @override
  void dispose() {
    unawaited(_nudges?.cancel());
    super.dispose();
  }

  bool get _phone => ref.read(signsInWithFirebaseProvider);
  TwoStepApi get _api => ref.read(twoStepApiProvider);
  TwoStepConfirm get _confirm => ref.read(twoStepConfirmProvider);
  AppLocalizations get _l10n => AppLocalizations.of(context)!;

  // ── Reading it ───────────────────────────────────────────────────

  Future<void> _load() async {
    if (_loading) {
      _loadAgain = true;
      return;
    }
    _loading = true;
    final uid = _loadedFor;
    try {
      final state = await _api.state();
      var passkeys = const <PasskeyItem>[];
      if (state.passkeysAvailable && !state.older && state.passkeys > 0) passkeys = await _api.passkeys();
      if (!mounted || uid != _loadedFor) return;
      setState(() {
        _state = state;
        _passkeys = passkeys;
        _loadError = null;
      });
    } catch (e) {
      AppLogger.warning('Two-step: not read ($e)');
      if (mounted && uid == _loadedFor) setState(() => _loadError = e);
    } finally {
      _loading = false;
      if (_loadAgain && mounted) {
        _loadAgain = false;
        unawaited(_load());
      }
    }
  }

  Future<void> _readWaitingHere() async {
    final waiting = await ref.read(lockoutRecoveryStoreProvider).read();
    if (mounted) setState(() => _waitingHere = waiting);
  }

  // ── Running a change ─────────────────────────────────────────────

  /// Runs [change]; what went wrong is said in the section, with its code.
  Future<void> _run(Future<void> Function() change, {TwoStepDoing doing = TwoStepDoing.changing}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _problem = null;
      _problemCause = null;
    });
    try {
      await change();
    } catch (e) {
      AppLogger.warning('Two-step: a change did not go through ($e)');
      if (mounted) {
        final problem = twoStepProblem(_l10n, e, doing: doing);
        setState(() {
          if (problem.quiet) {
            _notice = problem.text;
          } else {
            _problem = problem;
            _problemCause = e;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted && widget.signedIn) unawaited(_load());
    }
  }

  /// Says what a change did, and how many of the account's other devices it
  /// signed out.
  void _say(String done, {int signedOut = 0, String? more}) {
    if (!mounted) return;
    setState(() {
      _notice = [done, ?more, if (signedOut > 0) _l10n.twoStepSignedOutOthers(signedOut)].join(' ');
    });
  }

  /// Confirms it is the person, for a change that wants a sign-in from the
  /// last few minutes (with the second step where the account has one). A
  /// phone signs in again. A computer signs in in the browser, which hands
  /// over a fresh ID token, and its session is traded for that sign-in: the
  /// token is returned for what Firebase itself is asked to do. Null when it
  /// did not happen; '' on a phone.
  Future<String?> _confirmIt() async {
    if (_phone) return await _confirm.recent(context, ref) ? '' : null;
    if (!await _browserOpensFirst()) return null;
    if (!mounted) return null;
    return _confirm.idToken(context, ref, upgrade: true);
  }

  /// A computer says first that the browser opens to confirm it is
  /// them.
  Future<bool> _browserOpensFirst() async {
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      icon: LucideIcons.globe,
      title: _l10n.stepUpTitle,
      body: _l10n.twoStepBrowserOpens,
      confirmLabel: _l10n.profileContinue,
    );
    return go == true && mounted;
  }

  /// Runs [change]; where ZestSSH Cloud wants a newer sign-in, or a
  /// computer's fresh ID token, confirms it is the person and runs it once
  /// more, with the token where there is one. Null when they backed out.
  Future<T?> _confirmed<T>(Future<T> Function(String? idToken) change) async {
    try {
      return await change(null);
    } on TwoStepRefusal catch (e) {
      if (!mounted || !(e.needsRecentSignIn || e.needsIdToken)) rethrow;
      final token = await _confirmIt();
      if (token == null || !mounted) return null;
      return change(token.isEmpty ? null : token);
    }
  }

  // ── Passkeys ─────────────────────────────────────────────────────

  Future<String?> _askName({required String initial, required String title, required String confirm}) {
    return showZestInputDialog(
      context: context,
      title: title,
      subtitle: _l10n.passkeyNameHelp,
      icon: LucideIcons.fingerprint,
      fieldLabel: _l10n.passkeyNameLabel,
      initialValue: initial,
      maxLength: 64,
      confirmLabel: confirm,
      validator: (v) => cleanPasskeyName(v) == null ? _l10n.passkeyInvalidName : null,
    ).then((v) => v == null ? null : cleanPasskeyName(v));
  }

  /// Asks whether a passkey may replace the account's authenticator app (one
  /// or the other), and why.
  Future<bool> _askReplaceAuthenticator() async {
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.fingerprint,
      title: _l10n.passkeyReplaceAuthenticatorTitle,
      body: _l10n.passkeyReplaceAuthenticatorBody,
      confirmLabel: _l10n.passkeyReplaceAuthenticatorConfirm,
    );
    return go == true && mounted;
  }

  Future<void> _addPasskey(PasskeyWay way) async {
    final state = _state;
    if (state == null) return;
    final first = !state.on;
    // One or the other: the first passkey of an account with the
    // authenticator app replaces it. zestssh.com asks that itself.
    final besideAuthenticator = state.authenticator && state.passkeys == 0;
    var replace = false;
    if (besideAuthenticator && way != PasskeyWay.browser) {
      if (!await _askReplaceAuthenticator()) {
        _say(_l10n.twoStepNothingChanged);
        return;
      }
      replace = true;
    } else if (first) {
      // The first second step: what it does, said before anything happens.
      final go = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.info,
        icon: LucideIcons.fingerprint,
        title: _l10n.passkeyAddTitle,
        body: _l10n.twoStepFirstStepBody,
        confirmLabel: _l10n.profileContinue,
      );
      if (go != true || !mounted) return;
    }
    if (way == PasskeyWay.browser) return _addInBrowser(first: first, replacing: besideAuthenticator);
    final name = await _askName(
      initial: defaultPasskeyName(_l10n),
      title: _l10n.passkeyAddTitle,
      confirm: _l10n.passkeyAddContinue,
    );
    if (name == null || !mounted) return;
    await _run(doing: TwoStepDoing.adding, () => SignInChange.during(() async {
          final platform = ref.read(passkeyPlatformProvider);
          var api = _api;
          String? idToken;
          if (state.passkeys == 0) {
            // The account's first passkey comes with its bridge, which
            // ZestSSH Cloud enrols with a fresh ID token: a phone's own
            // sign-in, from the last five minutes; a computer's from the
            // browser.
            if (_phone) {
              if (!await _confirm.recent(context, ref)) return;
            } else {
              if (!await _browserOpensFirst() || !mounted) return;
              idToken = await _confirm.idToken(context, ref, upgrade: !first);
              if (idToken == null) return;
              // With no second step on the account yet, this computer's
              // session cannot be traded for one with it: the ID token is
              // this change's sign-in.
              if (first) {
                api = api.withBearer(idToken);
                idToken = null;
              }
            }
          }
          if (!mounted) return;
          Future<Map<String, Object?>?> options() => _confirmed((token) {
                if (token != null && idToken == null) idToken = token;
                return api.passkeyOptions(replaceAuthenticator: replace);
              });
          Map<String, Object?>? made;
          try {
            made = await options();
          } on TwoStepRefusal catch (e) {
            // An authenticator app the section did not know of: asked, as above.
            if (!e.authenticatorOn || replace || !mounted) rethrow;
            if (!await _askReplaceAuthenticator()) {
              _say(_l10n.twoStepNothingChanged);
              return;
            }
            replace = true;
            made = await options();
          }
          if (made == null) return;
          final response = await platform.create(made);
          final added = await api.addPasskey(
              response: response, name: name, idToken: idToken, replaceAuthenticator: replace);
          idToken = null;
          if (!mounted) return;
          setState(() {
            _state = added.change.state;
            _passkeys = [..._passkeys.where((p) => p.id != added.passkey.id), added.passkey];
          });
          _say(replace ? _l10n.passkeyReplacedAuthenticator(added.passkey.name) : _l10n.passkeyAdded(added.passkey.name),
              signedOut: added.change.signedOut);
          if (first && added.change.state.on) await _afterFirstStep();
        }));
  }

  /// Adds a passkey on zestssh.com, on a computer whose system makes none
  /// for the app. The page makes the recovery codes where it is the first
  /// second step; then this computer signs in again, with it. Where it
  /// [replacing] the authenticator app (the page asks), the change signed
  /// this computer out (only the page's sign-in stays): it signs in again too.
  Future<void> _addInBrowser({required bool first, bool replacing = false}) async {
    if (!await _browserOpensFirst()) return;
    await _run(doing: TwoStepDoing.adding, () => SignInChange.during(() async {
          if (!mounted) return;
          final added = await _confirm.addPasskeyInBrowser(context, ref);
          if (!mounted) return;
          if (!added) {
            _say(_l10n.passkeyBrowserCancelled);
            return;
          }
          if (first || replacing) {
            // Its first second step signed this computer's own sign-in out
            // (it never passed one), and so did a passkey in the place of the
            // authenticator app: it signs in again, with the new passkey.
            await ZestConfirmDialog.show(
              context,
              // On: the green tick (it was the info tile's).
              tone: ZestDialogTone.success,
              title: _l10n.twoStepOnTitle,
              body: first ? _l10n.twoStepBrowserFirstStepBody : _l10n.twoStepBrowserReplacedBody,
              showCancel: false,
              confirmLabel: _l10n.profileContinue,
            );
            if (!mounted) return;
            if (!await _confirm.recent(context, ref)) {
              if (mounted) setState(() => _problem = TwoStepProblem(_l10n.twoStepFirstStepNoSignIn));
              return;
            }
          }
          _say(_l10n.passkeyBrowserAdded);
        }));
  }

  /// Two-step sign-in just turned on, with this device's change. Its own
  /// sign-in never passed a second step, so it signs in again with the new
  /// one before anything else, and the recovery codes are made and shown.
  Future<void> _afterFirstStep() async {
    if (!mounted) return;
    var passed = false;
    final user = AuthService.currentUser;
    if (user != null) {
      try {
        passed = await TwoStepAccount(user).passedSecondStep();
      } catch (_) {
        passed = false;
      }
    }
    if (!passed && mounted) {
      await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.success,
        title: _l10n.twoStepOnTitle,
        body: _l10n.twoStepFirstStepSignInAgain,
        showCancel: false,
        confirmLabel: _l10n.profileContinue,
      );
      if (!mounted) return;
      if (!await _confirm.recent(context, ref)) {
        if (mounted) setState(() => _problem = TwoStepProblem(_l10n.twoStepFirstStepNoSignIn));
        return;
      }
    }
    if (mounted) await _makeCodes(afterSetup: true);
  }

  Future<void> _rename(PasskeyItem passkey) async {
    final name = await _askName(initial: passkey.name, title: _l10n.passkeyRenameTitle, confirm: _l10n.passkeyRename);
    if (name == null || name == passkey.name || !mounted) return;
    await _run(() async {
      final item = await _confirmed((_) => _api.renamePasskey(passkey.id, name));
      if (item == null || !mounted) return;
      setState(() => _passkeys = [for (final p in _passkeys) p.id == item.id ? item : p]);
      _say(_l10n.passkeyRenamed(item.name));
    });
  }

  Future<void> _removePasskey(PasskeyItem passkey) async {
    final state = _state;
    if (state == null) return;
    final last = state.factors <= 1;
    final lastPasskey = !last && state.passkeys <= 1;
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: _l10n.passkeyRemoveTitle(passkey.name),
      body: last
          ? _l10n.passkeyRemoveLastBody
          : lastPasskey
              ? _l10n.passkeyRemoveLastPasskeyBody
              : _l10n.passkeyRemoveBody,
      confirmLabel: _l10n.passkeyRemove,
    );
    if (go != true || !mounted) return;
    await _run(() async {
      final change = await _confirmed((token) => _api.removePasskey(passkey.id, idToken: token));
      if (change == null || !mounted) return;
      setState(() {
        _state = change.state;
        _passkeys = change.state.on ? [for (final p in _passkeys) if (p.id != passkey.id) p] : const [];
      });
      _say(change.state.on ? _l10n.passkeyRemoved(passkey.name) : _l10n.passkeyRemovedOff(passkey.name),
          more: _l10n.passkeyStaysElsewhere, signedOut: change.signedOut);
    });
  }

  // ── The authenticator app ────────────────────────────────────────

  Future<void> _setUpAuthenticator() async {
    final state = _state;
    if (state == null || ref.read(authenticatorEnrollerProvider)() == null) return;
    final first = !state.on;
    // One or the other: the authenticator app in the place of the passkeys.
    final inPlace = state.passkeys > 0;
    final go = await ZestConfirmDialog.show(
      context,
      tone: inPlace ? ZestDialogTone.neutral : ZestDialogTone.info,
      icon: LucideIcons.shieldCheck,
      title: inPlace ? _l10n.authenticatorReplacePasskeysTitle : _l10n.twoStepSetupTitle,
      body: inPlace
          ? _l10n.authenticatorReplacePasskeysBody
          : first
              ? _l10n.twoStepSetupIntro
              : _l10n.authenticatorSetupIntro,
      confirmLabel: inPlace ? _l10n.authenticatorReplacePasskeysConfirm : _l10n.profileContinue,
    );
    if (go != true || !mounted) {
      if (inPlace && mounted) _say(_l10n.twoStepNothingChanged);
      return;
    }
    final gone = ValueNotifier<bool>(false);
    var removedSignedOut = 0;
    try {
      await _run(() => SignInChange.during(() async {
            // Firebase wants a recent sign-in to add a factor.
            if (!await _confirm.recent(context, ref) || !mounted) return;
            final enroller = ref.read(authenticatorEnrollerProvider)();
            if (enroller == null) return;
            // The passkeys and their bridge go at ZestSSH Cloud: Firebase
            // holds one TOTP factor, and the bridge is it.
            Future<void> removePasskeys() async {
              final change = await _api.removePasskeysForAuthenticator();
              gone.value = true;
              removedSignedOut = change.signedOut;
              if (mounted) {
                setState(() {
                  _state = change.state;
                  _passkeys = const [];
                });
              }
            }

            AuthenticatorSetup? early;
            if (inPlace) {
              final begun = await beginInPlaceOfPasskeys(
                start: enroller.start,
                agreeGap: () async =>
                    mounted &&
                    // Two-step sign-in off meanwhile: its amber sentence.
                    await ZestConfirmDialog.show(
                          context,
                          tone: ZestDialogTone.warning,
                          title: _l10n.authenticatorPasskeysFirstTitle,
                          body: '',
                          warning: _l10n.authenticatorPasskeysFirstBody,
                          confirmLabel: _l10n.authenticatorPasskeysFirstConfirm,
                        ) ==
                        true &&
                    mounted,
                removePasskeys: removePasskeys,
              );
              if (begun == null) {
                _say(_l10n.twoStepNothingChanged);
                return;
              }
              early = begun.setup;
            }
            if (!mounted) return;
            final result = await TwoStepSetupDialog.show(
              context,
              start: () async {
                final made = early;
                early = null;
                return made ?? enroller.start();
              },
              finish: inPlace
                  ? (setup, code) => finishInPlaceOfPasskeys(
                        setup: setup,
                        code: code,
                        passkeysGone: gone.value,
                        removePasskeys: removePasskeys,
                        enroll: enroller.finish,
                      )
                  : enroller.finish,
              canOpenInApp: Platform.isAndroid || Platform.isIOS,
              inPlaceOfPasskeys: inPlace,
              passkeysGone: gone,
            );
            if (!mounted) return;
            if (result != TwoStepSetupResult.done && gone.value) {
              // The passkeys went and the app was not set up: two-step
              // sign-in is off, which the read after this change turns into
              // what ZestSSH Cloud holds (and tells the account).
              setState(() => _problem = TwoStepProblem(_l10n.twoStepLeftOff, code: ErrorCodes.twoStepLeftOff.code));
              return;
            }
            if (result == TwoStepSetupResult.needsSignIn) {
              showTopSnackBar(context, _l10n.twoStepSetupExpired, isError: true);
              return;
            }
            if (result != TwoStepSetupResult.done) return;
            // ZestSSH Cloud is told at once, before anything else (the
            // contract, 7.3): it signs out the devices that never passed a
            // second step and emails the account.
            final change = await _tellChanged();
            if (change == null || !mounted) return;
            _say(inPlace ? _l10n.authenticatorReplacedPasskeys : _l10n.authenticatorOn,
                signedOut: change.signedOut + removedSignedOut);
            if (first && change.state.on) await _afterFirstStep();
          }));
    } finally {
      gone.dispose();
    }
  }

  /// POST /v1/account/two-step/changed: the change, or null where ZestSSH
  /// Cloud could not be told (said, with Try again). A server before 3.3
  /// has no such route, and needs no word.
  Future<TwoStepChange?> _tellChanged() async {
    try {
      final change = await _api.changed();
      if (mounted) setState(() => _changedUntold = false);
      return change;
    } on TwoStepRefusal catch (e) {
      // A server before 3.3 has no such route: what Firebase holds now is
      // the authenticator, set up a moment ago.
      if (e.routeMissing) return const TwoStepChange(TwoStepState(on: true, authenticator: true, older: true));
      AppLogger.warning('Two-step: ZestSSH Cloud was not told of the authenticator ($e)');
      if (mounted) {
        setState(() {
          _changedUntold = true;
          _problem = TwoStepProblem(_l10n.twoStepChangedUntold, code: e.shownCode);
          _problemCause = e;
        });
      }
      return null;
    } catch (e) {
      AppLogger.warning('Two-step: ZestSSH Cloud was not told of the authenticator ($e)');
      if (mounted) {
        setState(() {
          _changedUntold = true;
          _problem = TwoStepProblem(_l10n.twoStepChangedUntold);
          _problemCause = e;
        });
      }
      return null;
    }
  }

  Future<void> _tellAgain() async {
    await _run(() async {
      final change = await _tellChanged();
      if (change != null) _say(_l10n.twoStepChangedTold, signedOut: change.signedOut);
    });
  }

  Future<void> _removeAuthenticator() async {
    final state = _state;
    if (state == null) return;
    final last = state.factors <= 1;
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: _l10n.authenticatorRemoveTitle,
      body: last ? _l10n.authenticatorRemoveLastBody : _l10n.authenticatorRemoveBody,
      confirmLabel: _l10n.authenticatorRemove,
    );
    if (go != true || !mounted) return;
    await _run(() async {
      final change = await _confirmed((token) => _api.removeAuthenticator(idToken: token));
      if (change == null || !mounted) return;
      setState(() {
        _state = change.state;
        if (!change.state.on) _passkeys = const [];
      });
      _say(change.state.on ? _l10n.authenticatorRemoved : _l10n.authenticatorRemovedOff, signedOut: change.signedOut);
    });
  }

  Future<void> _openWeb() async {
    try {
      await launchUrl(Uri.parse(kTwoStepWebPage), mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.warning('Opening the two-step page failed: $e');
      if (mounted) showTopSnackBar(context, _l10n.profileCouldNotOpenBrowser, isError: true, details: '$e');
    }
  }

  // ── Turning it all off ───────────────────────────────────────────

  Future<void> _turnOff() async {
    final state = _state;
    if (state == null) return;
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: _l10n.twoStepTurnOffConfirmTitle,
      body: state.older ? _l10n.twoStepTurnOffConfirmBody : _l10n.twoStepTurnOffAllBody,
      confirmLabel: _l10n.twoStepTurnOff,
    );
    if (go != true || !mounted) return;
    if (state.older) return _turnOffOnOlderServer();
    await _run(() async {
      final change = await _confirmed((_) => _api.turnOff());
      if (change == null || !mounted) return;
      setState(() {
        _state = change.state;
        _passkeys = const [];
      });
      _say(_l10n.twoStepTurnedOff, signedOut: change.signedOut);
    });
  }

  /// A server before 3.3, without DELETE /v1/account/two-step: the way
  /// before, the codes first, then the authenticator with Firebase here. The
  /// bridge is ZestSSH Cloud's and is never removed here.
  Future<void> _turnOffOnOlderServer() async {
    await _run(() async {
      if (!await _confirm.recent(context, ref)) return;
      final user = AuthService.currentUser;
      if (user == null) return;
      try {
        await ref.read(recoveryCodesApiProvider).forget();
      } catch (e) {
        // A code does nothing once no second step is set up, and new codes
        // replace these the next time one is.
        AppLogger.warning('Forgetting recovery codes failed: $e');
      }
      await TwoStepAccount(user).removeAuthenticatorHere();
      await _tellChanged();
      _say(_l10n.twoStepTurnedOff);
    });
  }

  // ── Recovery codes ───────────────────────────────────────────────

  /// Makes ten new recovery codes and shows them once.
  Future<void> _makeCodes({bool afterSetup = false}) async {
    final codesApi = ref.read(recoveryCodesApiProvider);
    List<String>? codes;
    try {
      try {
        codes = await codesApi.make();
      } on RecoveryCodesException catch (e) {
        if (!e.needsRecentSignIn || !mounted) rethrow;
        if (await _confirmIt() == null) return;
        codes = await codesApi.make();
      }
    } catch (e) {
      AppLogger.warning('Making recovery codes failed: $e');
      if (mounted) {
        setState(() {
          _problem = TwoStepProblem(
            e is RecoveryCodesException && e.twoStepOff
                ? _l10n.twoStepOffAlready
                : afterSetup
                    ? _l10n.twoStepCodesFailed
                    : _l10n.twoStepCodesMakeFailed,
            code: e is RecoveryCodesException ? (e.code ?? 'HTTP ${e.status}') : '',
          );
          _problemCause = e;
        });
      }
      return;
    }
    if (!mounted) return;
    final email = ref.read(currentUserProvider)?.email ?? AuthService.currentUser?.email ?? '';
    await showRecoveryCodes(context, codes: codes, email: email);
  }

  Future<void> _newCodes() async {
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.warning,
      title: _l10n.twoStepNewCodesConfirmTitle,
      // The codes kept now stop working: its amber sentence.
      body: '',
      warning: _l10n.twoStepNewCodesConfirmBody,
      confirmLabel: _l10n.twoStepNewCodesConfirm,
    );
    if (ok != true || !mounted) return;
    await _run(() => _makeCodes());
  }

  // ── A recovery someone asked for ─────────────────────────────────

  /// "This wasn't me": the recovery ends at once, with no new sign-in.
  Future<void> _notMe() async {
    await _run(() async {
      final cancelled = await _api.cancelLockoutRecovery();
      if (!mounted) return;
      setState(() => _state = _state?.withoutRecovery());
      ref.read(notificationCenterProvider.notifier).remove(kLockoutNoticeId);
      _say(cancelled ? _l10n.lockoutCancelled : _l10n.lockoutNothingWaiting);
    });
  }

  // ── The recovery proof ───────────────────────────────────────────

  /// Whether to ask for the sync password once, so that a recovery keeps the
  /// account's data: two-step sign-in is on, ZestSSH Cloud says the account
  /// has no recovery proof, this device syncs to ZestSSH Cloud, and the
  /// person did not say "Not now".
  bool _asksForProof(TwoStepState state) =>
      widget.proveSyncPassword != null &&
      state.on &&
      !state.older &&
      !state.recoveryProof &&
      !_proofAskDismissed &&
      !ref.read(settingsServiceProvider).recoveryProofAskDismissed;

  /// "Type it": the sync password, proved as Sync now proves it, registers
  /// the recovery proof; what ZestSSH Cloud holds then is read, and the row
  /// goes once it has the proof.
  Future<void> _proveForRecovery() async {
    final prove = widget.proveSyncPassword;
    if (prove == null) return;
    await _run(() async {
      if (!await prove() || !mounted) return;
      final state = await _api.state();
      if (!mounted) return;
      setState(() => _state = state);
      if (state.recoveryProof) {
        _say(_l10n.recoveryProofAskDone);
      } else {
        setState(() => _problem = TwoStepProblem(_l10n.recoveryProofAskNotKept));
      }
    });
  }

  /// "Not now": not asked again on this device.
  Future<void> _notNowForProof() async {
    setState(() => _proofAskDismissed = true);
    await ref.read(settingsServiceProvider).setRecoveryProofAskDismissed();
  }

  // ── On screen ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!widget.signedIn) return _signedOut(l10n);
    final uid = ref.watch(currentUserProvider)?.uid;
    if (uid != _loadedFor) {
      _loadedFor = uid;
      _state = null;
      _passkeys = const [];
      _loadError = null;
      _notice = null;
      _problem = null;
      _changedUntold = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
    final state = _state;
    final rows = <Widget>[];
    if (state == null && !_phone) {
      // A computer, while it is asked and where it cannot be (ZestSSH Cloud
      // out of reach): the row says where two-step sign-in is managed, with
      // the way there. Nothing here is broken, and no Retry would change
      // where it is set up.
      return _Card(children: [_webRow(l10n, const TwoStepState(on: false, known: false))]);
    }
    if (state == null) {
      final error = _loadError;
      rows.add(_Row(
        key: const ValueKey('two-step-loading'),
        title: l10n.accountTwoStep,
        desc: error == null ? null : twoStepProblem(l10n, error).text,
        trailing: error == null
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : _Button(label: l10n.retry, onTap: _busy ? null : _load),
      ));
      return _Card(children: rows);
    }
    final way = ref.watch(passkeyWayProvider).valueOrNull ?? PasskeyWay.none;
    final enabled = !_busy;
    // A computer and a server before 3.3: as before, the authenticator alone,
    // changed on zestssh.com.
    if (state.older && !_phone) return _Card(children: [_webRow(l10n, state)]);

    rows.add(_Row(
      key: const ValueKey('two-step-status'),
      title: l10n.accountTwoStep,
      titleTrailing: state.on ? _Pill(label: l10n.twoStepStatusOn, color: AppColors.success) : null,
      desc: state.on ? l10n.twoStepSectionOnDesc : l10n.twoStepSectionOffDesc,
      // One or the other, said plainly.
      note: state.older ? null : l10n.twoStepRule,
      trailing: state.on && (!state.older || state.authenticator)
          ? _Button(
              key: const ValueKey('two-step-turn-off'),
              label: l10n.twoStepTurnOff,
              danger: true,
              onTap: enabled ? _turnOff : null)
          : null,
    ));

    // Passkeys, while ZestSSH Cloud has them on: where this device can add
    // one (its own ceremony, or the browser on a computer), or the account
    // has some.
    if (state.passkeysAvailable && !state.older && (way != PasskeyWay.none || _passkeys.isNotEmpty)) {
      final full = _passkeys.length >= 10;
      rows.add(_Row(
        key: const ValueKey('passkeys'),
        title: l10n.passkeysTitle,
        desc: switch (way) {
          // One or the other: a passkey here replaces the authenticator app.
          PasskeyWay.here || PasskeyWay.browser when state.authenticator && _passkeys.isEmpty => l10n.passkeysInsteadDesc,
          PasskeyWay.here => l10n.passkeysDesc,
          PasskeyWay.browser => l10n.passkeysBrowserDesc,
          PasskeyWay.none => l10n.passkeysCannotAddHere,
        },
        trailing: way == PasskeyWay.none
            ? null
            : _Button(
                key: const ValueKey('passkey-add'),
                label: l10n.passkeyAdd,
                onTap: enabled && !full ? () => _addPasskey(way) : null,
              ),
      ));
      for (final p in _passkeys) {
        rows.add(_PasskeyRow(
          key: ValueKey('passkey-${p.id}'),
          passkey: p,
          onRename: enabled ? () => _rename(p) : null,
          onRemove: enabled ? () => _removePasskey(p) : null,
        ));
      }
    }

    rows.add(_authenticatorRow(l10n, state, enabled));

    if (state.on) {
      rows.add(_Row(
        key: const ValueKey('two-step-codes'),
        title: l10n.twoStepCodesRow,
        desc: l10n.twoStepCodesRowDescAny(state.recoveryCodes),
        trailing: _Button(label: l10n.twoStepNewCodes, onTap: enabled ? _newCodes : null),
      ));
    }

    // The sync password, once, so that a recovery keeps the data.
    if (_asksForProof(state)) {
      rows.add(_Row(
        key: const ValueKey('recovery-proof-ask'),
        title: l10n.recoveryProofAskTitle,
        desc: l10n.recoveryProofAskBody,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: const ValueKey('recovery-proof-not-now'),
              onPressed: enabled ? _notNowForProof : null,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurfaceDim,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600),
              ),
              child: Text(l10n.notNow),
            ),
            const SizedBox(width: 6),
            _Button(
              key: const ValueKey('recovery-proof-type'),
              label: l10n.recoveryProofAskAction,
              onTap: enabled ? _proveForRecovery : null,
            ),
          ],
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.lockoutRecovery != null) ...[
          _recoveryBanner(l10n, state.lockoutRecovery!),
          const SizedBox(height: 10),
        ],
        _Card(children: rows),
        if (_busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 8),
          _Message(key: const ValueKey('two-step-notice'), text: _notice!),
        ],
        if (_problem != null) ...[
          const SizedBox(height: 8),
          _ProblemBox(
            problem: _problem!,
            cause: _problemCause,
            onRetry: _changedUntold ? (enabled ? _tellAgain : null) : null,
          ),
        ],
      ],
    );
  }

  Widget _authenticatorRow(AppLocalizations l10n, TwoStepState state, bool enabled) {
    final has = state.authenticator;
    final Widget trailing;
    if (has) {
      trailing = _Button(
        key: const ValueKey('authenticator-remove'),
        label: l10n.authenticatorRemove,
        danger: true,
        onTap: enabled ? (state.older ? _turnOff : _removeAuthenticator) : null,
      );
    } else if (_phone) {
      trailing = _Button(
        key: const ValueKey('authenticator-set-up'),
        // One or the other: in the place of the passkeys.
        label: state.passkeys > 0 ? l10n.authenticatorUseInstead : l10n.twoStepSetUp,
        onTap: enabled ? _setUpAuthenticator : null,
      );
    } else {
      // A computer sets the authenticator up on zestssh.com.
      trailing = _Button(key: const ValueKey('authenticator-web'), label: l10n.twoStepOpenWeb, onTap: _openWeb);
    }
    return _Row(
      key: const ValueKey('authenticator'),
      title: l10n.authenticatorTitle,
      titleTrailing: has ? _Pill(label: l10n.twoStepStatusOn, color: AppColors.success) : null,
      desc: has
          ? l10n.authenticatorOnDesc
          : state.passkeys > 0
              ? (_phone ? l10n.authenticatorInsteadDesc : l10n.authenticatorWebInsteadDesc)
              : _phone
                  ? l10n.authenticatorOffDesc
                  : l10n.authenticatorWebDesc,
      trailing: trailing,
    );
  }

  /// A computer and a server before 3.3: whether it is on, changed on
  /// zestssh.com.
  Widget _webRow(AppLocalizations l10n, TwoStepState state) => _Row(
        key: const ValueKey('two-step-web'),
        title: l10n.accountTwoStep,
        titleTrailing: state.on ? _Pill(label: l10n.twoStepStatusOn, color: AppColors.success) : null,
        desc: !state.known
            ? l10n.twoStepWebManagedDesc
            : state.on
                ? l10n.twoStepWebOnDesc
                : l10n.twoStepWebOffDesc,
        trailing: _Button(label: l10n.twoStepOpenWeb, onTap: _openWeb),
      );

  Widget _recoveryBanner(AppLocalizations l10n, WaitingRecovery waiting) {
    final email = ref.watch(currentUserProvider)?.email;
    final shown = email == null || email.isEmpty ? '' : Redactable.account(email).displayIn(ref);
    final asked = waiting.requestedAt;
    final completes = dayWords(l10n, waiting.completesAt);
    final color = AppColors.error;
    return Container(
      key: const ValueKey('lockout-waiting-banner'),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 17, color: color),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.lockoutWaitingTitle, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                Text(
                  asked == null
                      ? l10n.lockoutWaitingBodyNoDate(shown, completes)
                      : l10n.lockoutWaitingBody(dayWords(l10n, asked), shown, completes),
                  style: TextStyle(fontSize: 11.5, height: 1.55, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  key: const ValueKey('lockout-not-me'),
                  onPressed: _busy ? null : _notMe,
                  style: FilledButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(l10n.lockoutNotMe),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Signed out: two-step sign-in needs an account, and the way to recover
  /// one whose second step is lost (with the recovery this device waits
  /// for, where there is one).
  Widget _signedOut(AppLocalizations l10n) {
    if (!_waitingRead) {
      _waitingRead = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_readWaitingHere());
      });
    }
    final waiting = _waitingHere;
    Future<void> open() async {
      await showLockoutRecovery(context);
      if (mounted) await _readWaitingHere();
    }

    return _Card(children: [
      _Row(
        title: l10n.accountTwoStep,
        desc: l10n.twoStepSectionOffDesc,
        enabled: false,
        titleTrailing: _GatedChip(label: l10n.accountNeedsAccount),
      ),
      if (waiting != null)
        _Row(
          key: const ValueKey('lockout-here'),
          title: waiting.dueAt(DateTime.now()) ? l10n.lockoutDueTitle : l10n.lockoutWaitingSelfTitle,
          desc: l10n.lockoutHereDesc(dayWords(l10n, waiting.completesAt)),
          trailing: _Button(label: l10n.profileContinue, onTap: open),
        )
      else
        _Row(
          key: const ValueKey('lockout-start'),
          title: l10n.lockoutTitle,
          desc: l10n.lockoutLinkDesc,
          trailing: _Button(label: l10n.lockoutStart, onTap: open),
        ),
    ]);
  }
}

/// The id of the notice of a recovery someone asked for.
const kLockoutNoticeId = 'lockout-recovery';

// ── Building blocks, as the account page's ──────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle));
      rows.add(children[i]);
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.title,
    this.desc,
    this.note,
    this.trailing,
    this.titleTrailing,
    this.enabled = true,
  });

  final String title;
  final String? desc;

  /// A line under [desc], quieter.
  final String? note;
  final Widget? trailing;
  final Widget? titleTrailing;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: enabled ? AppColors.onSurface : AppColors.onSurfaceDim,
              ),
            ),
            ?titleTrailing,
          ],
        ),
        if (desc != null) ...[
          const SizedBox(height: 3),
          Text(desc!, style: TextStyle(fontSize: 11.5, height: 1.45, color: AppColors.onSurfaceDim)),
        ],
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(note!,
              key: const ValueKey('two-step-rule'),
              style: TextStyle(fontSize: 11, height: 1.4, fontStyle: FontStyle.italic, color: AppColors.onSurfaceDim)),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: trailing == null ? words : BesideOrUnder(words: words, control: trailing!),
    );
  }
}

/// One passkey: its name, what it is, and Rename and Remove.
class _PasskeyRow extends StatelessWidget {
  const _PasskeyRow({super.key, required this.passkey, this.onRename, this.onRemove});

  final PasskeyItem passkey;
  final VoidCallback? onRename;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 9, 6, 9),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.onSurfaceDim.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              passkey.kind == PasskeyKind.securityKey ? LucideIcons.usb : LucideIcons.fingerprint,
              size: 15,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(passkey.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.onSurface)),
                const SizedBox(height: 2),
                Text(passkeyDetails(l10n, passkey),
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.onSurfaceDim)),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('passkey-rename-${passkey.id}'),
            tooltip: l10n.passkeyRename,
            onPressed: onRename,
            icon: const Icon(LucideIcons.pencil, size: 16),
          ),
          IconButton(
            key: ValueKey('passkey-remove-${passkey.id}'),
            tooltip: l10n.passkeyRemove,
            onPressed: onRemove,
            icon: Icon(LucideIcons.trash2, size: 16, color: onRemove == null ? null : AppColors.error),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.32)),
        ),
        child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      );
}

class _GatedChip extends StatelessWidget {
  const _GatedChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.v3BorderStrong),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.onSurfaceDim)),
      );
}

class _Button extends StatelessWidget {
  const _Button({super.key, required this.label, required this.onTap, this.danger = false});

  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: danger ? AppColors.error : AppColors.onSurface,
          side: BorderSide(color: danger ? AppColors.error.withValues(alpha: 0.5) : AppColors.v3BorderStrong),
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(label),
      );
}

/// What a change did.
class _Message extends StatelessWidget {
  const _Message({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.checkCircle2, size: 15, color: AppColors.success),
            const SizedBox(width: 7),
            Expanded(child: Text(text, style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textSecondary))),
          ],
        ),
      );
}

/// What went wrong: what happened and what to do, its code, Copy details,
/// and Try again where trying again is what there is to do.
class _ProblemBox extends StatelessWidget {
  const _ProblemBox({required this.problem, this.cause, this.onRetry});

  final TwoStepProblem problem;
  final Object? cause;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tone = AppColors.error;
    return Container(
      key: const ValueKey('two-step-problem'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tone.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.alertCircle, size: 15, color: tone),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(problem.text, style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.onSurface)),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (problem.code.isNotEmpty)
                SelectableText(l10n.twoStepErrorCode(problem.code),
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              if (onRetry != null) TextButton(onPressed: onRetry, child: Text(l10n.retry)),
              CopyDetailsButton(
                detail: ErrorReport.build(what: problem.text, where: 'Two-step sign-in', error: cause),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
