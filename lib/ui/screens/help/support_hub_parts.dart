import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tickets/attachment_refusal.dart';
import 'package:zestssh/features/tickets/support_diagnostics.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/ticket_actions.dart';
import 'package:zestssh/ui/screens/help/ticket_detail_screen.dart' show TicketMenuButton;
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// The pieces of the Support Hub
/// that its pages share, and that a ticket's own page draws itself with
/// when it stands in the hub's middle column.

/// A kind of ticket's colour, from the first glance at a list: help blue, a bug
/// red, an idea violet.
Color hubKindInk(TicketType type) => switch (type) {
      TicketType.support => AppColors.v3Info,
      TicketType.bug => AppColors.v3Error,
      TicketType.suggestion => GroupColor.purple.value,
    };

/// The glyph of a kind on a wash of its colour.
class HubKindTile extends StatelessWidget {
  const HubKindTile({super.key, required this.type, this.size = 32});

  final TicketType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ink = hubKindInk(type);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Icon(ticketTypeIcon(type), size: size / 2, color: ink),
    );
  }
}

/// A key's name in a little frame ("Esc", "/").
class HubKbd extends StatelessWidget {
  const HubKbd(this.keyName, {super.key});

  final String keyName;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.v3BorderDefault),
      ),
      child: Text(
        keyName,
        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, height: 1.4, color: AppColors.v3TextSecondary),
      ),
    );
  }
}

/// A framed group of the details column.
class HubCard extends StatelessWidget {
  const HubCard({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestSectionHeader(label: label),
          child,
        ],
      ),
    );
  }
}

/// A fact that goes with a ticket, as it is sent.
class HubFact extends StatelessWidget {
  const HubFact(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      // As it is sent, in any language: a version's "(340)" stays after it.
      child: Text(
        text,
        textDirection: TextDirection.ltr,
        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: AppColors.v3TextSecondary),
      ),
    );
  }
}

/// A line of who sees something and what stays out of it, with a green lock
/// or the globe of what is public.
class HubPrivacyLine extends StatelessWidget {
  const HubPrivacyLine({super.key, required this.public, required this.text});

  final bool public;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            public ? LucideIcons.globe : LucideIcons.lock,
            size: 15,
            color: public ? AppColors.v3TextTertiary : AppColors.v3Success,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary)),
        ),
      ],
    );
  }
}

/// Where [t] stands, as the hub's pill says it: one of the statuses the app has,
/// which stay as they are. An answer not read yet
/// is told by the dot beside it.
({String label, Color ink, Color fill, IconData? icon}) hubStanding(AppLocalizations l10n, SupportTicketRow t) {
  ({String label, Color ink, Color fill, IconData? icon}) quiet(String label, IconData? icon) => (
        label: label,
        ink: ZestTokens.textSecondary,
        fill: ZestTokens.surfaceChip,
        icon: icon,
      );
  if (t.isRefused) {
    return (
      label: '${l10n.ticketStatusNotSent} · ${ticketNotSentCode(t).code}',
      ink: AppColors.v3Error,
      fill: AppColors.v3Error.withValues(alpha: 0.12),
      icon: LucideIcons.alertCircle,
    );
  }
  if (t.isWaiting) return quiet(l10n.ticketStatusWaiting, LucideIcons.clock);
  if (t.isGone) return quiet(l10n.ticketStatusGone, null);
  if (t.isClosed) return quiet(l10n.ticketStatusClosed, null);
  if (hubWaitsForYou(t)) {
    return (
      label: l10n.ticketAwaitingYou,
      ink: ZestTokens.brandInk,
      fill: ZestTokens.brand.withValues(alpha: 0.14),
      icon: null,
    );
  }
  return (
    label: l10n.ticketAwaitingSupport,
    ink: AppColors.v3Info,
    fill: AppColors.v3Info.withValues(alpha: 0.13),
    icon: null,
  );
}

/// The ticket is the person's to answer.
bool hubWaitsForYou(SupportTicketRow t) => t.isOpen && (t.hasUnreadReply || t.awaiting == 'user');

/// A forum tag of a public report as a pill ("In progress", "Planned", "Fixed
/// in 3.2.2"), coloured by what its words mean; one it cannot place stays
/// neutral. The tags are named on the forum, in English.
class HubTagPill extends StatelessWidget {
  const HubTagPill({super.key, required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final words = tag.toLowerCase();
    final Color? ink;
    if (RegExp(r'fixed|solved|done|released|implemented|shipped').hasMatch(words)) {
      ink = AppColors.v3Success;
    } else if (RegExp(r'planned|accepted|considering|later').hasMatch(words)) {
      ink = GroupColor.purple.value;
    } else if (RegExp(r'progress|confirmed|working|investigating').hasMatch(words)) {
      ink = AppColors.v3Info;
    } else {
      ink = null;
    }
    return TicketChip(
      label: tag,
      ink: ink ?? ZestTokens.textSecondary,
      fill: ink?.withValues(alpha: 0.13) ?? ZestTokens.surfaceChip,
    );
  }
}

/// The top of a conversation in the hub:
/// the subject, and under it where it stands, what kind it is, who can see it,
/// its number and when it was opened; Copy link and the ticket's menu beside.
class HubTicketHead extends ConsumerWidget {
  const HubTicketHead({super.key, required this.ticket, required this.onRemoved});

