import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/screens/this_pc/this_pc_remote_access.dart';
import 'package:zestssh/features/screens/this_pc/this_pc_remote_access_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;

import '../../visual/shots_util.dart';

/// Remote access to this PC (4.1, Windows): what is read of Windows, the one
/// change made through its administrator question and how it came out, and
/// the dialog. Pictures with `--dart-define=ZEST_SHOTS=true`
/// (build/shots/this_pc_*.png). Addresses are made up.

/// Answers the scripts as a PC with [state] would, and keeps what was asked.
class _FakePc extends ThisPcRemoteAccess {
  _FakePc(this.state, {this.changeResult = ThisPcChange.done});

  ThisPcState? state;
  ThisPcChange changeResult;
  final changes = <bool>[];

  @override
  Future<ThisPcState?> read() async => state;

  @override
  Future<ThisPcChange> change({required bool on}) async {
    changes.add(on);
    if (changeResult == ThisPcChange.done) {
      state = ThisPcState(edition: state!.edition, on: on, nla: on || state!.nla, port: state!.port, firewallOpen: on);
    }
    return changeResult;
  }
}

ProcessResult _result(int code, [String out = '']) => ProcessResult(0, code, out, '');

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('reading Windows', () {
    test('a Pro PC with Remote Desktop on, sign-in first and the firewall open is ready', () {
      final s = ThisPcState.fromJson('{"edition":"Professional","deny":0,"nla":1,"port":3389,"firewall":3}')!;
      expect(s.isHome, isFalse);
      expect(s.on && s.nla && s.firewallOpen, isTrue);
      expect(s.ready, isTrue);
    });

    test('Home cannot be reached, whatever else it says', () {
      for (final id in ['Core', 'CoreN', 'CoreSingleLanguage', 'CoreCountrySpecific']) {
        final s = ThisPcState.fromJson('{"edition":"$id","deny":0,"nla":1,"port":3389,"firewall":2}')!;
        expect(s.isHome, isTrue, reason: id);
        expect(s.ready, isFalse, reason: id);
      }
    });

    test('values Windows leaves unset read as off; an odd port is kept; junk is nothing', () {
      final s = ThisPcState.fromJson('{"edition":"Enterprise","deny":null,"nla":null,"port":53389,"firewall":0}')!;
      expect(s.on, isFalse);
      expect(s.nla, isFalse);
      expect(s.port, 53389);
      expect(s.firewallOpen, isFalse);
      expect(ThisPcState.fromJson('not json'), isNull);
    });

    test('read runs the read script once and nothing else', () async {
      final asked = <List<String>>[];
      final pc = ThisPcRemoteAccess(run: (args) async {
        asked.add(args);
        return _result(0, '{"edition":"Professional","deny":1,"nla":1,"port":3389,"firewall":0}');
      });
      final s = await pc.read();
      expect(s!.on, isFalse);
      expect(asked.single, ['-Command', ThisPcRemoteAccess.readScript]);
      expect(ThisPcRemoteAccess.readScript, isNot(contains('Set-')));
      expect(ThisPcRemoteAccess.readScript, isNot(contains('Enable-')));
    });
  });

  group('changing it', () {
    test('turning on changes what Windows\' own switch changes, and nothing more', () {
      final on = ThisPcRemoteAccess.changeScript(on: true);
      expect(on, contains("-Name fDenyTSConnections -Value 0"));
      expect(on, contains('-Name UserAuthentication -Value 1'));
      expect(on, contains("Enable-NetFirewallRule -Group '$kRdpFirewallGroup'"));
      final off = ThisPcRemoteAccess.changeScript(on: false);
      expect(off, contains('-Name fDenyTSConnections -Value 1'));
      expect(off, contains("Disable-NetFirewallRule -Group '$kRdpFirewallGroup'"));
      expect(off, isNot(contains('UserAuthentication')), reason: 'turning off leaves the sign-in rule as it is');
      for (final script in [on, off]) {
        final setLines = script.split('\n').where((l) => l.contains('Set-') || l.contains('-NetFirewallRule'));
        expect(setLines.length, lessThanOrEqualTo(3));
      }
    });

    test('the change runs only through Windows\' administrator question, the script carried whole', () {
      final inner = ThisPcRemoteAccess.changeScript(on: true);
      final outer = ThisPcRemoteAccess.elevateScript(inner);
      expect(outer, contains('-Verb RunAs'));
      // Windows' own PowerShell by its full path, the variable expanded (double quotes).
      expect(outer, contains(r'-FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"'));
      final encoded = RegExp(r"'-EncodedCommand','([A-Za-z0-9+/=]+)'").firstMatch(outer)!.group(1)!;
      final bytes = base64.decode(encoded);
      final units = [for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
      expect(String.fromCharCodes(units), inner);
    });

    test('how it came out: done, refused at the question, or failed', () async {
      Future<ThisPcChange> withCode(int code) =>
          ThisPcRemoteAccess(run: (_) async => _result(code)).change(on: true);
      expect(await withCode(0), ThisPcChange.done);
      expect(await withCode(kElevationRefused), ThisPcChange.refused);
      expect(await withCode(2), ThisPcChange.failed);
      expect(await ThisPcRemoteAccess(run: (_) async => throw const ProcessException('powershell.exe', [])).change(on: true),
          ThisPcChange.failed);
    });

    test('the scripts are valid PowerShell (parsed, never run)', () async {
      for (final script in [
        ThisPcRemoteAccess.readScript,
        ThisPcRemoteAccess.changeScript(on: true),
        ThisPcRemoteAccess.changeScript(on: false),
        ThisPcRemoteAccess.elevateScript(ThisPcRemoteAccess.changeScript(on: true)),
      ]) {
        final f = File('${Directory.systemTemp.createTempSync('zs_ps').path}/s.ps1')..writeAsStringSync(script);
        final r = await Process.run('powershell.exe', [
          '-NoProfile',
          '-Command',
          "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('${f.path}',[ref]\$null,[ref]\$e); if(\$e){'bad'} else {'ok'}",
        ]);
        expect('${r.stdout}'.trim(), 'ok', reason: script);
        f.parent.deleteSync(recursive: true);
      }
    }, skip: !Platform.isWindows ? 'PowerShell parses on Windows' : false);
  });

  test('addresses: not the loopback, not self-assigned', () {
    expect(reachableAddresses(['127.0.0.1', '192.168.1.42', '169.254.10.3', '10.0.5.17']), ['192.168.1.42', '10.0.5.17']);
  });

  group('the dialog', () {
    final shot = GlobalKey();

    Future<_FakePc> pump(WidgetTester tester, ThisPcState? state, {ThisPcChange result = ThisPcChange.done}) async {
      await tester.runAsync(loadShotFonts);
      L10nGlobal.update(en);
      final t = BuiltInThemes.getById('default_dark');
      AppColors.applyTheme(t.colorScheme);
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(900, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pc = _FakePc(state, changeResult: result);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          thisPcRemoteAccessProvider.overrideWithValue(pc),
          thisPcAddressesProvider.overrideWith((ref) async => const ['192.168.1.42', '10.0.5.17']),
          thisPcAccountProvider.overrideWithValue('alex'),
        ],
        child: MaterialApp(
          theme: t.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (context, child) => RepaintBoundary(key: shot, child: child),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(onPressed: () => showThisPcRemoteAccess(context), child: const Text('open')),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
      return pc;
    }

    testWidgets('off: says why it cannot be reached, turns it on, then shows where to reach it', (tester) async {
      final pc = await pump(
          tester, const ThisPcState(edition: 'Professional', on: false, nla: true, port: 3389, firewallOpen: false));
      expect(find.text(en.thisPcNotReady), findsOneWidget);
      expect(find.text(en.thisPcFirewallClosed), findsOneWidget);
      expect(find.text(en.thisPcReach), findsNothing, reason: 'no address to add while it is off');
      if (shotsEnabled) await saveShot(tester, shot, 'this_pc_off');
      await tester.tap(find.byKey(const ValueKey('this-pc-turn-on')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(pc.changes, [true]);
      expect(find.text(en.thisPcReady), findsOneWidget);
      expect(find.text(en.thisPcReach), findsOneWidget);
      expect(find.byKey(const ValueKey('this-pc-address-192.168.1.42')), findsOneWidget);
      expect(find.byKey(const ValueKey('this-pc-turn-on')), findsNothing);
      if (shotsEnabled) await saveShot(tester, shot, 'this_pc_on');
    });

    testWidgets('refused at Windows\' question: nothing changed, and it says so', (tester) async {
      // (A computer's notices go to the app's toast layer; shown in place here.)
      debugTopSnackBarOnPhone = true;
      addTearDown(() => debugTopSnackBarOnPhone = null);
      final pc = await pump(tester, const ThisPcState(edition: 'Professional', on: false, nla: true, port: 3389, firewallOpen: false),
          result: ThisPcChange.refused);
      await tester.tap(find.byKey(const ValueKey('this-pc-turn-on')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(pc.changes, [true]);
      expect(find.text(en.thisPcRefused), findsOneWidget);
      expect(find.text(en.thisPcNotReady), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('Windows Home: says so and offers no switch', (tester) async {
      await pump(tester, const ThisPcState(edition: 'Core', on: false, nla: false, port: 3389, firewallOpen: false));
      expect(find.text(en.thisPcEditionHome), findsOneWidget);
      expect(find.byKey(const ValueKey('this-pc-turn-on')), findsNothing);
      expect(find.byKey(const ValueKey('this-pc-rdp')), findsNothing);
    });

    testWidgets('nothing could be read: says so', (tester) async {
      await pump(tester, null);
      expect(find.text(en.thisPcUnreadable), findsOneWidget);
    });
  });
}
