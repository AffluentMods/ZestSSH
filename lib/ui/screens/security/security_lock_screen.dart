import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show activeSessionsProvider, SessionStatus;
import 'package:zestssh/services/profiles/profile_boot.dart' show dataStaysAsItIs;
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/security/lock_art.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// The lock screen (4.0): the app's mark,
/// "ZestSSH is locked" and why, one PIN box with its arrow, and the system's own
/// unlock where the lock has it.
///
/// On a computer the PIN box takes the keyboard: Enter or the arrow tries the PIN,
/// a digit typed anywhere goes into the box, Esc clears it, and number pad keys that
/// arrive with Num Lock off say so. Windows Hello (Touch ID on a Mac) is a button,
/// Ctrl+U (Cmd+U on a Mac), and never opens by itself: a prompt that pops up on its
/// own over whatever the person was doing is the system's, not the app's. On a
/// phone or tablet the app's own number pad types the PIN, so the system keyboard
/// never slides up, and Face ID or the fingerprint prompt opens by itself as the
/// lock comes up, with a key on the pad to ask again.
///
/// A wrong PIN shakes the box (not with reduce motion) and says how many wrong PINs
/// are left before the wait, from the durable counter in [SecurityLockService];
/// during the wait it counts down, and biometrics stay allowed. The encrypting lock
/// has no biometric slot: only the PIN unwraps the vault and opens the database, so
/// it offers no biometrics and says why. A right PIN whose vault slot is behind (a
/// PIN change left half done) asks once for the PIN before and heals the slot.
///
/// The screen cannot be dismissed: back is blocked. Where the app's root has the
/// curtain ([LockCurtain]) it draws this screen on its doors, which split open onto
/// the app once the check passes; on its own (a test) it draws the art itself.
class SecurityLockScreen extends ConsumerStatefulWidget {
  const SecurityLockScreen({super.key, this.drawsArt = true});

  /// Whether this screen draws the art behind it. The curtain draws its own, on
  /// the doors.
  final bool drawsArt;

  @override
  ConsumerState<SecurityLockScreen> createState() => _SecurityLockScreenState();
}

/// What the system's unlock is called, and its glyph.
enum _Bio { windowsHello, touchId, faceId, any }

/// How a line under the PIN box reads: a refusal, or a note.
enum _Tone { error, warning }

class _Line {
  const _Line(this.text, this.tone);

  final String text;
  final _Tone tone;
}

class _SecurityLockScreenState extends ConsumerState<SecurityLockScreen> with TickerProviderStateMixin {
  final _pin = TextEditingController();
  final _pinFocus = FocusNode(debugLabel: 'lock-pin');

  /// What the line under the PIN box says, when it says something fixed (the
  /// wait's countdown is worked out as it is drawn).
  _Line? _line;

  /// Keys of the number pad came with Num Lock off (computers).
  bool _numLockOff = false;

  /// The report of data that could not be opened with a right PIN (3.0:
  /// it stood as the PIN field's error, raw, as if the PIN were wrong).
  String? _openFailure;

  /// What stopped it may well pass by itself: Try again is the answer, and setting
  /// the data aside is not offered.
  bool _openFailureMayPass = false;

  /// A biometric prompt is in progress. It never stops the PIN: a prompt that hung
  /// (a Windows Hello dialog that never showed) must not lock the person out.
  bool _biometricInProgress = false;

  /// The last biometric try did not unlock (a phone's glyph turns red).
  bool _biometricFailed = false;

  /// A submitted PIN is being verified right now.
  bool _verifyingPin = false;

  /// What the system's unlock is called here. On an iPhone or iPad it is read from
  /// the system (Face ID or Touch ID).
  _Bio _bio = _Bio.any;