  final SupportTicketRow ticket;

  /// The ticket was removed from this device through the menu.
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final t = ticket;
    final standing = hubStanding(l10n, t);
    final quiet = TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary);
    final link = t.discordUrl;
    Widget fact(IconData icon, String text, {Key? key}) => Row(
          key: key,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppColors.v3TextTertiary),
            const SizedBox(width: 5),
            Flexible(child: Text(text, style: quiet)),
          ],
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // A subject is what the person typed: it can name a host, so
                // recording mode hides it like any other free text of theirs.
                Text(
                  Redactable.freeText(t.title).displayIn(ref),
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 19,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TicketChip(
                      key: const ValueKey('hub-status'),
                      // As the list's group says it.
                      label: hubWaitsForYou(t) ? l10n.supportHubGroupNeedsReply : standing.label,
                      ink: standing.ink,
                      fill: standing.fill,
                      icon: standing.icon,
                    ),
                    fact(ticketTypeIcon(t.ticketType), ticketTypeLabel(l10n, t.ticketType)),
                    fact(
                      t.isPrivate ? LucideIcons.lock : LucideIcons.globe,
                      t.isPrivate ? l10n.supportHubPrivateOnlyYou : l10n.supportHubPublicNamesRemoved,
                      key: const ValueKey('hub-who-sees'),
                    ),
                    if (t.number != null)
                      Text(
                        ticketNumberLabel(t.number),
                        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: AppColors.v3TextSecondary),
                      ),
                    Text(l10n.supportHubOpened(ticketStamp(context, DateTime.fromMillisecondsSinceEpoch(t.createdAt))),
                        style: quiet),
                    for (final tag in t.tagNames) HubTagPill(tag: tag),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (link != null || t.number != null)
            TextButton.icon(
              key: const ValueKey('hub-copy-link'),
              onPressed: () => copyTicketLink(context, t),
              style: TextButton.styleFrom(foregroundColor: AppColors.v3TextSecondary),
              icon: const Icon(LucideIcons.link, size: 14),
              label: Text(
                link != null ? l10n.supportHubCopyLink : l10n.supportHubCopyNumber,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          TicketMenuButton(nonce: t.nonce, onRemoved: onRemoved),
        ],
      ),
    );
  }
}

/// A line of what happened in a conversation that nobody wrote: support took
/// it up, it waits on the person and closes by itself.
class HubEventLine extends StatelessWidget {
  const HubEventLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 44, bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 13, color: AppColors.v3TextTertiary),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary))),
        ],
      ),
    );
  }
}

/// The screenshot of [nonce] (or of its follow-up [messageId]) as the person
/// attached it, read with the ticket's token when it shows, kept in memory.
final hubScreenshotProvider = FutureProvider.autoDispose.family<Uint8List?, (String, String?)>((ref, key) {
  if (!ref.watch(dbReadyProvider)) return Future.value(null);
  return ref.watch(ticketServiceProvider).screenshot(key.$1, messageId: key.$2);
});

/// What the person attached under their words: the redacted screenshot, and
/// the diagnostics as a line that opens what was sent.
class HubAttachments extends ConsumerWidget {
  const HubAttachments({
    super.key,
    required this.nonce,
    this.messageId,
    required this.hasScreenshot,
    this.diagnostics,
  });

