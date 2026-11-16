import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/member_picture.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart' show zestUsesSheets;
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;

// The parts the team's admin pages are built from (one
// design): one card, one callout, one way to show an action, a
// key and its value, and a row that opens something. Each page drew its own
// before: bordered boxes in bordered boxes, bare bold words as buttons, and a
// state in a different colour on every page.

/// What a callout or an icon tile says by its colour.
enum TeamTone { info, warning, critical, success }

/// The colour of [tone]: amber for what needs attention, red for what failed
/// or cannot be undone, green for what went through, and the neutral ink for
/// the rest (the brand orange is never a state).
Color teamToneColor(TeamTone tone) => switch (tone) {
      TeamTone.info => ZestTokens.textSecondary,
      TeamTone.warning => ZestTokens.statusWarning,
      TeamTone.critical => ZestTokens.statusCritical,
      TeamTone.success => ZestTokens.statusHealthy,
    };

/// Below this width a card's actions go under its words, across the width.
const kTeamNarrow = 520.0;

/// A card on a team page: the raised surface (white on Daylight's grey
/// page) with a hairline, 20 inside it, 16 on a phone.
class TeamCard extends StatelessWidget {
  const TeamCard({super.key, required this.child, this.padding});

  final Widget child;

  /// Inside the card; 20 (16 where narrow) when null.
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => Container(
        width: double.infinity,
        padding: padding ?? EdgeInsets.all(box.maxWidth < kTeamNarrow ? 16 : 20),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: child,
      ),
    );
  }
}

/// A 32 pixel tile with an icon, the neutral one unless [tone] says more.
class TeamIconTile extends StatelessWidget {
  const TeamIconTile({super.key, required this.icon, this.tone = TeamTone.info, this.size = 32});

  final IconData icon;
  final TeamTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = teamToneColor(tone);
    final neutral = tone == TeamTone.info;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: neutral ? ZestTokens.surfaceRaisedAlt : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: neutral ? ZestTokens.borderSubtle : color.withValues(alpha: 0.30)),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// A person's initials in a circle [size] across, where a row is about
/// someone: two letters from [name] as it is shown (an address's part before
/// the @, split at dots, dashes, underscores and spaces; the first two
/// letters of a single word).
/// A member's picture, round: their account's, or their
/// initials where they have none, where it does not load or is not at an
/// address a picture may come from ([memberPicture]), or where recording mode
/// hides it ([picture] null then).
class TeamFace extends StatelessWidget {
  const TeamFace({super.key, required this.name, this.picture, this.size = 32});

  /// The person as the page shows them (already masked in recording mode).
  final String name;
  final String? picture;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initials = TeamInitials(name: name, size: size);
    final url = picture;
    if (url == null || !isKnownPictureAddress(url)) return initials;
    return ClipOval(
      child: SizedBox(
        key: const ValueKey('team-face-picture'),
        width: size,
        height: size,
        child: FutureBuilder<Uint8List?>(
          future: memberPicture(url),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) return initials;
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              width: size,
              height: size,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (context, error, stack) => initials,
            );
          },
        ),
      ),
    );
  }
}

class TeamInitials extends StatelessWidget {
  const TeamInitials({super.key, required this.name, this.size = 32});

  /// The person as the page shows them (already masked in recording mode).
  final String name;
  final double size;

  /// The two letters [TeamInitials] shows for [name].
  static String lettersOf(String name) {
    final at = name.indexOf('@');
    final local = (at > 0 ? name.substring(0, at) : name).trim();
    final words = [
      for (final w in local.split(RegExp(r'[\s._\-+]+')))
        if (w.isNotEmpty) w,
    ];
    if (words.isEmpty) return '?';
    final letters = words.length >= 2
        ? '${words[0].characters.first}${words[1].characters.first}'
        : words[0].characters.take(2).toString();
    return letters.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        shape: BoxShape.circle,
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Text(
        lettersOf(name),
        style: TextStyle(
          fontSize: size * 0.36,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: ZestTokens.textPrimary,
        ),
      ),
    );
  }
}

