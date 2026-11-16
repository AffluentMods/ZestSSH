import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;

/// The pieces every Help form is made of (the bug and suggestion form, the
/// support form, the reply box of a ticket), so a change to the counter, the
/// field or the check row lands on all of them.

/// The six facts that go with a report or a ticket, and whether an account is
/// signed in (which the forms say). Null where the form has gone by the time
/// they are in.
Future<(FeedbackContext, bool)?> collectFeedbackContext(BuildContext context, WidgetRef ref) async {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return null;
  final pro = ref.read(isProProvider);
  final cloud = ref.read(isCloudSyncProvider);
  final tier = pro && cloud
      ? 'bundle'
      : cloud
          ? 'juiced'
          : pro
              ? 'squeezed'
              : 'free';
  final signedIn = (await accountBearer()) != null;
  return (
    FeedbackContext(
      appVersion: info.version,
      build: int.tryParse(info.buildNumber) ?? 0,
      platform: Platform.operatingSystem,
      osVersion: _osVersionLabel(),
      locale: locale,
      tier: tier,
    ),
    signedIn,
  );
}

/// The OS version as a report carries it. Android and Linux report a whole
/// uname line (kernel build, host, date), which says more about the device
/// than "OS version" promises, so only its leading words are kept.
String _osVersionLabel() {
  final raw = Platform.operatingSystemVersion.trim();
  if (!(Platform.isAndroid || Platform.isLinux)) return raw;
  final words = raw.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final short = words.take(3).join(' ');
  return short.length <= 40 ? short : short.substring(0, 40);
}

/// The scroll view keeps this much room above and below a focused field, so
/// bringing a field into view never tucks its label under the pane header.
const EdgeInsets kHelpFieldScrollPadding = EdgeInsets.symmetric(vertical: 56);

/// The label above a field.
Widget helpFormLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.v3TextSecondary)),
    );

InputDecoration helpFormDecoration({String? hint, String? errorText}) {
  OutlineInputBorder border(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c),
      );
  return InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: AppColors.v3TextTertiary),
    errorText: errorText,
    filled: true,
    fillColor: AppColors.v3Surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    border: border(AppColors.v3BorderSubtle),
    enabledBorder: border(AppColors.v3BorderSubtle),
    focusedBorder: border(AppColors.brandOrange),
  );
}

/// The counter of a capped field (fixes spec, section 4): hidden until 80
/// percent of the cap, then the count, warning colour from 95 percent, error
/// colour at the cap.
Widget? helpFormCounter(
  BuildContext context, {
  required int currentLength,
  required int? maxLength,
  required bool isFocused,
}) {
  final max = maxLength ?? 0;
  if (max <= 0 || currentLength < max * 0.8) return null;
  final l10n = AppLocalizations.of(context)!;
  final color = currentLength >= max
      ? AppColors.v3Error
      : currentLength >= max * 0.95
          ? AppColors.v3Warning
          : AppColors.v3TextTertiary;
  return Text(
    l10n.reportCounter(currentLength, max),
    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: color),
  );
}

/// One capped text field with the shared counter.
class HelpFormField extends StatelessWidget {
  const HelpFormField({
    super.key,
    required this.controller,
    required this.maxLength,
    this.focusNode,
    this.minLines = 1,
    this.maxLines = 1,
    this.hint,
    this.errorText,
    this.keyboardType,
    this.enabled = true,
  });

  final TextEditingController controller;
  final int maxLength;
  final FocusNode? focusNode;
  final int minLines;
  final int maxLines;
  final String? hint;
  final String? errorText;
  final TextInputType? keyboardType;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      maxLength: maxLength,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: keyboardType,
      scrollPadding: kHelpFieldScrollPadding,
      buildCounter: helpFormCounter,
      decoration: helpFormDecoration(hint: hint, errorText: errorText),
      style: const TextStyle(fontSize: 13),
    );
  }
}

/// A check box with its label, the whole row tappable.
class HelpCheckRow extends StatelessWidget {
  const HelpCheckRow({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.subtitle,
    this.trailing,
    this.enabled = true,
    this.dense = false,
  });

  final bool value;
  final String label;

  /// A second, quieter line under the label.
  final String? subtitle;
  final Widget? trailing;
  final bool enabled;
  final bool dense;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    // One stop to a screen reader: the box and its words ("Include the app's
    // log, checkbox, checked"), where the box was a checkbox of nothing and
    // its words a second stop; at least 32 high to a pointer.
    return MergeSemantics(
      child: InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minTapTarget(context)),
        child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 0 : 4),
        child: Row(
          crossAxisAlignment: subtitle == null
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: enabled ? onChanged : null,
                activeColor: AppColors.brandOrange,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: subtitle == null
                  ? Text(label, style: const TextStyle(fontSize: 13))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child:
                              Text(label, style: const TextStyle(fontSize: 13)),
                        ),
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            style: TextStyle(
                                fontSize: 11.5,
                                height: 1.35,
                                color: AppColors.v3TextSecondary)),
                      ],
                    ),
            ),
            ?trailing,
          ],
        ),
      ),
      ),
      ),
    );
  }
}

/// A one-line notice with a leading glyph: who can read what is being sent.
class HelpNoticeLine extends StatelessWidget {
  const HelpNoticeLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: AppColors.v3TextTertiary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: AppColors.v3TextSecondary)),
        ),
      ],
    );
  }
}

/// The amber box a form shows when a send did not go through, with whatever
/// the person can do about it underneath.
class HelpFailureBox extends StatelessWidget {
  const HelpFailureBox({super.key, required this.message, this.actions = const []});

  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: const TextStyle(fontSize: 12)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: actions),
          ],
        ],
      ),
    );
  }
}

/// A row that opens and closes what is under it ("See exactly what will be
/// sent"): the same quiet row whether open or closed, only its chevron
/// turning (a text button's fill stayed on it once opened, so open looked
/// like another control than closed).
class HelpDisclosure extends StatelessWidget {
  const HelpDisclosure({super.key, required this.label, required this.open, required this.onToggle});

  final String label;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(6),
        // No fill left behind by a tap: hover and the keyboard's focus only.
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Icon(LucideIcons.chevronRight, size: 14, color: AppColors.v3TextSecondary),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(label, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
