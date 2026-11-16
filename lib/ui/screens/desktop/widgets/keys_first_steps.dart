import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/ui/widgets/phone_list.dart' show PhoneListCard;
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/utils/help_links.dart';

// The Keys page with nothing saved (4.0).
// It was one faint key, "No keys yet" and one
// orange button that did what the orange New key beside the title did, while
// the real ways to add a key hid in that button's menu. Now: what a key is
// for, a link to the docs' page on SSH keys, and one card for each real first
// step, each opening what the page's New key menu opens (generate, import, the
// SSH agent, a password manager), with only the recommended one in the brand's
// colour; and the line for a host that signs in with a password. A phone has
// the same choices as a list (no SSH agent or password manager tools there).

/// One way to start: what it is, a line on it, and what it does.
class KeysFirstStep {
  const KeysFirstStep({
    required this.id,
    required this.icon,
    required this.title,
    required this.body,
    required this.go,
    required this.onTap,
    this.recommended = false,
  });

  /// For tests and the keys of its widgets: `keys-first-<id>`.
  final String id;
  final IconData icon;
  final String title;

  /// The line under the title; `.pem` and `.ppk` in it are drawn as code.
  final String body;

  /// The card's action line (a computer's).
  final String go;
  final VoidCallback onTap;

  /// The one card in the brand's colour, with its Recommended tag.
  final bool recommended;
}

/// The docs' page on SSH keys, in the browser. A test sets [debugOpenPage]
/// to see it asked for.
Future<void> openWhatIsAnSshKey() async {
  final page = Uri.parse(kZestDocsWhatIsAnSshKey);
  final open = KeysFirstSteps.debugOpenPage;
  if (open != null) return open(page);
  await launchUrl(page, mode: LaunchMode.externalApplication);
}

/// A computer's Keys page with nothing saved: the heading, what a key is for,
/// What is an SSH key?, the ways to start as cards (two to a row where they
/// fit), and the line for hosts that sign in with a password.
class KeysFirstSteps extends StatelessWidget {
  const KeysFirstSteps({
    super.key,
    required this.onGenerate,
    required this.onImport,
    required this.onNewPassword,
    this.onAgent,
    this.onPasswordManager,
    this.takesDrops = false,
  });

  /// Stands in for the browser in a test.
  static Future<void> Function(Uri page)? debugOpenPage;

  final VoidCallback onGenerate;
  final VoidCallback onImport;
  final VoidCallback onNewPassword;

  /// Null where there is no SSH agent to use (no card).
  final VoidCallback? onAgent;

  /// Null where no password manager's tools run (no card).
  final VoidCallback? onPasswordManager;

