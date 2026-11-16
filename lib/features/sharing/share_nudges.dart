import 'dart:async';

/// Word from ZestSSH Cloud's live line that an invitation to a shared
/// session came or went (3.0, session sharing): whoever keeps the
/// invitations looks again. It says nothing else.
final StreamController<void> shareInviteNudges = StreamController<void>.broadcast();
