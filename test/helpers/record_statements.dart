import 'dart:convert';

import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// [by]'s signed statement that they compared [subject]'s keys in
/// [orchardId], as base64: what an entry making someone an owner or admin
/// carries in a format-2 record (3.0), for tests that write such
/// entries by hand.
Future<String> comparedStatement(AccountKeys by, String byUid, String orchardId, PublishedAccountKeys subject) async =>
    base64Encode(await signMemberVerification(by, verifierUid: byUid, orchardId: orchardId, subject: subject));