  final String nonce;
  final String? messageId;
  final bool hasScreenshot;
  final String? diagnostics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final shot = hasScreenshot ? ref.watch(hubScreenshotProvider((nonce, messageId))).valueOrNull : null;
    final d = diagnostics;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (hasScreenshot) HubShotThumb(key: const ValueKey('hub-attached-shot'), png: shot),
          if (d != null)
            Container(
              key: const ValueKey('hub-attached-diagnostics'),
              padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
              decoration: BoxDecoration(
                color: AppColors.v3Surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.v3BorderDefault),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.fileText, size: 14, color: AppColors.v3TextSecondary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      l10n.supportHubDiagnosticsChip(diagnosticsSummary(d)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('·  ${l10n.supportHubNamesRemoved}', style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
                  TextButton(
                    key: const ValueKey('hub-diagnostics-view'),
                    onPressed: () => showDiagnosticsText(context, d),
                    style: TextButton.styleFrom(
                      foregroundColor: ZestTokens.brandInk,
                      minimumSize: const Size(0, 24),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(l10n.supportHubView, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A screenshot, small, with "Names blurred" over its corner; a sketch of one
/// while it is read.
class HubShotThumb extends StatelessWidget {
  const HubShotThumb({super.key, required this.png, this.width = 168, this.height = 96});

  final Uint8List? png;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bytes = png;
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderDefault),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            Image.memory(bytes, fit: BoxFit.cover, alignment: Alignment.topLeft, errorBuilder: (_, _, _) => const SizedBox())
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (w, c) in [
                    (0.7, AppColors.v3BorderDefault),
                    (0.45, ZestTokens.brand.withValues(alpha: 0.6)),
                    (0.8, AppColors.v3BorderDefault),
                    (0.35, AppColors.v3BorderDefault),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: FractionallySizedBox(
                        widthFactor: w,
                        child: Container(height: 4, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
                      ),
                    ),
                ],
              ),
            ),
          // On a scrim of its own: a picture of a dark window under a light
          // theme hid the words.
          PositionedDirectional(
            start: 6,
            bottom: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(LucideIcons.eye, size: 11, color: Color(0xFFDADDE2)),
                  const SizedBox(width: 4),
                  Text(l10n.supportHubNamesBlurred, style: const TextStyle(fontSize: 11, color: Color(0xFFDADDE2))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What diagnostics said, as it was sent: the "View" of a conversation and the
/// "See exactly what's sent" of a new report.
Future<void> showDiagnosticsText(BuildContext context, String text, {String? before}) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.neutral,
    title: l10n.supportHubWhatsSentTitle,
    icon: LucideIcons.fileText,
    body: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (before != null) ...[
            Text(l10n.supportHubWhatsSentReport, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
            const SizedBox(height: 6),
            _MonoBox(text: before, valueKey: 'hub-sent-payload'),
            const SizedBox(height: 14),
          ],
          if (text.isNotEmpty) ...[
            Text(l10n.supportHubDiagnosticsHeading, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
            const SizedBox(height: 6),
            _MonoBox(text: text, valueKey: 'hub-sent-diagnostics'),
          ],
        ],
      ),
    ),
  );
}

class _MonoBox extends StatelessWidget {
  const _MonoBox({required this.text, required this.valueKey});

  final String text;
  final String valueKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: SelectableText(
        text,
        key: ValueKey(valueKey),
        textDirection: TextDirection.ltr,
        style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, height: 1.4),
      ),
    );
  }
}

/// One entry of the conversation in the hub: an avatar, the name and the time,
/// the words. Support's stand on a wash of the accent, with their badge.
class HubMessage extends ConsumerWidget {
  const HubMessage({
    super.key,
    required this.who,
    required this.when,
    required this.text,
    this.fromSupport = false,
    this.extraLabel,
    this.extra,
    this.state,
    this.failed = false,
    this.actions = const [],
    this.attachments,
  });

  final String who;
  final DateTime when;
  final String text;
  final bool fromSupport;

  /// What the person attached, under the words (3.4).
  final Widget? attachments;

  /// A second block under the text ("What you expected").
  final String? extraLabel;
  final String? extra;

  /// "Waiting to be sent" or why it was not sent.
  final String? state;
  final bool failed;
  final List<Widget> actions;

