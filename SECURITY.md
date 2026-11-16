# Security policy

This is the disclosure policy published at https://zestssh.com/security-disclosure, in short. Where the two differ,
the page on the website is the one that applies.

## Reporting a vulnerability

Please do not open a public issue, discussion or pull request for a security problem.

Email **support@zestssh.com** with:

- a description of the vulnerability,
- steps to reproduce it, ideally with a proof of concept,
- the affected versions and platforms, and anything about the setup that matters,
- how you would like us to reply, and your name or handle if you want credit.

For something especially sensitive, ask for a PGP key first and we exchange one. The machine-readable contact is
https://zestssh.com/.well-known/security.txt.

ZestSSH is built and maintained by one person, who reads and answers every report personally.

## What happens next

1. **Acknowledgment** within 5 business days of your report.
2. **Triage** within 14 days: how severe and how exploitable, and a timeline or a plan.
3. **Fix** in proportion to severity. A critical issue comes before any other work.
4. **Disclosure** coordinated with you. The preferred window is 14 days, for every severity.
5. **Credit** in the release notes and on the disclosure page, if you want it.

If you need a faster disclosure for safety reasons, such as active exploitation, say so and we coordinate. What a
validated finding receives is on the disclosure page.

## Scope

In scope:

- the ZestSSH apps for phones, tablets and computers (this repository),
- ZestSSH Cloud and its API, including teams, session sharing and the sign-in checks for company sign-in,
- the websites zestssh.com and docs.zestssh.com,
- the Automation API, its keys and what it can run,
- backup file (`.zest`) encryption,
- cryptographic design issues in the whitepaper.

Out of scope:

- third-party dependencies (report them upstream, and tell us so we can pin around the fix),
- social engineering of the developer, or physical attacks on the developer's hardware,
- issues that need a compromised, rooted or jailbroken device to begin with,
- denial of service attacks,
- self-XSS, and other issues that need a person to paste an attacker's input somewhere privileged,
- beta or preview features clearly marked as experimental.

## Builds made by others

A build made from this source by someone else is not the app Affluent Labs LLC ships. Report a problem in the source
here; report a problem that exists only in someone's modified build to whoever made it.

## Safe harbor

We will not pursue legal action against researchers who make a good-faith effort to avoid privacy violations,
destroying data and disrupting the service; use only accounts they own or have explicit permission to test; do not
attack other users, production infrastructure at scale, or neighboring services; report promptly and give us
reasonable time to fix the issue before any public disclosure; and do not exploit the issue beyond what shows its
impact, and stay within the law. The full wording is on the disclosure page.

## Supported versions

Security fixes go into the latest released version on each platform. Please check that a problem is still there in
the latest release before you report it.
