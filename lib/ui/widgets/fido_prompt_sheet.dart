import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart' show dbReadyProvider;
import 'package:zestssh/providers/security_providers.dart' show isAppLockedProvider;
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/fido/fido_signer.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Shows the security key's sheet over whatever is on screen while a
/// conversation with a security key is under way (lib/services/fido/
/// fido_signer.dart): hold the key to the phone or plug it in, touch it,
/// type its PIN. Closing it cancels the conversation.
///
/// It stands at the app's root on a phone and a tablet, beside the other
/// questions a sign-in asks (PhoneSignInQuestions), because a sign-in asks
/// for the key from wherever the person is.
class FidoPromptHost extends ConsumerStatefulWidget {
  const FidoPromptHost({super.key, required this.router, required this.child, this.signer});

  final GoRouter router;
  final Widget child;

  /// The conversation shown; the app's own unless a test gives one.
  final FidoSigner? signer;

  @override
  ConsumerState<FidoPromptHost> createState() => _FidoPromptHostState();
}

class _FidoPromptHostState extends ConsumerState<FidoPromptHost> {
  bool _showing = false;

  FidoSigner get _signer => widget.signer ?? fidoSigner;

  @override
  void initState() {
    super.initState();
    _signer.prompt.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    _signer.prompt.removeListener(_changed);
    super.dispose();
  }

  /// Where the sheet is shown: the navigator's, while the app is open and
  /// not on its lock screen.
  BuildContext? get _at {
    if (!mounted || ref.read(isAppLockedProvider) || !ref.read(dbReadyProvider)) return null;
    final delegate = widget.router.routerDelegate;
    if (delegate.currentConfiguration.uri.path == Routes.securityLock) return null;
    final at = delegate.navigatorKey.currentContext;
    return at != null && at.mounted ? at : null;
  }

  void _changed() {
    if (_showing || _signer.prompt.value == null) return;
    final at = _at;
    if (at == null) {
      // Nowhere to ask (the app is locked): the key is not waited for unseen.
      _signer.cancel();
      return;
    }
    _showing = true;
    final l10n = AppLocalizations.of(at)!;
    _signer.nfcSheetText = l10n.fidoPresentNfcIphone;
    unawaited(showZestModal<void>(
      context: at,
      size: ZestModalSize.compact,
      useRootNavigator: true,
      child: FidoPromptSheet(signer: _signer),
    ).whenComplete(() {
      _showing = false;
      // Closed by the person (a swipe, the scrim, Escape) while the key was
      // still waited for: that is a Cancel.
      if (_signer.prompt.value != null) _signer.cancel();
      // (And the next conversation, where one waited behind this one.)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _changed();
      });
    }));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The sheet itself: what [signer] asks of the person now.
class FidoPromptSheet extends StatefulWidget {
  const FidoPromptSheet({super.key, required this.signer});

  final FidoSigner signer;

  @override
  State<FidoPromptSheet> createState() => _FidoPromptSheetState();
}

class _FidoPromptSheetState extends State<FidoPromptSheet> {
  final TextEditingController _pin = TextEditingController();
  FidoPrompt? _shown;
  String? _said;

  @override
  void initState() {
    super.initState();
    _shown = widget.signer.prompt.value;
    widget.signer.prompt.addListener(_changed);
  }

  @override
  void dispose() {
    widget.signer.prompt.removeListener(_changed);
    // What was typed is not left in the field's memory.
    _pin.clear();
    _pin.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final now = widget.signer.prompt.value;
    if (now == null) {
      // The conversation ended: the sheet goes.
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _shown = now);
  }

  void _submit() {
    final pin = _pin.text;
    if (pin.isEmpty) return;
    _pin.clear();
    widget.signer.submitPin(pin);
  }

  /// What the person is to do, in words.
  static String instruction(AppLocalizations l10n, FidoPrompt p, {required bool iphone}) => switch (p.step) {
        FidoStep.pin => l10n.fidoPinHelp,
        FidoStep.touch => l10n.fidoTouch,
        FidoStep.working => l10n.fidoWorking,
        FidoStep.present => [
            if (p.again) l10n.fidoPresentAgain,
            if (iphone)
              l10n.fidoPresentNfcIphone
            else if (p.ways.nfc && p.ways.nfcOn && p.ways.usb)
              l10n.fidoPresentBoth
            else if (p.ways.nfc && p.ways.nfcOn)
              l10n.fidoPresentNfc
            else
              l10n.fidoPresentUsb,
          ].join(' '),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final p = _shown;
    if (p == null) return const SizedBox.shrink();
    final iphone = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final words = instruction(l10n, p, iphone: iphone);
    // Said to a screen reader as it changes: "Touch your security key" must
    // not wait to be found on the screen.
    if (p.step != FidoStep.pin && words != _said) {
      _said = words;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) zestAnnounce(context, words);
      });
    }
    final pinStep = p.step == FidoStep.pin;
    final wrong = !pinStep
        ? null
        : p.pinWrong
            ? [l10n.fidoPinWrong, if (p.pinTriesLeft != null) l10n.fidoPinTriesLeft(p.pinTriesLeft!)].join(' ')
            : p.pinAgain
                ? l10n.fidoPinAgain
                : null;
    return ZestDialogShell(
      key: const ValueKey('fido-prompt'),
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.fidoSheetTitle,
      subtitle: p.label,
      body: pinStep
          ? ZestTextField(
              key: const ValueKey('fido-pin'),
              controller: _pin,
              label: l10n.fidoPinLabel,
              helperText: l10n.fidoPinHelp,
              errorText: wrong,
              obscureText: true,
              // A PIN is letters and digits as typed: no suggestions, no
              // correction, nothing for a keyboard or a password manager to
              // learn or fill.
              literal: true,
              keyboardType: TextInputType.visiblePassword,
              autofillHints: const [],
              onSubmit: _submit,
            )
          : Row(
              key: ValueKey('fido-step-${p.step.name}'),
              children: [
                if (p.step == FidoStep.working)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  ExcludeSemantics(
                    child: Icon(
                      p.step == FidoStep.touch ? LucideIcons.pointer : LucideIcons.nfc,
                      size: 22,
                      color: ZestTokens.textSecondary,
                    ),
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    words,
                    style: TextStyle(fontSize: 15, height: 1.45, color: ZestTokens.textPrimary),
                  ),
                ),
              ],
            ),
      primaryKey: const ValueKey('fido-pin-continue'),
      primaryAction: pinStep ? (label: l10n.profileContinue, icon: null, onPressed: _submit) : null,
      secondaryKey: const ValueKey('fido-cancel'),
      secondaryAction: (label: l10n.cancel, onPressed: widget.signer.cancel),
    );
  }
}
