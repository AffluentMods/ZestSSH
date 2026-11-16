import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/session/rdp_account.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// An RDP account as written in a key's user name (4.0;
/// the domain is typed with the name), what the engine is told for a
/// host's options, and what it says back when a host's setting does not fit
/// its server.
void main() {
  test('a domain is taken from DOMAIN\\user; user@domain goes as it is; a name alone has none', () {
    expect(rdpAccount(r'CORP\alex'), (username: 'alex', domain: 'CORP'));
    expect(rdpAccount(r'  CORP \ alex  '), (username: 'alex', domain: 'CORP'));
    expect(rdpAccount(r'.\alex'), (username: 'alex', domain: '.'), reason: "the PC's own account");
    expect(rdpAccount('alex@corp.example'), (username: 'alex@corp.example', domain: null));
    expect(rdpAccount('alex'), (username: 'alex', domain: null));
    expect(rdpAccount(r'\alex'), (username: 'alex', domain: null));
    expect(rdpAccount(r'CORP\'), (username: '', domain: 'CORP'));
    // Only the first backslash parts the two.
    expect(rdpAccount(r'CORP\al\ex'), (username: r'al\ex', domain: 'CORP'));
  });

  test('H.264 is asked for by Modern alone (and used only where the device has a decoder)', () {
    expect({for (final g in ScreenGraphics.values) g: rdpH264Name(g.name)}, {
      ScreenGraphics.auto: 'off',
      ScreenGraphics.modern: 'avc444',
      ScreenGraphics.remotefx: 'off',
      ScreenGraphics.basic: 'off',
    });
  });

  test("a host's Graphics choice as the engine names it", () {
    expect({for (final g in ScreenGraphics.values) g: rdpGraphicsName(g.name)}, {
      ScreenGraphics.auto: 'gfx',
      ScreenGraphics.modern: 'gfx',
      ScreenGraphics.remotefx: 'remotefx',
      ScreenGraphics.basic: 'bitmap',
    });
  });

  test('the request of an RDP session: with NLA its password, without NLA none at all', () {
    const withNla = ScreenConnectOptions.rdp(
        username: 'alex', domain: 'CORP', password: 'hunter2', serverName: 'pc.example.com', graphics: 'gfx', h264: 'off');
    final a = withNla.toRequest();
    expect(a['kind'], 'rdp');
    expect(a['rdp_nla'], isTrue);
    expect(a['password'], 'hunter2');
    expect((a['username'], a['domain'], a['server_name']), ('alex', 'CORP', 'pc.example.com'));
    const without = ScreenConnectOptions.rdp(username: 'alex', password: 'hunter2', nla: false);
    final b = without.toRequest();
    expect(b['rdp_nla'], isFalse);
    expect(b.containsKey('password'), isFalse, reason: 'never handed to the engine');
    expect(without.password, isNull);
    // The pin added for a second try keeps the rest.
    expect(without.copyWith(tlsPin: 'ab' * 32).toRequest()['rdp_nla'], isFalse);
    expect(withNla.toString(), isNot(contains('hunter2')));
    // A VNC request says nothing of NLA.
    expect(const ScreenConnectOptions.vnc(password: 'p').toRequest().containsKey('rdp_nla'), isFalse);
    // The clipboard's channel: none unless asked for, and then there but not shared yet (the
    // view's switch says when). The pin added for a second try keeps it.
    expect(a['rdp_clipboard'], 'none');
    const sharing = ScreenConnectOptions.rdp(username: 'alex', password: 'p', clipboard: true);
    expect(sharing.toRequest()['rdp_clipboard'], 'off');
    expect(sharing.copyWith(tlsPin: 'ab' * 32).toRequest()['rdp_clipboard'], 'off');
    expect(const ScreenConnectOptions.vnc(password: 'p').toRequest().containsKey('rdp_clipboard'), isFalse);
  });

  test("the pointer's shape from the engine: a shape, hidden, and the system's own", () {
    final shape = ScreenCursor.parse(Uint8List.fromList([1, 0, 1, 0, 0, 0, 0, 0, 9, 8, 7, 255]))!;
    expect((shape.width, shape.height, shape.hidden, shape.system), (1, 1, false, false));
    final hidden = ScreenCursor.parse(Uint8List(8))!;
    expect((hidden.hidden, hidden.system), (true, false));
    // The event's number 1: the system's own pointer, whatever bytes come with it.
    for (final bytes in [Uint8List(8), Uint8List(0), Uint8List.fromList([1, 0, 1, 0, 0, 0, 0, 0, 9, 8, 7, 255])]) {
      final system = ScreenCursor.parse(bytes, a: 1)!;
      expect((system.system, system.hidden, system.width), (true, false, 0));
    }
    // Pixels that are not the size said: hidden, not half drawn.
    expect(ScreenCursor.parse(Uint8List.fromList([2, 0, 2, 0, 0, 0, 0, 0, 1, 2, 3]))!.hidden, isTrue);
    expect(ScreenCursor.parse(Uint8List(3)), isNull);
  });

  test("the engine's own word for what did not fit is kept; anything else in its place is not", () {
    ScreenClosed closed(Object? detail) =>
        ScreenClosed.fromJson({'reason': 'protocol', 'message': 'negotiation failure', 'detail': detail});
    expect(closed('nla_missing').detail, 'nla_missing');
    expect(closed('nla_required').detail, 'nla_required');
    expect(closed(null).detail, isNull);
    expect(closed(7).detail, isNull);
    expect(closed('Click here: http://example.com').detail, isNull);
    expect(closed('x' * 41).detail, isNull);
  });

  test("an RDP host that did not open is said in RDP's words, each with its code, and is not tried again", () {
    final en = lookupAppLocalizations(const Locale('en'));
    ScreenFailure of(String reason, {String? detail, bool rdp = true}) => ScreenFailure.ofClosed(
        ScreenClosed.fromJson({'reason': reason, 'message': 'as the engine said it', 'detail': detail}),
        rdp: rdp);

    final refused = of('auth');
    expect(refused.kind, ScreenFailureKind.rdpSignInRefused);
    expect(refused.code?.code, 'ZS-1812');
    expect(refused.reconnectCannotHelp, isTrue);
    expect(screenFailureText(en, refused), allOf(contains(en.screenRdpSignInRefused), contains('ZS-1812')));
    expect(screenFailureText(en, refused), isNot(contains('VNC')));

    final missing = of('protocol', detail: 'nla_missing');
    expect(missing.kind, ScreenFailureKind.rdpNlaMissing);
    expect(missing.code?.code, 'ZS-1813');
    expect(missing.reconnectCannotHelp, isTrue);
    expect(screenFailureText(en, missing), allOf(contains(en.connectionEditRdpWithoutNla), contains('ZS-1813')));

    final required = of('protocol', detail: 'nla_required');
    expect(required.kind, ScreenFailureKind.rdpNlaRequired);
    expect(required.code?.code, 'ZS-1814');
    expect(screenFailureText(en, required), allOf(contains(en.connectionEditRdpWithoutNla), contains('ZS-1814')));

    // Any other protocol or TLS failure of an RDP host: as it came, with no code and no word of VNC.
    for (final other in [of('protocol'), of('tls'), of('protocol', detail: 'something_else')]) {
      expect(other.kind, ScreenFailureKind.stopped);
      expect(other.code, isNull);
      expect(screenFailureText(en, other), allOf(contains('as the engine said it'), isNot(contains('VNC'))));
    }

    // A VNC screen's closings keep VNC's kinds, whatever detail came with them.
    expect(of('auth', rdp: false).kind, ScreenFailureKind.passwordRefused);
    expect(of('protocol', detail: 'nla_missing', rdp: false).kind, ScreenFailureKind.noSecurity);
    // A certificate that changed is the same for both; a server that ended the session is said
    // without "VNC" for an RDP host.
    expect(of('certificate').kind, ScreenFailureKind.certificateChanged);
    expect(of('server_closed', rdp: false).kind, ScreenFailureKind.serverEnded);
    expect(of('server_closed').kind, ScreenFailureKind.rdpEnded);
    expect(screenFailureText(en, of('server_closed')), en.screenRdpServerEnded);

    // Why the server refused the sign-in, where it said: each with its own words and code, and
    // none tried again by itself.
    for (final (detail, kind, code) in [
      ('account_locked', ScreenFailureKind.rdpAccountLocked, 'ZS-1815'),
      ('account_disabled', ScreenFailureKind.rdpAccountDisabled, 'ZS-1816'),
      ('password_expired', ScreenFailureKind.rdpPasswordExpired, 'ZS-1817'),
      ('account_restricted', ScreenFailureKind.rdpAccountNotAllowed, 'ZS-1818'),
    ]) {
      final f = of('auth', detail: detail);
      expect(f.kind, kind, reason: detail);
      expect(f.code?.code, code, reason: detail);
      expect(f.reconnectCannotHelp, isTrue, reason: detail);
      expect(screenFailureText(en, f), allOf(contains(code), isNot(contains('VNC'))), reason: detail);
      // The same name on a VNC screen's closing means nothing there.
      expect(of('auth', detail: detail, rdp: false).kind, ScreenFailureKind.passwordRefused);
    }
    // A name of a newer engine's: the sign-in was refused, no more.
    expect(of('auth', detail: 'something_new').kind, ScreenFailureKind.rdpSignInRefused);

    // Why the server ended a session, where it said. Three have a code; the others are said and
    // nothing is wrong on this side. None is connected to again by itself.
    expect(of('server_closed', detail: 'replaced').code?.code, 'ZS-1819');
    expect(of('server_closed', detail: 'licence').code?.code, 'ZS-1820');
    expect(of('server_closed', detail: 'not_allowed').code?.code, 'ZS-1818');
    final said = <String, String>{
      'idle': en.screenRdpEndedIdle,
      'logon_timeout': en.screenRdpEndedLogonTimeout,
      'denied': en.screenRdpEndedDenied,
      'fresh_credentials': en.screenRdpEndedFreshCredentials,
      'admin_disconnected': en.screenRdpEndedByAdmin,
      'admin_signed_out': en.screenRdpEndedByAdmin,
      'signed_out': en.screenRdpEndedSignedOut,
      'disconnected': en.screenRdpEndedDisconnected,
      'shutdown': en.screenRdpEndedShutdown,
      'restart': en.screenRdpEndedShutdown,
      'something_new': en.screenRdpServerEnded,
    };
    for (final MapEntry(key: detail, value: words) in said.entries) {
      final f = of('server_closed', detail: detail);
      expect(f.kind, ScreenFailureKind.rdpEnded, reason: detail);
      expect(f.code, isNull, reason: detail);
      expect(f.reconnectCannotHelp, isTrue, reason: detail);
      expect(screenFailureText(en, f), words, reason: detail);
    }
    for (final detail in ['replaced', 'licence', 'not_allowed']) {
      expect(of('server_closed', detail: detail).reconnectCannotHelp, isTrue, reason: detail);
    }

    // Nothing answers at the address: an RDP host's sentence names RDP, a VNC screen's VNC, and
    // the place and the code are the same.
    const nothing = ScreenFailure(ScreenFailureKind.nothingAnswers, 'x', carrier: 'gw', address: 'localhost:3389');
    expect(screenFailureText(en, nothing), allOf(contains('VNC'), contains('localhost:3389 on gw'), contains('ZS-1801')));
    final asRdp = nothing.asRdp();
    expect((asRdp.rdp, asRdp.carrier, asRdp.address), (true, 'gw', 'localhost:3389'));
    expect(screenFailureText(en, asRdp),
        allOf(contains('the RDP server is not running'), contains('localhost:3389 on gw'), contains('ZS-1801'), isNot(contains('VNC'))));
    expect(identical(asRdp.asRdp(), asRdp), isTrue);
    // A closing read for an RDP host is an RDP host's, with its reason kept.
    expect(of('server_closed', detail: 'idle').rdp, isTrue);
    expect(of('server_closed', detail: 'idle').asRdp().hint, 'idle');
    expect(of('auth', rdp: false).rdp, isFalse);
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(l.screenRdpNothingAnswers('a', 'b'), allOf(contains('RDP'), isNot(contains('VNC'))), reason: '$locale');
    }

    // In every language the switch is named as the host's editor names it.
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final name = l.connectionEditRdpWithoutNla;
      expect(l.screenRdpNlaMissing(name), contains(name), reason: '$locale');
      expect(l.screenRdpNlaRequired(name), contains(name), reason: '$locale');
      expect(l.screenRdpSignInRefused, isNotEmpty);
    }
  });
}
