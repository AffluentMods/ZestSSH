import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';

/// "Check your browser", over everything while a sign-in waits for the
/// browser, wherever it was started (a spinner
/// alone was easy to miss). It goes by itself once the browser comes back;
/// Open again and Copy link for a browser that did not open or a sign-in
/// finished in another browser (Windows Sandbox, for one,
/// where links open nothing), and Cancel stops the wait. A sign-in
/// handed to the app shows the code zestssh.com asks for.
class BrowserSignInPopup extends StatelessWidget {
  const BrowserSignInPopup({super.key, required this.child, this.onCancel});

  final Widget child;

  /// Stops the wait (tests put their own).
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        ValueListenableBuilder<BrowserSignInPage?>(
          valueListenable: DesktopBrowserSignIn.pending,
          builder: (context, page, _) => page == null
              ? const SizedBox.shrink()
              : Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Center(child: _Card(page: page, onCancel: onCancel ?? DesktopBrowserSignIn.cancel)),
                ),
        ),
      ],
    );
  }
}

class _Card extends StatefulWidget {
  const _Card({required this.page, required this.onCancel});

  final BrowserSignInPage page;
  final VoidCallback onCancel;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final page = widget.page;
    final code = page.signInCode;
    final body = TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.textSecondary);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Material(
        key: const ValueKey('browser-sign-in-popup'),
        elevation: 12,
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandOrange),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(l10n.signInBrowserTitle,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                // A browser that did not open is said at once.
                page.opened ? l10n.signInBrowserWaiting : l10n.signInBrowserNotOpened,
                key: const ValueKey('browser-sign-in-words'),
                style: body,
              ),
              // The code zestssh.com asks for before it signs anything in, so a
              // sign-in another program on this computer started cannot reach it
              // None for a page that hands no sign-in to the app.
              if (code != null) ...[
                const SizedBox(height: 10),
                SelectableText(
                  code,
                  key: const ValueKey('browser-sign-in-code'),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(l10n.signInBrowserCode, key: const ValueKey('browser-sign-in-code-words'), style: body),
              ],
              if (_copied) ...[
                const SizedBox(height: 4),
                Text(l10n.signInBrowserLinkCopied, key: const ValueKey('browser-sign-in-copied'), style: body),
              ],
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    key: const ValueKey('browser-sign-in-open-again'),
                    onPressed: () => launchUrl(page.uri, mode: LaunchMode.externalApplication),
                    icon: const Icon(LucideIcons.externalLink, size: 14),
                    label: Text(l10n.signInBrowserOpenAgain),
                  ),
                  TextButton.icon(
                    key: const ValueKey('browser-sign-in-copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: page.uri.toString()));
                      if (mounted) setState(() => _copied = true);
                    },
                    icon: const Icon(LucideIcons.copy, size: 14),
                    label: Text(l10n.signInBrowserCopyLink),
                  ),
                  TextButton(
                    key: const ValueKey('browser-sign-in-cancel'),
                    onPressed: widget.onCancel,
                    style: TextButton.styleFrom(foregroundColor: AppColors.error),
                    child: Text(l10n.cancel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
