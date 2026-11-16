import 'dart:async';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show MyInvite;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/tree_providers.dart';
import 'package:zestssh/services/desktop_auth_server.dart' show BrowserSignInCancelled;
import 'package:zestssh/services/desktop_browser_sign_in.dart' show BrowserSession;
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/ui/screens/desktop/widgets/tree_selector.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';
import 'package:zestssh/ui/screens/profile/account_switch.dart';
import 'package:zestssh/ui/screens/profile/widgets/locked_copies_row.dart';
import 'package:zestssh/utils/redactor.dart';

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _c = 'cccccccccccccccccccccccccccccccc';

ComputerAccount _account(String id, String uid, {bool inUse = false, bool asks = false, ProfileState state = ProfileState.open}) =>
    ComputerAccount(
      entry: ProfileEntry(id: id, uid: uid, label: '$uid@example.com', state: state),
      inUse: inUse,
      needsSignIn: asks,
      lost: state == ProfileState.lost,
    );

/// The controller as the screens reach it: what they ask of it, written down.
class _Profiles implements ProfileController {
  List<ComputerAccount> accounts = [];
  bool guestOnScreen = false;
  bool room = true;
  bool asksWhose = false;
  int sessions = 0;
  final switched = <String>[];
  final removed = <String>[];
  final said = <bool>[];
  final opened = <String>[];
  final endedSessions = <String>[];
  Object? switchFails;
  List<LockedCopyInfo> copies = const [];
  String? copyHere;
  final deletedCopies = <String>[];
  Object? copiesFail;
  Object? deleteFails;

  @override
  bool get on => true;
  @override
  List<ComputerAccount> get accountsHere => accounts;
  @override
  bool get guestDataOnScreen => guestOnScreen;
  @override
  bool get roomForAnotherAccount => room;
  @override
  bool get addAsksWhose => asksWhose;
  @override
  int get openSessions => sessions;
  @override
  List<ProfileEntry> get keptGuestData => const [];
  @override
  bool get heldByFirebase => false;

  @override
  Future<void> switchTo(String id) async {
    if (switchFails != null) throw switchFails!;
    switched.add(id);
  }

  @override
  Future<void> switchToGuest() async => switched.add('guest');
  @override
  Future<bool> removeFromComputer(String id) async {
    removed.add(id);
    return true;
  }

  @override
  Future<SignInSaid> nextSignInIs({required bool mine}) async {
    said.add(mine);
    return answer;
  }

  /// What every answer comes back as; what each sign-in went with; what was forgotten.
  final answer = const SignInSaid('of-the-answer');
  final openedWith = <SignInSaid?>[];
  final forgotten = <SignInSaid>[];
  @override
  void forgetNextSignIn(SignInSaid said) => forgotten.add(said);
  @override
  Future<void> openForAccount({required String uid, String? label, required String? bearer, SignInSaid? said}) async {
    opened.add(uid);
    openedWith.add(said);
  }

  @override
  Future<void> sessionKept() async {}
  @override
  Future<void> sessionNotKept() async {}
  @override
  Future<void> endSessionOf(String bearer) async => endedSessions.add(bearer);
  @override
  Future<(List<LockedCopyInfo>, String?)> lockedCopiesAtCloud() async {
    if (copiesFail != null) throw copiesFail!;
    return (copies, copyHere);
  }

