import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/automation_service.dart';

/// SSRF guard for automation webhooks.
///
/// `AutomationService.sendWebhook` POSTs command stdout/stderr to a
/// user-configured URL. A malicious deep link / synced workflow could point
/// that URL at an internal service (loopback, RFC-1918, link-local, or the
/// 169.254.169.254 cloud-metadata endpoint) to exfiltrate output or reach
/// services that should never be exposed. `isBlockedWebhookHost` is the
/// synchronous classifier that refuses those literal targets.
///
/// Contract under test (read from the implementation):
///  - Only *literal* IPs and the `localhost` name are classified. Real DNS
///    names are NOT resolved here (deliberate - avoids DNS-rebinding TOCTOU
///    and latency), so `isBlockedWebhookHost` returns false for them. Any
///    DNS-rebinding defense would live elsewhere and is NOT covered by these
///    tests (see note at the bottom of the file).
///  - The host string comes from `Uri.host`, which has already stripped the
///    brackets from IPv6 literals (`[::1]` -> `::1`).
void main() {
  group('AutomationService.isBlockedWebhookHost (SSRF guard)', () {
    // ── Loopback is blocked ──────────────────────────────────────

    group('loopback targets are blocked', () {
      test('127.0.0.1 is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('127.0.0.1'), isTrue);
      });

      test('localhost name is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('localhost'), isTrue);
      });

      test('localhost is matched case-insensitively', () {
        expect(AutomationService.isBlockedWebhookHost('LOCALHOST'), isTrue);
      });

      test('*.localhost subdomains are blocked', () {
        expect(
          AutomationService.isBlockedWebhookHost('api.localhost'),
          isTrue,
        );
      });

      test('0.0.0.0 (this-network / all-interfaces) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('0.0.0.0'), isTrue);
      });

      test('::1 (IPv6 loopback) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('::1'), isTrue);
      });
    });

    // ── RFC-1918 private ranges are blocked ──────────────────────

    group('RFC-1918 private ranges are blocked', () {
      test('10.0.0.5 (10.0.0.0/8) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('10.0.0.5'), isTrue);
      });

      test('172.16.0.1 (low end of 172.16.0.0/12) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('172.16.0.1'), isTrue);
      });

      test('172.31.255.255 (high end of 172.16.0.0/12) is blocked', () {
        expect(
          AutomationService.isBlockedWebhookHost('172.31.255.255'),
          isTrue,
        );
      });

      test('192.168.1.1 (192.168.0.0/16) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('192.168.1.1'), isTrue);
      });
    });

    // ── Link-local / cloud metadata is blocked ───────────────────

    group('link-local and cloud metadata are blocked', () {
      test('169.254.169.254 (cloud metadata endpoint) is blocked', () {
        expect(
          AutomationService.isBlockedWebhookHost('169.254.169.254'),
          isTrue,
        );
      });

      test('169.254.0.1 (link-local) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('169.254.0.1'), isTrue);
      });
    });

    // ── Public hosts are allowed ─────────────────────────────────

    group('legitimate public destinations are allowed', () {
      test('a normal DNS hostname is allowed (not resolved here)', () {
        expect(
          AutomationService.isBlockedWebhookHost('hooks.example.com'),
          isFalse,
        );
      });

      test('203.0.113.10 (TEST-NET-3, a public literal) is allowed', () {
        expect(
          AutomationService.isBlockedWebhookHost('203.0.113.10'),
          isFalse,
        );
      });

      test('8.8.8.8 (public IPv4) is allowed', () {
        expect(AutomationService.isBlockedWebhookHost('8.8.8.8'), isFalse);
      });

      test('a boundary-adjacent public IP (172.15.0.1) is allowed', () {
        // 172.15.x is just below the 172.16.0.0/12 private block.
        expect(
          AutomationService.isBlockedWebhookHost('172.15.0.1'),
          isFalse,
        );
      });

      test('a boundary-adjacent public IP (172.32.0.1) is allowed', () {
        // 172.32.x is just above the 172.16.0.0/12 private block.
        expect(
          AutomationService.isBlockedWebhookHost('172.32.0.1'),
          isFalse,
        );
      });
    });

    // ── Extra ranges the implementation also covers ──────────────

    group('additional non-routable ranges are blocked', () {
      test('100.64.0.0/10 CGNAT (100.64.0.1) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('100.64.0.1'), isTrue);
      });

      test('fc00::/7 unique-local IPv6 (fc00::1) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('fc00::1'), isTrue);
      });

      test('fe80::/10 link-local IPv6 (fe80::1) is blocked', () {
        expect(AutomationService.isBlockedWebhookHost('fe80::1'), isTrue);
      });

      test('IPv4-mapped IPv6 loopback (::ffff:127.0.0.1) is blocked', () {
        // A ::ffff:a.b.c.d literal must be re-checked against the embedded
        // v4 address - otherwise it is a trivial loopback bypass.
        expect(
          AutomationService.isBlockedWebhookHost('::ffff:127.0.0.1'),
          isTrue,
        );
      });

      test('IPv4-mapped IPv6 metadata (::ffff:169.254.169.254) is blocked', () {
        expect(
          AutomationService.isBlockedWebhookHost('::ffff:169.254.169.254'),
          isTrue,
        );
      });

      // Regression: the IPv4-mapped path once omitted the CGNAT range that the
      // plain-IPv4 path blocked; both now share one classifier.
      test('IPv4-mapped IPv6 CGNAT (::ffff:100.64.0.1) is blocked', () {
        expect(
          AutomationService.isBlockedWebhookHost('::ffff:100.64.0.1'),
          isTrue,
        );
      });
    });

    // ── Bracketed IPv6: guarded via Uri.host, not the classifier ──

    group('bracketed IPv6 is handled by Uri.host before the classifier', () {
      test('classifier alone does NOT parse a bracketed literal', () {
        // The classifier is fed `Uri.host`, so it never sees brackets. On its
        // own, `[::1]` is not a parseable IP literal and is treated as a
        // (non-blocked) hostname. This documents WHY the guard relies on the
        // Uri.host bracket-strip below rather than parsing brackets itself.
        expect(AutomationService.isBlockedWebhookHost('[::1]'), isFalse);
      });

      test('Uri.host strips the brackets, and ::1 is then blocked', () {
        // This is the real runtime path: sendWebhook passes uri.host, which
        // is already unbracketed, so loopback IPv6 is still refused.
        final host = Uri.parse('https://[::1]:8080/hook').host;
        expect(host, '::1');
        expect(AutomationService.isBlockedWebhookHost(host), isTrue);
      });
    });
  });

  // ── NOT covered (documented gaps) ──────────────────────────────
  //
  // This classifier is intentionally synchronous and literal-only. The
  // following are OUT OF SCOPE and cannot be asserted without real network
  // or a fake resolver:
  //   * DNS-rebinding: a hostname such as `evil.example` that resolves to
  //     127.0.0.1 / 169.254.169.254 is NOT blocked here (the guard does not
  //     resolve names, by design, to avoid TOCTOU between check and connect).
  //   * HTTP redirects to an internal target after the initial POST.
  //   * Non-`https` schemes are rejected earlier in `sendWebhook`, not by
  //     this classifier.
}
