import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';

/// The rule "Sign in with SSO" (3.0): in the record only when on,
/// so rules from before it keep their bytes; read back as off when missing;
/// named by the server as 'sso'.
void main() {
  test('written only when on, read back either way', () {
    expect(RecordRules.none.toBody().containsKey('require_sso'), isFalse);
    expect(RecordRules.none.toBody().containsKey('sso_two_step'), isFalse, reason: 'written only when on');
    expect(const RecordRules(ssoTwoStep: true).toBody()['sso_two_step'], isTrue);
    expect(const RecordRules(ssoTwoStep: true).isNone, isFalse);
    const on = RecordRules(requireSso: true);
    expect(on.toBody()['require_sso'], isTrue);
    expect(on.isNone, isFalse);
    expect(RecordRules.fromStored(on.toBody()).requireSso, isTrue);
    expect(RecordRules.fromStored(RecordRules.none.toBody()).requireSso, isFalse);
    expect(RecordRules.fromStored({'require_sso': 'true'}).requireSso, isFalse, reason: 'only a real true');
    expect(on.copyWith(noExport: true).requireSso, isTrue);
    expect(on.copyWith(requireSso: false).isNone, isTrue);
  });

  test("the server's name for it", () {
    expect(UnmetRule.fromServer('sso'), UnmetRule.sso);
    expect(UnmetRule.sso.server, isTrue);
  });
}