  /// The wait after too many wrong PINs, counted down each second.
  Timer? _waitTicker;

  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 340));
  late final Animation<double> _shakeOffset = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: -9), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -9, end: 8), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 8, end: -5), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -5, end: 3), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 3, end: 0), weight: 1),
  ]).animate(CurvedAnimation(parent: _shake, curve: Curves.easeOut));

  /// A computer, or a phone or tablet: the layout, the keyboard, and whether the
  /// system's unlock opens by itself.
  bool get _touch => isTouchLayout;

  @override
  void initState() {
    super.initState();
    _bio = _bioHere();
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_shown()));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _waitTicker?.cancel();
    _pin.dispose();
    _pinFocus.dispose();
    _shake.dispose();
    super.dispose();
  }

  // ── What is shown ──────────────────────────────────────────────

  /// The lock as it stands: the method and whether the encrypting lock is on.
  ({bool pin, bool bio, bool encrypting}) _lockHere({SecurityLockMethod? method}) {
    final m = method ?? ref.read(lockMethodProvider).valueOrNull ?? SecurityLockMethod.pin;
    // The encrypting lock has no biometric slot: only the PIN can unwrap the
    // database's key, so no biometric is offered while it is on.
    final encrypting = ref.read(settingsServiceProvider).encryptingLockEnabled;
    return (
      pin: encrypting || m == SecurityLockMethod.pin || m == SecurityLockMethod.both,
      bio: !encrypting && (m == SecurityLockMethod.biometric || m == SecurityLockMethod.both),
      encrypting: encrypting,
    );
  }

  /// The system's unlock on this platform: Windows Hello, Touch ID on a Mac, and on
  /// a phone Face ID or Touch ID (an iPhone) or a face or fingerprint (Android).
  _Bio _bioHere() {
    if (!_touch) {
      return switch (defaultTargetPlatform) {
        TargetPlatform.windows => _Bio.windowsHello,
        TargetPlatform.macOS => _Bio.touchId,
        _ => _Bio.any,
      };
    }
    return _Bio.any;
  }

  /// [bio]'s name, as a sentence says it.
  String _bioName(AppLocalizations l10n) => switch (_bio) {
        _Bio.windowsHello => l10n.pinSetupBiometricFactorWindowsHello,
        _Bio.touchId => l10n.pinSetupBiometricFactorTouchId,
        _Bio.faceId => l10n.lockMethodFaceId,
        _Bio.any => l10n.pinSetupBiometricFactorGeneric,
      };

  /// [bio]'s name at the start of a line (under a phone's glyph).
  String _bioLabel(AppLocalizations l10n) => _bio == _Bio.any ? l10n.lockMethodGenericLabel : _bioName(l10n);

  IconData get _bioIcon => switch (_bio) {
        _Bio.windowsHello || _Bio.faceId => LucideIcons.scanFace,
        _Bio.touchId || _Bio.any => LucideIcons.fingerprint,
      };

  /// Ctrl+U, Cmd+U on a Mac: what asks for the system's unlock.
  bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  String get _bioShortcut =>
      formatShortcutKey(ShortcutKey(keyId: LogicalKeyboardKey.keyU.keyId, ctrl: !_mac, meta: _mac));

  /// Why the app locked, as the line under the title says it.
  String _reason(AppLocalizations l10n) {
    final why = ref.read(isAppLockedProvider.notifier).why;
    return switch (why.cause) {
      AppLockCause.started => l10n.lockReasonStarted,
      AppLockCause.byYou => l10n.lockReasonByYou,
      AppLockCause.idle => l10n.lockReasonIdle(why.minutes),
      AppLockCause.away => why.minutes <= 0 ? l10n.lockReasonLeft : l10n.lockReasonAway(why.minutes),
      AppLockCause.slept => l10n.lockReasonSlept,
      AppLockCause.computerLocked => l10n.lockReasonComputerLocked,
    };
  }

  /// Said by the screen reader.
  void _say(String text) {
    if (!mounted) return;
    unawaited(SemanticsService.sendAnnouncement(View.of(context), text, Directionality.of(context)));
  }

  /// Whether this screen is the one in front, with the app locked: no dialog over
  /// it, and not on its way out behind the opening doors.
  bool get _inFront => mounted && ref.read(isAppLockedProvider) && (ModalRoute.of(context)?.isCurrent ?? true);

  /// The lock came up: the screen reader says so, and a phone or tablet asks for
  /// its face or fingerprint (a computer never opens the prompt by itself).
  Future<void> _shown() async {
    SecurityLockMethod method;
    try {
      method = await ref.read(lockMethodProvider.future);
    } catch (_) {
      method = SecurityLockMethod.pin;
    }
    if (!mounted) return;
    final lock = _lockHere(method: method);
    if (_touch && defaultTargetPlatform == TargetPlatform.iOS && lock.bio) {
      try {
        final kinds = await ref.read(securityLockServiceProvider).getAvailableBiometrics();
        if (mounted) setState(() => _bio = kinds.contains(BiometricType.face) ? _Bio.faceId : _Bio.touchId);
      } catch (_) {/* keeps the general name */}
    }
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _say(lock.pin || !lock.bio ? l10n.lockAnnounceLocked : l10n.lockAnnounceLockedMethod(_bioName(l10n)));
    if (_touch && lock.bio && ref.read(isAppLockedProvider)) await _attemptBiometric();
  }

  // ── The system's unlock ────────────────────────────────────────

  Future<void> _attemptBiometric() async {
    if (_biometricInProgress || !mounted) return;
    // The lock method may still be loading on a cold start: its real value, not a
    // stand-in, decides.
    SecurityLockMethod method;
    try {
      method = await ref.read(lockMethodProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final lock = _lockHere(method: method);
    if (!lock.bio) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _biometricInProgress = true;
      _biometricFailed = false;
      if (_line?.tone == _Tone.error && _waitTicker == null) _line = null;
    });
    final outcome = await ref
        .read(securityLockServiceProvider)
        .authenticateWithBiometric(reason: l10n.docCheckBiometricReason);
    if (!mounted) return;
    final name = _bioName(l10n);
    switch (outcome) {
      case BiometricAuthOutcome.success:
        _unlocked();
        ref.read(isAppLockedProvider.notifier).unlock();
        setState(() => _biometricInProgress = false);
        return;
      case BiometricAuthOutcome.lockedOut:
      case BiometricAuthOutcome.unavailable:
        // The sensor cannot unlock right now: the PIN, where there is one.
        final said = lock.pin ? l10n.lockMethodUnavailable(name) : l10n.lockMethodUnavailableNoPin(name);
        setState(() {
          _biometricInProgress = false;
          _biometricFailed = true;
          if (_waitTicker == null) _line = _Line(said, _Tone.error);
        });
        _say(said);
      case BiometricAuthOutcome.failed:
        final said = lock.pin ? l10n.lockMethodFailed(name) : l10n.lockMethodFailedNoPin(name);
        setState(() {
          _biometricInProgress = false;
          _biometricFailed = true;
          if (_waitTicker == null) _line = _Line(said, _Tone.error);
        });
        _say(said);
    }
    if (!_touch && lock.pin && _pinFocus.canRequestFocus) _pinFocus.requestFocus();
  }

  // ── The PIN ────────────────────────────────────────────────────

  bool get _waiting => _waitTicker != null && ref.read(securityLockServiceProvider).isLockedOut;

  /// A digit from the pad, or typed with the box not in focus.
  void _typeDigit(String digit) {
    if (_waiting || _verifyingPin || _pin.text.length >= 32) return;
    setState(() {
      _pin.text = '${_pin.text}$digit';
      _pin.selection = TextSelection.collapsed(offset: _pin.text.length);
      _clearLine();
      _numLockOff = false;
    });
  }

  void _deleteDigit() {
    if (_waiting || _verifyingPin || _pin.text.isEmpty) return;
    setState(() {
      _pin.text = _pin.text.substring(0, _pin.text.length - 1);
      _pin.selection = TextSelection.collapsed(offset: _pin.text.length);
    });
  }

  void _clearPin() {
    setState(() {
      _pin.clear();
      _clearLine();
      _numLockOff = false;
    });
  }

  /// Typing again takes away what was said of the last try (not the wait).
  void _clearLine() {
    if (_waitTicker == null) _line = null;
  }

  /// The box's text changed by typing in it.
  void _typed() => setState(() {
        _clearLine();
        _numLockOff = false;
      });

  /// The check passed: a tick on a phone, and the screen reader says so.
  void _unlocked() {
    haptic(ref, Haptic.selection);
    _say(AppLocalizations.of(context)!.lockAnnounceUnlocked);
  }

  Future<void> _verifyPin() async {
    // Guard against a re-entrant submit (the arrow and Enter), which would count
    // a wrong PIN twice and, with the encrypting lock, race two opens of the
    // database's file.
    if (_verifyingPin) return;
    final service = ref.read(securityLockServiceProvider);
    final l10n = AppLocalizations.of(context)!;

    // A wait under way: no PIN is tried, and it is counted down.
    if (service.isLockedOut) {
      _pin.clear();
      _startWait(say: true);
      return;
    }

    if (_pin.text.length < 4) {
      setState(() => _line = _Line(l10n.lockPinMinLength, _Tone.error));
      _say(l10n.lockPinMinLength);
      return;
    }

    setState(() {
      _verifyingPin = true;
      _line = null;
      _openFailure = null;
    });

    final pin = _pin.text;
    final success = await service.verifyPin(pin);
    if (!mounted) return;

    if (success) {
      // verifyPin passed (a right PIN, no wait). With the encrypting lock the SAME
      // PIN unwraps the vault's key and opens the database; a failure there is an
      // open or migration error, not a wrong PIN, so it is said as such and the
      // app stays locked rather than open over a closed database.
      if (ref.read(settingsServiceProvider).encryptingLockEnabled) {
        try {
          await ref.read(isAppLockedProvider.notifier).unlockVault(pin: pin);
          _unlocked();
          if (mounted) setState(() => _verifyingPin = false);
        } on VaultLockedException {
          // The hash accepted this PIN but the vault's slot rejects it: the two
          // stores desynced (a PIN change that did not reach the vault, or a crash
          // halfway through one). The data is whole under the PREVIOUS PIN: it is
          // asked for once, and the slot moves to this PIN.
          if (mounted) {
            setState(() => _verifyingPin = false);
            await _healVaultPinMismatch(pin);
          }
        } catch (e, stack) {
          if (mounted) {
            setState(() {
              _openFailure = _openFailureReport(l10n, e, stack);
              _openFailureMayPass = dataStaysAsItIs(e);
              _verifyingPin = false;
              _pin.clear();
            });
          }
        }
      } else {
        _unlocked();
        ref.read(isAppLockedProvider.notifier).unlock();
        setState(() => _verifyingPin = false);
      }
      return;
    }

    // A wrong PIN: the box shakes, a phone buzzes, and the line says how many are
    // left before the wait (from the counter that survives a restart), or the
    // wait itself.
    if (!MediaQuery.disableAnimationsOf(context)) unawaited(_shake.forward(from: 0));
    haptic(ref, Haptic.heavy);
    final lockedOut = service.isLockedOut;
    setState(() {
      _pin.clear();
      _verifyingPin = false;
      if (!lockedOut) {
        final left = math.max(1, service.maxAttempts - service.failedAttempts);
        _line = _Line(l10n.lockWrongPinTries(left, SecurityLockService.waitAfter(service.maxAttempts)), _Tone.error);
      }
    });
    if (lockedOut) {
      _startWait(say: true);
    } else {
      _say(_line!.text);
      if (!_touch) _pinFocus.requestFocus();
    }
  }

  /// The wait after too many wrong PINs: the line counts it down each second, the
  /// PIN box is closed until it is over, and biometrics stay allowed.
  void _startWait({required bool say}) {
    _waitTicker?.cancel();
    final service = ref.read(securityLockServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _line = null;
      _waitTicker = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (service.isLockedOut) {
          setState(() {});
          return;
        }
        t.cancel();
        // Over: from now on every wrong PIN starts a wait again, and the line says
        // how long.
        final next = SecurityLockService.waitAfter(service.failedAttempts + 1);
        final over = next > 0 ? l10n.lockWaitOver(next) : l10n.securityLockTryAgainNow;
        setState(() {
          _waitTicker = null;
          _line = _Line(over, _Tone.warning);
        });
        _say(over);
        if (!_touch) _pinFocus.requestFocus();
      });
    });
    if (say) _say(_waitText(l10n, service.remainingLockoutSeconds));
  }

  String _waitText(AppLocalizations l10n, int seconds) {
    final s = math.max(1, seconds);
    return _lockHere().bio ? l10n.lockWaitOrMethod(s, _bioName(l10n)) : l10n.lockWait(s);
  }

  /// Migrate a desynced vault PIN slot: the hash accepted [newPin] but the vault
  /// did not. The previous PIN still opens the vault, so it is asked for once, the
  /// slot is wrapped again to [newPin], and the app unlocks.
  Future<void> _healVaultPinMismatch(String newPin) async {
    final l10n = AppLocalizations.of(context)!;
    final previous = await showZestInputDialog(
      context: context,
      title: l10n.securityLockFinishPinChangeTitle,
      subtitle: l10n.securityLockFinishPinChangeBody,
      icon: LucideIcons.pin,
      fieldLabel: l10n.securityLockPreviousPinLabel,
      confirmLabel: l10n.lockUnlock,
      obscureText: true,
      maxLength: 32,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
    if (previous == null || previous.isEmpty || !mounted) {
      if (mounted) {
        setState(() {
          _line = _Line(l10n.securityLockEnterPreviousPin, _Tone.error);
          _pin.clear();
        });
      }
      return;
    }
    try {
      final vault = ref.read(vaultSlotServiceProvider);
      final vaultKey = await vault.unlockVaultKey(pin: previous);
      // Wrap the slot again to the PIN the hash now expects, then unlock with it.
      await vault.changePin(vaultKey, newPin);
      await ref.read(isAppLockedProvider.notifier).unlockVault(pin: newPin);
      if (mounted) _unlocked();
    } on VaultLockedException {
      if (mounted) {
        setState(() {
          _line = _Line(l10n.securityLockPreviousPinIncorrect, _Tone.error);
          _pin.clear();
        });
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _openFailure = _openFailureReport(l10n, e, stack);
          _openFailureMayPass = dataStaysAsItIs(e);
          _pin.clear();
        });
      }
    }
  }

  /// The profile did not open: another is what the next right PIN opens.
  Future<void> _openOtherProfile() async {
    await ref.read(profileControllerProvider).openOtherAfterFailure();
    if (mounted) setState(() => _openFailure = null);
  }

  /// What did not open goes to a folder of its own, deleting nothing, once the
  /// person has said so: the next right PIN starts fresh.
  Future<void> _setAside() async {
    final l10n = AppLocalizations.of(context)!;
    final sure = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.databaseErrorSetAsideTitle,
      body: l10n.databaseErrorSetAsideBody,
      confirmLabel: l10n.databaseErrorSetAside,
    );
    if (sure != true || !mounted) return;
    try {
      await ref.read(profileControllerProvider).setAsideAfterFailure();
      if (mounted) setState(() => _openFailure = null);
    } catch (e, stack) {
      if (!mounted) return;
      setState(() => _openFailure = ErrorReport.build(
            what: l10n.databaseErrorSetAsideFailed,
            where: 'Setting the data aside',
            error: e,
            stack: stack,
          ));
    }
  }

  /// The report of data that would not open after a right PIN.
  String _openFailureReport(AppLocalizations l10n, Object error, StackTrace stack) => ErrorReport.build(
        what: l10n.securityLockDataNotOpened,
        where: 'Opening the data after unlocking',
        error: error,
        stack: stack,
      );

  // ── The keyboard ───────────────────────────────────────────────

  /// Every key, wherever the focus is: Ctrl+U (Cmd+U on a Mac) asks for the
  /// system's unlock; on a computer a digit typed anywhere goes into the PIN box,
  /// Esc clears it, and number pad keys with Num Lock off say so; on a phone or
  /// tablet with a keyboard, digits, Backspace and Enter work the pad.
  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent || !_inFront) return false;
    final keys = HardwareKeyboard.instance;
    final lock = _lockHere();

    if (event.logicalKey == LogicalKeyboardKey.keyU &&
        (_mac ? keys.isMetaPressed : keys.isControlPressed) &&
        !keys.isShiftPressed &&
        !keys.isAltPressed) {
      if (!lock.bio) return false;
      if (event is KeyDownEvent) unawaited(_attemptBiometric());
      return true;
    }

    final digit = _digitOf(event);
    if (!_touch && digit == null && _numpadKeys.contains(event.physicalKey)) {
      // A number pad key that typed no digit: Num Lock is off.
      if (!_numLockOff) setState(() => _numLockOff = true);
      return false;
    }
    if (!lock.pin || event is! KeyDownEvent) return false;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) return false;

    if (digit != null) {
      if (!_touch && _pinFocus.hasPrimaryFocus) {
        // The box has it already, through the system's typing.
        if (_numLockOff) setState(() => _numLockOff = false);
        return false;
      }
      _typeDigit(digit);
      if (!_touch && !_waiting) _pinFocus.requestFocus();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _clearPin();
      return true;
    }
    if (_touch && event.logicalKey == LogicalKeyboardKey.backspace) {
      _deleteDigit();
      return true;
    }
    if (_touch && (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      unawaited(_verifyPin());
      return true;
    }
    return false;
  }

  static String? _digitOf(KeyEvent event) {
    final c = event.character;
    if (c == null || c.length != 1) return null;
    final unit = c.codeUnitAt(0);
    return unit >= 0x30 && unit <= 0x39 ? c : null;
  }

  static final _numpadKeys = {
    PhysicalKeyboardKey.numpad0,
    PhysicalKeyboardKey.numpad1,
    PhysicalKeyboardKey.numpad2,
    PhysicalKeyboardKey.numpad3,
    PhysicalKeyboardKey.numpad4,
    PhysicalKeyboardKey.numpad5,
    PhysicalKeyboardKey.numpad6,
    PhysicalKeyboardKey.numpad7,
    PhysicalKeyboardKey.numpad8,
    PhysicalKeyboardKey.numpad9,
    PhysicalKeyboardKey.numpadDecimal,
  };

  // ── Drawing ────────────────────────────────────────────────────

  /// The line under the PIN box: the wait's countdown, what was said of the last
  /// try, or the Num Lock note.
  _Line? _lineNow(AppLocalizations l10n) {
    final service = ref.read(securityLockServiceProvider);
    if (_waitTicker != null && service.isLockedOut) {
      return _Line(_waitText(l10n, service.remainingLockoutSeconds), _Tone.error);
    }
    if (_line != null) return _line;
    if (_numLockOff && !_touch) return _Line(l10n.lockNumLockOff, _Tone.warning);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Rebuilt as the lock method loads, the lock state changes and the setting
    // of the sessions line changes.
    ref.watch(lockMethodProvider);
    ref.watch(isAppLockedProvider);
    final lock = _lockHere();
    final showSessions = ref.watch(lockShowSessionsProvider);
    final sessions = showSessions
        ? ref.watch(activeSessionsProvider.select((all) => all.values.where((s) => s.status == SessionStatus.connected).length))
        : 0;

    final body = _touch
        ? _PhoneLayout(screen: this, l10n: l10n, lock: lock, sessions: sessions)
        : _ComputerLayout(screen: this, l10n: l10n, lock: lock, sessions: sessions);

    // Back is blocked: there is no way past the lock screen but the check.
    return PopScope(
      canPop: false,
      child: WindowBarOver(
        child: Scaffold(
          backgroundColor: widget.drawsArt ? ZestTokens.surfacePanel : Colors.transparent,
          resizeToAvoidBottomInset: !_touch,
          body: Stack(
            children: [
              if (widget.drawsArt)
                Positioned.fill(
                  child: ExcludeSemantics(
                    child: LockArt(panel: ZestTokens.surfacePanel, accent: ZestTokens.brand, phone: _touch),
                  ),
                ),
              Positioned.fill(child: body),
            ],
          ),
        ),
      ),
    );
  }

  // ── Parts both layouts share ───────────────────────────────────

  Widget _mark(double size) => ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size / 4),
          child: Image.asset('assets/ZestSSH.png', width: size, height: size, filterQuality: FilterQuality.medium),
        ),
      );

  Widget _title(AppLocalizations l10n) => Semantics(
        header: true,
        child: Text(
          l10n.lockTitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            height: 1.5,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.22,
            color: ZestTokens.textPrimary,
          ),
        ),
      );

  Widget _reasonLine(AppLocalizations l10n) => Text(
        _reason(l10n),
        key: const ValueKey('lock-reason'),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 14, height: 1.5, color: ZestTokens.textFaint),
      );

  /// The arrow inside the PIN box: orange once there is a PIN to try. Its fill and
  /// its ink change together, so the arrow reads on its fill at every step.
  Widget _arrow(AppLocalizations l10n) {
    final ready = _pin.text.isNotEmpty && !_waiting && !_verifyingPin;
    final lit = ready || _verifyingPin;
    return Semantics(
      button: true,
      enabled: ready,
      label: l10n.lockUnlock,
      child: GestureDetector(
        key: const ValueKey('lock-go'),
        behavior: HitTestBehavior.opaque,
        onTap: ready ? () => unawaited(_verifyPin()) : null,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: lit ? 1 : 0),
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
              builder: (context, t, _) {
                final ink = Color.lerp(ZestTokens.textTertiary, ZestTokens.onBrand, t)!;
                return Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Color.lerp(ZestTokens.surfaceSunken, ZestTokens.brand, t),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(color: ink),
                    child: Center(
                      child: _verifyingPin
                          ? const SizedBox(width: 16, height: 16, child: ButtonSpinner())
                          : Icon(LucideIcons.arrowRight, size: 18, color: ink),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The line under the PIN box, as tall when empty as when it says something.
  Widget _lineArea(AppLocalizations l10n, {required double minHeight}) {
    final line = _lineNow(l10n);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.only(top: 9),
        child: line == null
            ? const SizedBox(width: double.infinity)
            : Text(
                line.text,
                key: const ValueKey('lock-message'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: line.tone == _Tone.error ? ZestTokens.statusCritical : ZestTokens.statusWarning,
                ),
              ),
      ),
    );
  }

  /// The PIN was right, the data would not open: said apart from the PIN, with
  /// what stands behind it.
  Widget _openFailurePanel(AppLocalizations l10n) {
    final profiles = ref.read(profileControllerProvider);
    return Container(
      key: const ValueKey('lock-open-failure'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.securityLockDataNotOpened,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.45),
          ),
          CopyDetailsButton(detail: _openFailure!),
          // A profile that cannot open never stops the others.
          if (profiles.canOpenOther)
            TextButton(
              key: const ValueKey('lock-open-other'),
              onPressed: _openOtherProfile,
              child: Text(l10n.databaseErrorOpenOther),
            ),
          if (profiles.canSetAside && !_openFailureMayPass)
            TextButton(
              key: const ValueKey('lock-set-aside'),
              onPressed: _setAside,
              child: Text(l10n.databaseErrorSetAside),
            ),
        ],
      ),
    );
  }

  /// With the encrypting lock: why there is no biometric.
  Widget _onlyPinNote(AppLocalizations l10n) => Container(
        key: const ValueKey('lock-only-pin'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LucideIcons.lock, size: 16, color: ZestTokens.brandInk),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.lockOnlyPinNote,
                style: TextStyle(fontSize: 13.5, height: 1.4, color: ZestTokens.textTertiary),
              ),
            ),
          ],
        ),
      );

  /// "2 sessions still connected": a count, never names (the setting's own).
  Widget _sessionsLine(AppLocalizations l10n, int count) => Row(
        key: const ValueKey('lock-sessions'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: ZestTokens.statusHealthy,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: ZestTokens.statusHealthy.withValues(alpha: 0.25), spreadRadius: 3)],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l10n.lockSessionsConnected(count),
              style: TextStyle(fontSize: 13, height: 1.4, color: ZestTokens.textTertiary),
            ),
          ),
        ],
      );
}

