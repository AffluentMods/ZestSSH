import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Opens a sign-in link in the system's browser: the app's own launcher, or
/// the test's.
@visibleForTesting
Future<bool> Function(Uri link)? debugOpenSignInLink;

Future<bool> _open(Uri link) async {
  final open = debugOpenSignInLink;
  if (open != null) return open(link);
  return launchUrl(link, mode: LaunchMode.externalApplication);
}

/// Shows queued login banners with a link one at a time, until none are
/// left or the caller goes away. Each closes itself once its sign-in is over
/// (done, failed or cancelled); one taken away with its page (the lock
/// screen) stays queued and is shown again at the next pending check.
Future<void> showSignInNotices(
  BuildContext context,
  WidgetRef ref, {
  required bool Function() isMounted,
}) async {
  SignInNoticeRequest? next() => ref.read(signInNoticeProvider);
  var request = next();
  while (request != null && isMounted()) {
    final current = request;
    if (current.isOpen) {
      try {
        await Future.any<void>([
          showSignInLinkDialog(context, current),
          current.cancelled.then((_) {}),
        ]);
      } catch (e) {
        AppLogger.error('Failed to show a sign-in link', e);
      }
      if (current.isOpen) break;
    }
    ref.read(signInNoticeQueueProvider.notifier).remove(current);
    request = next();
  }
}

/// Shows one login banner with a link ([request]) as the app's dialog (a
/// phone's sheet) until its sign-in is over or the person cancels it.
Future<void> showSignInLinkDialog(BuildContext context, SignInNoticeRequest request) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    barrierDismissible: false,
    onDismissAttempt: () async => false,
    useRootNavigator: true,
    child: SignInLinkDialog(request: request),
  );
}

/// A server's login banner that gives its person a link to open before the
/// sign-in goes on (Tailscale SSH's "check" mode): the banner's words as the
/// server's, the host the link goes to, and Open link, which opens it in
/// the system's browser. Only https links are offered, and nothing is opened
/// without the person. The sign-in waits meanwhile (kSignInLinkPatience);
/// Cancel ends it. The dialog closes itself when the sign-in is over.
class SignInLinkDialog extends StatefulWidget {
  const SignInLinkDialog({super.key, required this.request});

  final SignInNoticeRequest request;

  @override
  State<SignInLinkDialog> createState() => _SignInLinkDialogState();
}

class _SignInLinkDialogState extends State<SignInLinkDialog> {
  bool _finished = false;

  /// The last Open link opened nothing (no browser, or it refused).
  bool _notOpened = false;

  @override
  void initState() {
    super.initState();
    // Over (signed in, failed, or cancelled elsewhere): close.
    widget.request.cancelled.then((_) {
      if (!_finished && mounted) _close();
    });
  }

  void _close() {
    _finished = true;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  void _cancel() {
    if (_finished) return;
    widget.request.cancel();
    _close();
  }

  Future<void> _openLink(Uri link) async {
    var opened = false;
    try {
      opened = await _open(link);
    } catch (e) {
      AppLogger.warning('A sign-in link did not open (${errorKind(e)})');
    }
    // Said in the dialog, where the person is looking, with Copy link next to it.
    if (mounted) setState(() => _notOpened = !opened);
  }

  void _copyLink(Uri link) {
    final l10n = AppLocalizations.of(context)!;
    Clipboard.setData(ClipboardData(text: link.toString()));
    showTopSnackBar(context, l10n.signInLinkCopied, isSuccess: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final request = widget.request;
    final notice = request.notice;
    final link = notice.link!;
    final jumpHost = request.jumpHost;
    final secondary = TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary);

    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.externalLink,
      title: l10n.signInLinkTitle,
      maxWidth: 500,
      onClose: _cancel,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RedactedText(
            Redactable.freeText('${request.username}@${request.host}'),
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, color: AppColors.v3TextSecondary),
          ),
          // A jump host on the way: which one, and to where.
          if (jumpHost != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.signInLinkJumpHost(
                Redactable.host(jumpHost).display,
                Redactable.host(request.onward ?? request.host).display,
              ),
              key: const ValueKey('sign-in-link-jump-host'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
            ),
          ],
          const SizedBox(height: 8),
          Text(l10n.signInLinkFromServer, style: secondary),
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('sign-in-link-banner'),
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 180),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: SingleChildScrollView(
              child: RedactedText(
                Redactable.freeText(notice.text),
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: AppColors.v3TextPrimary),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(LucideIcons.globe, size: 15, color: AppColors.v3TextSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  // Recording mode masks the host, as every host it shows.
                  l10n.signInLinkGoesTo(Redactable.host(link.host).display),
                  key: const ValueKey('sign-in-link-host'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            switch (request.purpose) {
              SignInNoticeFor.session => l10n.signInLinkWaiting,
              SignInNoticeFor.run => l10n.signInLinkWaitingRun,
              SignInNoticeFor.test => l10n.signInLinkWaitingTest,
            },
            key: const ValueKey('sign-in-link-waiting'),
            style: secondary,
          ),
          if (_notOpened) ...[
            const SizedBox(height: 12),
            ZestCallout(l10n.signInLinkNotOpened),
          ],
        ],
      ),
      tertiaryAction: (label: l10n.signInLinkCopy, onPressed: () => _copyLink(link)),
      secondaryAction: (label: l10n.cancel, onPressed: _cancel),
      primaryAction: (label: l10n.signInLinkOpen, icon: LucideIcons.externalLink, onPressed: () => _openLink(link)),
    );
  }
}
