import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_detail_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_edit_controller.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  // ══════════════════════════════════════════════════════════════
  // Live command preview (fix #4) - matches the real ssh invocation
  // ══════════════════════════════════════════════════════════════
  group('buildForwardCommand', () {
    test('local (-L) reproduces the canonical invocation', () {
      expect(
        buildForwardCommand(
          type: PfForwardType.local,
          bindAddress: 'localhost',
          bindPort: 3306,
          remoteHost: 'localhost',
          remotePort: 3306,
          host: '10.50.0.21',
          username: 'deploy',
        ),
        'ssh -N -f -L 3306:localhost:3306 deploy@10.50.0.21',
      );
    });

    test('remote (-R) inverts to serverPort:localHost:localPort', () {
      // The service binds `remotePort` on the server and relays back to the
      // local `bindAddress:bindPort` - so -R lists the server port first.
      expect(
        buildForwardCommand(
          type: PfForwardType.remote,
          bindAddress: 'localhost',
          bindPort: 8080,
          remoteHost: 'localhost',
          remotePort: 3000,
          host: 'srv',
          username: 'u',
        ),
        'ssh -N -f -R 3000:localhost:8080 u@srv',
      );
    });

    test('dynamic (-D) is just the local SOCKS port', () {
      expect(
        buildForwardCommand(
          type: PfForwardType.dynamic,
          bindAddress: 'localhost',
          bindPort: 1080,
          remoteHost: '',
          remotePort: null,
          host: 'srv',
          username: 'u',
        ),
        'ssh -N -f -D 1080 u@srv',
      );
    });

    test('a non-loopback bind address surfaces as the [bind:] prefix', () {
      expect(
        buildForwardCommand(
          type: PfForwardType.local,
          bindAddress: '0.0.0.0',
          bindPort: 8080,
          remoteHost: '10.0.0.5',
          remotePort: 80,
          host: 'srv',
          username: 'u',
        ),
        'ssh -N -f -L 0.0.0.0:8080:10.0.0.5:80 u@srv',
      );
    });

    test('missing ports dim in place as <port>, never a literal ?', () {
      expect(
        buildForwardCommand(
          type: PfForwardType.local,
          bindAddress: 'localhost',
          bindPort: null,
          remoteHost: 'localhost',
          remotePort: null,
          host: 'srv',
          username: 'u',
        ),
        'ssh -N -f -L <port>:localhost:<port> u@srv',
      );
    });

    test('a missing host dims in place as <user@host>, never literal host', () {
      expect(
        buildForwardCommand(
          type: PfForwardType.local,
          bindAddress: 'localhost',
          bindPort: 3306,
          remoteHost: 'localhost',
          remotePort: 3306,
          host: '',
        ),
        'ssh -N -f -L 3306:localhost:3306 <user@host>',
      );
    });

    test('the Options toggles inject -o ExitOnForwardFailure=yes and -g', () {
      expect(
        buildForwardCommand(
          type: PfForwardType.local,
          bindAddress: '0.0.0.0',
          bindPort: 8080,
          remoteHost: 'localhost',
          remotePort: 80,
          host: 'srv',
          username: 'u',
          exitOnFailure: true,
          gatewayPorts: true,
        ),
        'ssh -N -f -o ExitOnForwardFailure=yes -g -L 0.0.0.0:8080:localhost:80 '
        'u@srv',
      );
    });

    test('no username → bare host; custom flags pass through', () {
      expect(
        buildForwardCommand(
          type: PfForwardType.local,
          bindAddress: 'localhost',
          bindPort: 22,
          remoteHost: 'localhost',
          remotePort: 22,
          host: 'box',
          username: null,
          flags: '-N -f -o ExitOnForwardFailure=yes',
        ),
        'ssh -N -f -o ExitOnForwardFailure=yes -L 22:localhost:22 box',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════
  // Saved-rule runtime state word (fix #6)
  // ══════════════════════════════════════════════════════════════
  group('pfRuleStateFor / pfRuleStatusKind', () {
    test('stopped when neither active nor errored', () {
      expect(pfRuleStateFor(active: false, errored: false),
          PfRuleState.stopped);
      expect(pfRuleStatusKind(PfRuleState.stopped), ZestStatusKind.neutral);
    });

    test('running when active', () {
      expect(
          pfRuleStateFor(active: true, errored: false), PfRuleState.running);
      expect(pfRuleStatusKind(PfRuleState.running), ZestStatusKind.healthy);
    });

    test('error wins even when a forward is nominally active', () {
      expect(pfRuleStateFor(active: false, errored: true), PfRuleState.error);
      expect(pfRuleStateFor(active: true, errored: true), PfRuleState.error);
      expect(pfRuleStatusKind(PfRuleState.error), ZestStatusKind.critical);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // Controller - defaults, dirty, validation, live preview
  // ══════════════════════════════════════════════════════════════
  group('PortForwardEditController', () {
    test('a new rule opens in Simple with localhost + -N -f as VALUES', () {
      final c = PortForwardEditController()..bind(null);
      expect(c.isCreating, isTrue);
      expect(c.mode, PfEditorMode.simple);
      expect(c.isDirty, isFalse);
      // The defaults live in the TEXT slot (bright value), never a placeholder.
      expect(c.advSourceHostController.text, 'localhost');
      expect(c.advDestHostController.text, 'localhost');
      expect(c.advFlagsController.text, '-N -f');
      c.dispose();
    });

    test('any edit flips the dirty flag', () {
      final c = PortForwardEditController()..bind(null);
      expect(c.isDirty, isFalse);
      c.markDirty();
      expect(c.isDirty, isTrue);
      c.dispose();
    });

    test('buildCompanion refuses without a scoped connection', () {
      final c = PortForwardEditController()..bind(null);
      final r = c.buildCompanion();
      expect(r.companion, isNull);
      expect(r.error, contains('Pick a host'));
      c.dispose();
    });

    test('Simple local requires both ports', () {
      final c = PortForwardEditController()
        ..bind(null)
        ..setConnectionId('conn1');
      // Only the service port set - My port is still missing.
      c.simpleRemotePortController.text = '3306';
      final r = c.buildCompanion();
      expect(r.companion, isNull);
      expect(r.error, contains('My port'));
      c.dispose();
    });

    test('Simple local maps My port → bindPort, Service port → remotePort', () {
      final c = PortForwardEditController()
        ..bind(null)
        ..setConnectionId('conn1');
      c.nameController.text = 'MySQL';
      c.simpleRemotePortController.text = '3306'; // Service port → remotePort
      c.simpleBindPortController.text = '13306'; // My port → bindPort
      final r = c.buildCompanion();
      expect(r.error, isNull);
      final comp = r.companion!;
      expect(comp.type.value, 'local');
      expect(comp.bindPort.value, 13306);
      expect(comp.remotePort.value, 3306);
      expect(comp.label.value, 'MySQL');
      c.dispose();
    });

    test('Advanced builds a faithful local companion', () {
      final c = PortForwardEditController()
        ..bind(null)
        ..setConnectionId('conn1')
        ..setMode(PfEditorMode.advanced);
      c.setAdvancedType(PfForwardType.local);
      c.advSourcePortController.text = '3306';
      c.advDestHostController.text = 'localhost';
      c.advDestPortController.text = '3306';
      final r = c.buildCompanion();
      expect(r.error, isNull);
      final comp = r.companion!;
      expect(comp.type.value, 'local');
      expect(comp.bindAddress.value, 'localhost');
      expect(comp.bindPort.value, 3306);
      expect(comp.remoteHost.value, 'localhost');
      expect(comp.remotePort.value, 3306);
      c.dispose();
    });

    test('previewCommand tracks the advanced fields for L / R / D', () {
      final c = PortForwardEditController()
        ..bind(null)
        ..setConnectionId('conn1')
        ..setMode(PfEditorMode.advanced);
      // Isolate the L/R/D mapping from the Options flags.
      c.setExitOnFailure(false);
      c.setGatewayPorts(false);

      c.setAdvancedType(PfForwardType.local);
      c.advSourceHostController.text = 'localhost';
      c.advSourcePortController.text = '3306';
      c.advDestHostController.text = 'localhost';
      c.advDestPortController.text = '3306';
      expect(
        c.previewCommand(host: '10.50.0.21', username: 'deploy'),
        'ssh -N -f -L 3306:localhost:3306 deploy@10.50.0.21',
      );

      c.setAdvancedType(PfForwardType.remote);
      c.advSourcePortController.text = '8080';
      c.advDestPortController.text = '3000';
      expect(
        c.previewCommand(host: 'srv', username: 'u'),
        'ssh -N -f -R 3000:localhost:8080 u@srv',
      );

      c.setAdvancedType(PfForwardType.dynamic);
      c.advSourcePortController.text = '1080';
      expect(
        c.previewCommand(host: 'srv', username: 'u'),
        'ssh -N -f -D 1080 u@srv',
      );
      c.dispose();
    });
  });

  // ══════════════════════════════════════════════════════════════
  // Widget - placeholder vs value contrast + live preview render
  // ══════════════════════════════════════════════════════════════
  group('PortForwardDetailPane (Advanced)', () {
    Widget host(PortForwardEditController controller) {
      return ProviderScope(
        overrides: [
          // The pane watches recording mode (masked host fields), which is
          // seeded from preferences.
          sharedPreferencesProvider.overrideWithValue(prefs),
          connectionsWithDetailsProvider.overrideWith(
            (ref) => Stream.value(const <ConnectionWithDetails>[]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PortForwardDetailPane(
              controller: controller,
              hasSelection: true,
              onSave: () async => true,
              onClose: () {},
              onDelete: () {},
              onModeChanged: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets(
        'localhost renders as a VALUE (controller text), the port as a '
        'dim placeholder, and the command preview is live', (tester) async {
      final controller = PortForwardEditController()..bind(null);
      controller.setMode(PfEditorMode.advanced);
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(controller));
      await tester.pumpAndSettle();

      // VALUE (bright): the Source Host field's text is the committed default,
      // sitting in the controller/text slot - not the placeholder hint.
      expect(
        find.byWidgetPredicate(
            (w) => w is TextField && w.controller?.text == 'localhost'),
        findsWidgets,
      );

      // PLACEHOLDER (dim): the Source Port field carries '8080' only as a hint,
      // and its controller is empty.
      expect(
        find.byWidgetPredicate((w) =>
            w is TextField &&
            w.decoration?.hintText == '8080' &&
            (w.controller?.text ?? '').isEmpty),
        findsOneWidget,
      );

      // Live command preview is present. exitOnFailure defaults on for a new
      // rule, so the Options-driven -o flag sits between -N -f and -L.
      expect(find.textContaining('ssh -N -f'), findsOneWidget);
    });

    // Found while comparing the five versions: Reconnect was
    // offered, and nothing read it.
    testWidgets('its options are those that do something: no Reconnect', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final controller = PortForwardEditController()..bind(null);
      controller.setMode(PfEditorMode.advanced);
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));
      await tester.pumpAndSettle();
      for (final option in [l10n.zestPfOptAutoStart, l10n.zestPfOptExitOnFailure, l10n.zestPfOptGatewayPorts]) {
        expect(find.text(option), findsOneWidget, reason: option);
      }
      expect(find.text('Reconnect if dropped'), findsNothing);
    });
  });
}
