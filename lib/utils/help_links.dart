/// The public places the Help menu and the report form point at. One list so
/// a moved page is fixed once.
///
/// Each is made from the build's own addresses (lib/config/official_identity.dart),
/// so a build that names another website, docs site or support address links
/// there.
library;

import 'package:zestssh/config/official_identity.dart';

/// The documentation site is its own host, not a path on the marketing site.
String get kZestDocsUrl => zestUnder(kZestDocsOrigin, '/');
String get kZestFaqUrl => zestUnder(kZestWebsite, '/faq');
String get kZestChangelogUrl => zestUnder(kZestWebsite, '/changelog');

/// The website's page on the plans: what Squeezed, Juiced and the Bundle are.
String get kZestPlansUrl => zestUnder(kZestWebsite, '/pricing/plans');
String get kZestDiscordUrl => kZestDiscordInvite;

/// Support is a conversation, so it lives in email or the Discord, not in the
/// one-way report relay. The address is shown with a copy button next to the
/// link: a share of desktops have no mail client, and a dead mailto reads as
/// a broken app.
String get kZestSupportEmail => kZestSupportAddress;
String get kZestSupportMailto =>
    kZestSupportAddress == '' ? '' : 'mailto:$kZestSupportAddress?subject=ZestSSH%20support';

/// FAQ entries in the Help panel link straight into the docs.
String get kZestDocsImporting => zestUnder(kZestDocsOrigin, '/getting-started/importing-from-other-apps/');
String get kZestDocsConnectionIssues => zestUnder(kZestDocsOrigin, '/troubleshooting/connection-issues/');
String get kZestDocsSyncNotWorking => zestUnder(kZestDocsOrigin, '/troubleshooting/sync-not-working/');

/// The Keys page with nothing saved links here: what an SSH key is, in plain
/// words, for someone who has never made one.
String get kZestDocsWhatIsAnSshKey => zestUnder(kZestDocsOrigin, '/getting-started/what-is-an-ssh-key/');
