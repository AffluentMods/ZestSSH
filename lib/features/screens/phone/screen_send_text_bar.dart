// Remote screens (4.0): Send text, a field along the bottom of a
// phone's remote screen. What is typed, dictated or pasted there is held
// until Send and then typed into the remote as text, which is what a phone's
// keyboard suggestions, dictation and other alphabets need (the hidden field
// behind the soft keyboard sends each key as it is pressed, and loses what a
// keyboard composes). Backspace and Enter beside it are sent at once.
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_keyboard.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

class ScreenSendTextBar extends StatefulWidget {
  const ScreenSendTextBar({
    super.key,
    required this.keyboard,
    this.usScancodes = false,
    this.enabled = true,
    this.autofocus = false,
  });

  final ScreenKeyboard keyboard;

  /// RDP: characters on US keys go as their scancodes
  /// ([ScreenKeyboard.typeText]).
  final bool usScancodes;

  /// False while the screen is only looked at: nothing is sent.
  final bool enabled;
  final bool autofocus;

  @override
  State<ScreenSendTextBar> createState() => _ScreenSendTextBarState();
}

class _ScreenSendTextBarState extends State<ScreenSendTextBar> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  @override
  void dispose() {
    _text
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  void _send() {
    final text = _text.text;
    if (!widget.enabled || text.isEmpty) return;
    widget.keyboard.typeText(text, usScancodes: widget.usScancodes);
    _text.clear();
  }

  void _tap(ScreenKey key) {
    if (widget.enabled) widget.keyboard.tapKey(key);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = widget.enabled;
    final canSend = enabled && _text.text.isNotEmpty;
    Widget key(String id, IconData icon, String tip, VoidCallback onTap) => IconButton(
          key: ValueKey('screen-send-text-$id'),
          tooltip: tip,
          onPressed: enabled ? onTap : null,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          icon: Icon(icon, size: 20, color: enabled ? ZestColors.textPrimary : ZestColors.textMuted),
        );
    return Material(
      key: const ValueKey('screen-send-text'),
      color: ZestColors.chromeElevated,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('screen-send-text-field'),
                controller: _text,
                enabled: enabled,
                autofocus: widget.autofocus,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: TextStyle(color: ZestColors.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.screenSendTextHint,
                  hintStyle: TextStyle(color: ZestColors.textMuted),
                  prefixIcon: Icon(LucideIcons.keyboard, size: 18, color: ZestColors.textMuted),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: const ValueKey('screen-send-text-send'),
              tooltip: l10n.screenSendTextSend,
              onPressed: canSend ? _send : null,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              icon: Icon(LucideIcons.send, size: 20, color: canSend ? AppColors.v3AccentInk : ZestColors.textMuted),
            ),
            key('backspace', LucideIcons.delete, l10n.screenKeyBackspace, () => _tap(ScreenKey.backspace)),
            key('enter', LucideIcons.cornerDownLeft, l10n.screenKeyEnter, () => _tap(ScreenKey.enter)),
          ],
        ),
      ),
    );
  }
}
