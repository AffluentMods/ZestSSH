# ZestSSH architecture

A map of the code as it is on `master`. For how to build and test, see [BUILDING.md](BUILDING.md). Most files open
with a comment that says what they are for; follow the paths below and read those.

## The stack

| Part | What is used |
|---|---|
| App | Flutter (version in `.fvmrc`), one `lib/` tree for Android, iOS, Windows, macOS and Linux |
| State | Riverpod (`flutter_riverpod`), providers in `lib/providers/` and beside each feature |
| Navigation | GoRouter (`lib/router/`) |
| Local data | Drift over SQLCipher (`lib/database/`), schema 56 |
| Secrets | the system's keystore, through `flutter_secure_storage` |
| SSH | `packages/zest_ssh_core`, in Dart |
| Terminal | `packages/xterm` |
| Native code | `packages/zest_native`, in Rust: FTPS, remote screens, Mosh, sound |
| Languages | 12, as ARB files in `lib/l10n/` (`flutter gen-l10n` writes `lib/l10n/generated/`, which is not in git) |

## The app: `lib/`

```
lib/
  main.dart      start: the main window, and the detached windows of a computer (editor, remote screen)
  app.dart       the root widget: lock, lifecycle, links, the things that run while the app is open
  config/        official_identity.dart (the build's addresses) and feature_flags.dart
  core/          shared catalogs, error codes, models and small widgets
  database/      the Drift database: database.dart, tables/, daos/, and the generated *.g.dart
  features/      one folder per feature (see below)
  l10n/          the app's words
  models/        types used across features (panes, tabs, workflows)
  providers/     Riverpod providers that are not owned by one feature
  router/        the routes (router.dart, routes.dart)
  services/      long-lived services and input/output
  theme/         colours, sizes, terminal themes
  ui/            screens (ui/screens/), shared widgets (ui/widgets/), the detached windows (ui/windows/)
  utils/         helpers
```

A computer and a phone share the code and differ in their shell: `lib/ui/screens/desktop/desktop_shell.dart` on
Windows, macOS and Linux, `lib/ui/screens/home/` on Android and iOS.

Some of `lib/features/`:

| Folder | What it holds |
|---|---|
| `hosts/`, `groups/`, `identity/`, `keys/`, `networks/` | hosts and their groups, sign-in details, keys, per-network settings |
| `terminal/`, `tmux/`, `broadcast/`, `triggers/`, `snippets/`, `command_history/` | the terminal and what runs in it |
| `sftp/` | files |
| `screens/` | remote screens (below) |
| `orchards/`, `teams/` | teams (below); `teams/` holds an account's keys |
| `sharing/` | sharing a live session |
| `automation/`, `monitoring/`, `workspaces/`, `shortcuts/`, `notifications/` | workflows and schedules, monitoring, saved layouts, keyboard shortcuts, the notification center |
| `tickets/`, `feedback/`, `help/`, `assistant/`, `changelog/`, `onboarding/` | support and help |

Some of `lib/services/`: `ssh_service.dart` and `ssh_connection_factory.dart` (an SSH session and how it is
dialled, jump hosts included), `sftp_service.dart`, `port_forward_service.dart`, `mosh_service.dart` and `mosh/`,
`eternal_terminal_service.dart`, `telnet_service.dart`, `serial_service.dart`, `local_shell_service.dart`,
`ftps/`, `sync_service.dart` and `sync/` (below), `backup/`, `fido/` and `hardware_token/` (security keys),
`ssh_cert/` (SSH certificates), `passkeys/`, `security_lock_service.dart` (the app lock),
`app_updater.dart` and `update_check_service.dart` (the updater of the computer builds).

