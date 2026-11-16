import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';

/// Which level of the desktop Help panel is showing (help/feedback/support
/// spec, section 2). The panel is one pane with levels pushed inside it, not
/// a stack of dialogs.
///
/// [support] is "Get help" (the ways to reach support); [contactSupport] is
/// the private ticket form; [tickets] is My tickets and [ticket] one ticket's
/// conversation (which one: [helpDockTicketProvider]). [guides] is the
/// search over the feature guides and [guide] one guide (which one:
/// [helpDockGuideProvider]).
enum HelpPage {
  home,
  reportBug,
  suggest,
  support,
  contactSupport,
  tickets,
  ticket,
  guides,
  guide,

  /// Ask Astryx (4.0, a named preview): a question answered from the docs.
  askAstryx,
}

/// Null = the Help panel is closed. Set by the `?` button, the palette and
/// the macOS menu; cleared by the panel's X or a finished report.
final helpDockProvider = StateProvider<HelpPage?>((_) => null);

/// The ticket the [HelpPage.ticket] level shows, by the nonce it was sent
/// with.
final helpDockTicketProvider = StateProvider<String?>((_) => null);

/// Where the support form was opened from ([HelpPage.support] or
/// [HelpPage.tickets]), so its Back returns there.
final helpDockSupportOriginProvider =
    StateProvider<HelpPage>((_) => HelpPage.support);

/// The guide the [HelpPage.guide] level shows, by its slug (set by a page's
/// "?" and by the guides list).
final helpDockGuideProvider = StateProvider<String?>((_) => null);

/// Whether the Support Hub is open on a computer:
/// the page over the shell that holds tickets, bug
/// reports and suggestions in one list. The sessions go on running behind it.
final supportHubOpenProvider = StateProvider<bool>((_) => false);

/// The ticket the hub has in the middle, by the nonce it was sent with. Kept
/// while the hub is closed: it opens again where it was left. Null: the newest
/// where the window has room for a list beside it, the list where it has not.
final supportHubTicketProvider = StateProvider<String?>((_) => null);

/// What the hub's New report has chosen, or null while it is not showing. Kept
/// while the hub is closed, as what was typed there is.
final supportHubComposeProvider = StateProvider<TicketType?>((_) => null);

/// The Support Hub's three tabs: the
/// tickets this device sent, everyone's known issues, and everyone's ideas.
enum HubTab { myTickets, knownIssues, ideas }

/// Which tab the hub shows. Kept while the hub is closed: it opens again where
/// it was left.
final supportHubTabProvider = StateProvider<HubTab>((_) => HubTab.myTickets);