/// A computer's lock: the mark, the title and why, the PIN box with its arrow,
/// the line under it, and Windows Hello or Touch ID as a button with its shortcut.
class _ComputerLayout extends StatelessWidget {
  const _ComputerLayout({required this.screen, required this.l10n, required this.lock, required this.sessions});

  final _SecurityLockScreenState screen;
  final AppLocalizations l10n;
  final ({bool pin, bool bio, bool encrypting}) lock;
  final int sessions;

  @override
  Widget build(BuildContext context) {
    final s = screen;
    return LayoutBuilder(
      builder: (context, box) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: math.min(360, math.max(0, box.maxWidth - 48)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                s._mark(56),
                const SizedBox(height: 16),
                s._title(l10n),
                const SizedBox(height: 4),
                s._reasonLine(l10n),
                const SizedBox(height: 22),
                if (lock.pin) ...[
                  _PinBox(key: const ValueKey('lock-pin-box'), screen: s, l10n: l10n),
                  s._lineArea(l10n, minHeight: 42),
                  if (s._openFailure != null) s._openFailurePanel(l10n),
                ],
                if (lock.bio)
                  _BiometricButton(
                    label: l10n.lockUnlockWith(s._bioName(l10n)),
                    icon: s._bioIcon,
                    shortcut: s._bioShortcut,
                    onPressed: () => unawaited(s._attemptBiometric()),
                  )
                else if (lock.encrypting)
                  s._onlyPinNote(l10n),
                if (!lock.pin) s._lineArea(l10n, minHeight: 42),
                if (sessions > 0) ...[
                  const SizedBox(height: 22),
                  s._sessionsLine(l10n, sessions),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A computer's PIN box: a real text field (a Windows tablet's touch keyboard
/// types into it), the dots large, the arrow inside, a ring while it has the
/// keyboard, shaken by a wrong PIN.
class _PinBox extends StatelessWidget {
  const _PinBox({super.key, required this.screen, required this.l10n});

  final _SecurityLockScreenState screen;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final s = screen;
    final waiting = s._waiting;
    return AnimatedBuilder(
      animation: s._shakeOffset,
      builder: (context, child) => Transform.translate(offset: Offset(s._shakeOffset.value, 0), child: child),
      child: ListenableBuilder(
        listenable: s._pinFocus,
        builder: (context, _) {
          final focused = s._pinFocus.hasFocus && !waiting;
          return Opacity(
            opacity: waiting ? 0.55 : 1,
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                color: ZestTokens.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: focused ? ZestTokens.brand : ZestTokens.border),
                boxShadow: focused ? [BoxShadow(color: ZestTokens.brand.withValues(alpha: 0.16), spreadRadius: 3)] : null,
              ),
              child: Stack(
                children: [
                  // The placeholder, drawn apart from the field so that it sits in
                  // the middle of the box at its own size (the field's line is the
                  // dots' height); the field itself gives it to a screen reader.
                  // Always in the stack, hidden once a digit is typed: the field
                  // after it keeps its place, and with it its caret and keyboard.
                  Positioned.fill(
                    left: 16,
                    right: 56,
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: Visibility(
                          visible: s._pin.text.isEmpty,
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              l10n.lockPinPlaceholder,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 15, color: ZestTokens.textTertiary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // The dots: GeistSans' bullet at 33, 8 across and 16 apart, the
                  // first 16 in (half the letter spacing and a hair of the glyph's
                  // own width come before it) and on the box's middle line.
                  Positioned.fill(
                    left: 12,
                    right: 56,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: MediaQuery.withNoTextScaling(
                        // The dots are no text to read: the same size at any text
                        // size, so the box keeps its height.
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 3.6),
                          child: TextField(
                            key: const ValueKey('lock-pin'),
                            controller: s._pin,
                            focusNode: s._pinFocus,
                            enabled: !waiting,
                            autofocus: true,
                            obscureText: true,
                            obscuringCharacter: '•',
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            enableInteractiveSelection: false,
                            enableSuggestions: false,
                            autocorrect: false,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(32),
                            ],
                            style: TextStyle(
                              fontFamily: 'GeistSans',
                              fontSize: 33,
                              height: 1,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 5.1,
                              color: ZestTokens.textPrimary,
                            ),
                            cursorColor: ZestTokens.brand,
                            cursorWidth: 2,
                            cursorHeight: 22,
                            cursorRadius: const Radius.circular(1),
                            // The box is the field: nothing of the theme's fields (their
                            // fill, their border). A hint no one sees, for the screen
                            // reader's name of the field.
                            decoration: InputDecoration(
                              isCollapsed: true,
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              hintText: l10n.lockPinPlaceholder,
                              hintStyle: const TextStyle(fontSize: 15, color: Colors.transparent),
                            ),
                            onChanged: (_) => s._typed(),
                            // Enter tries the PIN and the box keeps the keyboard.
                            onEditingComplete: () {},
                            onSubmitted: (_) => unawaited(s._verifyPin()),
                          ),
                        ),
                      ),
                    ),
                  ),
                  PositionedDirectional(top: 1, end: 1, child: s._arrow(l10n)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Windows Hello or Touch ID on a computer: a button, with its shortcut beside
/// the words. It never opens the prompt by itself.
class _BiometricButton extends StatefulWidget {
  const _BiometricButton({required this.label, required this.icon, required this.shortcut, required this.onPressed});

  final String label;
  final IconData icon;
  final String shortcut;
  final VoidCallback onPressed;

  @override
  State<_BiometricButton> createState() => _BiometricButtonState();
}

class _BiometricButtonState extends State<_BiometricButton> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // One node for a screen reader: its name, and the tap that the parts below
    // would have given it (they are left out, so it is not read twice).
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: FocusableActionDetector(
        onShowHoverHighlight: (on) => setState(() => _hover = on),
        onShowFocusHighlight: (on) => setState(() => _focused = on),
        mouseCursor: SystemMouseCursors.click,
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed())},
        child: GestureDetector(
          key: const ValueKey('lock-biometric'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            height: 46,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _hover ? ZestTokens.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused
                    ? ZestTokens.brand
                    : (_hover ? Color.lerp(ZestTokens.border, ZestTokens.brand, 0.4)! : ZestTokens.border),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 18, color: ZestTokens.brandInk),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, color: ZestTokens.textPrimary),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                  decoration: BoxDecoration(
                    color: ZestTokens.surfaceSunken,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: ZestTokens.border),
                  ),
                  child: Text(
                    widget.shortcut,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w500,
                      color: ZestTokens.textFaint,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A phone's or tablet's lock: the mark, the title and why, Face ID or the
/// fingerprint (or why there is none), the PIN as dots, and the app's own number
/// pad, so the system keyboard never slides up. A tablet keeps it all together in
/// the middle; a phone on its side puts the pad beside the rest.
class _PhoneLayout extends StatelessWidget {
  const _PhoneLayout({required this.screen, required this.l10n, required this.lock, required this.sessions});

  final _SecurityLockScreenState screen;
  final AppLocalizations l10n;
  final ({bool pin, bool bio, bool encrypting}) lock;
  final int sessions;

  @override
  Widget build(BuildContext context) {
    final s = screen;
    return SafeArea(
      child: LayoutBuilder(builder: (context, box) {
        final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;
        final sideways = !tablet && box.maxWidth > box.maxHeight;
        final compact = !tablet && box.maxHeight < 700;
        final keyHeight = compact ? 56.0 : 60.0;
        final gap = compact ? 10.0 : 14.0;

        final head = <Widget>[
          s._mark(compact ? 44 : 52),
          SizedBox(height: gap),
          s._title(l10n),
          const SizedBox(height: 4),
          s._reasonLine(l10n),
          SizedBox(height: gap),
          if (lock.bio)
            _Scan(screen: s, l10n: l10n, tappable: !lock.pin, compact: compact)
          else if (lock.encrypting)
            s._onlyPinNote(l10n),
          if (lock.bio || lock.encrypting) SizedBox(height: gap),
          if (lock.pin) ...[
            _PinDots(screen: s, l10n: l10n),
            s._lineArea(l10n, minHeight: compact ? 34 : 42),
            if (s._openFailure != null) s._openFailurePanel(l10n),
          ] else
            s._lineArea(l10n, minHeight: compact ? 34 : 42),
        ];
        final pad = lock.pin ? _Pad(screen: s, l10n: l10n, bio: lock.bio, keyHeight: keyHeight) : null;
        final sessionsLine = sessions > 0 ? s._sessionsLine(l10n, sessions) : null;

        if (tablet) {
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: math.min(380, math.max(0, box.maxWidth - 48)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ...head,
                  if (sessionsLine != null) ...[sessionsLine, const SizedBox(height: 16)],
                  ?pad,
                ]),
              ),
            ),
          );
        }
        if (sideways) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: Row(children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ...head,
                      ?sessionsLine,
                    ]),
                  ),
                ),
              ),
              if (pad != null) ...[
                const SizedBox(width: 24),
                Expanded(child: Center(child: SingleChildScrollView(child: pad))),
              ],
            ]),
          );
        }
        // Upright: the head at the top, the pad at the bottom within the thumb's
        // reach, and the space between. Where the head needs more than its room
        // (a short phone, a large text size) it scrolls; the pad never moves.
        return Padding(
          padding: EdgeInsets.fromLTRB(22, (box.maxHeight * 0.06).clamp(12, 56), 22, compact ? 12 : 24),
          child: Column(children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: head)),
              ),
            ),
            if (sessionsLine != null) ...[sessionsLine, const SizedBox(height: 14)],
            ?pad,
          ]),
        );
      }),
    );
  }
}