  /// The page takes a key file dropped on it: the import card says so.
  final bool takesDrops;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final steps = keysFirstSteps(
      l10n,
      onGenerate: onGenerate,
      onImport: onImport,
      onAgent: onAgent,
      onPasswordManager: onPasswordManager,
      takesDrops: takesDrops,
    );
    return LayoutBuilder(builder: (context, box) {
      const gap = 14.0;
      const side = 24.0;
      final room = math.max(0.0, box.maxWidth - 2 * side);
      // Two to a row where each keeps 300 for its words; else one.
      final two = room >= 2 * 300 + gap;
      final cardWidth = two ? math.min(404.0, (room - gap) / 2) : math.min(room, 520.0);
      final width = two ? 2 * cardWidth + gap : cardWidth;
      final top = box.maxHeight.isFinite ? (box.maxHeight * 0.12).clamp(24.0, 92.0) : 48.0;
      return SingleChildScrollView(
        key: const ValueKey('keys-first-steps'),
        padding: EdgeInsets.fromLTRB(side, top, side, 32),
        child: Center(
          child: SizedBox(
            width: width,
            child: Column(
              children: [
                const _Hero(),
                const SizedBox(height: 30),
                for (var i = 0; i < steps.length; i += two ? 2 : 1) ...[
                  if (i > 0) const SizedBox(height: gap),
                  if (two)
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: cardWidth, child: _StepCard(step: steps[i])),
                          const SizedBox(width: gap),
                          SizedBox(
                            width: cardWidth,
                            child: i + 1 < steps.length ? _StepCard(step: steps[i + 1]) : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    )
                  else
                    _StepCard(step: steps[i]),
                ],
                const SizedBox(height: 24),
                _PasswordLine(onNewPassword: onNewPassword),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// The ways to start, in the order the page shows them: generate (the one
/// recommended), import, the SSH agent, a password manager; the last two only
/// where they are given.
List<KeysFirstStep> keysFirstSteps(
  AppLocalizations l10n, {
  required VoidCallback onGenerate,
  required VoidCallback onImport,
  VoidCallback? onAgent,
  VoidCallback? onPasswordManager,
  bool takesDrops = false,
}) =>
    [
      KeysFirstStep(
        id: 'generate',
        icon: LucideIcons.sparkle,
        title: l10n.keysFirstGenerateTitle,
        body: l10n.keysFirstGenerateBody,
        go: l10n.keysFirstGenerateGo,
        onTap: onGenerate,
        recommended: true,
      ),
      KeysFirstStep(
        id: 'import',
        icon: LucideIcons.import,
        title: l10n.keysFirstImportTitle,
        body: takesDrops ? _sentences(l10n.keysFirstImportBody, l10n.keysFirstImportDrop) : l10n.keysFirstImportBody,
        go: l10n.keysFirstImportGo,
        onTap: onImport,
      ),
      if (onAgent != null)
        KeysFirstStep(
          id: 'agent',
          icon: LucideIcons.cpu,
          title: l10n.keysFirstAgentTitle,
          body: l10n.keysFirstAgentBody,
          go: l10n.keysFirstAgentGo,
          onTap: onAgent,
        ),
      if (onPasswordManager != null)
        KeysFirstStep(
          id: 'pm',
          icon: LucideIcons.archive,
          title: l10n.keysUiFromPasswordManager,
          body: l10n.keysFirstPmBody,
          go: l10n.pmAddFrom,
          onTap: onPasswordManager,
        ),
    ];

/// Two sentences as one line: a space between them, but none after a
/// sentence that ends in a full-width mark (Chinese and Japanese write none).
String _sentences(String first, String second) =>
    RegExp('[　-〿＀-￯]\$').hasMatch(first) ? '$first$second' : '$first $second';

/// The key in its tile, the heading, the line under it and What is an SSH
/// key?.
class _Hero extends StatelessWidget {
  const _Hero({this.phone = false});

  final bool phone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: ZestTokens.surfaceChip, borderRadius: BorderRadius.circular(14)),
          child: Icon(LucideIcons.keyRound, size: 26, color: ZestTokens.textSecondary),
        ),
        const SizedBox(height: 18),
        Semantics(
          header: true,
          child: Text(
            l10n.keysFirstTitle,
            key: const ValueKey('keys-first-title'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: phone ? 20 : 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              height: 1.25,
              color: ZestTokens.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.keysFirstLead,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.45, color: ZestTokens.textFaint),
        ),
        SizedBox(height: phone ? 4 : 10),
        _DocsLink(phone: phone),
      ],
    );
  }
}

/// What is an SSH key?: a link, as a screen reader says it, to the docs'
/// page in the browser.
class _DocsLink extends StatefulWidget {
  const _DocsLink({required this.phone});

  final bool phone;

  @override
  State<_DocsLink> createState() => _DocsLinkState();
}

class _DocsLinkState extends State<_DocsLink> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    // (The page is the docs site's: a build with none has no link.)
    if (kZestDocsWhatIsAnSshKey == '') return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final ink = _hover || _focus ? ZestTokens.textPrimary : ZestTokens.textSecondary;
    return Semantics(
      link: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            openWhatIsAnSshKey();
            return null;
          }),
        },
        child: GestureDetector(
          key: const ValueKey('keys-first-what-is-key'),
          behavior: HitTestBehavior.opaque,
          onTap: openWhatIsAnSshKey,
          child: Container(
            // A finger's target on a phone; a link's on a computer.
            constraints: BoxConstraints(minHeight: widget.phone ? 48 : 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _focus ? ZestTokens.brand : Colors.transparent, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.helpCircle, size: 15, color: ZestTokens.textTertiary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    l10n.keysFirstWhatIsKey,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: ink,
                      decoration: _hover ? TextDecoration.underline : null,
                      decorationColor: ZestTokens.textTertiary,
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

/// One way to start, as a card: its tile, its title (with Recommended on the
/// one recommended), its line, and what it does; the whole card is the
/// button, by click, Enter or Space.
class _StepCard extends StatefulWidget {
  const _StepCard({required this.step});

  final KeysFirstStep step;

  @override
  State<_StepCard> createState() => _StepCardState();
}

class _StepCardState extends State<_StepCard> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final rec = step.recommended;
    final radius = BorderRadius.circular(12);
    final border = rec
        ? (_hover ? ZestTokens.brand : ZestTokens.brandBorder)
        : (_hover ? ZestTokens.borderStrong : ZestTokens.border);
    final goInk = rec ? ZestTokens.brandInk : ZestTokens.textPrimary;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final card = Container(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 16),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: border),
        color: rec ? null : ZestTokens.surfaceElevated,
        // The recommended card's brand fill fades into the card's own.
        gradient: rec
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [ZestTokens.brandFill, ZestTokens.surfaceElevated],
                stops: const [0, 0.7],
              )
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepTile(icon: step.icon, recommended: rec),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _StepTitle(step: step, size: 15),
                const SizedBox(height: 4),
                _StepBody(text: step.body, size: 13),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        step.go,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: goInk, height: 1.3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(rtl ? LucideIcons.arrowLeft : LucideIcons.arrowRight, size: 15, color: goInk),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (v) => setState(() => _hover = v),
          onShowFocusHighlight: (v) => setState(() => _focus = v),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
              step.onTap();
              return null;
            }),
          },
          child: GestureDetector(
            key: ValueKey('keys-first-${step.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: step.onTap,
            // The focus ring outside the card, as a button's is: showing it
            // moves nothing.
            child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.passthrough,
              children: [
                card,
                if (_focus)
                  Positioned(
                    left: -4,
                    top: -4,
                    right: -4,
                    bottom: -4,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(color: ZestTokens.brand, width: 2),
                        ),
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

/// A way's glyph in its tile: the brand's on the one recommended, grey on
/// the others (only the recommended one carries the brand's colour).
class _StepTile extends StatelessWidget {
  const _StepTile({required this.icon, required this.recommended, this.size = 40});

  final IconData icon;
  final bool recommended;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: recommended ? ZestTokens.brandIconBg : ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Icon(icon, size: size / 2, color: recommended ? ZestTokens.brandInk : ZestTokens.textSecondary),
    );
  }
}

/// A way's title, with Recommended beside the one recommended (beneath it
/// where the line has no room).
class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.step, required this.size});

  final KeysFirstStep step;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = Text(
      step.title,
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, height: 1.3, color: ZestTokens.textPrimary),
    );
    if (!step.recommended) return title;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        title,
        Container(
          key: const ValueKey('keys-first-recommended'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: ZestTokens.brandBadge, borderRadius: BorderRadius.circular(999)),
          child: Text(
            l10n.keysFirstRecommended,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.3, color: ZestTokens.brandInk),
          ),
        ),
      ],
    );
  }
}

