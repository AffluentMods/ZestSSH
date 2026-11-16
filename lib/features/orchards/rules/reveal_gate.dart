import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/security/security_actions.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';

/// Asks this device's person to confirm it is them before a password,
/// passphrase or private key from a Crate that asks again is shown or copied
/// (3.0): the device's own check (its PIN or passcode, a
/// fingerprint or face; Windows Hello; Touch ID), or, on a device without
/// one, the app's PIN. False when they did not confirm, or this device has
/// no way to ask; they are told which. [sending] words it for a secret
/// about to leave the device (sent to a server, or put in a share) rather
/// than shown.
Future<bool> confirmItIsYou(BuildContext context, WidgetRef ref, {bool sending = false, String? destination}) async {
  final l10n = AppLocalizations.of(context)!;
  final auth = ref.read(localAuthProvider);
  var deviceCheck = false;
  try {
    deviceCheck = await auth.isDeviceSupported();
  } catch (_) {
    deviceCheck = false;
  }
  if (deviceCheck) {
    try {
      final ok = await auth
          .authenticate(
            localizedReason: destination != null
                ? l10n.orchardSendToReason(destination)
                : sending
                    ? l10n.orchardSendReason
                    : l10n.orchardRevealReason,
            // The device's PIN counts as well as a fingerprint or face, on
            // every platform (and forcing biometrics hides Windows Hello's
            // own prompt on computers without a sensor).
            options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
          )
          .timeout(const Duration(minutes: 2), onTimeout: () => false);
      if (!ok && context.mounted) showTopSnackBar(context, l10n.orchardRevealNotConfirmed, isWarning: true);
      return ok;
    } on PlatformException catch (e) {
      // No screen lock set up after all: the app's PIN, below.
      final none = e.code == auth_error.notAvailable ||
          e.code == auth_error.notEnrolled ||
          e.code == auth_error.passcodeNotSet;
      if (!none) {
        AppLogger.warning('Orchards: the device could not confirm it is you (${e.code})');
        if (context.mounted) showTopSnackBar(context, l10n.orchardRevealNotConfirmed, isWarning: true);
        return false;
      }
    }
  }
  final lock = ref.read(securityLockServiceProvider);
  if (!await lock.hasPinConfigured()) {
    if (context.mounted) showTopSnackBar(context, l10n.orchardRevealNoWay, isError: true);
    return false;
  }
  if (!context.mounted) return false;
  final pin = await SecurityActions(context, ref).promptForPin(
    title: l10n.orchardRevealTitle,
    body: destination != null
        ? l10n.orchardSendToPinBody(destination)
        : sending
            ? l10n.orchardSendPinBody
            : l10n.orchardRevealPinBody,
    confirmLabel: sending ? l10n.orchardSendContinue : l10n.orchardRevealShow,
  );
  if (pin == null || !context.mounted) return false;
  if (lock.isLockedOut) {
    showTopSnackBar(context, l10n.secSetTooManyAttempts(lock.remainingLockoutSeconds), isError: true);
    return false;
  }
  final ok = await lock.verifyPin(pin);
  if (!ok && context.mounted) showTopSnackBar(context, l10n.orchardRevealNotConfirmed, isError: true);
  return ok;
}

/// Whether the password and private key of the key (identity) [identityId]
/// on screen may go into a share now: at once, unless its Crate asks
/// again; then only once the person confirms it is them ([confirmItIsYou]),
/// before anything secret is read.
Future<bool> mayShareSecretsOf(BuildContext context, WidgetRef ref, String identityId) async {
  if (!await revealAsksAgainNow(ref, identityId)) return true;
  if (!context.mounted) return false;
  return confirmItIsYou(context, ref, sending: true);
}

// ── Asked by a session ──────────────────────────────────────────────────

/// A session's request that the person confirm it is them, before a
/// saved password from a Crate that asks again goes to a host this account
/// may change. A session has no screen of its own: the app answers it on
/// screen ([answerConfirmItIsYouRequests]).
class ConfirmItIsYouRequest {
  ConfirmItIsYouRequest({this.destination});

  /// Where the password goes ("host:port"), said in the question.
  final String? destination;

  final _answer = Completer<bool>();

  /// Whether the person confirmed it is them.
  Future<bool> get answer => _answer.future;

  /// False once answered.
  bool get isOpen => !_answer.isCompleted;

  void reply(bool confirmed) {
    if (isOpen) _answer.complete(confirmed);
  }
}

/// The session's request waiting for the person, if any.
final confirmItIsYouRequestProvider = StateProvider<ConfirmItIsYouRequest?>((ref) => null);

/// How long a session waits for the person: nothing answering counts as no.
const kConfirmItIsYouTimeout = Duration(minutes: 2);

/// Asks the person, through the app's screen, to confirm it is them,
/// for a session connecting to [destination]. Sessions going to the same
/// place that ask while a request is open share its answer, so hosts opened
/// together ask once; one going somewhere else waits its turn and is asked
/// on its own, since the question names where the password goes.
/// False when they do not confirm, when there is no screen to ask on, or
/// when nothing answers in time.
Future<bool> askConfirmItIsYou(Ref ref, {String? destination}) async {
  while (true) {
    final open = ref.read(confirmItIsYouRequestProvider);
    if (open == null || !open.isOpen) break;
    if (open.destination == destination) return open.answer;
    await open.answer;
  }
  final request = ConfirmItIsYouRequest(destination: destination);
  ref.read(confirmItIsYouRequestProvider.notifier).state = request;
  try {
    return await request.answer.timeout(kConfirmItIsYouTimeout, onTimeout: () {
      AppLogger.warning('Orchards: nobody confirmed it is them in time; the password was not sent');
      request.reply(false);
      return false;
    });
  } finally {
    final pending = ref.read(confirmItIsYouRequestProvider.notifier);
    if (identical(pending.state, request)) pending.state = null;
  }
}

/// Answers the sessions' requests to confirm it is them on screen, in
/// the context [navigator] gives (the app's navigator), with the device's
/// own check or the app's PIN. Call it from a build: the app's root does.
void answerConfirmItIsYouRequests(WidgetRef ref, BuildContext? Function() navigator) {
  ref.listen<ConfirmItIsYouRequest?>(confirmItIsYouRequestProvider, (_, request) {
    if (request == null || !request.isOpen) return;
    unawaited(_answer(ref, navigator(), request));
  });
}

Future<void> _answer(WidgetRef ref, BuildContext? context, ConfirmItIsYouRequest request) async {
  var confirmed = false;
  try {
    if (context != null && context.mounted) {
      // The address as recording mode shows hosts: hidden while it is on.
      final destination = request.destination;
      confirmed = await confirmItIsYou(context, ref,
          sending: true, destination: destination == null ? null : Redactable.host(destination).display);
    }
  } catch (e) {
    AppLogger.warning('Orchards: could not ask the person to confirm it is them ($e)');
  } finally {
    request.reply(confirmed);
  }
}
