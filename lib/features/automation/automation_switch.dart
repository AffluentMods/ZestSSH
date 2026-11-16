/// Turning automation on and off, the one way every switch for it does (3.0;
/// found while comparing the five versions). A phone's switch
/// asked first what turning it on lets in, and was Squeezed's alone; a
/// computer's (its Automation page's engine and the off notice's Turn on)
/// turned it on for anyone with no word, and set the persisted flag alone,
/// which the engine had read once as it started.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Turns automation [on] or off. On is Squeezed's: without it, the upgrade
/// page is opened instead; with it, the person is asked first, in the words
/// that say what it lets in. Returns whether it was changed.
Future<bool> setAutomationOn(BuildContext context, WidgetRef ref, bool on) async {
  if (on) {
    if (!ref.read(isProProvider)) {
      unawaited(GoRouter.of(context).push<void>(Routes.upgrade));
      return false;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.settingsMobEnableExternalAutomationTitle,
      body: l10n.settingsMobExternalAutomationConfirmBody,
      confirmLabel: l10n.commonEnable,
    );
    if (confirmed != true) return false;
  }
  ref.read(automationEnabledProvider.notifier).set(on);
  return true;
}