/// A role (or "You") as a small tag beside a person's name; [accent] for
/// the role that runs the team (Owner).
class TeamRolePill extends StatelessWidget {
  const TeamRolePill(this.label, {super.key, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent ? ZestTokens.brandSubtle : ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: accent ? ZestTokens.brandBorder : ZestTokens.borderSubtle),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          height: 1.3,
          color: accent ? zestBrandOnSubtle : ZestTokens.textSecondary,
        ),
      ),
    );
  }
}

/// A card's head: its icon tile, title and what it is, and its state at the
/// end.
class TeamCardHeader extends StatelessWidget {
  const TeamCardHeader({super.key, required this.icon, required this.title, this.body, this.bodyKey, this.trailing});

  final IconData icon;
  final String title;
  final String? body;

  /// The key of [body]'s words (a test reads them by it).
  final Key? bodyKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final words = body == null
        ? null
        : Text(body!, key: bodyKey, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary));
    return LayoutBuilder(builder: (context, box) {
      // On a phone the words take the card's width under the head (beside
      // the tile and the state they ran a few words to a line).
      final narrow = box.maxWidth < kTeamNarrow;
      final head = Row(
        crossAxisAlignment: narrow ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          TeamIconTile(icon: icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: narrow ? 0 : 1),
                  child: Text(title,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.35, color: ZestTokens.textPrimary)),
                ),
                if (words != null && !narrow) ...[const SizedBox(height: 2), words],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Padding(padding: EdgeInsets.only(top: narrow ? 0 : 4), child: trailing!),
          ],
        ],
      );
      if (!narrow || words == null) return head;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [head, const SizedBox(height: 10), words],
      );
    });
  }
}

/// A note set apart, in the colour of what it says, with at most one thing
/// to do: beside the words on a computer, under them across the width on a
/// phone.
class TeamCallout extends StatelessWidget {
  const TeamCallout({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.below,
    this.titleKey,
  });

  final TeamTone tone;
  final IconData icon;
  final String title;

  /// The key of the title's words (a test reads them by it).
  final Key? titleKey;
  final String? body;

  /// The one button ([teamButton]).
  final Widget? action;

  /// Anything else under the words (a list of fixes, a link).
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final color = teamToneColor(tone);
    final neutral = tone == TeamTone.info;
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A title with words under it is bold; a sentence alone is not.
        Text(title,
            key: titleKey,
            style: TextStyle(
                fontSize: 13,
                fontWeight: body == null ? FontWeight.w500 : FontWeight.w600,
                height: 1.45,
                color: ZestTokens.textPrimary)),
        if (body != null) ...[
          const SizedBox(height: 2),
          Text(body!, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
        ],
        if (below != null) ...[const SizedBox(height: 8), below!],
      ],
    );
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < kTeamNarrow;
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: neutral ? ZestTokens.surfaceRaisedAlt : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: neutral ? ZestTokens.borderSubtle : color.withValues(alpha: 0.32)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
            const SizedBox(width: 10),
            Expanded(
              child: narrow && action != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [words, const SizedBox(height: 10), action!],
                    )
                  : words,
            ),
            if (!narrow && action != null) ...[const SizedBox(width: 12), action!],
          ],
        ),
      );
    });
  }
}

enum TeamButtonKind { primary, secondary, danger, ghost }

