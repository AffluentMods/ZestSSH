import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';

import 'roles_vaults_fixture.dart';

/// On a computer the Team page's own list of pages is reached and worked by
/// keyboard, and says what it is to a screen reader (found in a
/// review). Its items were bare GestureDetectors: Tab never landed on one,
/// so with nothing waiting on Overview a person without a mouse could not
/// get to Members, where a role is changed and a team is left.
void main() {
  bool inside(Key key) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) return false;
    var found = false;
    focus.visitAncestorElements((e) {
      if (e.widget.key == key) {
        found = true;
        return false;
      }
      return true;
    });
    return found || focus.widget.key == key;
  }

  testWidgets('Tab reaches Members in the list, Enter opens it, and Space opens another', (tester) async {
    final team = await buildRolesVaultsTeam(tester);
    final (key: _, :container) = await pumpRolesVaults(tester, team, page: TeamPage.overview);
    expect(container.read(teamPageProvider), TeamPage.overview);

    const members = ValueKey('team-nav-members');
    var reached = false;
    for (var i = 0; i < 80 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      reached = inside(members);
    }
    expect(reached, isTrue, reason: 'Tab never landed on Members in the Team page\'s list');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleTeam(tester);
    expect(container.read(teamPageProvider), TeamPage.members);

    const roles = ValueKey('team-nav-roles');
    reached = false;
    for (var i = 0; i < 80 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      reached = inside(roles);
    }
    expect(reached, isTrue, reason: 'Tab never landed on Roles');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await settleTeam(tester);
    expect(container.read(teamPageProvider), TeamPage.roles);
  });

  testWidgets('to a screen reader each item is a button, and the page shown is the selected one', (tester) async {
    final handle = tester.ensureSemantics();
    final team = await buildRolesVaultsTeam(tester);
    await pumpRolesVaults(tester, team, page: TeamPage.overview);

    final overview = tester.getSemantics(find.byKey(const ValueKey('team-nav-overview')));
    final members = tester.getSemantics(find.byKey(const ValueKey('team-nav-members')));
    // ignore: deprecated_member_use
    expect(overview.hasFlag(SemanticsFlag.isButton), isTrue);
    // ignore: deprecated_member_use
    expect(overview.hasFlag(SemanticsFlag.isSelected), isTrue);
    // ignore: deprecated_member_use
    expect(members.hasFlag(SemanticsFlag.isButton), isTrue);
    // ignore: deprecated_member_use
    expect(members.hasFlag(SemanticsFlag.isSelected), isFalse);
    handle.dispose();
  });
}