  @override
  Future<void> deleteLockedCopyAtCloud(String id) async {
    if (deleteFails != null) throw deleteFails!;
    deletedCopies.add(id);
    copies = [...copies.where((c) => c.id != id)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service implements OrchardService {
  List<MyInvite> waiting = const [];
  final declined = <String>[];
  @override
  Future<List<MyInvite>> myInvites() async => waiting;
  @override
  Future<void> declineInvite(String id) async {
    declined.add(id);
    waiting = [...waiting.where((i) => i.id != id)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A test whose app is closed at its end, with what a notice left running.
void _test(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}

void main() {
  late _Profiles profiles;
  late AppLocalizations l10n;
  late WidgetRef rowRef;
  late BuildContext rowContext;

  setUp(() {
    profiles = _Profiles();
    debugBrowserSession = null;
  });
  tearDown(() => debugBrowserSession = null);

  Future<void> pump(WidgetTester tester, {List<Override> more = const [], Widget? child}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        profileControllerProvider.overrideWithValue(profiles),
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Juiced()),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 31))),
        ...more,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: child ??
              Align(
                alignment: Alignment.bottomLeft,
                child: Consumer(
                  builder: (context, ref, _) {
                    rowRef = ref;
                    rowContext = context;
                    return const SizedBox(width: 220, height: 44, child: Text('the row'));
                  },
                ),
              ),
        ),
      ),
    ));
    await tester.pump();
    if (child == null) l10n = AppLocalizations.of(rowContext)!;
  }

  Future<void> openRow(WidgetTester tester) async {
    unawaited(openAccountRow(rowContext, rowRef));
    await tester.pumpAndSettle();
  }

  Finder row(String id) => find.byKey(ValueKey('account-row-$id'));

  /// Whether [message] shows, on screen or as a computer's notice.
  bool shows(String message) =>
      find.text(message).evaluate().isNotEmpty ||
      ProviderScope.containerOf(rowContext).read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);

  group('the account row', () {
    // A build made without ZEST_OFFICIAL=true has no account to add.
    _test('a community build: the list has no Add account', (tester) async {
      debugZestOfficial = false;
      addTearDown(() => debugZestOfficial = true);
      profiles.accounts = [_account(_a, 'alex', inUse: true)];
      await pump(tester);
      await openRow(tester);
      expect(row(_a), findsOneWidget);
      expect(find.byKey(const ValueKey('account-add')), findsNothing);
    });

    _test('lists this computer\'s accounts and guest data, the one in use marked, with what it can do', (tester) async {
      profiles.accounts = [
        _account(_a, 'alex', inUse: true),
        _account(_b, 'alex-work'),
        _account(_c, 'sam', asks: true),
      ];
      await pump(tester);
      await openRow(tester);

      expect(find.descendant(of: row(_a), matching: find.text('alex@example.com')), findsOneWidget);
      expect(find.descendant(of: row(_a), matching: find.text(l10n.accountRowInUse)), findsOneWidget);
      expect(find.descendant(of: row(_b), matching: find.text(l10n.accountRowSignedIn)), findsOneWidget);
      expect(find.descendant(of: row(_c), matching: find.text(l10n.accountRowAsksSignIn)), findsOneWidget);
      expect(find.descendant(of: row('guest'), matching: find.text(l10n.narrowSidebarGuest)), findsOneWidget);
      expect(find.byKey(const ValueKey('account-add')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-manage')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-sign-out')), findsOneWidget, reason: 'Sign out is the account\'s');
    });

    _test('guest data on screen has nothing to sign out of', (tester) async {
      profiles.guestOnScreen = true;
      await pump(tester);
      await openRow(tester);
      expect(find.byKey(const ValueKey('account-sign-out')), findsNothing);
      expect(find.descendant(of: row('guest'), matching: find.text(l10n.railGuestLocal)), findsOneWidget);
    });

    _test('an account of mine opens at once with nothing open', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true), _account(_b, 'alex-work')];
      await pump(tester);
      await openRow(tester);
      await tester.tap(row(_b));
      await tester.pumpAndSettle();
      expect(profiles.switched, [_b]);
      expect(shows(l10n.accountSwitchedTo('alex-work@example.com')), isTrue);
    });

    _test('the one in use does nothing', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true)];
      await pump(tester);
      await openRow(tester);
      await tester.tap(row(_a));
      await tester.pumpAndSettle();
      expect(profiles.switched, isEmpty);
    });

    _test('sessions running are said first, with what happens to them; staying changes nothing', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true), _account(_b, 'alex-work')];
      profiles.sessions = 2;
      await pump(tester);
      await openRow(tester);
      await tester.tap(row(_b));
      await tester.pumpAndSettle();
      expect(find.text(l10n.accountSwitchSessionsClose(2)), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(profiles.switched, isEmpty);

      await openRow(tester);
      await tester.tap(row(_b));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.accountSwitchConfirm).last);
      await tester.pumpAndSettle();
      expect(profiles.switched, [_b]);
    });

    _test('a switch that fails says so with its code and Copy details, and the person stays', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true), _account(_b, 'alex-work')];
      profiles.switchFails = const ProfileCannotOpen('profile-not-opened');
      await pump(tester);
      await openRow(tester);
      await tester.tap(row(_b));
      await tester.pumpAndSettle();
      expect(shows(ErrorCodes.withCode(l10n.accountSwitchFailedBody, ErrorCodes.accountSwitchFailed)), isTrue);
      expect(profiles.switched, isEmpty);
    });

    _test('guest data opens from the list', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true)];
      await pump(tester);
      await openRow(tester);
      await tester.tap(row('guest'));
      await tester.pumpAndSettle();
      expect(profiles.switched, ['guest']);
    });
  });

  group('one that takes its sign-in', () {
    _test('the sign-in must be that account: another changes nothing, and its session ends', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true), _account(_c, 'sam', asks: true)];
      debugBrowserSession = ({bool create = false}) async => const BrowserSession(token: 'not-sams', email: 'x@example.com', uid: 'someone');
      await pump(tester);
      await openRow(tester);
      await tester.tap(row(_c));
      await tester.pumpAndSettle();
      expect(profiles.opened, isEmpty);
      expect(profiles.endedSessions, ['not-sams']);
    });

    _test('that account\'s sign-in opens it, and one cancelled leaves the person where they were', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true), _account(_c, 'sam', state: ProfileState.locked, asks: true)];
      debugBrowserSession = ({bool create = false}) async => throw const BrowserSignInCancelled();
      await pump(tester);
      await openRow(tester);
      await tester.tap(row(_c));
      await tester.pumpAndSettle();
      expect(profiles.opened, isEmpty);

      debugBrowserSession = ({bool create = false}) async => const BrowserSession(token: 'sams', email: 'sam@example.com', uid: 'sam');
      await openRow(tester);
      await tester.tap(row(_c));
      await tester.pumpAndSettle();
      expect(profiles.opened, ['sam']);
    });
  });

  group('Add account', () {
    _test('at five it says so at once, with how to remove one, and no sign-in starts', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true)];
      profiles.room = false;
      var signIns = 0;
      debugBrowserSession = ({bool create = false}) async {
        signIns++;
        throw const BrowserSignInCancelled();
      };
      await pump(tester);
      await openRow(tester);
      await tester.tap(find.byKey(const ValueKey('account-add')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.accountsFullTitle), findsOneWidget);
      expect(find.textContaining(ErrorCodes.tooManyAccounts.code), findsOneWidget);
      expect(find.textContaining(l10n.accountRemoveAction), findsOneWidget);
      expect(signIns, 0);
    });

    _test('asks whose it is first, and each answer is kept for its sign-in; closing the question stops there', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true)];
      profiles.asksWhose = true;
      var signIns = 0;
      debugBrowserSession = ({bool create = false}) async {
        signIns++;
        throw const BrowserSignInCancelled();
      };
      await pump(tester);

      await openRow(tester);
      await tester.tap(find.byKey(const ValueKey('account-add')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.accountWhoseTitle), findsOneWidget);
      await tester.tap(find.text(l10n.accountWhoseMine).last);
      await tester.pumpAndSettle();
      expect(profiles.said, [true]);
      expect(signIns, 1);

      await openRow(tester);
      await tester.tap(find.byKey(const ValueKey('account-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.accountWhoseOther).last);
      await tester.pumpAndSettle();
      expect(profiles.said, [true, false]);
      expect(signIns, 2);

      await openRow(tester);
      await tester.tap(find.byKey(const ValueKey('account-add')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(profiles.said, [true, false]);
      expect(signIns, 2);
    });

    _test('what was said goes with this flow\'s sign-in, and is forgotten as the flow ends', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true)];
      profiles.asksWhose = true;
      debugBrowserSession = ({bool create = false}) async => const BrowserSession(token: 'sams', email: 'sam@example.com', uid: 'sam');
      await pump(tester);

      await openRow(tester);
      await tester.tap(find.byKey(const ValueKey('account-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.accountWhoseOther).last);
      await tester.pumpAndSettle();
      expect(profiles.opened, ['sam']);
      expect(identical(profiles.openedWith.single, profiles.answer), isTrue);
      expect(identical(profiles.forgotten.single, profiles.answer), isTrue);
    });

    _test('with nobody to call it another of, it signs in with no question', (tester) async {
      profiles.guestOnScreen = true;
      var signIns = 0;
      debugBrowserSession = ({bool create = false}) async {
        signIns++;
        throw const BrowserSignInCancelled();
      };
      await pump(tester);
      await openRow(tester);
      await tester.tap(find.byKey(const ValueKey('account-add')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.accountWhoseTitle), findsNothing);
      expect(signIns, 1);
    });
  });

  group('Remove from this computer', () {
    Future<void> hoverAndRemove(WidgetTester tester, String id) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(row(id)));
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('account-row-$id-remove')));
      await tester.pumpAndSettle();
    }

    _test('says what goes and what stays; a signed-out account\'s copy stays at ZestSSH Cloud; it goes on the word', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true), _account(_c, 'sam', state: ProfileState.locked, asks: true)];
      await pump(tester);
      await openRow(tester);
      await hoverAndRemove(tester, _c);
      expect(find.text(l10n.accountRemoveTitle('sam@example.com')), findsOneWidget);
      expect(find.textContaining(l10n.accountRemoveBody), findsOneWidget);
      expect(find.textContaining(l10n.accountRemoveCopyStays), findsOneWidget);
      expect(find.textContaining(l10n.accountRemoveGuestOpens), findsNothing);
      await tester.tap(find.text(l10n.commonRemove).last);
      await tester.pumpAndSettle();
      expect(profiles.removed, [_c]);
    });

    _test('the one in use says guest data opens, and staying removes nothing', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true)];
      await pump(tester);
      await openRow(tester);
      await hoverAndRemove(tester, _a);
      expect(find.textContaining(l10n.accountRemoveGuestOpens), findsOneWidget);
      expect(find.textContaining(l10n.accountRemoveCopyStays), findsNothing);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(profiles.removed, isEmpty);
    });
  });

  group('the space switcher (plan item 24)', () {
    const team = OrchardSummary(id: 't1', name: 'Acme', role: 'owner', defaultCrateId: null, crates: []);
    OrchardSummary another(String id) => OrchardSummary(id: id, name: 'Team $id', role: 'owner', defaultCrateId: null, crates: const []);

    Future<_Service> pumpSwitcher(WidgetTester tester, List<OrchardSummary> teams, {List<MyInvite> invites = const []}) async {
      final service = _Service()..waiting = invites;
      await pump(
        tester,
        more: [
          currentUserProvider.overrideWithValue(const UserProfile(uid: 'alex', email: 'alex@example.com')),
          connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
          orchardSummariesProvider.overrideWith((ref) async => teams),
          orchardServiceProvider.overrideWithValue(service),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
          treeNameOverrideProvider.overrideWith((ref) => 'Personal'),
        ],
        child: const Align(alignment: Alignment.topLeft, child: TreeSelector()),
      );
      await tester.pumpAndSettle();
      l10n = AppLocalizations.of(tester.element(find.byType(TreeSelector)))!;
      await tester.tap(find.byType(TreeSelector));
      await tester.pumpAndSettle();
      return service;
    }

    _test('accounts above, spaces below, no heads with one team, New team and Join with code at the foot, no Sign out', (tester) async {
      profiles.accounts = [_account(_a, 'alex', inUse: true), _account(_b, 'alex-work')];
      await pumpSwitcher(tester, const [team]);
      expect(find.byKey(const ValueKey('space-account-line')), findsOneWidget);
      expect(row(_b), findsOneWidget);
      expect(tester.getTopLeft(row(_b)).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('space-row-tree'))).dy));
      expect(find.byKey(const ValueKey('space-row-t1')), findsOneWidget);
      expect(find.text(l10n.spaceSwitcherTeams.toUpperCase()), findsNothing);
      expect(find.byKey(const ValueKey('space-new-team')), findsOneWidget);
      expect(find.byKey(const ValueKey('space-join-team')), findsOneWidget);
      expect(find.text(l10n.treeSelectorSignOut), findsNothing);
      expect(find.text('Ctrl+1'), findsOneWidget);
      expect(find.text('Ctrl+2'), findsOneWidget);
      expect(find.byKey(const ValueKey('space-filter')), findsNothing);
    });

    _test('two teams bring the heads; six spaces bring a filter, which narrows the list', (tester) async {
      await pumpSwitcher(tester, [team, for (final i in ['t2', 't3', 't4', 't5']) another(i)]);
      expect(find.text(l10n.spaceSwitcherTeams.toUpperCase()), findsOneWidget);
      expect(find.byKey(const ValueKey('space-filter')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('space-filter')), 'acme');
      await tester.pump();
      expect(find.byKey(const ValueKey('space-row-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('space-row-t2')), findsNothing);
      expect(find.byKey(const ValueKey('space-row-tree')), findsNothing);
    });

    _test('an invitation is a row among them: Decline answers there, Accept goes to where it says what joining means', (tester) async {
      final invite = MyInvite(id: 'i1', orchardId: 'o', role: 'admin', crates: 1, expiresAt: DateTime.utc(2030), accepted: false, invitedBy: 'lee@example.com');
      final service = await pumpSwitcher(tester, const [], invites: [invite]);
      expect(find.byKey(const ValueKey('space-invite-i1')), findsOneWidget);
      expect(find.text('lee@example.com'), findsOneWidget);
      expect(find.byKey(const ValueKey('space-invite-accept-i1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('space-invite-decline-i1')));
      await tester.pumpAndSettle();
      expect(service.declined, ['i1']);
      expect(find.byKey(const ValueKey('space-invite-i1')), findsNothing);
    });
  });

  group('Locked copies', () {
    const elsewhere = LockedCopyInfo(id: 'elsewhere', platform: 'linux', madeOn: '2026-10-20');
    const here = LockedCopyInfo(id: 'here', platform: 'windows', madeOn: '2026-10-30');

    Future<void> openCopies(WidgetTester tester) async {
      await pump(tester);
      unawaited(showLockedCopies(rowContext, rowRef));
      await tester.pumpAndSettle();
    }

    _test('each by its platform and day; this computer\'s has no Delete', (tester) async {
      profiles.copies = const [elsewhere, here];
      profiles.copyHere = 'here';
      await openCopies(tester);
      expect(find.text(l10n.lockedCopyOnComputer('Linux', 'Oct 20, 2026')), findsOneWidget);
      expect(find.text(l10n.lockedCopyThisComputer('Windows', 'Oct 30, 2026')), findsOneWidget);
      expect(find.byKey(const ValueKey('locked-copy-delete-elsewhere')), findsOneWidget);
      expect(find.byKey(const ValueKey('locked-copy-delete-here')), findsNothing);
    });

    _test('Delete says first that the copy can never be opened, and goes on the word', (tester) async {
      profiles.copies = const [elsewhere];
      await openCopies(tester);
      await tester.tap(find.byKey(const ValueKey('locked-copy-delete-elsewhere')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.lockedCopyDeleteBody), findsOneWidget);
      await tester.tap(find.text(l10n.delete).last);
      await tester.pumpAndSettle();
      expect(profiles.deletedCopies, ['elsewhere']);
      expect(find.text(l10n.lockedCopiesNone), findsOneWidget);
    });

    _test('a list that cannot be read says so with a code, and that hosts are not touched', (tester) async {
      profiles.copiesFail = const LockedCopyRefused(503, 'unknown');
      await openCopies(tester);
      expect(find.byKey(const ValueKey('locked-copies-failed')), findsOneWidget);
      expect(find.textContaining(ErrorCodes.lockedCopyNotDeleted.code), findsOneWidget);
    });
  });
}
