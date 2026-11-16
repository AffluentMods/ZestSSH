import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/terminal_providers.dart' show keepCompletionListing, kCompletionListingKeptFor;

/// Path completion's folder listings go once they are no longer used (found in
/// a review): every folder a session completed in kept its listing
/// (up to 20,000 names) until the session closed.
void main() {
  test('a listing older than it is used is dropped as another is kept', () {
    final listings = <String, ({DateTime at, List<(String, bool)> names})>{};
    final start = DateTime(2026, 11, 14, 9);
    for (var i = 0; i < 100; i++) {
      keepCompletionListing(listings, 's1\u0000/srv/f$i', [('a', false)], start.add(Duration(milliseconds: i)));
    }
    expect(listings, hasLength(100), reason: 'all still within their time');
    keepCompletionListing(listings, 's1\u0000/etc', [('hosts', false)], start.add(kCompletionListingKeptFor + const Duration(seconds: 1)));
    expect(listings.keys, ['s1\u0000/etc']);
  });
}
