// Importing hosts (4.0): a Remote Desktop file (.rdp). What an RDP
// host can hold is read; the saved password never is; a file that names a
// program or turns NLA off is not obeyed; and a hostile file costs no more
// than what is looked at.
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart' show decodeCsvBytes, kCsvMaxBytes;
import 'package:zestssh/features/cloud_import/csv/csv_import_writer.dart' show importedScreenOptions;
import 'package:zestssh/features/cloud_import/csv/rdp_file.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';

/// A file as Windows' own client saves one (made-up names).
const _windows = '''
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
full address:s:office-pc.example.test
audiomode:i:0
redirectprinters:i:1
redirectclipboard:i:1
autoreconnection enabled:i:1
authentication level:i:2
prompt for credentials:i:0
gatewayhostname:s:
gatewayusagemethod:i:4
promptcredentialonce:i:0
username:s:EXAMPLE\\alex
drivestoredirect:s:
''';

void main() {
  test('a file as Windows saves it: the computer, the account, sound and the clipboard; the rest counted', () {
    final f = readRdpFile(_windows.replaceAll('\n', '\r\n'));
    expect(f.problem, isNull);
    expect((f.address, f.port), ('office-pc.example.test', 3389));
    expect(f.user, r'EXAMPLE\alex');
    expect(f.account, r'EXAMPLE\alex');
    expect(f.sound, isTrue);
    expect(f.clipboard, isTrue);
    expect(f.gateway, isNull, reason: 'the file names none and says not to use one');
    expect((f.allMonitors, f.monitors), (false, 1));
    expect((f.hadPassword, f.forProgram, f.nlaOff), (false, false, false));
    // screen mode, the desktop's width and height, bpp, printers, reconnection, the two prompts, drives.
    expect(f.unused, 9);
  });

  test('it is known by its full address line, and nothing else is one', () {
    expect(isRdpFile(_windows), isTrue);
    expect(isRdpFile('  Full Address:s:pc.example.test\n'), isTrue);
    expect(isRdpFile('name,host\nweb,web-01.example.test\n'), isFalse);
    expect(isRdpFile('the full address:s:pc of a note'), isFalse);
    expect(isRdpFile(''), isFalse);
  });

  test('a file in UTF-16, as Windows writes one, reads the same', () {
    final units = _windows.codeUnits;
    final bytes = [0xFF, 0xFE, for (final u in units) ...[u & 0xff, u >> 8]];
    final f = readRdpFile(decodeCsvBytes(bytes));
    expect((f.address, f.user), ('office-pc.example.test', r'EXAMPLE\alex'));
    // And one whose byte order mark is still in its text.
    expect(readRdpFile('${String.fromCharCode(0xFEFF)}full address:s:pc.example.test').address, 'pc.example.test');
  });

  group('the address', () {
    RdpFile of(String address, {String more = ''}) => readRdpFile('full address:s:$address\n$more');

    test('with its port, in brackets, or the port on a line of its own', () {
      expect((of('pc.example.test:3390').address, of('pc.example.test:3390').port), ('pc.example.test', 3390));
      expect((of('[2001:db8::7]:3391').address, of('[2001:db8::7]:3391').port), ('2001:db8::7', 3391));
      expect((of('[2001:db8::7]').address, of('[2001:db8::7]').port), ('2001:db8::7', 3389));
      expect(of('192.0.2.10', more: 'server port:i:13389').port, 13389);
      // The address's own port is the one meant.
      expect(of('pc.example.test:3390', more: 'server port:i:13389').port, 3390);
      // A port that is none is not taken: the usual one.
      expect(of('pc.example.test', more: 'server port:i:99999').port, 3389);
      expect(of('pc.example.test', more: 'server port:i:abc').port, 3389);
    });

    test('what is no address is a file with no computer in it', () {
      for (final bad in [
        '',
        '   ',
        'two words',
        'pc/example',
        r'pc\share',
        '-oProxyCommand=x',
        'alex@pc.example.test',
        'pc.example.test:0',
        'pc.example.test:70000',
        'pc.example.test:port',
        '[2001:db8::7',
        '[2001:db8::7]x',
        'a' * 300,
      ]) {
        expect(of(bad).problem, RdpFileProblem.noAddress, reason: bad);
        expect(of(bad).address, isEmpty);
      }
      expect(readRdpFile('username:s:alex\n').problem, RdpFileProblem.noAddress);
    });
  });

  test('a gateway only where the file says to use one, with its port and whose sign-in it takes', () {
    RdpFile of(int usage, {String host = 'gw.example.test', String more = ''}) =>
        readRdpFile('full address:s:pc.example.test\ngatewayhostname:s:$host\ngatewayusagemethod:i:$usage\n$more');
    for (final use in [1, 2]) {
      expect((of(use).gateway, of(use).gatewayPort), ('gw.example.test', 443), reason: '$use');
    }
    for (final not in [0, 3, 4, 9]) {
      expect(of(not).gateway, isNull, reason: '$not');
    }
    expect(of(1, host: 'gw.example.test:8443').gatewayPort, 8443);
    expect(of(1, host: 'not an address').gateway, isNull);
    expect(of(1).gatewaySameSignIn, isTrue);
    expect(of(1, more: 'promptcredentialonce:i:0').gatewaySameSignIn, isFalse);
    expect(of(1, more: 'promptcredentialonce:i:1').gatewaySameSignIn, isTrue);
  });

  // RD Gateway (4.0): the host comes in through its gateway only where the build offers gateways.
  test("the imported host carries the file's gateway, written into its options only where gateways are offered", () {
    final row = readRdpFileHosts(
            'full address:s:pc.example.test\ngatewayhostname:s:gw.example.test:8443\ngatewayusagemethod:i:1\n',
            rdp: true)
        .rows
        .single;
    expect((row.gateway, row.gatewayPort), ('gw.example.test', 8443));
    expect(ScreenOptions.decode(importedScreenOptions(row, gateway: true)).gateway,
        const ScreenGateway(host: 'gw.example.test', port: 8443));
    expect(ScreenOptions.decode(importedScreenOptions(row)).gateway, isNull, reason: 'not offered: it connects directly');
    final none = readRdpFileHosts('full address:s:pc.example.test\n', rdp: true).rows.single;
    expect(none.gateway, isNull);
    expect(importedScreenOptions(none, gateway: true), ScreenOptions.encodeDefaults());
  });

  test('every monitor, or the ones picked', () {
    RdpFile of(String more) => readRdpFile('full address:s:pc.example.test\n$more');
    expect((of('use multimon:i:1').allMonitors, of('use multimon:i:1').monitors), (true, 0));
    final picked = of('use multimon:i:1\nselectedmonitors:s:0, 2,2,x,');
    expect((picked.allMonitors, picked.monitors), (true, 2));
    // Monitors picked without multimon: one screen.
    expect(of('selectedmonitors:s:0,1').monitors, 1);
  });

  test('sound and the clipboard, only where the file says', () {
    RdpFile of(String more) => readRdpFile('full address:s:pc.example.test\n$more');
    expect(of('audiomode:i:0').sound, isTrue);
    expect(of('audiomode:i:1').sound, isFalse, reason: 'played on the remote');
    expect(of('audiomode:i:2').sound, isFalse);
    expect(of('').sound, isNull);
    expect(of('audiomode:i:7').sound, isNull);
    expect(of('redirectclipboard:i:0').clipboard, isFalse);
    expect(of('').clipboard, isNull);
  });

  test('the saved password is never read: the file is said to have had one, and that is all', () {
    const secret = '01000000D08C9DDF0115D1118C7A00C04FC297EB';
    final f = readRdpFile('full address:s:pc.example.test\nusername:s:alex\npassword 51:b:$secret\n');
    expect(f.hadPassword, isTrue);
    expect(f.unused, 0, reason: 'known, and left on purpose');
    for (final held in [f.address, f.user, f.domain, f.gateway, f.account]) {
      expect(held ?? '', isNot(contains(secret.substring(0, 12))));
    }
    // Under another number too.
    expect(readRdpFile('full address:s:pc.example.test\npassword 52:b:AA\n').hadPassword, isTrue);
  });

  test('a file for one program, or one that turns NLA off, is noted and not obeyed', () {
    RdpFile of(String more) => readRdpFile('full address:s:pc.example.test\n$more');
    expect(of('remoteapplicationmode:i:1').forProgram, isTrue);
    expect(of(r'remoteapplicationprogram:s:C:\tools\run.exe').forProgram, isTrue);
    expect(of('alternate shell:s:cmd.exe /c anything').forProgram, isTrue);
    expect(of('alternate shell:s:').forProgram, isFalse);
    expect(of('enablecredsspsupport:i:0').nlaOff, isTrue);
    expect(of('enablecredsspsupport:i:1').nlaOff, isFalse);
    expect(of('').nlaOff, isFalse);
  });

  test('the account: the domain in front where the file names one apart', () {
    RdpFile of(String more) => readRdpFile('full address:s:pc.example.test\n$more');
    expect(of('username:s:alex\ndomain:s:EXAMPLE').account, r'EXAMPLE\alex');
    expect(of('username:s:alex@example.test\ndomain:s:EXAMPLE').account, 'alex@example.test');
    expect(of(r'username:s:OTHER\alex' '\ndomain:s:EXAMPLE').account, r'OTHER\alex');
    expect(of('username:s:alex').account, 'alex');
    expect(of('domain:s:EXAMPLE').account, isNull);
  });

  test('the first of a name counts, names are read in any case, and what is not a setting is passed over', () {
    final f = readRdpFile(
      'FULL ADDRESS:s:first.example.test\n'
      'full address:s:second.example.test\n'
      'this is not a setting\n'
      ':s:nothing\n'
      'username:x:not a kind of value\n'
      'Username:S:alex\n',
    );
    expect(f.address, 'first.example.test');
    expect(f.user, 'alex');
  });

  group('a hostile file', () {
    test('larger than a file may be: not read', () {
      expect(readRdpFile('full address:s:pc.example.test\n${'x' * kCsvMaxBytes}').problem, RdpFileProblem.tooLarge);
    });

    test('millions of lines: the first two thousand are looked at, at once', () {
      final many = StringBuffer();
      for (var i = 0; i < 200000; i++) {
        many.write('setting$i:i:1\n');
      }
      many.write('full address:s:late.example.test\n');
      final watch = Stopwatch()..start();
      final f = readRdpFile(many.toString());
      expect(watch.elapsedMilliseconds, lessThan(2000));
      expect(f.problem, RdpFileProblem.noAddress, reason: 'the address is past what is looked at');
      expect(f.unused, kRdpFileMaxLines);
    });

    test('one line of four megabytes: cut, and the next line still read', () {
      final f = readRdpFile('username:s:${'a' * 4000000}\nfull address:s:pc.example.test\n');
      expect(f.address, 'pc.example.test');
      expect(f.user!.length, lessThanOrEqualTo(255));
    });

    test('text that would hide or reorder what is beside it does not come through', () {
      final rtl = String.fromCharCode(0x202e);
      final bell = String.fromCharCode(7);
      final f = readRdpFile('full address:s:pc.example.test\nusername:s:al${rtl}ex$bell\ndomain:s:EX${rtl}AMPLE\n');
      expect(f.user, 'al ex');
      expect(f.domain, 'EX AMPLE');
      // In an address it is no address at all.
      expect(readRdpFile('full address:s:pc$rtl.example.test\n').problem, isNotNull);
    });
  });
}