  /// What stands in a person's avatar: the first letters of the first two
  /// words of their name.
  static String initialsOf(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2);
    return words.map((w) => String.fromCharCode(w.runes.first)).join().toUpperCase();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final ink = TextStyle(fontSize: 13.5, height: 1.45, color: AppColors.v3TextPrimary);
    final quiet = TextStyle(fontSize: 11, color: AppColors.v3TextTertiary);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                padding: const EdgeInsets.all(4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fromSupport ? ZestTokens.brand : ZestTokens.surfaceChipStrong,
                  shape: BoxShape.circle,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    fromSupport ? initialsOf(who) : who,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fromSupport ? ZestTokens.onBrand : AppColors.v3TextSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          who,
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                        ),
                        if (fromSupport)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: ZestTokens.brand.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l10n.ticketTypeSupport,
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: ZestTokens.brandInk),
                            ),
                          ),
                        Text(ticketStamp(context, when), style: quiet),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: fromSupport ? ZestTokens.brand.withValues(alpha: 0.07) : AppColors.v3Surface,
                        // The small corner on the avatar's side, in either
                        // direction of writing.
                        borderRadius: const BorderRadiusDirectional.only(
                          topStart: Radius.circular(4),
                          topEnd: Radius.circular(12),
                          bottomStart: Radius.circular(12),
                          bottomEnd: Radius.circular(12),
                        ),
                        border: Border.all(
                          color: failed
                              ? AppColors.v3Warning.withValues(alpha: 0.6)
                              : fromSupport
                                  ? ZestTokens.brand.withValues(alpha: 0.22)
                                  : AppColors.v3BorderSubtle,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(Redactable.freeText(text).displayIn(ref), style: ink),
                          if (extra != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              extraLabel ?? '',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.v3TextSecondary),
                            ),
                            const SizedBox(height: 2),
                            SelectableText(Redactable.freeText(extra!).displayIn(ref), style: ink),
                          ],
                        ],
                      ),
                    ),
                    ?attachments,
                    if (state != null || actions.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (state != null) ...[
                            Icon(
                              failed ? LucideIcons.alertCircle : LucideIcons.clock,
                              size: 11,
                              color: failed ? AppColors.v3Warning : AppColors.v3TextTertiary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                state!,
                                style: quiet.copyWith(color: failed ? AppColors.v3Warning : AppColors.v3TextTertiary),
                              ),
                            ),
                          ],
                          ...actions,
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A ticket's details, who sees it and what can be done to it: the hub's right
/// column, and what its Details button opens where the window has no room for
/// that. Each line only where this device knows it: a ticket sent before 3.3
/// has no facts kept with it.
class HubTicketDetails extends ConsumerWidget {
  const HubTicketDetails({super.key, required this.ticket, required this.onRemoved});

  final SupportTicketRow ticket;
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final t = ticket;
    final sent = t.cachedConversation?.sentWith;
    final link = t.discordUrl;
    final lines = <(String, Widget)>[
      (l10n.supportHubType, _value(ticketTypeLabel(l10n, t.ticketType))),
      if (t.number != null) (l10n.supportHubNumber, _value(ticketNumberLabel(t.number), mono: true)),
      (l10n.supportHubStatus, _value(hubStanding(l10n, t).label)),
      if (t.tagNames.isNotEmpty)
        (
          l10n.supportHubTags,
          Wrap(spacing: 4, runSpacing: 4, children: [for (final tag in t.tagNames) HubTagPill(tag: tag)]),
        ),
      if (sent != null) ...[
        if (sent.appVersion.isNotEmpty) (l10n.supportHubApp, _value('${sent.appVersion} (${sent.build})', ltr: true)),
        if (sent.osVersion.isNotEmpty) (l10n.supportHubSystem, _value(sent.osVersion)),
        if (t.isPrivate)
          (
            l10n.supportHubAccount,
            _value(t.cachedConversation!.accountIncluded ? l10n.supportHubAccountIncluded : l10n.supportHubAccountLeftOut),
          ),
      ],
    ];
    return Column(
      key: const ValueKey('hub-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HubCard(
          label: l10n.supportHubDetails,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (name, value) in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 84,
                        child: Text(name, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: value),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        HubCard(
          label: l10n.supportHubWhoSees,
          child: HubPrivacyLine(
            public: !t.isPrivate,
            text: t.isPrivate ? l10n.supportHubWhoPrivate : l10n.ticketPublicLine,
          ),
        ),
        const SizedBox(height: 14),
        HubCard(
          label: l10n.supportHubActions,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (link != null) ...[
                ZestButton(
                  key: const ValueKey('hub-view-discord'),
                  label: l10n.ticketViewOnDiscord,
                  icon: LucideIcons.externalLink,
                  onPressed: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
                ),
                const SizedBox(height: 6),
              ],
              ZestButton(
                key: const ValueKey('hub-forget'),
                label: l10n.ticketRemove,
                variant: ZestButtonVariant.ghost,
                onPressed: () => forgetTicketAsking(context, ref, t, onRemoved: onRemoved),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _value(String text, {bool mono = false, bool ltr = false}) => Text(
        text,
        textDirection: ltr ? TextDirection.ltr : null,
        style: TextStyle(
          fontFamily: mono ? 'JetBrainsMono' : null,
          fontSize: mono ? 12 : 12.5,
          color: AppColors.v3TextPrimary,
        ),
      );
}

/// Why a ticket, a reply or a report was refused for what was attached to
/// it (a screenshot, diagnostics), said with the words left to go alone.
String attachmentsRefusalSaid(AppLocalizations l10n, AttachmentRefusal why, int? minutes) => switch (why) {
      AttachmentRefusal.full => l10n.supportAttachmentsFull,
      AttachmentRefusal.hourly => l10n.supportAttachmentsHourly(minutes ?? 60),
      AttachmentRefusal.paused => l10n.supportAttachmentsPaused,
    };
