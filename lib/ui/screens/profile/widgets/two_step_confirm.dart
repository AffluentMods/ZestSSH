import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/browser_handoff.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';
import 'package:zestssh/ui/widgets/sign_in_again.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';

/// The steps of a change to two-step sign-in that leave the app (3.3): a
/// sign-in again to confirm it is the person, a computer's fresh ID token
/// from the browser, zestssh.com's page that adds a passkey on Linux and the
/// Mac. Each says what went wrong itself and answers false or null then.
/// Tests put their own.
class TwoStepConfirm {
  const TwoStepConfirm();

  /// A sign-in from the last few minutes that passed the second step where
  /// the account has one: a phone signs in again (Firebase asks for the
  /// second step), a computer signs in in the browser and keeps that
  /// session. Also how a device signs in again with the account's first
  /// second step, which signed its sign-in out.
  Future<bool> recent(BuildContext context, WidgetRef ref) => refreshSignIn(context, ref);

  /// A computer's fresh ID token for one change, from the browser
  /// (purpose=id-token), in memory for that change only. With [upgrade],
  /// this computer's session is traded for one of that sign-in (the same
  /// session, now recent and with the second step), so one trip to the
  /// browser serves both. Null when it did not happen.
  Future<String?> idToken(BuildContext context, WidgetRef ref, {bool upgrade = false}) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(twoStepApiProvider);
    final uid = await signedInAccountUid(ref.read(currentUserProvider), ref.read(secureStorageProvider));
    if (uid == null) return null;
    try {
      final address = ref.read(currentUserProvider)?.email?.trim() ?? '';
      final session = await AccountSecret.sessionToken.read(ref.read(secureStorageProvider));
      final token = await handedIdToken(
        api: api,
        accountUid: uid,
        handoff: () => DesktopBrowserSignIn.idTokenHandoff(
          confirm: address.isEmpty ? null : BrowserConfirm(address, way: sessionSignInWay(session)),
        ),
      );
      if (upgrade) {
        try {
          final session = await api.upgradeSession(idToken: token);
          await AccountSecret.sessionToken.write(ref.read(secureStorageProvider), session);
        } on TwoStepRefusal catch (e) {
          // A sign-in without the second step (an account without one yet)
          // cannot be traded for one with it: the token still serves.
          AppLogger.info('Two-step: the session was not upgraded (${e.shownCode})');
        }
      }
      return token;
    } on BrowserSignInCancelled {
      return null;
    } on TimeoutException {
      if (context.mounted) showTopSnackBar(context, l10n.profileSignInTimedOut, duration: const Duration(seconds: 6));
    } catch (e) {
      AppLogger.warning('Two-step: no fresh sign-in from the browser ($e)');
      if (context.mounted) {
        final problem = e is AuthCallbackError ? null : twoStepProblem(l10n, e);
        showTopSnackBar(
          context,
          problem?.text ?? l10n.profileSignInTimedOut,
          isError: true,
          details: '$e',
          duration: const Duration(seconds: 8),
        );
      }
    }
    return null;
  }

  /// Adds a passkey on zestssh.com in the browser, on a computer whose
  /// system makes none for the app: true when one was added.
  Future<bool> addPasskeyInBrowser(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      return await DesktopBrowserSignIn.addPasskeyInBrowser();
    } on BrowserSignInCancelled {
      return false;
    } on TimeoutException {
      if (context.mounted) showTopSnackBar(context, l10n.profileSignInTimedOut, duration: const Duration(seconds: 6));
    } catch (e) {
      AppLogger.warning('Two-step: the browser did not add a passkey ($e)');
      if (context.mounted) {
        showTopSnackBar(context, l10n.profileCouldNotOpenBrowser, isError: true, details: '$e');
      }
    }
    return false;
  }
}

/// The steps of a change to two-step sign-in that leave the app.
final twoStepConfirmProvider = Provider<TwoStepConfirm>((ref) => const TwoStepConfirm());