/// The button of the team pages: the theme's own (34 high on a computer, 44
/// on a phone), filled for the one main thing, outlined for the rest, and
/// outlined in red for what removes, ends or turns off. [busy] shows a
/// spinner in place of the icon and takes the press away.
Widget teamButton({
  Key? key,
  required String label,
  required VoidCallback? onPressed,
  IconData? icon,
  TeamButtonKind kind = TeamButtonKind.secondary,
  bool busy = false,
}) {
  final press = busy ? null : onPressed;
  // At the theme's full height on a computer too (34; the platform's
  // compact density took it to 26 there), 44 on a phone.
  const density = ButtonStyle(visualDensity: VisualDensity.standard);
  final Widget? glyph = busy
      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
      : icon == null
          ? null
          : Icon(icon, size: 16);
  final text = Text(label, textAlign: TextAlign.center);
  switch (kind) {
    case TeamButtonKind.primary:
      return glyph == null
          ? FilledButton(key: key, onPressed: press, style: density, child: text)
          : FilledButton.icon(key: key, onPressed: press, style: density, icon: glyph, label: text);
    case TeamButtonKind.secondary:
      return glyph == null
          ? OutlinedButton(key: key, onPressed: press, style: density, child: text)
          : OutlinedButton.icon(key: key, onPressed: press, style: density, icon: glyph, label: text);
    // Quiet: words with no edge (Team settings, Turn away beside Review).
    case TeamButtonKind.ghost:
      final style = TextButton.styleFrom(
        foregroundColor: ZestTokens.textSecondary,
        visualDensity: VisualDensity.standard,
        minimumSize: Size(0, isTouchLayout ? 44 : 34),
      );
      return glyph == null
          ? TextButton(key: key, onPressed: press, style: style, child: text)
          : TextButton.icon(key: key, onPressed: press, style: style, icon: glyph, label: text);
    case TeamButtonKind.danger:
      // Its words in the nearest red that reads on the tint of the callout it
      // stands in ("Delete team" was 4.2:1 on Daylight's).
      final red = zestInkOnTint(ZestTokens.statusCritical, 0.12);
      final style = ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? red.withValues(alpha: 0.45) : red),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(
            color: red.withValues(alpha: s.contains(WidgetState.disabled) ? 0.25 : 0.55))),
        overlayColor: WidgetStatePropertyAll(red.withValues(alpha: 0.08)),
        visualDensity: VisualDensity.standard,
      );
      return glyph == null
          ? OutlinedButton(key: key, onPressed: press, style: style, child: text)
          : OutlinedButton.icon(key: key, onPressed: press, style: style, icon: glyph, label: text);
  }
}

/// A label and its value on one line: the label muted, the value at the
/// end, in the code font for an address or a key.
class TeamKeyValue extends StatelessWidget {
  const TeamKeyValue({super.key, required this.label, required this.value, this.mono = false, this.valueKey, this.color});

  final String label;
  final String value;
  final bool mono;
  final Key? valueKey;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final labelText = Text(label, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary));
    Text valueText(TextAlign align) => Text(
          value,
          key: valueKey,
          textAlign: align,
          style: TextStyle(
            fontSize: mono ? 12 : 12.5,
            height: 1.45,
            fontFamily: mono ? 'JetBrainsMono' : null,
            color: color ?? ZestTokens.textPrimary,
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      // On a phone the value goes under its label (beside it, a sentence
      // ran a few words to a line).
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth < kTeamNarrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [labelText, const SizedBox(height: 2), valueText(TextAlign.start)],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(constraints: const BoxConstraints(minWidth: 96, maxWidth: 160), child: labelText),
                  const SizedBox(width: 16),
                  Expanded(child: valueText(TextAlign.end)),
                ],
              ),
      ),
    );
  }
}

/// A row that opens something (a dialog, a page): its icon, its words, and a
/// chevron at the end; 44 high at least.
class TeamLinkRow extends StatelessWidget {
  const TeamLinkRow({super.key, required this.icon, required this.label, required this.onTap, this.detail});

  final IconData icon;
  final String label;

  /// What is set now, before the chevron.
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Icon(icon, size: 16, color: ZestTokens.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
                ),
                if (detail != null) ...[
                  Text(detail!, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary)),
                  const SizedBox(width: 6),
                ],
                Icon(LucideIcons.chevronRight, size: 16, color: ZestTokens.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 44 by 44 icon button with its name as a tooltip; red for what removes.
class TeamIconAction extends StatelessWidget {
  const TeamIconAction({super.key, required this.icon, required this.tooltip, required this.onPressed, this.danger = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 16, color: danger ? ZestTokens.statusCritical : ZestTokens.textSecondary),
      ),
    );
  }
}