/// A way's line, with `.pem` and `.ppk` in it drawn as code; read out as its
/// words.
class _StepBody extends StatelessWidget {
  const _StepBody({required this.text, required this.size});

  final String text;
  final double size;

  static final _fileTypes = RegExp(r'\.(?:pem|ppk)\b');

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: size, height: 1.5, color: ZestTokens.textFaint);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _fileTypes.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: ZestTokens.surfaceChip, borderRadius: BorderRadius.circular(5)),
          child: Text(
            m.group(0)!,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: size - 1.5,
              fontWeight: FontWeight.w500,
              height: 1.3,
              color: ZestTokens.textSecondary,
            ),
          ),
        ),
      ));
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Semantics(
      label: text,
      child: ExcludeSemantics(child: Text.rich(TextSpan(style: style, children: spans))),
    );
  }
}

/// The line for a host that signs in with a password, and New saved
/// password.
class _PasswordLine extends StatelessWidget {
  const _PasswordLine({required this.onNewPassword, this.phone = false});

  final VoidCallback onNewPassword;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ask = l10n.keysFirstPasswordAsk;
    // The rest of the line: what follows the question, with the space a
    // Latin sentence has after it.
    final rest = _sentences(ask, l10n.keysFirstPasswordBody).substring(ask.length);
    final words = Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 13.5, height: 1.45, color: ZestTokens.textFaint),
        children: [
          TextSpan(text: ask, style: TextStyle(fontWeight: FontWeight.w500, color: ZestTokens.textSecondary)),
          TextSpan(text: rest),
        ],
      ),
      key: const ValueKey('keys-first-password-words'),
    );
    final line = Row(
      mainAxisSize: phone ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(LucideIcons.lock, size: 16, color: ZestTokens.textFaint),
        ),
        const SizedBox(width: 10),
        Flexible(child: words),
      ],
    );
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line,
          const SizedBox(height: 12),
          // A finger's height, taller where its words take two lines.
          ButtonBox(
            height: 48,
            child: OutlinedButton.icon(
              key: const ValueKey('keys-first-new-password'),
              onPressed: onNewPassword,
              icon: const Icon(LucideIcons.plus, size: 18),
              label: Text(l10n.zestKeysNewPassword),
              style: OutlinedButton.styleFrom(
                foregroundColor: ZestTokens.textPrimary,
                side: BorderSide(color: ZestTokens.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 10,
      children: [
        line,
        ZestButton(
          key: const ValueKey('keys-first-new-password'),
          label: l10n.zestKeysNewPassword,
          icon: LucideIcons.plus,
          onPressed: onNewPassword,
        ),
      ],
    );
  }
}

/// A phone's Keys page with nothing saved: the same heading and ways to
/// start as a computer's, as rows of a list (a phone has no SSH agent and no
/// password manager's tools, so it has the two ways that are there), and
/// the line for a host that signs in with a password with New saved
/// password, a finger's height.
class KeysFirstStepsList extends StatelessWidget {
  const KeysFirstStepsList({
    super.key,
    required this.onGenerate,
    required this.onImport,
    required this.onNewPassword,
    this.bottomPadding = 24,
  });

  final VoidCallback onGenerate;
  final VoidCallback onImport;
  final VoidCallback onNewPassword;

  /// Room at the foot for what floats over the list (a phone's tab bar).
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final steps = keysFirstSteps(l10n, onGenerate: onGenerate, onImport: onImport);
    return ListView(
      key: const ValueKey('keys-first-steps'),
      padding: EdgeInsets.fromLTRB(16, 28, 16, bottomPadding),
      children: [
        const _Hero(phone: true),
        const SizedBox(height: 20),
        PhoneListCard(children: [for (final step in steps) _StepRow(step: step)]),
        const SizedBox(height: 20),
        _PasswordLine(onNewPassword: onNewPassword, phone: true),
      ],
    );
  }
}

/// One way to start, as a phone's row: its tile, its title (with
/// Recommended), its line, and the chevron of a row that opens something.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final KeysFirstStep step;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('keys-first-${step.id}'),
            onTap: step.onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 10, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StepTile(icon: step.icon, recommended: step.recommended, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _StepTitle(step: step, size: 15),
                          const SizedBox(height: 3),
                          _StepBody(text: step.body, size: 12.5),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Icon(
                        Directionality.of(context) == TextDirection.rtl
                            ? LucideIcons.chevronLeft
                            : LucideIcons.chevronRight,
                        size: 18,
                        color: ZestTokens.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