/// Face ID or the fingerprint on a phone: its glyph and its name, pulsing while
/// the system's prompt is up (still with reduce motion), red once it failed. With
/// no PIN it is the button that asks again; otherwise the pad's key is.
class _Scan extends StatefulWidget {
  const _Scan({required this.screen, required this.l10n, required this.tappable, required this.compact});

  final _SecurityLockScreenState screen;
  final AppLocalizations l10n;
  final bool tappable;
  final bool compact;

  @override
  State<_Scan> createState() => _ScanState();
}

class _ScanState extends State<_Scan> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.screen;
    final busy = s._biometricInProgress;
    final still = MediaQuery.disableAnimationsOf(context);
    if (busy && !still) {
      if (!_pulse.isAnimating) unawaited(_pulse.repeat(reverse: true));
    } else if (_pulse.isAnimating || _pulse.value != 0) {
      _pulse
        ..stop()
        ..value = 0;
    }
    final color = s._biometricFailed ? ZestTokens.statusCritical : ZestTokens.brandInk;
    final glyph = AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Opacity(
        opacity: 1 - 0.65 * _pulse.value,
        child: Transform.scale(scale: 1 - 0.08 * _pulse.value, child: child),
      ),
      child: Icon(s._bioIcon, size: 36, color: color),
    );
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: widget.compact ? 52 : 62, minWidth: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          const SizedBox(height: 4),
          Text(
            s._bioLabel(widget.l10n),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.3, color: ZestTokens.textFaint),
          ),
        ],
      ),
    );
    if (!widget.tappable) return ExcludeSemantics(child: content);
    return Semantics(
      button: true,
      label: widget.l10n.lockUseMethod(s._bioName(widget.l10n)),
      onTap: () => unawaited(s._attemptBiometric()),
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('lock-biometric'),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(s._attemptBiometric()),
        child: content,
      ),
    );
  }
}

