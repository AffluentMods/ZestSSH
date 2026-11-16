import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';

/// Who the rule on address domains holds back: the app and the server decide
/// it from the same corpus (domain_rule_corpus.json here, copied to the
/// backend's test/fixtures/orchard_domain_rule_corpus.json and read by
/// test/orchard_domain_rule_corpus.test.js there), so that what the member list
/// marks is what the server does (for members a new
/// list of domains leaves out).
void main() {
  final corpus = jsonDecode(File('test/features/orchards/rules/domain_rule_corpus.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (corpus['cases'] as List).cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('${c['why']}: ${c['held'] == true ? 'held back' : 'not held back'}', () {
      expect(
        domainRuleHolds({...(c['domains'] as List).cast<String>()}, c['email'] as String?, endsAt: c['ends_at'] as int?),
        c['held'],
      );
    });
  }

  final endNow = corpus['end_now'] as int;
  for (final c in (corpus['end_dates'] as List).cast<Map<String, dynamic>>()) {
    test('an end date: ${c['why']}: ${c['too_far'] == true ? 'too far' : 'not too far'}', () {
      expect(memberEndTooFar(c['ends_at'] as int?, endNow), c['too_far']);
    });
  }

  test('the corpus holds both sides of the rule', () {
    expect(cases.any((c) => c['held'] == true), isTrue);
    expect(cases.any((c) => c['held'] == false && c['ends_at'] != null && (c['domains'] as List).isNotEmpty), isTrue);
  });

  test('a domain is what follows the last @, in small letters', () {
    expect(addressDomain('Ann@CORP.Example'), 'corp.example');
    expect(addressDomain(' a@b@c.example '), 'c.example');
    expect(addressDomain('nobody'), '');
    expect(addressDomain(null), '');
  });
}