/// Whether this screen is a phone's (its sheets, its 44 pixel targets).
bool teamOnPhone(BuildContext context) => zestUsesSheets(context);

/// A one-line field at the height of the buttons beside it (34 on a
/// computer, 44 on a phone), drawn as the theme's inputs are (its fill, its
/// hairline, the accent's ring while typed in). What is wrong with it is not
/// written inside it: its border turns red, and the words go where its help
/// is ([TeamFieldNote]), at the same edge. (The theme's decorator came out
/// 26 high under a computer's compact density, with room for a line under
/// it that nothing used.)
class TeamField extends StatefulWidget {
  const TeamField({
    super.key,
    this.fieldKey,
    required this.controller,
    this.hint,
    this.wrong = false,
    this.enabled = true,
    this.mono = false,
    this.obscure = false,
    this.keyboardType,
    this.onSubmitted,
    this.onChanged,
  });

  /// The key of the text field itself (what a test types into and reads).
  final Key? fieldKey;
  final TextEditingController controller;
  final String? hint;
  final bool wrong;
  final bool enabled;
  final bool mono;
  final bool obscure;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  State<TeamField> createState() => _TeamFieldState();
}

class _TeamFieldState extends State<TeamField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deco = Theme.of(context).inputDecorationTheme;
    Color side(InputBorder? b, Color fallback) => b is OutlineInputBorder ? b.borderSide.color : fallback;
    final focused = _focus.hasFocus;
    final color = widget.wrong
        ? ZestTokens.statusCritical
        : focused
            ? side(deco.focusedBorder, ZestTokens.brand)
            : side(deco.enabledBorder, ZestTokens.border);
    final text = TextStyle(
      fontSize: widget.mono ? 12.5 : 13,
      fontFamily: widget.mono ? 'JetBrainsMono' : null,
      color: ZestTokens.textPrimary,
    );
    return Opacity(
      opacity: widget.enabled ? 1 : 0.6,
      child: Container(
        // 34 high (44 on a phone) or more where larger text needs it; the
        // field fills the box, so the whole box takes a tap (the field was a
        // 20 high strip in its middle, and a fixed height cut large text).
        constraints: BoxConstraints(minHeight: teamOnPhone(context) ? 44 : 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: deco.fillColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: focused || widget.wrong ? 1.2 : 1),
        ),
        child: TextField(
          key: widget.fieldKey,
          controller: widget.controller,
          focusNode: _focus,
          enabled: widget.enabled,
          obscureText: widget.obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: widget.keyboardType,
          onSubmitted: widget.onSubmitted,
          onChanged: widget.onChanged,
          style: text,
          // Bare inside its box: no border or fill of the theme's own.
          decoration: InputDecoration(
            isCollapsed: true,
            // (The theme's own padding sat on top of the box's: the words
            // stood off centre.)
            contentPadding: EdgeInsets.symmetric(vertical: teamOnPhone(context) ? 18 : 10),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            hintText: widget.hint,
            hintStyle: text.copyWith(color: ZestTokens.textPlaceholder),
          ),
        ),
      ),
    );
  }
}

/// The line under a field: its help, or in its place what is wrong with
/// it, in red, at the same edge.
class TeamFieldNote extends StatelessWidget {
  const TeamFieldNote({super.key, this.help, this.problem, this.problemKey});

  final String? help;
  final String? problem;
  final Key? problemKey;

  @override
  Widget build(BuildContext context) {
    final problem = this.problem;
    if (problem == null && help == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        problem ?? help!,
        key: problem == null ? null : problemKey,
        style: TextStyle(
          fontSize: 12,
          height: 1.45,
          color: problem == null ? ZestTokens.textSecondary : ZestTokens.statusCritical,
        ),
      ),
    );
  }
}

/// A sixteen pixel progress ring on its track, with the words beside it at
/// the body's edge: what a dialog shows while it waits for someone.
class TeamWaiting extends StatelessWidget {
  const TeamWaiting(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ZestTokens.brand,
              backgroundColor: ZestTokens.border,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary))),
      ],
    );
  }
}