Opening a host goes through `activeSessionsProvider` in `lib/providers/terminal_providers.dart`: it reads the host
and its sign-in details from the database, dials (through the host's jump hosts when it has any), and gives the
session to a terminal, a file browser or a remote screen.

## The packages: `packages/`

| Package | What it is |
|---|---|
| `zest_ssh_core/` | the SSH library, a fork of dartssh2 (MIT): transport, key exchange, ciphers, keys and certificates, SFTP, forwarding |
| `zest_native/` | the Rust library (below) and its Dart bindings |
| `xterm/` | the terminal emulator and its renderer, a fork of xterm.dart (MIT) |
| `lucide_icons/` | the Lucide icons for Flutter, a fork (ISC) |
| `desktop_multi_window/` | detached windows on a computer, a fork (Apache-2.0) |
| `speech_to_text_windows/` | speech to text on Windows, a fork (BSD-3-Clause) |

### `zest_native`

The crate is `packages/zest_native/rust`. Its build hook (`hook/build.dart`) runs `cargo build --release --locked`
for the platform's target on every Flutter build and test run, and the Dart side calls it through `dart:ffi`
(`lib/src/*bindings.dart`). The app turns its cargo features on in `pubspec.yaml` (`cargo_features`): `vnc`, `rdp`,
`mosh` and `sound`.

| Module (`rust/src/`) | What it does |
|---|---|
| `ftps/` | FTPS (always built) |
| `vnc/` | VNC: an RFB engine forked from vnc-rs (`vnc/engine`) |
| `rdp/` | RDP through IronRDP, with the crate's own TLS (rustls with ring) |
| `screen/` | a remote screen's session for both protocols: the frame buffer, RDP's graphics, clipboard, layout and sound (`rdp_sound.rs`, played through cpal), and RD Gateway (`rdp_gateway.rs`) |
| `mosh/` | a Mosh client, so a Mosh host opens without a mosh program on the device |

Five IronRDP crates are vendored with changes under `rust/vendor/` (ironrdp-connector, ironrdp-dvc, ironrdp-graphics, ironrdp-rdpsnd and ironrdp-session), each with a `NOTICE-ZESTSSH` that says exactly what changed and from which upstream commit. The fuzz targets are in `rust/fuzz/`.

## The database

`lib/database/database.dart` defines `AppDatabase` (Drift). The file is encrypted with SQLCipher and its key is
kept in the system's keystore. A debug build keeps its database unencrypted.

- The schema version is `AppDatabase.currentSchemaVersion`, 56 on `master`. There are 36 tables
  (`lib/database/tables/`): hosts (`connections`), sign-in details (`identities`), groups, tags, known host keys,
  snippets, port forwards, networks, workflows and schedules, monitoring samples, command history, the tombstones
  sync uses, local state, the support tickets, and the tables a team's database uses.
- Migrations are the `if (from < N)` steps of `onUpgrade`, in order, never renumbered. Before migrating, the app
  copies the database file and counts each table's rows; after, it compares the counts. `test/database/` has a test
  for the steps (`migration_v*_test.dart`).
- The generated code (`*.g.dart`) is in git. After changing a table or a DAO, run `dart run build_runner build`.

## Sync

A person's own data is synced as one encrypted file. `lib/services/sync_service.dart` is the cryptography and does
no network work; the transports are behind `SyncBackend` (`lib/services/sync/`).

- A random 256-bit data key encrypts the data (JSON, zlib, AES-256-GCM). That key is wrapped twice: by a key derived
  from the sync password with Argon2id, and by one derived from the recovery key. Changing the password wraps the
  data key again and leaves the data as it is.
- The Argon2id parameters travel with the file. The app refuses parameters weaker than the weakest it has ever
  written, and ones above a safe maximum.
- No store sees the data, the data key, the password or the recovery key.
- The stores: ZestSSH Cloud and a server of your own (`zest_server_backend.dart`), WebDAV, S3-compatible storage
  and Google Drive (the three that extend `dumb_store_sync_backend.dart`). The guide for your own storage is
  [docs/self-hosted-sync.md](docs/self-hosted-sync.md).

## Teams

In the code a team is an Orchard, a team vault is a Crate, and a person's own space is the Tree. Teams are compiled
in with `ZEST_ORCHARDS=true` and need a ZestSSH Cloud account. The code is in `lib/features/orchards/`.

- **A database per team.** Each team has its own database file (`orchards/<id>.db` beside the person's own), with
  the same schema, opened by `AppDatabase.orchard`, which adds the triggers that note every change of an item for
  its vault's sync.
- **The record** (`record/orchard_record.dart`). A team's members, roles and rights are an append-only chain of
  entries, each signed by the member who made the change and naming the hash of the entry before it. Every member's
  app works out who is in the team and what each may do from the chain alone; the server applies the same rules.
- **Keys** (`crypto/orchard_crypto.dart`, `lib/features/teams/crypto/`). A team's key and each vault's key are
  random, sealed to each member's account key and signed by the account that sealed them. A device opens a copy
  only when it matches the commitment in the signed record entry that made it.
- **Sync** (`sync/crate_sync_engine.dart`). The items of a vault are encrypted under the vault's key before they
  leave the device.

## Remote screens

`lib/features/screens/` is the app's side: the session (`session/`), the view and its input (`view/`, `desktop/`,
`phone/`, `window/`), and the Proxmox console (`proxmox/`). The engine is `zest_native` (above).

- VNC and RDP. Where a remote screen's bytes go is a `ScreenTarget` (`session/screen_target.dart`): through an SSH
  host (its carrier) to an address and port, to a Unix socket on that host or to an X program started there; to a
  Proxmox guest's console; or, with no carrier, straight to the server (a VNC server only over TLS with a
  certificate). An RDP host can be reached through an RD Gateway (`session/screen_gateway_route.dart`).
- A team can set rules for remote screens (`session/screen_team_rules.dart`).
- On a computer a remote screen can be moved to a window of its own.

## Community build and official build

Every setting is a compile-time define with a default; `.env.example` lists them.

- A build without `ZEST_OFFICIAL=true` is a community build. It has no accounts, ZestSSH Cloud, teams, plans,
  tickets or updater, and no links to a website, unless the build names its own addresses.
- `lib/config/official_identity.dart` holds every address of the official builds (the API, the website, the docs,
  the update host and its key, the store listings) and the define that replaces each. The rest of the code reads
  them from there.
- `ZEST_BUILD_NAME` names a build in About and in copied reports.

## Tests

| What | How |
|---|---|
| The app | `flutter test --no-pub --dart-define=ZEST_ORCHARDS=true` (`test/`, laid out like `lib/`) |
| The repository's guards | `test/docs/`: licences and notices, the Rust advisories, the error codes, demo names and addresses in tests, the open source tree, platform build files |
| The SSH library | `dart test -x integration` in `packages/zest_ssh_core` |
| The native library | `cargo test --features vnc,rdp,mosh` in `packages/zest_native/rust` |
| On a device | `integration_test/` |

Tests that need a server skip themselves when it is not there; `tool/` has the scripts that start the local SSH,
FTPS and remote screen servers. [BUILDING.md](BUILDING.md), section 7, has the details.

## Conventions

- Every word a person sees is in all the ARB files of `lib/l10n/`.
- Colours and sizes come from `lib/theme/`.
- Errors carry a code. The codes are listed in `lib/core/errors/error_codes.dart`, `docs/ERROR-CODES.md` is written
  from that list, and `test/docs/error_codes_test.dart` checks both.
- Never run `dart format` on a directory.