/// A phone's PIN: a dot per digit typed on the pad, the arrow inside.
class _PinDots extends StatelessWidget {
  const _PinDots({required this.screen, required this.l10n});

  final _SecurityLockScreenState screen;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final s = screen;
    final count = s._pin.text.length;
    return AnimatedBuilder(
      animation: s._shakeOffset,
      builder: (context, child) => Transform.translate(offset: Offset(s._shakeOffset.value, 0), child: child),
      child: Opacity(
        opacity: s._waiting ? 0.55 : 1,
        child: Container(
          key: const ValueKey('lock-pin'),
          height: 50,
          decoration: BoxDecoration(
            color: ZestTokens.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZestTokens.border),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                left: 16,
                right: 56,
                child: Semantics(
                  label: count == 0 ? l10n.lockPinNothingTyped : l10n.lockPinDigitsTyped(count),
                  excludeSemantics: true,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: count == 0
                        ? Text(
                            l10n.lockPinPlaceholder,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, color: ZestTokens.textTertiary),
                          )
                        : ClipRect(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var i = 0; i < count; i++)
                                  Padding(
                                    padding: EdgeInsetsDirectional.only(end: i == count - 1 ? 0 : 10),
                                    child: Container(
                                      width: 11,
                                      height: 11,
                                      decoration: BoxDecoration(color: ZestTokens.textPrimary, shape: BoxShape.circle),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
              PositionedDirectional(top: 0, end: 0, child: s._arrow(l10n)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The app's own number pad, 3 by 4: 1 to 9, then the system's unlock (or a
/// blank), 0 and delete. Keys at least 56 high.
class _Pad extends StatelessWidget {
  const _Pad({required this.screen, required this.l10n, required this.bio, required this.keyHeight});

  final _SecurityLockScreenState screen;
  final AppLocalizations l10n;
  final bool bio;
  final double keyHeight;

  @override
  Widget build(BuildContext context) {
    final s = screen;
    final closed = s._waiting || s._verifyingPin;
    Widget digit(String d) => _PadKey(
          key: ValueKey('lock-key-$d'),
          label: d,
          height: keyHeight,
          onTap: closed ? null : () => s._typeDigit(d),
          child: Text(
            d,
            style: TextStyle(fontSize: 24, height: 1, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
          ),
        );
    Widget row(List<Widget> keys) => Row(children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: keys[i]),
          ],
        ]);
    final gap = keyHeight < 60 ? 8.0 : 12.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([digit('1'), digit('2'), digit('3')]),
        SizedBox(height: gap),
        row([digit('4'), digit('5'), digit('6')]),
        SizedBox(height: gap),
        row([digit('7'), digit('8'), digit('9')]),
        SizedBox(height: gap),
        row([
          bio
              ? _PadKey(
                  key: const ValueKey('lock-key-biometric'),
                  label: l10n.lockUseMethod(s._bioName(l10n)),
                  height: keyHeight,
                  ghost: true,
                  onTap: () => unawaited(s._attemptBiometric()),
                  child: Icon(s._bioIcon, size: 26, color: ZestTokens.brandInk),
                )
              : SizedBox(height: keyHeight),
          digit('0'),
          _PadKey(
            key: const ValueKey('lock-key-delete'),
            label: l10n.lockDeleteDigit,
            height: keyHeight,
            ghost: true,
            onTap: closed ? null : s._deleteDigit,
            onLongPress: closed ? null : s._clearPin,
            child: Icon(LucideIcons.delete, size: 26, color: ZestTokens.brandInk),
          ),
        ]),
      ],
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({
    super.key,
    required this.label,
    required this.height,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.ghost = false,
  });

  final String label;
  final double height;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    // One node for a screen reader, with the key's tap (and the delete key's
    // long press) on it: the ink below is left out.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Material(
          color: ghost ? Colors.transparent : ZestTokens.surfaceRaisedAlt,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            splashColor: ZestTokens.brandSubtle,
            highlightColor: ZestTokens.brandSubtle,
            child: SizedBox(height: height, child: Center(child: child)),
          ),
        ),
      ),
    );
  }
}
