# Contributing to ZestSSH

Thank you for wanting to help. ZestSSH is maintained by one person, so small, focused changes get reviewed fastest.

## Before you start

- **A bug:** open an issue with the bug report form first, unless the fix is a few lines.
- **A feature or a change of behaviour:** open an issue and wait for a reply before writing code. Not every feature
  fits, and it is better to hear that before the work than after.
- **A security problem:** do not open an issue. See [SECURITY.md](SECURITY.md).

## Building and testing

[BUILDING.md](BUILDING.md) takes a clean machine to a running build on each platform, with none of the official
services. In short:

```
flutter pub get
flutter gen-l10n
flutter test --no-pub --dart-define=ZEST_ORCHARDS=true
```

- Run the tests before you open a pull request, and add a test with every fix: one that fails without your change
  and passes with it.
- `flutter analyze` must report no new issue.
- Some tests need local test servers (`tool/test_sshd.sh` and others) and skip themselves without them.
  BUILDING.md lists them.
- In `packages/zest_ssh_core`, run `dart test -x integration`: the tests tagged `integration` connect to public test
  hosts on the internet.

## House rules for a change

- **Text a person sees goes through localization.** Add a key to `lib/l10n/app_en.arb` with a description, and an
  entry for it in each of the other eleven `.arb` files. A string written in code is refused.
- **No em dash or en dash characters** anywhere: code, strings, comments, docs, commit messages.
- **Never run `dart format` on a directory.** Format only the lines you change.
- **One change per pull request.** Do not mix a fix with a refactor or a rename.
- **Commit messages say what changed and why**, in plain sentences. A reported bug is traced to the version that has
  it by these messages.
- **Demo data only** in tests, screenshots and docs: made-up hosts and addresses from the documentation ranges
  (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, `example.com`). Never a real host, address, account or key.
- **No new dependency without asking first.** It must be under a licence that `tool/licence_policy.yaml` allows, and
  `dart run tool/licence_check.dart` must pass.
- **Do not copy code from other projects** unless its licence is one of those, and say where it came from. Never
  GPL, LGPL or AGPL code written by others: the official builds could not ship it.

## Licence of contributions

ZestSSH is licensed under the GNU General Public License version 3 with an additional permission under its
section 7 ([LICENSE](LICENSE), [LICENSE-EXCEPTION.txt](LICENSE-EXCEPTION.txt) and [NOTICE](NOTICE)). The packages
under `packages/` that carry a LICENSE file of their own stay under it: `zest_ssh_core` and `xterm` under MIT, for
example. A contribution to one of those folders is made under that folder's licence.

Before we can merge your first pull request you need to agree to the ZestSSH Individual Contributor License Agreement
([CLA.md](CLA.md)): tick its box in the pull request template, or write the sentence it gives in your pull request. You keep your copyright. The agreement gives
Affluent Labs LLC the right to distribute your contribution under other terms as well, which is what lets us publish
the official builds in the app stores, link the libraries of the stores and payment providers they use, and change
the licence later. In return we promise that your contribution stays available under the open-source licence.

Also sign off every commit (`git commit -s`): the sign-off states, as the Developer Certificate of Origin 1.1
(https://developercertificate.org) describes, that you wrote the change or have the right to submit it.

## How a change lands

The source of each release is published here. A pull request is reviewed here; when it is taken, it is applied to
our development tree with you as its author, and it appears here with the next published source. The pull request is
then closed with a note that names the commit that contains it.

## Builds you give to others

You may build, change and share ZestSSH under the licence. A build you give to others must not use the ZestSSH name,
icon or application id, must not talk to the official service, and must have its own update channel. See
[TRADEMARKS.md](TRADEMARKS.md).
